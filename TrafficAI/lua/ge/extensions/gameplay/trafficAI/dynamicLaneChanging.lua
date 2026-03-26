-- ============================================================================
-- dynamicLaneChanging.lua
-- Smart lane changing: even distribution, overtaking slow vehicles,
-- pre-positioning for turns, no "conga line" behavior
-- BeamNG.drive 0.38.3
-- ============================================================================

local M = {}

-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Lane widths and detection
local LANE_WIDTH = 3.5               -- standard lane width (meters)
local LANE_DETECTION_TOLERANCE = 1.5  -- tolerance for lane assignment

--- Lane change triggers
local TRIGGERS = {
  -- Speed difference to trigger "overtake" lane change
  OVERTAKE_SPEED_DIFF     = 12,     -- km/h slower than our limit
  -- Distance at which a slow vehicle triggers lane change consideration
  SLOW_VEHICLE_RANGE      = 50,     -- meters ahead
  -- Minimum gap in target lane for lane change
  MIN_GAP_AHEAD           = 20,     -- meters
  MIN_GAP_BEHIND          = 12,     -- meters
  -- Pre-turn preparation distance
  TURN_PREP_DISTANCE      = 150,    -- meters before turn to start lane change
  TURN_PREP_DISTANCE_CITY = 80,     -- meters in urban areas
  -- Queue balancing: check every N seconds
  BALANCE_CHECK_INTERVAL  = 5,      -- seconds
  -- Minimum speed to attempt lane change
  MIN_SPEED_FOR_CHANGE    = 15,     -- km/h
  -- Abort lane change if blocked for this long
  ABORT_TIMEOUT           = 5,      -- seconds
}

--- Lane change maneuver timing
local MANEUVER = {
  MIRROR_CHECK_TIME    = 0.8,   -- seconds to "check mirrors"
  SIGNAL_LEAD_TIME     = 2.0,   -- seconds of signal before moving
  CHANGE_DURATION_SLOW = 3.5,   -- seconds for careful lane change
  CHANGE_DURATION_FAST = 1.5,   -- seconds for quick lane change
  RETURN_TO_RIGHT_TIME = 10,    -- seconds in left lane before returning right
}

--- Lane change reasons (priority order, higher = more important)
local REASON_PRIORITY = {
  emergency      = 100,  -- emergency vehicle, accident avoidance
  turn_prep      = 80,   -- need to be in correct lane for upcoming turn
  obstacle       = 70,   -- blocked lane (accident, stopped vehicle)
  overtake       = 50,   -- passing slow vehicle
  balance        = 30,   -- even distribution across lanes
  return_right   = 20,   -- returning to rightmost lane after overtake
  courtesy       = 10,   -- yielding for merging traffic
}

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Per-vehicle lane change state
local laneChangeStates = {}
--[[ Structure:
  {
    phase = "none" | "evaluating" | "signaling" | "checking" | "executing" | "completing",
    reason = string,
    reasonPriority = number,
    targetLane = number,
    currentLane = number,
    totalLanes = number,
    direction = "left" | "right",
    offset = number,           -- current lateral offset (meters)
    targetOffset = number,     -- target lateral offset
    phaseTimer = number,
    signalActive = false,
    mirrorChecked = false,
    gapConfirmed = false,
    returnToRightTimer = 0,
    balanceCheckTimer = 0,
    consecutiveChanges = 0,    -- to prevent constant lane hopping
    changeCooldown = 0,
    lastChangeTime = 0,
    abortTimer = 0,
    -- Turn preparation
    upcomingTurnDir = nil,     -- "left" | "right" | nil
    upcomingTurnDist = math.huge,
    upcomingTurnLane = nil,    -- which lane to be in for the turn
    -- Stats
    totalChanges = 0,
    totalAborts = 0,
  }
]]

-- ══════════════════════════════════════════════════════════════════════════════
-- INIT
-- ══════════════════════════════════════════════════════════════════════════════

