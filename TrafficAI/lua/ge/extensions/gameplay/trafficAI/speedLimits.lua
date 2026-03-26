-- ============================================================================
-- speedLimits.lua
-- Realistic speed limits based on road zone type, width, curvature, etc.
-- ============================================================================

local M = {}

-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Speed limits per zone type (km/h) { min, max }
local ZONE_SPEED_LIMITS = {
  residential = { min = 25, max = 40 },
  urban       = { min = 40, max = 60 },
  suburban    = { min = 60, max = 80 },
  highway     = { min = 90, max = 130 },
  dirt        = { min = 20, max = 50 },
  parking     = { min = 5,  max = 15 },
}

--- Road width → zone heuristic thresholds (meters)
local ROAD_WIDTH_THRESHOLDS = {
  -- width < 6 → residential
  -- 6 <= width < 10 → urban
  -- 10 <= width < 14 → suburban
  -- width >= 14 → highway
  residential = 6,
  urban       = 10,
  suburban    = 14,
}

--- Curvature penalty: higher curvature = lower speed
--- Speed multiplier = 1.0 - (curvature * CURVE_PENALTY_FACTOR)
local CURVE_PENALTY_FACTOR = 0.4
local MIN_CURVE_SPEED_MULT = 0.35

--- Hill penalty: steep grades reduce speed
local HILL_PENALTY_FACTOR = 0.15
local MAX_GRADE_FOR_PENALTY = 0.3 -- 30% grade

--- Look-ahead distance for curvature detection (meters)
local CURVATURE_LOOKAHEAD = 80

--- Personal speed variation: bots won't all drive exactly the limit
--- Each bot gets a random factor between these
local SPEED_PERSONALITY_MIN = 0.88  -- cautious driver
local SPEED_PERSONALITY_MAX = 1.08  -- slightly aggressive

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

local roadNetwork = nil    -- reference to BeamNG map/road data
local personalityFactors = {}  -- { [vehId] = float }

-- ══════════════════════════════════════════════════════════════════════════════
-- INIT
-- ══════════════════════════════════════════════════════════════════════════════

function M.init()
  personalityFactors = {}
  log("I", "TrafficAI.SpeedLimits", "Speed limits module initialized.")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════════════════════════════════

--- Get or generate a personality speed factor for a vehicle
---@param vehId number
---@return number factor (0.88 .. 1.08)
local function getPersonalityFactor(vehId)
  if not personalityFactors[vehId] then
    personalityFactors[vehId] = SPEED_PERSONALITY_MIN
      + math.random() * (SPEED_PERSONALITY_MAX - SPEED_PERSONALITY_MIN)
  end
  return personalityFactors[vehId]
end

--- Determine road zone type from road properties at a given position
---@param pos vec3
---@return string zoneType
---@return number roadWidth
local function classifyRoadAtPosition(pos)
  -- Try to use BeamNG's map data
  local mapNodes = map and map.getMap() or nil

  if mapNodes and mapNodes.nodes then
    -- Find closest road node
    local closestNode = nil
    local closestDist = math.huge

    -- BeamNG map nodes have position, radius (half-width), links, etc.
    for nodeId, nodeData in pairs(mapNodes.nodes) do
      local nodePos = nodeData.pos
      if nodePos then
        local dist = (pos - nodePos):length()
        if dist < closestDist then
          closestDist = dist
          closestNode = nodeData
        end
      end
    end

    if closestNode and closestDist < 50 then
      local roadWidth = (closestNode.radius or 4) * 2

      -- Check if node has explicit speed limit data
      -- Some BeamNG roads store this in drivability or speedLimit fields
      local explicitLimit = closestNode.speedLimit -- may be nil

      -- Determine zone type based on road width
      local zoneType = "residential"
      if roadWidth >= ROAD_WIDTH_THRESHOLDS.suburban then
        zoneType = "highway"
      elseif roadWidth >= ROAD_WIDTH_THRESHOLDS.urban then
        zoneType = "suburban"
      elseif roadWidth >= ROAD_WIDTH_THRESHOLDS.residential then
        zoneType = "urban"
      end

      -- Check surface type for dirt roads
      -- BeamNG roads can have a "material" or "drivability" property
      local drivability = closestNode.drivability or 1.0
      if drivability < 0.5 then
        zoneType = "dirt"
      end

      return zoneType, roadWidth, explicitLimit
    end
  end

  -- Fallback: default to urban
  return "urban", 8, nil
end

--- Calculate road curvature ahead by sampling the AI path
---@param vehObj userdata
---@param pos vec3
---@param dir vec3
---@return number curvature (0 = straight, 1 = very sharp)
local function calculateCurvatureAhead(vehObj, pos, dir)
  local mapData = map and map.getMap() or nil
  if not mapData or not mapData.nodes then
    return 0
  end

  -- Sample points along the direction and measure deviation
  -- We'll check a few road nodes ahead and compute an approximate curvature
  local sampleDistances = { 20, 40, 60, 80 }
  local prevDir = dir
  local totalAngleChange = 0

  for _, dist in ipairs(sampleDistances) do
    local samplePos = pos + dir * dist

    -- Find closest node to this sample position
    local closestNode = nil
    local closestDist = math.huge
    for _, nodeData in pairs(mapData.nodes) do
      if nodeData.pos then
        local d = (samplePos - nodeData.pos):length()
        if d < closestDist then
          closestDist = d
          closestNode = nodeData
        end
      end
    end

    if closestNode and closestNode.pos and closestDist < 30 then
      local toNode = (closestNode.pos - pos):normalized()
      local angleDiff = math.acos(math.max(-1, math.min(1, toNode:dot(prevDir))))
      totalAngleChange = totalAngleChange + angleDiff
      prevDir = toNode
    end
  end

  -- Normalize: if total angle change across 80m is > PI/2 (90°), curvature ≈ 1
  local curvature = math.min(1, totalAngleChange / (math.pi * 0.5))
  return curvature
