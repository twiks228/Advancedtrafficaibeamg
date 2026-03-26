-- ============================================================================
-- accidentReaction.lua
-- Traffic reaction to accidents: stopping, rubbernecking, rerouting,
-- hazard lights, traffic jam formation
-- BeamNG.drive 0.38.3
-- ============================================================================

local M = {}

-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Detection ranges
local ACCIDENT_DETECTION_RANGE = 100  -- meters: how far to detect an accident
local WRECK_DETECTION_RANGE    = 60   -- meters: detect stopped/damaged vehicles
local JAM_PROPAGATION_RANGE    = 150  -- meters: how far back a jam extends

--- Speed thresholds for "accident" detection
local ACCIDENT_SPEED_THRESHOLD = 5    -- km/h: vehicles below this are "stopped"
local COLLISION_DECEL_THRESHOLD = 30  -- km/h per second: sudden deceleration

--- Timing
local RUBBERNECK_SLOW_FACTOR   = 0.5 -- slow down to 50% when passing an accident
local ACCIDENT_CLEAR_TIME      = 30  -- seconds before accident is "cleared"
local MIN_STOP_TIME_AT_JAM     = 2   -- seconds minimum stop in jam
local JAM_CRAWL_SPEED          = 8   -- km/h: crawling speed in jam

--- Pass-around behavior
local PASS_AROUND_MIN_WIDTH    = 6   -- meters: minimum road width to pass around
local PASS_AROUND_OFFSET       = 4   -- meters: lateral offset when passing wreckage
local PASS_AROUND_SPEED        = 15  -- km/h: speed when passing accident scene

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Known accident sites
local accidentSites = {}
--[[ Structure:
  {
    id = string,
    position = vec3,
    involvedVehicles = { [vehId] = true },
    discoveredAt = number,       -- sim time
    severity = "minor" | "major" | "blocking",
    isCleared = false,
    blockingLanes = { 1, 2 },    -- which lanes are blocked
    freePassSide = "left" | "right" | nil,
  }
]]

--- Per-vehicle accident awareness
local vehicleAccidentStates = {}
--[[ Structure:
  {
    nearestAccident = string|nil,   -- accident site ID
    distToAccident = number,
    reaction = "none" | "slowing" | "stopped" | "passing" | "rubbernecking",
    jamPosition = number,           -- position in the jam queue (1 = first)
    stopTimer = 0,
    passOffset = 0,
    hazardActive = false,
    previousSpeed = 0,              -- speed before encountering jam
  }
]]

--- Vehicle velocity history for collision detection
local velocityHistory = {} -- { [vehId] = { prevSpeed, prevPrevSpeed } }

local nextAccidentId = 0
local simTime = 0

-- ══════════════════════════════════════════════════════════════════════════════
-- INIT
-- ══════════════════════════════════════════════════════════════════════════════

function M.init()
  accidentSites = {}
  vehicleAccidentStates = {}
  velocityHistory = {}
  nextAccidentId = 0
  simTime = 0
  log("I", "TrafficAI.AccidentReaction", "Accident reaction system initialized.")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════════════════════════════════

local function getVehAccState(vehId)
  if not vehicleAccidentStates[vehId] then
    vehicleAccidentStates[vehId] = {
      nearestAccident  = nil,
      distToAccident   = math.huge,
      reaction         = "none",
      jamPosition      = 0,
      stopTimer        = 0,
      passOffset       = 0,
      hazardActive     = false,
      previousSpeed    = 0,
    }
  end
  return vehicleAccidentStates[vehId]
end

local function generateAccidentId()
  nextAccidentId = nextAccidentId + 1
  return "accident_" .. nextAccidentId
end

--- Get road width at a position
local function getRoadWidthAt(pos)
  local mapData = map and map.getMap() or nil
  if not mapData or not mapData.nodes then return 8 end

  local closestNode, closestDist = nil, math.huge
  for _, nodeData in pairs(mapData.nodes) do
    if nodeData.pos then
      local d = (pos - nodeData.pos):length()
      if d < closestDist then
        closestDist = d
        closestNode = nodeData
      end
    end
  end

  if closestNode then
    return (closestNode.radius or 4) * 2
  end
  return 8