function M.init()
  laneChangeStates = {}
  log("I", "TrafficAI.LaneChanging", "Dynamic lane changing system initialized.")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════════════════════════════════

local function getState(vehId)
  if not laneChangeStates[vehId] then
    laneChangeStates[vehId] = {
      phase                = "none",
      reason               = nil,
      reasonPriority       = 0,
      targetLane           = 0,
      currentLane          = 1,
      totalLanes           = 2,
      direction            = "right",
      offset               = 0,
      targetOffset         = 0,
      phaseTimer           = 0,
      signalActive         = false,
      mirrorChecked        = false,
      gapConfirmed         = false,
      returnToRightTimer   = 0,
      balanceCheckTimer    = 0,
      consecutiveChanges   = 0,
      changeCooldown       = 0,
      lastChangeTime       = 0,
      abortTimer           = 0,
      upcomingTurnDir      = nil,
      upcomingTurnDist     = math.huge,
      upcomingTurnLane     = nil,
      totalChanges         = 0,
      totalAborts          = 0,
    }
  end
  return laneChangeStates[vehId]
end

-- ══════════════════════════════════════════════════════════════════════════════
-- ROAD & LANE ANALYSIS
-- ══════════════════════════════════════════════════════════════════════════════

--- Analyze the road at a position: how many lanes, which lane is the vehicle in
---@param pos vec3
---@param dir vec3
---@return number currentLane
---@return number totalLanes
---@return number roadWidth
---@return number laneOffset  offset from center of current lane
local function analyzeRoadLanes(pos, dir)
  local mapData = map and map.getMap() or nil
  if not mapData or not mapData.nodes then
    return 1, 2, 8, 0
  end

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

  if not closestNode then
    return 1, 2, 8, 0
  end

  local roadWidth = (closestNode.radius or 4) * 2

  -- Estimate total lanes (each direction)
  -- Full road width / lane width / 2 (both directions)
  local totalLanesPerDir = math.max(1, math.floor(roadWidth / LANE_WIDTH / 2))
  if roadWidth < 6 then
    totalLanesPerDir = 1
  end

  -- Determine current lane via lateral position
  local roadDir
  -- Find connected node to determine road direction
  if closestNode.links then
    for linkedId, _ in pairs(closestNode.links) do
      local linkedNode = mapData.nodes[linkedId]
      if linkedNode and linkedNode.pos then
        roadDir = (linkedNode.pos - closestNode.pos):normalized()
        break
      end
    end
  end

  if not roadDir then
    return 1, totalLanesPerDir, roadWidth, 0
  end

  -- Ensure road direction aligns with vehicle direction
  if dir:dot(roadDir) < 0 then
    roadDir = -roadDir
  end

  -- Right-hand perpendicular
  local rightVec = vec3(roadDir.y, -roadDir.x, 0):normalized()
  local toVeh = pos - closestNode.pos
  local lateralPos = toVeh:dot(rightVec)

  -- In right-hand traffic: rightmost lane = lane 1, leftmost = lane N
  -- Positive lateral = right side of road
  -- Lane center positions: rightEdge - (laneIndex - 0.5) * LANE_WIDTH
  local rightEdge = roadWidth / 2
  local currentLane = 1

  for i = 1, totalLanesPerDir do
    local laneCenterFromRight = rightEdge - (i - 0.5) * LANE_WIDTH
    if math.abs(lateralPos - laneCenterFromRight) < LANE_DETECTION_TOLERANCE then
      currentLane = i
      break
    end
  end

  -- Offset from lane center
  local laneCenterPos = rightEdge - (currentLane - 0.5) * LANE_WIDTH
  local laneOffset = lateralPos - laneCenterPos

  return currentLane, totalLanesPerDir, roadWidth, laneOffset
end

