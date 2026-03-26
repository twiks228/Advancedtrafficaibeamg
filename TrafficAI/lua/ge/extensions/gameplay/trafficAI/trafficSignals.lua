-- ============================================================================
-- trafficSignals.lua
-- Traffic signals, stop signs, yield signs, and priority (right-of-way) logic
-- ============================================================================

local M = {}

-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Distance at which to start detecting upcoming signals/signs (meters)
local SIGNAL_DETECTION_RANGE = 80

--- Distance at which to begin braking for a red light (meters)
local BRAKE_START_DISTANCE = 50

--- Distance at which vehicle must be fully stopped at a red/stop sign (meters)
local STOP_LINE_DISTANCE = 4

--- How long to wait at a stop sign before proceeding (seconds)
local STOP_SIGN_WAIT_TIME = 2.0

--- How long to wait after light turns green before accelerating (reaction time)
local GREEN_REACTION_TIME = 0.5

--- Distance to check for cross-traffic at intersections (meters)
local CROSS_TRAFFIC_CHECK_DIST = 40

--- Right-of-way check: how far to scan for vehicles on the right
local RIGHT_OF_WAY_SCAN_DIST = 30

-- Signal phases
local SIGNAL_PHASE = {
  RED    = "red",
  YELLOW = "yellow",
  GREEN  = "green",
}

-- Sign types
local SIGN_TYPE = {
  NONE      = "none",
  STOP      = "stop_sign",
  YIELD     = "yield",
  PRIORITY  = "priority",   -- this road has priority
}

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Virtual traffic signals for intersections that don't have them
--- In BeamNG, most maps don't have proper signal objects, so we create virtual ones
local virtualSignals = {}  -- { [intersectionNodeId] = { phase, timer, ... } }

--- Per-vehicle signal interaction state
local vehicleSignalStates = {} -- { [vehId] = { ... } }

--- Simulated signal timing
local SIGNAL_TIMING = {
  greenDuration  = 25,  -- seconds
  yellowDuration = 4,   -- seconds
  redDuration    = 25,  -- seconds (should match opposing green + yellow)
}

-- ══════════════════════════════════════════════════════════════════════════════
-- INIT
-- ══════════════════════════════════════════════════════════════════════════════

function M.init()
  virtualSignals = {}
  vehicleSignalStates = {}
  M.buildVirtualSignals()
  log("I", "TrafficAI.Signals", "Traffic signals module initialized.")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- VIRTUAL SIGNAL GENERATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Scan the map and create virtual traffic signals at intersections
function M.buildVirtualSignals()
  local mapData = map and map.getMap() or nil
  if not mapData or not mapData.nodes then
    log("W", "TrafficAI.Signals", "No map data available for signal generation.")
    return
  end

  local signalCount = 0

  for nodeId, nodeData in pairs(mapData.nodes) do
    -- Count connections: 3+ connections = intersection
    local linkCount = 0
    local linkedNodes = {}
    if nodeData.links then
      for linkedId, _ in pairs(nodeData.links) do
        linkCount = linkCount + 1
        table.insert(linkedNodes, linkedId)
      end
    end

    if linkCount >= 3 then
      -- This is an intersection — create a virtual signal
      local roadWidth = (nodeData.radius or 4) * 2
      local signalType

      if roadWidth >= 12 then
        -- Major intersection: traffic light
        signalType = "traffic_light"
      elseif roadWidth >= 8 then
        -- Medium intersection: stop sign or yield
        signalType = "stop_sign"
      else
        -- Small intersection: yield / right-of-way
        signalType = "yield"
      end

      -- Determine which approaches get which signal phase
      -- For traffic lights, alternate phases between road directions
      local approaches = {}
      for i, linkedId in ipairs(linkedNodes) do
        local linkedNode = mapData.nodes[linkedId]
        if linkedNode and linkedNode.pos and nodeData.pos then
          local approachDir = (nodeData.pos - linkedNode.pos):normalized()
          approaches[linkedId] = {
            direction = approachDir,
            -- Alternate groups: even = group A, odd = group B
            group = (i % 2 == 0) and "A" or "B"
          }
        end
      end

      virtualSignals[nodeId] = {
        pos = nodeData.pos,
        type = signalType,
        -- Traffic light state
        currentPhase = SIGNAL_PHASE.GREEN,
        activeGroup = "A",
        phaseTimer = math.random() * SIGNAL_TIMING.greenDuration, -- randomize start
        -- Approach data
        approaches = approaches,
        -- Stop sign state
        stopWaitTimers = {}, -- { [vehId] = waitedTime }
      }

      signalCount = signalCount + 1
    end
  end

  log("I", "TrafficAI.Signals",
    string.format("Generated %d virtual signals at intersections.", signalCount))
