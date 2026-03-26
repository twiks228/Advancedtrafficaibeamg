-- ============================================================================
-- laneDiscipline.lua
-- Lane discipline, oncoming traffic awareness, and overtaking logic
-- ============================================================================

local M = {}

-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Minimum distance ahead to trigger overtake consideration (meters)
local OVERTAKE_TRIGGER_DIST = 35

--- Maximum speed difference to trigger overtake (km/h)
--- If bot is this much faster than vehicle ahead, consider overtaking
local OVERTAKE_SPEED_DIFF_THRESHOLD = 15

--- Time before aborting an overtake if can't complete (seconds)
local OVERTAKE_MAX_DURATION = 8.0

--- Distance to check for oncoming traffic before overtaking (meters)
local ONCOMING_CHECK_DISTANCE = 150

--- Minimum road width for overtaking to be possible (meters)
local MIN_OVERTAKE_ROAD_WIDTH = 7

--- Lateral offset for overtake (meters from road center)
local OVERTAKE_LATERAL_OFFSET = 3.5

--- Safe distance behind after overtake to return to lane (meters)
local OVERTAKE_RETURN_CLEARANCE = 15

--- Lane keeping offset from road edge (meters)
local LANE_KEEP_MARGIN = 1.5

-- Line marking types
local LINE_TYPE = {
  SOLID = "solid",           -- No crossing allowed
  DASHED = "dashed",         -- Overtaking allowed
  DOUBLE_SOLID = "double",   -- Absolutely no crossing
  NONE = "none",             -- No markings (usually small roads)
}

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

local overtakeStates = {} -- { [vehId] = { ... } }

-- ══════════════════════════════════════════════════════════════════════════════
-- INIT
-- ══════════════════════════════════════════════════════════════════════════════

function M.init()
  overtakeStates = {}
  log("I", "TrafficAI.LaneDiscipline", "Lane discipline module initialized.")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════════════════════════════════

--- Determine the center-line type for the road at given position
--- In a real scenario this would read from road metadata
---@param pos vec3
---@return string lineType (from LINE_TYPE)
local function getRoadLineType(pos)
  local mapData = map and map.getMap() or nil
  if not mapData or not mapData.nodes then
    return LINE_TYPE.DASHED -- default: allow overtaking
  end

  -- Find closest road node
  local closestNode = nil
  local closestDist = math.huge
  for _, nodeData in pairs(mapData.nodes) do
    if nodeData.pos then
      local d = (pos - nodeData.pos):length()
      if d < closestDist then
        closestDist = d
        closestNode = nodeData
      end
    end
  end

  if closestNode and closestDist < 30 then
    local width = (closestNode.radius or 4) * 2

    -- Heuristic: wide multi-lane roads → solid divider
    -- Narrow two-lane roads → depends on context
    if width >= 14 then
      -- Highway with median: don't cross
      return LINE_TYPE.DOUBLE_SOLID
    elseif width >= 8 then
      -- Two-lane road: allow overtaking (dashed)
      -- But near intersections, use solid
      -- Check if node has many connections (intersection)
      local linkCount = 0
      if closestNode.links then
        for _ in pairs(closestNode.links) do
          linkCount = linkCount + 1
        end
      end
      if linkCount > 2 then
        return LINE_TYPE.SOLID -- near intersection
      end
      return LINE_TYPE.DASHED
    else
      -- Very narrow road: no markings
      return LINE_TYPE.NONE
    end
  end

  return LINE_TYPE.DASHED
end

--- Determine which side of the road the vehicle is on
--- Returns "right" (correct) or "left" (oncoming lane)
---@param vehObj userdata
---@param aiState table
---@return string side
---@return number lateralOffset  offset from road center (negative = left of center)
local function determineLaneSide(vehObj, aiState)
  local mapData = map and map.getMap() or nil
  if not mapData or not mapData.nodes then
    return "right", 0
  end

  local pos = aiState.position
  local dir = aiState.direction

  -- Find the two closest road nodes to determine road direction
  local nodes = {}
  for nodeId, nodeData in pairs(mapData.nodes) do
    if nodeData.pos then
      local d = (pos - nodeData.pos):length()
      table.insert(nodes, { id = nodeId, data = nodeData, dist = d })
    end
  end
  table.sort(nodes, function(a, b) return a.dist < b.dist end)

  if #nodes >= 2 then
    local node1 = nodes[1].data
    local node2 = nodes[2].data

    -- Road direction vector
    local roadDir = (node2.pos - node1.pos):normalized()

    -- Check if vehicle is going WITH or AGAINST the road flow
    local dotProduct = dir:dot(roadDir)

    -- Lateral position: project vehicle pos onto the perpendicular
    local roadRight = vec3(roadDir.y, -roadDir.x, 0):normalized()
    local toVeh = (pos - node1.pos)
    local lateralOffset = toVeh:dot(roadRight)

    -- In right-hand traffic: positive lateral offset = right side (correct)
    -- Going with road flow (dot > 0): should be on right side
    -- Going against road flow (dot < 0): position should be on left side

    if dotProduct >= 0 then
      -- Going with road direction
      if lateralOffset >= 0 then
        return "right", lateralOffset
      else
        return "left", lateralOffset
      end
    else
      -- Going against road direction (this road node pair flows opposite)
      if lateralOffset <= 0 then
        return "right", math.abs(lateralOffset)
      else
        return "left", -lateralOffset
      end
    end
  end

  return "right", 0