--- Detect upcoming turns by looking at the road network ahead
---@param pos vec3
---@param dir vec3
---@return string|nil turnDir  "left" | "right" | nil
---@return number turnDist  distance to turn
---@return number|nil targetLane  which lane to be in
local function detectUpcomingTurn(pos, dir)
  local mapData = map and map.getMap() or nil
  if not mapData or not mapData.nodes then
    return nil, math.huge, nil
  end

  -- Look ahead along the path for intersections with turn requirements
  local lookAhead = TRIGGERS.TURN_PREP_DISTANCE
  local sampleDist = 20

  for dist = sampleDist, lookAhead, sampleDist do
    local samplePos = pos + dir * dist

    -- Find nearest node to sample position
    local closestNode, closestNodeId = nil, nil
    local closestDist = math.huge

    for nodeId, nodeData in pairs(mapData.nodes) do
      if nodeData.pos then
        local d = (samplePos - nodeData.pos):length()
        if d < closestDist then
          closestDist = d
          closestNode = nodeData
          closestNodeId = nodeId
        end
      end
    end

    if closestNode and closestDist < 15 then
      -- Check if this is an intersection
      local linkCount = 0
      if closestNode.links then
        for _ in pairs(closestNode.links) do
          linkCount = linkCount + 1
        end
      end

      if linkCount >= 3 then
        -- This is an intersection — check if our route turns here
        -- For now, use heuristic: check if the road curves significantly
        local aheadNode = nil
        local maxDot = -math.huge

        if closestNode.links then
          for linkedId, _ in pairs(closestNode.links) do
            local linkedNode = mapData.nodes[linkedId]
            if linkedNode and linkedNode.pos then
              local linkDir = (linkedNode.pos - closestNode.pos):normalized()
              local dot = dir:dot(linkDir)
              if dot > maxDot then
                maxDot = dot
                aheadNode = linkedNode
              end
            end
          end
        end

        if aheadNode then
          local continueDir = (aheadNode.pos - closestNode.pos):normalized()
          local turnAngle = math.acos(math.max(-1, math.min(1, dir:dot(continueDir))))
          local rightVec = vec3(dir.y, -dir.x, 0):normalized()
          local crossProduct = continueDir:dot(rightVec)

          -- Significant turn?
          if turnAngle > math.rad(30) then
            local turnDir = (crossProduct > 0) and "right" or "left"
            local currentLane, totalLanes = analyzeRoadLanes(pos, dir)

            -- Target lane for the turn
            local targetLane
            if turnDir == "right" then
              targetLane = 1  -- rightmost lane
            else
              targetLane = totalLanes  -- leftmost (passing) lane
            end

            return turnDir, dist, targetLane
          end
        end
      end
    end
  end

  return nil, math.huge, nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- GAP ANALYSIS
-- ══════════════════════════════════════════════════════════════════════════════

--- Check if there's a safe gap in the target lane
---@param pos vec3
---@param dir vec3
---@param targetLaneIndex number
---@param totalLanes number
---@param roadWidth number
---@param allVehicles table
---@param myVehId number
---@return boolean gapExists
---@return number gapAhead  distance to nearest vehicle ahead in target lane
---@return number gapBehind  distance to nearest vehicle behind in target lane
local function checkGapInLane(pos, dir, targetLaneIndex, totalLanes, roadWidth, allVehicles, myVehId)
  local rightVec = vec3(dir.y, -dir.x, 0):normalized()

  -- Calculate the lateral position of the target lane center
  local rightEdge = roadWidth / 2
  local targetLaneCenter = rightEdge - (targetLaneIndex - 0.5) * LANE_WIDTH

  local nearestAhead = math.huge
  local nearestBehind = math.huge

  for otherId, otherState in pairs(allVehicles) do
    if otherId ~= myVehId then
      local toOther = otherState.position - pos
      local longitudinal = toOther:dot(dir)
      local lateral = toOther:dot(rightVec)

      -- Is this vehicle in the target lane?
      if math.abs(lateral - targetLaneCenter) < LANE_DETECTION_TOLERANCE then
        if longitudinal > 0 then
          nearestAhead = math.min(nearestAhead, longitudinal)
        else
          nearestBehind = math.min(nearestBehind, math.abs(longitudinal))
        end
      end
    end
  end

  -- Check if gap is sufficient
  local gapOk = (nearestAhead >= TRIGGERS.MIN_GAP_AHEAD and
                 nearestBehind >= TRIGGERS.MIN_GAP_BEHIND)

  return gapOk, nearestAhead, nearestBehind