end

-- ══════════════════════════════════════════════════════════════════════════════
-- SIGNAL PHASE CYCLING
-- ══════════════════════════════════════════════════════════════════════════════

--- Update all virtual traffic light phases
---@param dt number
local function updateSignalPhases(dt)
  for nodeId, signal in pairs(virtualSignals) do
    if signal.type == "traffic_light" then
      signal.phaseTimer = signal.phaseTimer + dt

      if signal.currentPhase == SIGNAL_PHASE.GREEN then
        if signal.phaseTimer >= SIGNAL_TIMING.greenDuration then
          signal.currentPhase = SIGNAL_PHASE.YELLOW
          signal.phaseTimer = 0
        end
      elseif signal.currentPhase == SIGNAL_PHASE.YELLOW then
        if signal.phaseTimer >= SIGNAL_TIMING.yellowDuration then
          signal.currentPhase = SIGNAL_PHASE.RED
          signal.phaseTimer = 0
        end
      elseif signal.currentPhase == SIGNAL_PHASE.RED then
        if signal.phaseTimer >= SIGNAL_TIMING.redDuration then
          signal.currentPhase = SIGNAL_PHASE.GREEN
          signal.phaseTimer = 0
          -- Switch active group
          signal.activeGroup = (signal.activeGroup == "A") and "B" or "A"
        end
      end
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- SIGNAL DETECTION FOR VEHICLES
-- ══════════════════════════════════════════════════════════════════════════════

--- Find the nearest signal/sign ahead of the vehicle
---@param aiState table
---@return table|nil  nearest signal data
---@return number     distance to signal
local function findNearestSignalAhead(aiState)
  local pos = aiState.position
  local dir = aiState.direction

  local nearestSignal = nil
  local nearestDist = math.huge

  for nodeId, signal in pairs(virtualSignals) do
    local toSignal = signal.pos - pos
    local distAhead = toSignal:dot(dir)

    -- Is it ahead of us and within detection range?
    if distAhead > 0 and distAhead < SIGNAL_DETECTION_RANGE then
      -- Is it roughly on our path? (not far to the side)
      local totalDist = toSignal:length()
      local lateralDist = math.sqrt(math.max(0, totalDist * totalDist - distAhead * distAhead))

      if lateralDist < 15 then -- within 15m laterally
        if distAhead < nearestDist then
          nearestDist = distAhead
          nearestSignal = signal
          nearestSignal._nodeId = nodeId
        end
      end
    end
  end

  return nearestSignal, nearestDist
end