end

-- ══════════════════════════════════════════════════════════════════════════════
-- ACCIDENT DETECTION
-- ══════════════════════════════════════════════════════════════════════════════

--- Detect new accidents by monitoring sudden decelerations and collisions
---@param allVehicles table
---@param dt number
local function detectNewAccidents(allVehicles, dt)
  for vehId, aiState in pairs(allVehicles) do
    -- Track velocity history
    if not velocityHistory[vehId] then
      velocityHistory[vehId] = {
        prevSpeed = aiState.currentSpeed,
        prevPrevSpeed = aiState.currentSpeed,
        stoppedTime = 0,
      }
    end

    local vh = velocityHistory[vehId]

    -- Check for sudden deceleration (possible collision)
    local decel = (vh.prevSpeed - aiState.currentSpeed) / math.max(0.01, dt)

    if decel > COLLISION_DECEL_THRESHOLD and vh.prevSpeed > 20 then
      -- Sudden decel from speed > 20 km/h → likely collision
      -- Check if this vehicle is already part of a known accident
      local alreadyKnown = false
      for _, site in pairs(accidentSites) do
        if site.involvedVehicles[vehId] then
          alreadyKnown = true
          break
        end
        -- Also check proximity to existing accident
        if (aiState.position - site.position):length() < 20 then
          site.involvedVehicles[vehId] = true
          alreadyKnown = true
          break
        end
      end

      if not alreadyKnown then
        -- New accident!
        local accId = generateAccidentId()
        local roadWidth = getRoadWidthAt(aiState.position)

        -- Determine severity
        local severity = "minor"
        if decel > COLLISION_DECEL_THRESHOLD * 2 then
          severity = "major"
        end
        if decel > COLLISION_DECEL_THRESHOLD * 3 then
          severity = "blocking"
        end

        -- Determine which side is free for passing
        local freePassSide = nil
        if roadWidth > PASS_AROUND_MIN_WIDTH then
          freePassSide = "right" -- default: pass on right
        end

        accidentSites[accId] = {
          id = accId,
          position = vec3(aiState.position.x, aiState.position.y, aiState.position.z),
          involvedVehicles = { [vehId] = true },
          discoveredAt = simTime,
          severity = severity,
          isCleared = false,
          blockingLanes = {},
          freePassSide = freePassSide,
          roadWidth = roadWidth,
        }

        log("I", "TrafficAI.AccidentReaction",
          string.format("ACCIDENT DETECTED: %s at (%.0f, %.0f) severity=%s veh=%d decel=%.0f km/h/s",
            accId, aiState.position.x, aiState.position.y,
            severity, vehId, decel))
      end
    end

    -- Track vehicles that have been stopped for a long time (possible wreck)
    if aiState.currentSpeed < ACCIDENT_SPEED_THRESHOLD then
      vh.stoppedTime = vh.stoppedTime + dt

      if vh.stoppedTime > 10 then -- stopped for 10+ seconds
        -- Check if vehicle has damage
        local vehObj = be:getObjectByID(vehId)
        if vehObj then
          -- Check if it's on a road (not parked)
          local roadWidth = getRoadWidthAt(aiState.position)
          if roadWidth > 4 then
            -- Might be blocking traffic
            local alreadyKnown = false
            for _, site in pairs(accidentSites) do
              if site.involvedVehicles[vehId] or
                 (aiState.position - site.position):length() < 15 then
                alreadyKnown = true
                break
              end
            end

            if not alreadyKnown and vh.stoppedTime > 15 then
              local accId = generateAccidentId()
              accidentSites[accId] = {
                id = accId,
                position = vec3(aiState.position.x, aiState.position.y, aiState.position.z),
                involvedVehicles = { [vehId] = true },
                discoveredAt = simTime,
                severity = "minor",
                isCleared = false,
                blockingLanes = {},
                freePassSide = "right",
                roadWidth = roadWidth,
              }
              log("I", "TrafficAI.AccidentReaction",
                string.format("STALLED VEHICLE detected as obstacle: %s veh=%d", accId, vehId))
            end
          end
        end
      end
    else
      if vh then
        vh.stoppedTime = 0
      end
    end

    -- Update velocity history
    vh.prevPrevSpeed = vh.prevSpeed
    vh.prevSpeed = aiState.currentSpeed
  end