end

--- Check for slower vehicles ahead in the current lane
---@param pos vec3
---@param dir vec3
---@param currentLane number
---@param roadWidth number
---@param allVehicles table
---@param myVehId number
---@param mySpeed number km/h
---@return boolean hasSlowVehicle
---@return number distToSlow
---@return number slowSpeed km/h
local function findSlowVehicleAhead(pos, dir, currentLane, roadWidth, allVehicles, myVehId, mySpeed)
  local rightVec = vec3(dir.y, -dir.x, 0):normalized()
  local rightEdge = roadWidth / 2
  local myLaneCenter = rightEdge - (currentLane - 0.5) * LANE_WIDTH

  local closestSlowDist = math.huge
  local closestSlowSpeed = 0

  for otherId, otherState in pairs(allVehicles) do
    if otherId ~= myVehId then
      local toOther = otherState.position - pos
      local longitudinal = toOther:dot(dir)
      local lateral = toOther:dot(rightVec)

      -- In same lane and ahead
      if longitudinal > 3 and longitudinal < TRIGGERS.SLOW_VEHICLE_RANGE then
        if math.abs(lateral - myLaneCenter) < LANE_DETECTION_TOLERANCE then
          if otherState.currentSpeed < mySpeed - TRIGGERS.OVERTAKE_SPEED_DIFF then
            if longitudinal < closestSlowDist then
              closestSlowDist = longitudinal
              closestSlowSpeed = otherState.currentSpeed
            end
          end
        end
      end
    end
  end

  return closestSlowDist < TRIGGERS.SLOW_VEHICLE_RANGE, closestSlowDist, closestSlowSpeed
end

--- Count vehicles per lane to determine lane balance
---@param pos vec3
---@param dir vec3
---@param totalLanes number
---@param roadWidth number
---@param allVehicles table
---@param myVehId number
---@return table laneCounts  { [laneIndex] = count }
---@return number leastOccupiedLane
local function countVehiclesPerLane(pos, dir, totalLanes, roadWidth, allVehicles, myVehId)
  local rightVec = vec3(dir.y, -dir.x, 0):normalized()
  local rightEdge = roadWidth / 2
  local laneCounts = {}

  for i = 1, totalLanes do
    laneCounts[i] = 0
  end

  for otherId, otherState in pairs(allVehicles) do
    if otherId ~= myVehId then
      local toOther = otherState.position - pos
      local longitudinal = toOther:dot(dir)
      local lateral = toOther:dot(rightVec)

      -- Only count vehicles nearby and ahead/alongside
      if math.abs(longitudinal) < 80 then
        for i = 1, totalLanes do
          local laneCenterFromRight = rightEdge - (i - 0.5) * LANE_WIDTH
          if math.abs(lateral - laneCenterFromRight) < LANE_DETECTION_TOLERANCE then
            laneCounts[i] = laneCounts[i] + 1
            break
          end
        end
      end
    end
  end

  -- Find least occupied lane
  local leastOccupied = 1
  local minCount = laneCounts[1] or 0
  for i = 2, totalLanes do
    if (laneCounts[i] or 0) < minCount then
      minCount = laneCounts[i] or 0
      leastOccupied = i
    end
  end

  return laneCounts, leastOccupied
end

-- ══════════════════════════════════════════════════════════════════════════════
-- LANE CHANGE DECISION MAKING
-- ══════════════════════════════════════════════════════════════════════════════