--- Determine what signal phase applies to this vehicle's approach direction
---@param signal table
---@param aiState table
---@return string phase  "red", "yellow", "green", "stop_sign", "yield", or "none"
local function getSignalPhaseForVehicle(signal, aiState)
  if signal.type == "stop_sign" then
    return SIGN_TYPE.STOP
  end

  if signal.type == "yield" then
    return SIGN_TYPE.YIELD
  end

  if signal.type == "traffic_light" then
    -- Determine which approach group this vehicle belongs to
    local dir = aiState.direction
    local bestApproachGroup = "A"
    local bestDot = -math.huge

    for linkedId, approach in pairs(signal.approaches) do
      -- Find the approach most aligned with our direction
      -- (We're approaching FROM the opposite direction of the approach vector)
      local dot = dir:dot(approach.direction)
      if dot > bestDot then
        bestDot = dot
        bestApproachGroup = approach.group
      end
    end

    -- If our approach group is the active group, it's green
    if bestApproachGroup == signal.activeGroup then
      return signal.currentPhase
    else
      -- We're on the non-active group
      if signal.currentPhase == SIGNAL_PHASE.GREEN then
        return SIGNAL_PHASE.RED
      elseif signal.currentPhase == SIGNAL_PHASE.YELLOW then
        return SIGNAL_PHASE.RED  -- other group sees red while this one is yellow
      elseif signal.currentPhase == SIGNAL_PHASE.RED then
        return SIGNAL_PHASE.GREEN
      end
    end
  end

  return "none"
end

-- ══════════════════════════════════════════════════════════════════════════════
-- RIGHT-OF-WAY / PRIORITY LOGIC
-- ══════════════════════════════════════════════════════════════════════════════

--- Check if there is cross-traffic from the right that has priority
--- (помеха справа / right-hand priority rule)
---@param vehObj userdata
---@param aiState table
---@param allVehicles table|nil  (we access via core if needed)
---@return boolean  hasPriorityThreat
local function checkRightOfWay(vehObj, aiState)
  local pos = aiState.position
  local dir = aiState.direction

  -- "Right" direction in world space (perpendicular to forward, 2D)
  -- In right-hand traffic, priority = vehicle from your right
  local rightDir = vec3(dir.y, -dir.x, 0):normalized()

  -- Scan for nearby vehicles coming from the right
  local allVeh = getAllVehicles()
  if not allVeh then return false end

  for _, veh in ipairs(allVeh) do
    local otherId = veh:getId()
    if otherId ~= aiState.vehicleId then
      local otherObj = be:getObjectByID(otherId)
      if otherObj then
        local otherPos = otherObj:getPosition()
        local toOther = otherPos - pos
        local dist = toOther:length()

        if dist < RIGHT_OF_WAY_SCAN_DIST then
          -- Is the other vehicle to our RIGHT?
          local rightComponent = toOther:dot(rightDir)
          local forwardComponent = toOther:dot(dir)

          -- Right and slightly ahead or at the intersection
          if rightComponent > 2 and rightComponent < RIGHT_OF_WAY_SCAN_DIST
             and math.abs(forwardComponent) < 20 then

            -- Check if they're moving (not parked)
            local otherVel = otherObj:getVelocity()
            if otherVel:length() > 1.0 then
              -- Check if they're heading toward our path
              local otherDir = otherVel:normalized()
              local headingTowardUs = otherDir:dot(-rightDir)
              if headingTowardUs > 0.3 then
                return true -- threat from right!
              end
            end
          end
        end
      end
    end
  end

  return false
end

--- Check for any cross-traffic at an intersection
---@param aiState table
---@param signal table
---@return boolean hasCrossTraffic
local function checkCrossTraffic(aiState, signal)
  local pos = aiState.position
  local dir = aiState.direction

  -- Check perpendicular directions
  local leftDir  = vec3(-dir.y, dir.x, 0):normalized()
  local rightDir = vec3(dir.y, -dir.x, 0):normalized()

  local allVeh = getAllVehicles()
  if not allVeh then return false end

  for _, veh in ipairs(allVeh) do
    local otherId = veh:getId()
    if otherId ~= aiState.vehicleId then
      local otherObj = be:getObjectByID(otherId)
      if otherObj then
        local otherPos = otherObj:getPosition()
        local toOther = otherPos - pos
        local dist = toOther:length()

        if dist < CROSS_TRAFFIC_CHECK_DIST then
          local otherVel = otherObj:getVelocity()
          if otherVel:length() > 2.0 then
            -- Is this vehicle roughly perpendicular to us?
            local otherDir = otherVel:normalized()
            local dotForward = math.abs(otherDir:dot(dir))
            local dotLateral = math.abs(otherDir:dot(rightDir))

            -- Perpendicular traffic: lateral dot is high, forward dot is low
            if dotLateral > 0.5 and dotForward < 0.5 then
              return true
            end
          end
        end
      end
    end
  end

  return false
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PER-VEHICLE SIGNAL STATE
-- ══════════════════════════════════════════════════════════════════════════════

local function getVehicleSignalState(vehId)
  if not vehicleSignalStates[vehId] then
    vehicleSignalStates[vehId] = {
      stoppedAtSignal = false,
      stopWaitTimer = 0,
      greenReactionTimer = 0,
      lastSignalNodeId = nil,
      passedSignal = false,
    }
  end
  return vehicleSignalStates[vehId]
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UPDATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Update traffic signal awareness for a single vehicle
---@param vehObj userdata
---@param aiState table
---@param dt number
function M.update(vehObj, aiState, dt)
  -- Update global signal phases
  updateSignalPhases(dt)

  local vehId = aiState.vehicleId
  local vss = getVehicleSignalState(vehId)

  -- ── Find nearest signal ahead ──────────────────────────────────────────
  local signal, dist = findNearestSignalAhead(aiState)

  if not signal then
    -- No signal nearby
    aiState.nextSignalType = "none"
    aiState.distToNextSignal = math.huge
    aiState.waitingAtSignal = false
    aiState.rightOfWayCheck = false
    vss.stoppedAtSignal = false
    vss.stopWaitTimer = 0
    return
  end

  -- ── Determine effective phase for this vehicle ─────────────────────────
  local phase = getSignalPhaseForVehicle(signal, aiState)
  aiState.nextSignalType = phase
  aiState.distToNextSignal = dist

  -- ── Handle different signal types ──────────────────────────────────────

  if phase == SIGNAL_PHASE.RED then
    -- ── RED LIGHT ──────────────────────────────────────────────────────
    if dist < BRAKE_START_DISTANCE then
      if dist <= STOP_LINE_DISTANCE then
        aiState.waitingAtSignal = true
        vss.stoppedAtSignal = true
      else
        -- Approaching: slow down proportionally
        aiState.waitingAtSignal = false
      end
    end

  elseif phase == SIGNAL_PHASE.YELLOW then
    -- ── YELLOW LIGHT ───────────────────────────────────────────────────
    if dist > 20 then
      -- Far enough to stop safely
      aiState.waitingAtSignal = false
      -- Speed will be reduced by core based on distance
    else
      -- Too close to stop, proceed through
      aiState.waitingAtSignal = false
    end

  elseif phase == SIGNAL_PHASE.GREEN then
    -- ── GREEN LIGHT ────────────────────────────────────────────────────
    if vss.stoppedAtSignal then
      -- Was stopped, now green: reaction delay
      vss.greenReactionTimer = vss.greenReactionTimer + dt
      if vss.greenReactionTimer >= GREEN_REACTION_TIME then
        aiState.waitingAtSignal = false
        vss.stoppedAtSignal = false
        vss.greenReactionTimer = 0
      else
        aiState.waitingAtSignal = true
      end
    else
      aiState.waitingAtSignal = false
    end

  elseif phase == SIGN_TYPE.STOP then
    -- ── STOP SIGN ──────────────────────────────────────────────────────
    if dist <= STOP_LINE_DISTANCE then
      if not vss.stoppedAtSignal then
        -- Just arrived at stop sign
        vss.stoppedAtSignal = true
        vss.stopWaitTimer = 0
      end

      vss.stopWaitTimer = vss.stopWaitTimer + dt

      if vss.stopWaitTimer < STOP_SIGN_WAIT_TIME then
        -- Still waiting
        aiState.waitingAtSignal = true
      else
        -- Check for cross traffic and right-of-way
        local hasCross = checkCrossTraffic(aiState, signal)
        local hasRightThreat = checkRightOfWay(vehObj, aiState)

        if hasCross or hasRightThreat then
          -- Keep waiting
          aiState.waitingAtSignal = true
          aiState.rightOfWayCheck = true
        else
          -- Clear to go!
          aiState.waitingAtSignal = false
          aiState.rightOfWayCheck = false
          vss.stoppedAtSignal = false
          vss.stopWaitTimer = 0
          vss.lastSignalNodeId = signal._nodeId
          vss.passedSignal = true
        end
      end
    elseif dist < BRAKE_START_DISTANCE then
      -- Approaching stop sign
      aiState.waitingAtSignal = false
    end

  elseif phase == SIGN_TYPE.YIELD then
    -- ── YIELD SIGN ─────────────────────────────────────────────────────
    if dist < 30 then
      -- Check for cross traffic
      local hasCross = checkCrossTraffic(aiState, signal)
      local hasRightThreat = checkRightOfWay(vehObj, aiState)

      if hasCross or hasRightThreat then
        -- Must yield
        if dist <= STOP_LINE_DISTANCE + 3 then
          aiState.waitingAtSignal = true
        end
        aiState.rightOfWayCheck = true
      else
        -- Clear, proceed (but slow down)
        aiState.waitingAtSignal = false
        aiState.rightOfWayCheck = false
      end
    end
  end

  -- Reset passed signal flag when we move away
  if vss.passedSignal and dist > 20 then
    vss.passedSignal = false
    vss.lastSignalNodeId = nil
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

--- Get all virtual signals (for debug/UI)
function M.getVirtualSignals()
  return virtualSignals
end

--- Force a specific signal to a phase (for testing)
---@param nodeId string
---@param phase string
function M.forceSignalPhase(nodeId, phase)
  if virtualSignals[nodeId] then
    virtualSignals[nodeId].currentPhase = phase
    virtualSignals[nodeId].phaseTimer = 0
    log("I", "TrafficAI.Signals",
      string.format("Signal %s forced to phase: %s", tostring(nodeId), phase))
  end
end

--- Adjust signal timing
function M.setSignalTiming(greenDur, yellowDur, redDur)
  SIGNAL_TIMING.greenDuration  = greenDur or SIGNAL_TIMING.greenDuration
  SIGNAL_TIMING.yellowDuration = yellowDur or SIGNAL_TIMING.yellowDuration
  SIGNAL_TIMING.redDuration    = redDur or SIGNAL_TIMING.redDuration
  log("I", "TrafficAI.Signals",
    string.format("Signal timing set: G=%.1fs Y=%.1fs R=%.1fs",
      SIGNAL_TIMING.greenDuration, SIGNAL_TIMING.yellowDuration, SIGNAL_TIMING.redDuration))
end

--- Rebuild signals (e.g., after map change)
function M.rebuild()
  virtualSignals = {}
  vehicleSignalStates = {}
  M.buildVirtualSignals()
end

return M