end

--- Check if accidents should be cleared
local function updateAccidentSites()
  for accId, site in pairs(accidentSites) do
    if not site.isCleared then
      local timeSince = simTime - site.discoveredAt

      -- Check if involved vehicles have moved away
      local allMoved = true
      for vehId, _ in pairs(site.involvedVehicles) do
        local vehObj = be:getObjectByID(vehId)
        if vehObj then
          local pos = vehObj:getPosition()
          if (pos - site.position):length() < 15 then
            allMoved = false
            break
          end
        end
        -- Vehicle destroyed — still blocking as wreckage
      end

      if allMoved or timeSince > ACCIDENT_CLEAR_TIME then
        site.isCleared = true
        log("I", "TrafficAI.AccidentReaction",
          string.format("Accident %s cleared after %.0fs", accId, timeSince))
      end
    end
  end

  -- Remove old cleared accidents
  for accId, site in pairs(accidentSites) do
    if site.isCleared and simTime - site.discoveredAt > ACCIDENT_CLEAR_TIME * 2 then
      accidentSites[accId] = nil
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- JAM FORMATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Calculate jam queue position for a vehicle relative to an accident
---@param aiState table
---@param site table
---@param allVehicles table
---@return number queuePosition  (1 = closest to accident, higher = further back)
local function calculateJamPosition(aiState, site, allVehicles)
  local myDist = (aiState.position - site.position):length()
  local position = 1

  for otherId, otherState in pairs(allVehicles) do
    if otherId ~= aiState.vehicleId then
      local otherDist = (otherState.position - site.position):length()
      -- Count vehicles that are between us and the accident
      if otherDist < myDist and otherDist < JAM_PROPAGATION_RANGE then
        -- Check if they're on the same road/direction
        local toAccident = (site.position - aiState.position):normalized()
        local otherToAccident = (site.position - otherState.position):normalized()
        if toAccident:dot(otherToAccident) > 0.5 then
          position = position + 1
        end
      end
    end
  end

  return position
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PER-VEHICLE ACCIDENT RESPONSE
-- ══════════════════════════════════════════════════════════════════════════════