end

--- Check if there is a slower vehicle ahead in the same lane
---@param vehObj userdata
---@param aiState table
---@param allVehicles table  all managed vehicle states
---@return boolean hasSlowerAhead
---@return number distToSlow
---@return number slowVehSpeed (km/h)
local function checkSlowerVehicleAhead(vehObj, aiState, allVehicles)
  local pos = aiState.position
  local dir = aiState.direction
  local mySpeed = aiState.currentSpeed
  local vehId = aiState.vehicleId

  local closestSlowDist = math.huge
  local closestSlowSpeed = 0

  for otherId, otherState in pairs(allVehicles) do
    if otherId ~= vehId then
      local toOther = otherState.position - pos
      local distAhead = toOther:dot(dir)

      -- Is the other vehicle ahead of us?
      if distAhead > 3 and distAhead < OVERTAKE_TRIGGER_DIST * 2 then
        -- Is it roughly in our lane? (lateral distance check)
        local lateral = math.abs(toOther:length() * toOther:length() - distAhead * distAhead)
        lateral = math.sqrt(math.max(0, lateral))

        if lateral < 3.0 then
          -- Is it slower than us?
          if otherState.currentSpeed < mySpeed - 5 then
            if distAhead < closestSlowDist then
              closestSlowDist = distAhead
              closestSlowSpeed = otherState.currentSpeed
            end
          end
        end
      end
    end
  end

  local hasSlower = closestSlowDist < OVERTAKE_TRIGGER_DIST
  return hasSlower, closestSlowDist, closestSlowSpeed
end

--- Check if oncoming lane is clear for overtaking
---@param vehObj userdata
---@param aiState table
---@param allVehicles table
---@return boolean isClear
local function isOncomingLaneClear(vehObj, aiState, allVehicles)
  local pos = aiState.position
  local dir = aiState.direction
  local vehId = aiState.vehicleId

  for otherId, otherState in pairs(allVehicles) do
    if otherId ~= vehId then
      local toOther = otherState.position - pos
      local distAhead = toOther:dot(dir)

      -- Check vehicles coming toward us in the oncoming lane
      if distAhead > 0 and distAhead < ONCOMING_CHECK_DISTANCE then
        local otherDir = otherState.direction
        local headingDot = dir:dot(otherDir)

        -- If heading is opposite (dot < -0.5), it's oncoming
        if headingDot < -0.5 then
          -- Check lateral distance — if close to our overtake path
          local lateral = math.abs(toOther:length() * toOther:length() - distAhead * distAhead)
          lateral = math.sqrt(math.max(0, lateral))

          if lateral < 5.0 then
            return false -- oncoming traffic detected, not safe
          end
        end
      end
    end
  end

  return true
end

-- ══════════════════════════════════════════════════════════════════════════════
-- OVERTAKE STATE MACHINE
-- ══════════════════════════════════════════════════════════════════════════════

--- Get or create overtake state for a vehicle
local function getOvertakeState(vehId)
  if not overtakeStates[vehId] then
    overtakeStates[vehId] = {
      phase = "none",    -- none / check / preparing / overtaking / returning
      timer = 0,
      targetOffset = 0,
      startTime = 0,
    }
  end
  return overtakeStates[vehId]
end