--- Evaluate whether a lane change is needed and why
---@param vehObj userdata
---@param aiState table
---@param state table
---@param dt number
---@param allVehicles table
---@return string|nil reason
---@return number|nil targetLane
---@return number priority
local function evaluateLaneChangeNeed(vehObj, aiState, state, dt, allVehicles)
  local currentLane = state.currentLane
  local totalLanes = state.totalLanes
  local roadWidth = analyzeRoadLanes(aiState.position, aiState.direction)

  -- Skip if only one lane
  if totalLanes <= 1 then return nil, nil, 0 end

  -- Skip if going too slow
  if aiState.currentSpeed < TRIGGERS.MIN_SPEED_FOR_CHANGE then
    return nil, nil, 0
  end

  -- Skip if in emergency
  if aiState.isInEmergency then return nil, nil, 0 end

  local personality = aiState.personality
  local isAggressive = personality and personality.archetypeId == "aggressive"
  local isPensioner = personality and personality.archetypeId == "pensioner"

  local bestReason = nil
  local bestTarget = nil
  local bestPriority = 0

  -- ── 1. Turn preparation (highest non-emergency priority) ───────────────
  local turnDir, turnDist, turnTargetLane = detectUpcomingTurn(
    aiState.position, aiState.direction)

  if turnDir and turnTargetLane then
    state.upcomingTurnDir = turnDir
    state.upcomingTurnDist = turnDist
    state.upcomingTurnLane = turnTargetLane

    local prepDist = (aiState.roadZoneType == "urban" or aiState.roadZoneType == "residential")
      and TRIGGERS.TURN_PREP_DISTANCE_CITY
      or TRIGGERS.TURN_PREP_DISTANCE

    if turnDist < prepDist and currentLane ~= turnTargetLane then
      bestReason = "turn_prep"
      bestTarget = turnTargetLane
      bestPriority = REASON_PRIORITY.turn_prep

      -- Increase urgency as we get closer
      if turnDist < prepDist * 0.3 then
        bestPriority = bestPriority + 20
      end
    end
  end

  -- ── 2. Overtake slow vehicle ───────────────────────────────────────────
  local hasSlow, slowDist, slowSpeed = findSlowVehicleAhead(
    aiState.position, aiState.direction,
    currentLane, roadWidth, allVehicles,
    aiState.vehicleId, aiState.currentSpeedLimit)

  if hasSlow then
    -- Want to move to the passing lane (left)
    local passingLane = math.min(totalLanes, currentLane + 1)

    -- Aggressive drivers are more eager to overtake
    local priority = REASON_PRIORITY.overtake
    if isAggressive then
      priority = priority + 15
    end

    if priority > bestPriority and bestReason ~= "turn_prep" then
      -- Don't overtake if we need to turn soon
      if not state.upcomingTurnDir or state.upcomingTurnDist > 80 then
        bestReason = "overtake"
        bestTarget = passingLane
        bestPriority = priority
      end
    end
  end

  -- ── 3. Lane balancing (distribute evenly) ──────────────────────────────
  state.balanceCheckTimer = state.balanceCheckTimer + dt

  if state.balanceCheckTimer >= TRIGGERS.BALANCE_CHECK_INTERVAL then
    state.balanceCheckTimer = 0

    local laneCounts, leastOccupied = countVehiclesPerLane(
      aiState.position, aiState.direction,
      totalLanes, roadWidth, allVehicles, aiState.vehicleId)

    local myLaneCount = laneCounts[currentLane] or 0
    local bestLaneCount = laneCounts[leastOccupied] or 0

    -- Only rebalance if current lane has significantly more traffic
    if myLaneCount > bestLaneCount + 2 then
      local priority = REASON_PRIORITY.balance
      if priority > bestPriority then
        -- Only move one lane at a time toward the least occupied
        local target = currentLane
        if leastOccupied > currentLane then
          target = currentLane + 1
        elseif leastOccupied < currentLane then
          target = currentLane - 1
        end

        if target ~= currentLane then
          bestReason = "balance"
          bestTarget = target
          bestPriority = priority
        end
      end
    end
  end

  -- ── 4. Return to right lane (after overtake) ──────────────────────────
  if currentLane > 1 and not hasSlow then
    state.returnToRightTimer = state.returnToRightTimer + dt

    if state.returnToRightTimer > MANEUVER.RETURN_TO_RIGHT_TIME then
      local priority = REASON_PRIORITY.return_right
      if priority > bestPriority then
        bestReason = "return_right"
        bestTarget = currentLane - 1
        bestPriority = priority
      end
    end
  else
    state.returnToRightTimer = 0
  end

  -- ── 5. Obstacle avoidance ─────────────────────────────────────────────
  if aiState.accidentReaction and
     (aiState.accidentReaction == "slowing" or aiState.accidentReaction == "stopped") then
    -- Need to change lane to pass accident
    local avoidTarget = (currentLane > 1) and (currentLane - 1) or (currentLane + 1)
    avoidTarget = math.max(1, math.min(totalLanes, avoidTarget))

    if avoidTarget ~= currentLane then
      local priority = REASON_PRIORITY.obstacle
      if priority > bestPriority then
        bestReason = "obstacle"
        bestTarget = avoidTarget
        bestPriority = priority
      end
    end
  end

  return bestReason, bestTarget, bestPriority