--- Process accident awareness and reaction for a single vehicle
---@param vehObj userdata
---@param aiState table
---@param dt number
---@param allVehicles table
local function processAccidentReaction(vehObj, aiState, dt, allVehicles)
  local vehId = aiState.vehicleId
  local vas = getVehAccState(vehId)
  local pos = aiState.position
  local dir = aiState.direction

  -- ── Find nearest active accident ahead ─────────────────────────────────
  local nearestSite = nil
  local nearestDist = math.huge

  for accId, site in pairs(accidentSites) do
    if not site.isCleared and not site.involvedVehicles[vehId] then
      local toSite = site.position - pos
      local distAhead = toSite:dot(dir) -- only consider accidents ahead

      if distAhead > 0 and distAhead < ACCIDENT_DETECTION_RANGE then
        if distAhead < nearestDist then
          nearestDist = distAhead
          nearestSite = site
        end
      end
    end
  end

  -- ── No accident nearby ─────────────────────────────────────────────────
  if not nearestSite then
    if vas.reaction ~= "none" then
      -- Was reacting, now clear
      if vas.hazardActive then
        vas.hazardActive = false
        vehObj:queueLuaCommand('electrics.set("hazard", 0)')
      end
      vas.reaction = "none"
      vas.nearestAccident = nil
      vas.distToAccident = math.huge
      vas.passOffset = 0
    end
    return
  end

  vas.nearestAccident = nearestSite.id
  vas.distToAccident = nearestDist

  -- Get personality for reaction style
  local personality = aiState.personality
  local attentionLevel = (personality and personality.attentionLevel) or 0.9
  local reactionTime = (personality and personality.reactionTime) or 0.5

  -- Distracted drivers notice accidents later
  if personality and personality.attentionState == "distracted" then
    if nearestDist > 40 then
      return -- doesn't see it yet
    end
  end

  -- ══════════════════════════════════════════════════════════════════════════
  -- REACTION STATE MACHINE
  -- ══════════════════════════════════════════════════════════════════════════

  if vas.reaction == "none" then
    -- ── First detection ──────────────────────────────────────────────────
    if nearestDist < ACCIDENT_DETECTION_RANGE then
      vas.reaction = "slowing"
      vas.previousSpeed = aiState.currentSpeed

      -- Turn on hazard lights
      vas.hazardActive = true
      vehObj:queueLuaCommand('electrics.set("hazard", 1)')

      -- Calculate jam position
      vas.jamPosition = calculateJamPosition(aiState, nearestSite, allVehicles)

      log("D", "TrafficAI.AccidentReaction",
        string.format("Veh %d: noticed accident %s at %.0fm, jam pos=%d",
          vehId, nearestSite.id, nearestDist, vas.jamPosition))
    end

  elseif vas.reaction == "slowing" then
    -- ── Gradually slowing down ───────────────────────────────────────────
    local slowFactor = math.max(0.1, nearestDist / ACCIDENT_DETECTION_RANGE)
    local targetSpeed = aiState.currentSpeedLimit * slowFactor

    -- Cap at crawl speed when close
    if nearestDist < 30 then
      targetSpeed = math.min(targetSpeed, JAM_CRAWL_SPEED)
    end

    aiState.currentSpeedLimit = math.min(aiState.currentSpeedLimit, targetSpeed)

    -- If very close and accident is blocking, stop
    if nearestDist < 15 and nearestSite.severity == "blocking" then
      vas.reaction = "stopped"
      vas.stopTimer = 0
    elseif nearestDist < 20 and nearestSite.freePassSide then
      -- Can pass around
      vas.reaction = "passing"
      vas.passOffset = 0
    elseif nearestDist < 10 then
      -- Too close, stop
      vas.reaction = "stopped"
      vas.stopTimer = 0
    end

  elseif vas.reaction == "stopped" then
    -- ── Stopped in jam ───────────────────────────────────────────────────
    vas.stopTimer = vas.stopTimer + dt
    aiState.waitingAtSignal = true -- force stop

    -- Check if there's room to pass
    if nearestSite.freePassSide and vas.stopTimer > MIN_STOP_TIME_AT_JAM then
      -- Check if vehicle ahead has moved
      local canPass = true
      for otherId, otherState in pairs(allVehicles) do
        if otherId ~= vehId then
          local toOther = otherState.position - pos
          local otherAhead = toOther:dot(dir)
          if otherAhead > 2 and otherAhead < 10 then
            local lateral = math.sqrt(math.max(0,
              toOther:lengthSquared() - otherAhead * otherAhead))
            if lateral < 3 and otherState.currentSpeed < 3 then
              canPass = false -- someone stopped ahead, wait
              break
            end
          end
        end
      end

      if canPass then
        vas.reaction = "passing"
        vas.passOffset = 0
        aiState.waitingAtSignal = false
        log("D", "TrafficAI.AccidentReaction",
          string.format("Veh %d: starting to pass accident %s",
            vehId, nearestSite.id))
      end
    end

    -- Slowly creep forward in jam after waiting
    if vas.stopTimer > MIN_STOP_TIME_AT_JAM * 2 then
      -- Allow crawl speed
      aiState.waitingAtSignal = false
      aiState.currentSpeedLimit = JAM_CRAWL_SPEED
    end

  elseif vas.reaction == "passing" then
    -- ── Carefully passing the accident scene ─────────────────────────────
    local passSide = nearestSite.freePassSide or "right"

    -- Gradually increase lateral offset
    local targetOffset = PASS_AROUND_OFFSET * ((passSide == "right") and 1 or -1)
    local rampSpeed = 2.0 -- meters per second lateral movement
    local offsetDiff = targetOffset - vas.passOffset

    if math.abs(offsetDiff) > 0.1 then
      local step = rampSpeed * dt * (offsetDiff > 0 and 1 or -1)
      if math.abs(step) > math.abs(offsetDiff) then
        vas.passOffset = targetOffset
      else
        vas.passOffset = vas.passOffset + step
      end
    end

    -- Apply offset
    vehObj:queueLuaCommand(string.format(
      'ai.driveUsingPath({avoidCars = "on", routeOffset = %.2f})',
      vas.passOffset
    ))

    -- Limit speed while passing
    aiState.currentSpeedLimit = math.min(aiState.currentSpeedLimit, PASS_AROUND_SPEED)

    -- Check if we've passed the accident
    local toSite = nearestSite.position - pos
    local behindUs = toSite:dot(dir)

    if behindUs < -10 then
      -- We've passed! Transition to rubbernecking
      vas.reaction = "rubbernecking"
      vas.stopTimer = 0
      log("D", "TrafficAI.AccidentReaction",
        string.format("Veh %d: passed accident, rubbernecking", vehId))
    end

  elseif vas.reaction == "rubbernecking" then
    -- ── Slowing down to look at the accident (human nature) ──────────────
    vas.stopTimer = vas.stopTimer + dt

    -- Slow down for a bit
    aiState.currentSpeedLimit = aiState.currentSpeedLimit * RUBBERNECK_SLOW_FACTOR

    -- Gradually return to lane
    if math.abs(vas.passOffset) > 0.1 then
      vas.passOffset = vas.passOffset * (1 - dt * 0.5)
      vehObj:queueLuaCommand(string.format(
        'ai.driveUsingPath({avoidCars = "on", routeOffset = %.2f})',
        vas.passOffset
      ))
    end

    -- After rubbernecking period, return to normal
    if vas.stopTimer > 5.0 then
      vas.reaction = "none"
      vas.passOffset = 0
      vas.nearestAccident = nil
      vas.distToAccident = math.huge

      -- Turn off hazards
      if vas.hazardActive then
        vas.hazardActive = false
        vehObj:queueLuaCommand('electrics.set("hazard", 0)')
      end

      -- Reset route offset
      vehObj:queueLuaCommand('ai.driveUsingPath({avoidCars = "on", routeOffset = 0})')
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UPDATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Update accident detection and reaction for all vehicles
---@param vehObj userdata
---@param aiState table
---@param dt number
---@param allVehicles table
function M.update(vehObj, aiState, dt, allVehicles)
  simTime = simTime + dt

  -- Global: detect new accidents and update existing ones
  -- (run once per cycle, not per vehicle — use a flag)
  if aiState.vehicleId == next(allVehicles) then
    detectNewAccidents(allVehicles, dt)
    updateAccidentSites()
  end

  -- Per-vehicle: reaction to nearby accidents
  processAccidentReaction(vehObj, aiState, dt, allVehicles)

  -- Write state to aiState
  local vas = getVehAccState(aiState.vehicleId)
  aiState.accidentReaction = vas.reaction
  aiState.accidentDistance = vas.distToAccident
  aiState.isInJam = (vas.reaction == "stopped" or vas.reaction == "slowing")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

--- Get all active accident sites
function M.getAccidentSites()
  return accidentSites
end

--- Get accident count
function M.getActiveAccidentCount()
  local count = 0
  for _, site in pairs(accidentSites) do
    if not site.isCleared then count = count + 1 end
  end
  return count
end

--- Manually register an accident at a position
---@param pos vec3
---@param severity string "minor" | "major" | "blocking"
function M.registerAccident(pos, severity)
  local accId = generateAccidentId()
  accidentSites[accId] = {
    id = accId,
    position = vec3(pos.x, pos.y, pos.z),
    involvedVehicles = {},
    discoveredAt = simTime,
    severity = severity or "major",
    isCleared = false,
    blockingLanes = {},
    freePassSide = "right",
    roadWidth = getRoadWidthAt(pos),
  }
  log("I", "TrafficAI.AccidentReaction",
    string.format("Manual accident registered: %s at (%.0f, %.0f)", accId, pos.x, pos.y))
  return accId
end

--- Clear a specific accident
function M.clearAccident(accId)
  if accidentSites[accId] then
    accidentSites[accId].isCleared = true
  end
end

function M.removeVehicle(vehId)
  vehicleAccidentStates[vehId] = nil
  velocityHistory[vehId] = nil
end

return M