--- Process overtake logic for a vehicle
---@param vehObj userdata
---@param aiState table
---@param dt number
---@param allVehicles table
local function processOvertake(vehObj, aiState, dt, allVehicles)
  local vehId = aiState.vehicleId
  local os = getOvertakeState(vehId)
  local lineType = getRoadLineType(aiState.position)

  -- Can't overtake on solid or double-solid lines
  local canCrossCenter = (lineType == LINE_TYPE.DASHED or lineType == LINE_TYPE.NONE)

  if os.phase == "none" then
    -- ── Check if we need to overtake ────────────────────────────────────
    local hasSlower, dist, slowSpeed = checkSlowerVehicleAhead(vehObj, aiState, allVehicles)

    if hasSlower and canCrossCenter then
      local speedDiff = aiState.currentSpeed - slowSpeed
      if speedDiff > OVERTAKE_SPEED_DIFF_THRESHOLD or
         (dist < 15 and aiState.currentSpeedLimit - slowSpeed > 20) then
        os.phase = "check"
        os.timer = 0
      end
    end

    aiState.overtakeState = "none"
    aiState.canOvertake = false

  elseif os.phase == "check" then
    -- ── Verify it's safe to overtake ────────────────────────────────────
    os.timer = os.timer + dt

    if not canCrossCenter then
      -- Line changed to solid, abort
      os.phase = "none"
      aiState.overtakeState = "none"
      return
    end

    local clear = isOncomingLaneClear(vehObj, aiState, allVehicles)
    if clear then
      os.phase = "overtaking"
      os.timer = 0
      os.startTime = 0
      aiState.canOvertake = true
      log("D", "TrafficAI.LaneDiscipline",
        string.format("Veh %d: starting overtake maneuver", vehId))
    elseif os.timer > 3.0 then
      -- Waited too long, give up for now
      os.phase = "none"
      os.timer = 0
    end

    aiState.overtakeState = "preparing"

  elseif os.phase == "overtaking" then
    -- ── Actively overtaking ─────────────────────────────────────────────
    os.timer = os.timer + dt

    -- Apply lateral offset via AI route manipulation
    -- We send an offset command to the vehicle's AI
    vehObj:queueLuaCommand(string.format(
      'ai.driveUsingPath({avoidCars = "off", routeSpeed = %.2f, routeOffset = %.2f})',
      aiState.desiredSpeed / 3.6,
      -OVERTAKE_LATERAL_OFFSET -- negative = left side (oncoming lane)
    ))

    -- Check if we've passed the slow vehicle
    local hasSlower, dist, _ = checkSlowerVehicleAhead(vehObj, aiState, allVehicles)
    if not hasSlower then
      -- We've passed them, start returning
      os.phase = "returning"
      os.timer = 0
    end

    -- Timeout
    if os.timer > OVERTAKE_MAX_DURATION then
      os.phase = "returning"
      os.timer = 0
      log("D", "TrafficAI.LaneDiscipline",
        string.format("Veh %d: overtake timeout, returning to lane", vehId))
    end

    -- Safety check: if oncoming traffic appears, abort!
    local clear = isOncomingLaneClear(vehObj, aiState, allVehicles)
    if not clear then
      os.phase = "returning"
      os.timer = 0
      log("D", "TrafficAI.LaneDiscipline",
        string.format("Veh %d: oncoming traffic! Aborting overtake!", vehId))
    end

    aiState.overtakeState = "overtaking"
    aiState.isOncoming = true

  elseif os.phase == "returning" then
    -- ── Returning to correct lane ───────────────────────────────────────
    os.timer = os.timer + dt

    -- Gradually reduce lateral offset
    local returnProgress = math.min(1, os.timer / 2.0) -- 2 seconds to return
    local currentOffset = -OVERTAKE_LATERAL_OFFSET * (1 - returnProgress)

    vehObj:queueLuaCommand(string.format(
      'ai.driveUsingPath({avoidCars = "on", routeOffset = %.2f})',
      currentOffset
    ))

    if returnProgress >= 1.0 then
      os.phase = "none"
      os.timer = 0
      aiState.isOncoming = false
      log("D", "TrafficAI.LaneDiscipline",
        string.format("Veh %d: overtake complete, back in lane", vehId))
    end

    aiState.overtakeState = "returning"
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- LANE KEEPING
-- ══════════════════════════════════════════════════════════════════════════════

--- Ensure the vehicle stays in the correct lane when not overtaking
---@param vehObj userdata
---@param aiState table
local function enforceLaneKeeping(vehObj, aiState)
  if aiState.overtakeState ~= "none" then
    return -- don't interfere during overtake
  end

  local side, lateralOffset = determineLaneSide(vehObj, aiState)

  if side == "left" and math.abs(lateralOffset) > 1.0 then
    -- Vehicle is on the wrong side! Gently push it right
    aiState.isOncoming = true

    -- Apply a corrective offset
    vehObj:queueLuaCommand(string.format(
      'ai.driveUsingPath({avoidCars = "on", routeOffset = %.2f})',
      LANE_KEEP_MARGIN
    ))
  else
    aiState.isOncoming = false
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UPDATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Update lane discipline for a vehicle
---@param vehObj userdata
---@param aiState table
---@param dt number
---@param allVehicles table  all managed vehicle AI states
function M.update(vehObj, aiState, dt, allVehicles)
  -- 1. Determine current lane info
  local side, lateralOffset = determineLaneSide(vehObj, aiState)

  -- Estimate lane count from road width
  local mapData = map and map.getMap() or nil
  if mapData and mapData.nodes then
    local closestNode = nil
    local closestDist = math.huge
    for _, nodeData in pairs(mapData.nodes) do
      if nodeData.pos then
        local d = (aiState.position - nodeData.pos):length()
        if d < closestDist then
          closestDist = d
          closestNode = nodeData
        end
      end
    end
    if closestNode then
      local roadWidth = (closestNode.radius or 4) * 2
      -- Estimate: each lane ≈ 3.5m
      aiState.laneCount = math.max(1, math.floor(roadWidth / 3.5))
      aiState.currentLaneIndex = math.max(1,
        math.floor((lateralOffset + roadWidth/2) / 3.5) + 1)
    end
  end

  -- 2. Lane keeping
  enforceLaneKeeping(vehObj, aiState)

  -- 3. Overtake logic
  processOvertake(vehObj, aiState, dt, allVehicles)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

function M.getLineTypeAtPosition(pos)
  return getRoadLineType(pos)
end

function M.resetOvertakeStates()
  overtakeStates = {}
end

return M