end

-- ══════════════════════════════════════════════════════════════════════════════
-- LANE CHANGE EXECUTION STATE MACHINE
-- ══════════════════════════════════════════════════════════════════════════════

--- Execute the lane change state machine
---@param vehObj userdata
---@param aiState table
---@param state table
---@param dt number
---@param allVehicles table
local function executeLaneChange(vehObj, aiState, state, dt, allVehicles)
  local personality = aiState.personality
  local isAggressive = personality and personality.archetypeId == "aggressive"

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: NONE — check if lane change needed
  -- ══════════════════════════════════════════════════════════════════════════
  if state.phase == "none" then
    -- Cooldown check
    if state.changeCooldown > 0 then
      state.changeCooldown = state.changeCooldown - dt
      return
    end

    local reason, targetLane, priority = evaluateLaneChangeNeed(
      vehObj, aiState, state, dt, allVehicles)

    if reason and targetLane and targetLane ~= state.currentLane then
      state.phase = "evaluating"
      state.reason = reason
      state.reasonPriority = priority
      state.targetLane = targetLane
      state.direction = (targetLane > state.currentLane) and "left" or "right"
      state.phaseTimer = 0
      state.abortTimer = 0
    end

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: EVALUATING — confirm the lane change is still needed
  -- ══════════════════════════════════════════════════════════════════════════
  elseif state.phase == "evaluating" then
    state.phaseTimer = state.phaseTimer + dt

    -- Brief evaluation period
    local evalTime = isAggressive and 0.3 or 0.8

    if state.phaseTimer < evalTime then return end

    -- Re-evaluate: is it still needed?
    local _, _, roadWidth = analyzeRoadLanes(aiState.position, aiState.direction)
    local gapOk = checkGapInLane(
      aiState.position, aiState.direction,
      state.targetLane, state.totalLanes, roadWidth,
      allVehicles, aiState.vehicleId)

    if gapOk then
      state.phase = "signaling"
      state.phaseTimer = 0
      state.gapConfirmed = true
    else
      -- No gap — wait or abort
      state.abortTimer = state.abortTimer + dt
      if state.abortTimer > TRIGGERS.ABORT_TIMEOUT then
        -- Give up
        state.phase = "none"
        state.totalAborts = state.totalAborts + 1
        state.changeCooldown = 3.0
        log("D", "TrafficAI.LaneChanging",
          string.format("Veh %d: lane change aborted (no gap) reason=%s",
            aiState.vehicleId, state.reason))
      end
    end

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: SIGNALING — turn signal on, waiting before moving
  -- ══════════════════════════════════════════════════════════════════════════
  elseif state.phase == "signaling" then
    state.phaseTimer = state.phaseTimer + dt

    -- Activate turn signal
    if not state.signalActive then
      state.signalActive = true
      local useTurnSignals = true
      if personality then
        useTurnSignals = personality.useTurnSignals
      end

      if useTurnSignals then
        local signalName = (state.direction == "left") and "left" or "right"
        vehObj:queueLuaCommand(string.format(
          'electrics.set("signal_%s", 1)', signalName
        ))
      end
    end

    -- Wait for signal lead time (aggressive drivers signal shorter)
    local signalTime = isAggressive and 0.5 or MANEUVER.SIGNAL_LEAD_TIME

    if state.phaseTimer >= signalTime then
      state.phase = "checking"
      state.phaseTimer = 0
    end

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: CHECKING — final mirror check before moving
  -- ══════════════════════════════════════════════════════════════════════════
  elseif state.phase == "checking" then
    state.phaseTimer = state.phaseTimer + dt

    -- "Check mirrors" — actually re-verify gap
    if state.phaseTimer < MANEUVER.MIRROR_CHECK_TIME then return end

    local _, _, roadWidth = analyzeRoadLanes(aiState.position, aiState.direction)
    local gapOk, gapAhead, gapBehind = checkGapInLane(
      aiState.position, aiState.direction,
      state.targetLane, state.totalLanes, roadWidth,
      allVehicles, aiState.vehicleId)

    -- Distracted drivers might not check blind spot properly
    if personality and personality.blindSpotFailRate then
      if math.random() < personality.blindSpotFailRate then
        gapOk = true -- "didn't see" the vehicle in blind spot!
        log("D", "TrafficAI.LaneChanging",
          string.format("Veh %d: BLIND SPOT MISS during lane change!",
            aiState.vehicleId))
      end
    end

    if gapOk then
      state.phase = "executing"
      state.phaseTimer = 0
      state.mirrorChecked = true

      -- Calculate target offset
      local laneShift = state.targetLane - state.currentLane
      state.targetOffset = laneShift * LANE_WIDTH
      -- Negative = right in our coordinate system
      if state.direction == "right" then
        state.targetOffset = -math.abs(state.targetOffset)
      else
        state.targetOffset = math.abs(state.targetOffset)
      end

      log("D", "TrafficAI.LaneChanging",
        string.format("Veh %d: executing lane change %s (lane %d→%d) reason=%s",
          aiState.vehicleId, state.direction,
          state.currentLane, state.targetLane, state.reason))
    else
      -- Gap closed! Abort or wait
      if state.reasonPriority >= REASON_PRIORITY.obstacle then
        -- High priority: keep waiting
        state.phase = "evaluating"
        state.phaseTimer = 0
      else
        -- Low priority: abort
        state.phase = "none"
        state.signalActive = false
        state.totalAborts = state.totalAborts + 1
        state.changeCooldown = 2.0
        -- Turn off signal
        vehObj:queueLuaCommand('electrics.set("signal_left", 0)')
        vehObj:queueLuaCommand('electrics.set("signal_right", 0)')
      end
    end

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: EXECUTING — actually moving to new lane
  -- ══════════════════════════════════════════════════════════════════════════
  elseif state.phase == "executing" then
    state.phaseTimer = state.phaseTimer + dt

    -- Duration depends on personality
    local changeDuration = MANEUVER.CHANGE_DURATION_SLOW
    if personality then
      changeDuration = personality.laneChangeSpeed or changeDuration
    end
    if isAggressive then
      changeDuration = MANEUVER.CHANGE_DURATION_FAST
    end

    -- Progress: 0 → 1 over the change duration
    local progress = math.min(1.0, state.phaseTimer / changeDuration)

    -- Smooth S-curve interpolation
    local smoothProgress = progress * progress * (3 - 2 * progress) -- smoothstep

    -- Current offset
    state.offset = state.targetOffset * smoothProgress

    -- Apply offset to AI routing
    vehObj:queueLuaCommand(string.format(
      'ai.driveUsingPath({avoidCars = "on", routeOffset = %.2f})',
      state.offset
    ))

    -- Complete when done
    if progress >= 1.0 then
      state.phase = "completing"
      state.phaseTimer = 0
    end

    -- Safety: abort if collision imminent during change
    if aiState.isInEmergency then
      state.phase = "none"
      state.offset = 0
      state.signalActive = false
      state.totalAborts = state.totalAborts + 1
      vehObj:queueLuaCommand('electrics.set("signal_left", 0)')
      vehObj:queueLuaCommand('electrics.set("signal_right", 0)')
    end

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: COMPLETING — settling into new lane
  -- ══════════════════════════════════════════════════════════════════════════
  elseif state.phase == "completing" then
    state.phaseTimer = state.phaseTimer + dt

    -- Turn off signal
    if state.signalActive and state.phaseTimer > 0.5 then
      state.signalActive = false
      vehObj:queueLuaCommand('electrics.set("signal_left", 0)')
      vehObj:queueLuaCommand('electrics.set("signal_right", 0)')
    end

    -- Reset after settling
    if state.phaseTimer > 1.0 then
      local prevLane = state.currentLane
      state.currentLane = state.targetLane
      state.phase = "none"
      state.offset = 0
      state.targetOffset = 0
      state.reason = nil
      state.consecutiveChanges = state.consecutiveChanges + 1
      state.totalChanges = state.totalChanges + 1

      -- Cooldown to prevent constant lane hopping
      if state.consecutiveChanges > 2 then
        state.changeCooldown = 8.0  -- long cooldown after multiple changes
      else
        state.changeCooldown = 3.0  -- normal cooldown
      end

      -- Reset consecutive counter after a while
      if state.consecutiveChanges > 3 then
        state.consecutiveChanges = 0
      end

      -- Reset route offset
      vehObj:queueLuaCommand('ai.driveUsingPath({avoidCars = "on", routeOffset = 0})')

      log("D", "TrafficAI.LaneChanging",
        string.format("Veh %d: lane change complete (lane %d→%d) total=%d",
          aiState.vehicleId, prevLane, state.currentLane, state.totalChanges))
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UPDATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Update dynamic lane changing for a vehicle
---@param vehObj userdata
---@param aiState table
---@param dt number
---@param allVehicles table
function M.update(vehObj, aiState, dt, allVehicles)
  local vehId = aiState.vehicleId
  local state = getState(vehId)

  -- Update current lane info
  local currentLane, totalLanes, roadWidth, laneOffset = analyzeRoadLanes(
    aiState.position, aiState.direction)

  state.currentLane = currentLane
  state.totalLanes = totalLanes

  -- Write to aiState for other modules
  aiState.currentLaneIndex = currentLane
  aiState.laneCount = totalLanes

  -- Don't process lane changes during emergency avoidance
  if aiState.isInEmergency and state.phase ~= "executing" then
    return
  end

  -- Execute lane change state machine
  executeLaneChange(vehObj, aiState, state, dt, allVehicles)

  -- Write lane change state to aiState
  aiState.laneChangePhase = state.phase
  aiState.laneChangeDirection = state.direction
  aiState.laneChangeReason = state.reason
  aiState.laneChangeOffset = state.offset
  aiState.upcomingTurnDir = state.upcomingTurnDir
  aiState.upcomingTurnDist = state.upcomingTurnDist
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

function M.getLaneChangeState(vehId)
  return laneChangeStates[vehId]
end

function M.getLaneChangeStats(vehId)
  local s = laneChangeStates[vehId]
  if not s then return nil end
  return {
    phase = s.phase,
    reason = s.reason,
    currentLane = s.currentLane,
    totalLanes = s.totalLanes,
    totalChanges = s.totalChanges,
    totalAborts = s.totalAborts,
    upcomingTurn = s.upcomingTurnDir,
    upcomingTurnDist = s.upcomingTurnDist,
  }
end

function M.removeVehicle(vehId)
  laneChangeStates[vehId] = nil
end

--- Force a lane change (for testing)
function M.forceLaneChange(vehId, targetLane)
  local state = getState(vehId)
  state.phase = "evaluating"
  state.targetLane = targetLane
  state.reason = "forced"
  state.reasonPriority = 100
  state.phaseTimer = 0
end

return M