end

--- Calculate road grade (slope) at current position
---@param vehObj userdata
---@param pos vec3
---@param dir vec3
---@return number grade (-1..1, negative = downhill)
local function calculateGrade(vehObj, pos, dir)
  -- Sample a point ahead and compare heights
  local aheadDist = 20
  local aheadPos = pos + dir * aheadDist
  local groundAhead = be:getSurfaceHeightBelow(aheadPos)
  local groundHere  = be:getSurfaceHeightBelow(pos)

  if groundAhead and groundHere then
    local heightDiff = groundAhead - groundHere
    local grade = heightDiff / aheadDist
    return math.max(-MAX_GRADE_FOR_PENALTY, math.min(MAX_GRADE_FOR_PENALTY, grade))
  end
  return 0
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UPDATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Update speed limit for a vehicle based on current road conditions
---@param vehObj userdata  BeamNG vehicle
---@param aiState table    vehicle AI state from core
---@param dt number        delta time
function M.update(vehObj, aiState, dt)
  local pos = aiState.position
  local dir = aiState.direction
  local vehId = aiState.vehicleId

  -- ── 1. Classify the road ────────────────────────────────────────────────
  local zoneType, roadWidth, explicitLimit = classifyRoadAtPosition(pos)
  aiState.roadZoneType = zoneType

  -- ── 2. Base speed limit ─────────────────────────────────────────────────
  local baseLimit
  if explicitLimit and explicitLimit > 0 then
    -- Use explicit limit from road data (converted from m/s to km/h if needed)
    baseLimit = explicitLimit
    -- BeamNG sometimes stores speed in m/s
    if baseLimit < 5 then
      baseLimit = baseLimit * 3.6
    end
  else
    -- Use zone-based limits
    local zoneLimits = ZONE_SPEED_LIMITS[zoneType] or ZONE_SPEED_LIMITS.urban
    -- Pick a value within the zone range (tend toward max)
    baseLimit = zoneLimits.min + (zoneLimits.max - zoneLimits.min) * 0.7
  end

  -- ── 3. Curvature penalty ───────────────────────────────────────────────
  local curvature = calculateCurvatureAhead(vehObj, pos, dir)
  local curveMult = 1.0 - (curvature * CURVE_PENALTY_FACTOR)
  curveMult = math.max(MIN_CURVE_SPEED_MULT, curveMult)

  -- ── 4. Hill penalty (uphill only) ──────────────────────────────────────
  local grade = calculateGrade(vehObj, pos, dir)
  local hillMult = 1.0
  if grade > 0.02 then
    -- Uphill: reduce speed
    hillMult = 1.0 - (grade * HILL_PENALTY_FACTOR / MAX_GRADE_FOR_PENALTY)
    hillMult = math.max(0.6, hillMult)
  elseif grade < -0.05 then
    -- Downhill: might go slightly faster (but gravity already does that)
    hillMult = 1.0 -- let physics handle downhill acceleration
  end

  -- ── 5. Personality factor ──────────────────────────────────────────────
  local personality = getPersonalityFactor(vehId)

  -- ── 6. Compute final speed limit ───────────────────────────────────────
  local finalLimit = baseLimit * curveMult * hillMult * personality

  -- Clamp to absolute limits
  finalLimit = math.max(5, math.min(finalLimit, 140))

  aiState.currentSpeedLimit = finalLimit

  -- Debug logging (throttled)
  if math.random() < 0.01 then
    log("D", "TrafficAI.SpeedLimits",
      string.format("Veh %d: zone=%s width=%.1fm limit=%.0f km/h (curve=%.2f grade=%.2f pers=%.2f)",
        vehId, zoneType, roadWidth, finalLimit, curvature, grade, personality))
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

--- Get the zone speed limits table (for UI or debug)
function M.getZoneSpeedLimits()
  return ZONE_SPEED_LIMITS
end

--- Override a zone's speed limits at runtime
---@param zoneType string
---@param minSpeed number km/h
---@param maxSpeed number km/h
function M.setZoneSpeedLimit(zoneType, minSpeed, maxSpeed)
  ZONE_SPEED_LIMITS[zoneType] = { min = minSpeed, max = maxSpeed }
  log("I", "TrafficAI.SpeedLimits",
    string.format("Zone '%s' limits set to %d-%d km/h", zoneType, minSpeed, maxSpeed))
end

--- Clear personality cache (e.g., on mission restart)
function M.resetPersonalities()
  personalityFactors = {}
end

return M