-- ============================================================================
-- emergencyAvoidance.lua
-- Emergency collision avoidance: dodge oncoming vehicles, panic braking,
-- steering to shoulder, reaction to imminent threats
-- BeamNG.drive 0.38.3
-- ============================================================================

local M = {}

-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Threat detection cone: half-angle in degrees
local THREAT_CONE_HALF_ANGLE = 25

--- Detection ranges (meters)
local DETECTION = {
  ONCOMING_MAX_RANGE     = 120,  -- макс. дистанция обнаружения встречного
  ONCOMING_DANGER_RANGE  = 60,   -- "опасная" зона — начинаем реагировать
  ONCOMING_CRITICAL      = 25,   -- критическая — экстренный манёвр
  SIDE_COLLISION_RANGE   = 8,    -- боковое столкновение
  REAR_CHECK_RANGE       = 15,   -- проверка сзади перед уклонением
  OBSTACLE_STATIC_RANGE  = 40,   -- статическое препятствие впереди
}

--- Time-to-collision threshold (seconds)
local TTC_DANGER    = 3.0   -- начинаем реагировать
local TTC_CRITICAL  = 1.5   -- экстренное торможение
local TTC_PANIC     = 0.8   -- паника — руль + тормоз одновременно

--- Dodge lateral offset (meters)
local DODGE_OFFSET_NORMAL   = 3.0  -- обычное уклонение
local DODGE_OFFSET_EMERGENCY = 5.0 -- экстренное — на обочину
local DODGE_OFFSET_DITCH     = 7.0 -- в кювет — последнее средство

--- Brake force levels
local BRAKE = {
  GENTLE   = 0.3,
  FIRM     = 0.6,
  HARD     = 0.85,
  PANIC    = 1.0,   -- ABS will kick in on modern cars
  LOCKUP   = 1.0,   -- full lock for old cars without ABS
}

--- Recovery: how quickly to return to normal after threat passes (seconds)
local RECOVERY_TIME = 3.0

--- Shoulder detection: max width of usable shoulder (meters)
local MAX_SHOULDER_WIDTH = 4.0

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Per-vehicle avoidance state
local avoidanceStates = {}
--[[ Structure:
  {
    phase = "none" | "alert" | "braking" | "dodging" | "recovering",
    threatVehId = number|nil,
    threatType = "oncoming" | "side" | "static" | "cutoff",
    threatTTC = number,         -- time to collision
    threatDirection = vec3,     -- direction of threat
    dodgeDirection = "left" | "right",
    dodgeOffset = number,
    brakeForce = number,
    steerOverride = number,     -- -1..1 steering override
    phaseTimer = number,
    recoveryTimer = number,
    panicBrakeActive = false,
    hazardLightsOn = false,
    hornActive = false,
    hornTimer = 0,
    lastThreatTime = 0,
    totalDodges = 0,
    totalPanicBrakes = 0,
  }
]]

-- ══════════════════════════════════════════════════════════════════════════════
-- INIT
-- ══════════════════════════════════════════════════════════════════════════════

function M.init()
  avoidanceStates = {}
  log("I", "TrafficAI.Avoidance", "Emergency avoidance system initialized.")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════════════════════════════════

--- Get or create avoidance state for a vehicle
---@param vehId number
---@return table
local function getState(vehId)
  if not avoidanceStates[vehId] then
    avoidanceStates[vehId] = {
      phase              = "none",
      threatVehId        = nil,
      threatType         = nil,
      threatTTC          = math.huge,
      threatDirection    = vec3(0, 0, 0),
      dodgeDirection     = "right",
      dodgeOffset        = 0,
      brakeForce         = 0,
      steerOverride      = 0,
      phaseTimer         = 0,
      recoveryTimer      = 0,
      panicBrakeActive   = false,
      hazardLightsOn     = false,
      hornActive         = false,
      hornTimer          = 0,
      lastThreatTime     = 0,
      totalDodges        = 0,
      totalPanicBrakes   = 0,
    }
  end
  return avoidanceStates[vehId]
end

--- Calculate time-to-collision between two vehicles
---@param posA vec3
---@param velA vec3
---@param posB vec3
---@param velB vec3
---@return number ttc  (math.huge if no collision expected)
---@return number closestDist  closest approach distance
local function calculateTTC(posA, velA, posB, velB)
  local relPos = posB - posA
  local relVel = velB - velA

  local relSpeed = relVel:length()
  if relSpeed < 0.5 then
    return math.huge, relPos:length()
  end

  -- Project relative position onto relative velocity
  local relVelNorm = relVel:normalized()
  local approach = -relPos:dot(relVelNorm)

  if approach <= 0 then
    -- Moving apart
    return math.huge, relPos:length()
  end

  local ttc = relPos:length() / relSpeed

  -- Calculate closest approach distance (perpendicular distance)
  local closestPoint = relPos + relVel * ttc
  local closestDist = (relPos + relVel * (approach / relSpeed)):length()

  -- More accurate: find time of closest approach
  local a = relVel:dot(relVel)
  local b = 2 * relPos:dot(relVel)
  local c = relPos:dot(relPos)

  if a > 0.001 then
    local tClosest = -b / (2 * a)
    if tClosest > 0 then
      local distAtClosest = math.sqrt(math.max(0, c + b * tClosest + a * tClosest * tClosest))
      return tClosest, distAtClosest
    end
  end

  return ttc, closestDist
end

--- Determine which side to dodge to
---@param myPos vec3
---@param myDir vec3
---@param threatPos vec3
---@return string "left" | "right"
---@return number shoulderWidth  estimated available space
local function determineDodgeDirection(myPos, myDir, threatPos)
  local toThreat = (threatPos - myPos):normalized()

  -- Right-hand vector (perpendicular to forward direction, 2D)
  local rightVec = vec3(myDir.y, -myDir.x, 0):normalized()

  -- Is threat coming from left or right?
  local lateralComponent = toThreat:dot(rightVec)

  -- Check road boundaries on each side
  local mapData = map and map.getMap() or nil
  local leftSpace = MAX_SHOULDER_WIDTH
  local rightSpace = MAX_SHOULDER_WIDTH

  if mapData and mapData.nodes then
    local closestNode = nil
    local closestDist = math.huge
    for _, nodeData in pairs(mapData.nodes) do
      if nodeData.pos then
        local d = (myPos - nodeData.pos):length()
        if d < closestDist then
          closestDist = d
          closestNode = nodeData
        end
      end
    end

    if closestNode then
      local roadWidth = (closestNode.radius or 4) * 2
      local toNode = myPos - closestNode.pos
      local myLateralPos = toNode:dot(rightVec)

      -- Available space on each side
      rightSpace = (roadWidth / 2) - myLateralPos + 2 -- +2 for shoulder
      leftSpace = (roadWidth / 2) + myLateralPos + 2
    end
  end

  -- Prefer dodging AWAY from threat
  -- In right-hand traffic, prefer going RIGHT (toward shoulder)
  if lateralComponent > 0.2 then
    -- Threat is from right → dodge left
    if leftSpace > 2.0 then
      return "left", leftSpace
    else
      return "right", rightSpace
    end
  elseif lateralComponent < -0.2 then
    -- Threat is from left → dodge right
    if rightSpace > 2.0 then
      return "right", rightSpace
    else
      return "left", leftSpace
    end
  else
    -- Threat is head-on → prefer right (standard emergency protocol)
    if rightSpace >= leftSpace then
      return "right", rightSpace
    else
      return "left", leftSpace
    end
  end
end

--- Check if there are vehicles behind that would be hit if we brake suddenly
---@param myPos vec3
---@param myDir vec3
---@param allVehicles table
---@param myVehId number
---@return boolean hasTailgater
---@return number distBehind
local function checkBehind(myPos, myDir, allVehicles, myVehId)
  local behindDir = -myDir

  for otherId, otherState in pairs(allVehicles) do
    if otherId ~= myVehId then
      local toOther = otherState.position - myPos
      local behindDist = toOther:dot(behindDir)

      if behindDist > 0 and behindDist < DETECTION.REAR_CHECK_RANGE then
        local lateral = math.sqrt(math.max(0,
          toOther:lengthSquared() - behindDist * behindDist))
        if lateral < 2.5 then
          return true, behindDist
        end
      end
    end
  end
  return false, math.huge
end

-- ══════════════════════════════════════════════════════════════════════════════
-- THREAT DETECTION
-- ══════════════════════════════════════════════════════════════════════════════

--- Scan for all threats around the vehicle
---@param vehObj userdata
---@param aiState table
---@param allVehicles table
---@return table threats  list of { vehId, type, ttc, distance, direction, relSpeed }
local function detectThreats(vehObj, aiState, allVehicles)
  local threats = {}
  local myPos = aiState.position
  local myDir = aiState.direction
  local myVel = myDir * (aiState.currentSpeed / 3.6)
  local myVehId = aiState.vehicleId

  -- Cone detection angle
  local coneAngle = math.rad(THREAT_CONE_HALF_ANGLE)

  for otherId, otherState in pairs(allVehicles) do
    if otherId ~= myVehId then
      local otherObj = be:getObjectByID(otherId)
      if otherObj then
        local otherPos = otherState.position
        local otherVel = otherState.direction * (otherState.currentSpeed / 3.6)
        local toOther = otherPos - myPos
        local dist = toOther:length()

        if dist < DETECTION.ONCOMING_MAX_RANGE then
          local toOtherNorm = toOther:normalized()

          -- ── Check oncoming (head-on) ─────────────────────────────────
          local headingDot = myDir:dot(otherState.direction)
          local approachDot = myDir:dot(toOtherNorm)

          if headingDot < -0.3 and approachDot > math.cos(coneAngle) then
            -- Vehicles heading toward each other
            local ttc, closestDist = calculateTTC(myPos, myVel, otherPos, otherVel)

            -- Is this a real threat? (will they actually come close?)
            if closestDist < 4.0 and ttc < TTC_DANGER then
              table.insert(threats, {
                vehId     = otherId,
                type      = "oncoming",
                ttc       = ttc,
                distance  = dist,
                direction = toOtherNorm,
                relSpeed  = (myVel - otherVel):length() * 3.6,
                closestDist = closestDist,
              })
            end
          end

          -- ── Check side collision (cut-off / merge) ───────────────────
          if dist < DETECTION.SIDE_COLLISION_RANGE then
            local ttc, closestDist = calculateTTC(myPos, myVel, otherPos, otherVel)
            if closestDist < 2.5 and ttc < TTC_CRITICAL then
              -- Check if it's not behind us
              if approachDot > -0.3 then
                table.insert(threats, {
                  vehId     = otherId,
                  type      = "side",
                  ttc       = ttc,
                  distance  = dist,
                  direction = toOtherNorm,
                  relSpeed  = (myVel - otherVel):length() * 3.6,
                  closestDist = closestDist,
                })
              end
            end
          end

          -- ── Check cut-off (vehicle merging into our lane) ────────────
          if dist < 30 and approachDot > 0.5 then
            -- Other vehicle is ahead and roughly same direction
            -- but drifting into our lane
            local rightVec = vec3(myDir.y, -myDir.x, 0):normalized()
            local lateralSpeed = otherVel:dot(rightVec)
            local lateralPos = toOther:dot(rightVec)

            -- Moving toward our lane from the side
            if math.abs(lateralPos) < 5 and math.abs(lateralPos) > 1.5 then
              if (lateralPos > 0 and lateralSpeed < -1) or
                 (lateralPos < 0 and lateralSpeed > 1) then
                table.insert(threats, {
                  vehId     = otherId,
                  type      = "cutoff",
                  ttc       = math.abs(lateralPos / lateralSpeed),
                  distance  = dist,
                  direction = toOtherNorm,
                  relSpeed  = math.abs(lateralSpeed) * 3.6,
                  closestDist = math.abs(lateralPos),
                })
              end
            end
          end
        end
      end
    end
  end

  -- ── Check for static obstacles (stopped vehicles, wreckage) ────────────
  for otherId, otherState in pairs(allVehicles) do
    if otherId ~= myVehId then
      if otherState.currentSpeed < 3 then -- practically stopped
        local toOther = otherState.position - myPos
        local dist = toOther:length()
        local toOtherNorm = toOther:normalized()
        local approachDot = myDir:dot(toOtherNorm)

        if approachDot > 0.7 and dist < DETECTION.OBSTACLE_STATIC_RANGE then
          local lateral = math.sqrt(math.max(0,
            toOther:lengthSquared() - (toOther:dot(myDir))^2))
          if lateral < 3.0 then
            local ttc = dist / math.max(0.5, aiState.currentSpeed / 3.6)
            table.insert(threats, {
              vehId     = otherId,
              type      = "static",
              ttc       = ttc,
              distance  = dist,
              direction = toOtherNorm,
              relSpeed  = aiState.currentSpeed,
              closestDist = lateral,
            })
          end
        end
      end
    end
  end

  -- Sort by TTC (most urgent first)
  table.sort(threats, function(a, b) return a.ttc < b.ttc end)

  return threats
end

-- ══════════════════════════════════════════════════════════════════════════════
-- AVOIDANCE STATE MACHINE
-- ══════════════════════════════════════════════════════════════════════════════

--- Process the avoidance state machine for one vehicle
---@param vehObj userdata
---@param aiState table
---@param state table  avoidance state
---@param threats table
---@param dt number
---@param allVehicles table
local function processAvoidance(vehObj, aiState, state, threats, dt, allVehicles)
  local personality = aiState.personality
  local reactionTime = (personality and personality.reactionTime) or 0.5
  local attentionLevel = (personality and personality.attentionLevel) or 0.9

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: NONE — no active threat
  -- ══════════════════════════════════════════════════════════════════════════
  if state.phase == "none" then
    if #threats == 0 then return end

    local primaryThreat = threats[1]

    -- Attention check: distracted drivers might not notice
    if math.random() > attentionLevel then
      -- Didn't notice the threat! (reduced reaction)
      if primaryThreat.ttc > TTC_CRITICAL then
        return -- missed it completely until it's critical
      end
      -- At critical range, even distracted drivers notice
      reactionTime = reactionTime * 2
    end

    -- Transition based on threat severity
    if primaryThreat.ttc <= TTC_PANIC then
      state.phase = "dodging"  -- skip to emergency dodge
      state.phaseTimer = 0
    elseif primaryThreat.ttc <= TTC_CRITICAL then
      state.phase = "braking"
      state.phaseTimer = 0
    elseif primaryThreat.ttc <= TTC_DANGER then
      state.phase = "alert"
      state.phaseTimer = 0
    end

    state.threatVehId = primaryThreat.vehId
    state.threatType = primaryThreat.type
    state.threatTTC = primaryThreat.ttc
    state.threatDirection = primaryThreat.direction

    log("D", "TrafficAI.Avoidance",
      string.format("Veh %d: THREAT detected! type=%s ttc=%.1fs dist=%.0fm → phase=%s",
        aiState.vehicleId, primaryThreat.type, primaryThreat.ttc,
        primaryThreat.distance, state.phase))

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: ALERT — threat detected, preparing to react
  -- ══════════════════════════════════════════════════════════════════════════
  elseif state.phase == "alert" then
    state.phaseTimer = state.phaseTimer + dt

    -- Wait for reaction time before acting
    if state.phaseTimer < reactionTime then
      -- During reaction time, only light braking
      state.brakeForce = BRAKE.GENTLE
      return
    end

    -- Re-evaluate threat
    local stillThreat = false
    for _, t in ipairs(threats) do
      if t.vehId == state.threatVehId then
        state.threatTTC = t.ttc
        stillThreat = true
        break
      end
    end

    if not stillThreat or state.threatTTC > TTC_DANGER * 1.5 then
      -- Threat gone
      state.phase = "recovering"
      state.recoveryTimer = 0
      return
    end

    -- Escalate if needed
    if state.threatTTC <= TTC_CRITICAL then
      state.phase = "braking"
      state.phaseTimer = 0
    else
      -- Moderate braking
      state.brakeForce = BRAKE.FIRM

      -- Start determining dodge direction
      local dodgeDir, space = determineDodgeDirection(
        aiState.position, aiState.direction,
        be:getObjectByID(state.threatVehId):getPosition()
      )
      state.dodgeDirection = dodgeDir

      -- Honk!
      if not state.hornActive then
        state.hornActive = true
        state.hornTimer = 1.5
        vehObj:queueLuaCommand('electrics.horn(true)')
      end
    end

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: BRAKING — hard braking, preparing to dodge
  -- ══════════════════════════════════════════════════════════════════════════
  elseif state.phase == "braking" then
    state.phaseTimer = state.phaseTimer + dt

    -- Re-evaluate threat
    local currentThreat = nil
    for _, t in ipairs(threats) do
      if t.vehId == state.threatVehId then
        currentThreat = t
        state.threatTTC = t.ttc
        break
      end
    end

    if not currentThreat then
      -- Threat resolved
      state.phase = "recovering"
      state.recoveryTimer = 0
      return
    end

    -- Hard braking
    state.brakeForce = BRAKE.HARD
    state.panicBrakeActive = true

    -- Apply emergency braking
    vehObj:queueLuaCommand(string.format(
      'input.event("brake", %.3f, 2)', state.brakeForce
    ))

    -- Flash headlights
    vehObj:queueLuaCommand('electrics.toggle_highbeam()')

    -- Turn on hazard lights
    if not state.hazardLightsOn then
      state.hazardLightsOn = true
      vehObj:queueLuaCommand('electrics.set("hazard", 1)')
    end

    -- If TTC drops below panic threshold, DODGE
    if state.threatTTC <= TTC_PANIC then
      state.phase = "dodging"
      state.phaseTimer = 0

      -- Determine dodge direction with road context
      local threatObj = be:getObjectByID(state.threatVehId)
      if threatObj then
        local dodgeDir, space = determineDodgeDirection(
          aiState.position, aiState.direction,
          threatObj:getPosition()
        )
        state.dodgeDirection = dodgeDir

        -- How far to dodge based on available space
        if space > 5 then
          state.dodgeOffset = DODGE_OFFSET_EMERGENCY
        elseif space > 3 then
          state.dodgeOffset = DODGE_OFFSET_NORMAL
        else
          state.dodgeOffset = DODGE_OFFSET_DITCH
        end
      end

      state.totalDodges = state.totalDodges + 1
      log("D", "TrafficAI.Avoidance",
        string.format("Veh %d: PANIC DODGE %s! TTC=%.1fs offset=%.1fm",
          aiState.vehicleId, state.dodgeDirection,
          state.threatTTC, state.dodgeOffset))
    end

    -- Continuous horn
    if not state.hornActive then
      state.hornActive = true
      state.hornTimer = 3.0
      vehObj:queueLuaCommand('electrics.horn(true)')
    end

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: DODGING — emergency steering maneuver
  -- ══════════════════════════════════════════════════════════════════════════
  elseif state.phase == "dodging" then
    state.phaseTimer = state.phaseTimer + dt

    -- FULL BRAKE + STEER simultaneously
    state.brakeForce = BRAKE.PANIC
    state.panicBrakeActive = true

    -- Apply maximum braking
    vehObj:queueLuaCommand(string.format(
      'input.event("brake", %.3f, 2)', BRAKE.PANIC
    ))

    -- Calculate steering override
    local steerAmount = 0
    local steerSign = (state.dodgeDirection == "right") and 1 or -1

    -- Progressive steering: ramp up quickly, then hold
    local steerRamp = math.min(1.0, state.phaseTimer / 0.3) -- 0.3s to full lock
    steerAmount = steerSign * steerRamp * 0.8 -- 80% of full lock

    -- Reduce steering at very high speed to prevent spin
    if aiState.currentSpeed > 80 then
      steerAmount = steerAmount * (80 / aiState.currentSpeed)
    end

    state.steerOverride = steerAmount

    -- Apply steering override
    vehObj:queueLuaCommand(string.format(
      'input.event("steering", %.4f, 2)', steerAmount
    ))

    -- Apply AI route offset for the dodge
    local offsetValue = state.dodgeOffset * steerSign
    vehObj:queueLuaCommand(string.format(
      'ai.driveUsingPath({avoidCars = "on", routeOffset = %.2f})',
      offsetValue
    ))

    -- Check if threat has passed
    local threatPassed = true
    for _, t in ipairs(threats) do
      if t.vehId == state.threatVehId then
        if t.ttc < TTC_DANGER then
          threatPassed = false
        end
        break
      end
    end

    -- Or if dodge has been going on long enough
    if state.phaseTimer > 3.0 or threatPassed then
      state.phase = "recovering"
      state.recoveryTimer = 0
      state.totalPanicBrakes = state.totalPanicBrakes + 1
      log("D", "TrafficAI.Avoidance",
        string.format("Veh %d: dodge maneuver complete, recovering",
          aiState.vehicleId))
    end

  -- ══════════════════════════════════════════════════════════════════════════
  -- PHASE: RECOVERING — returning to normal driving
  -- ══════════════════════════════════════════════════════════════════════════
  elseif state.phase == "recovering" then
    state.recoveryTimer = state.recoveryTimer + dt

    local recoveryProgress = math.min(1.0, state.recoveryTimer / RECOVERY_TIME)

    -- Gradually reduce brake force
    state.brakeForce = BRAKE.GENTLE * (1 - recoveryProgress)

    -- Gradually return steering to center
    state.steerOverride = state.steerOverride * (1 - recoveryProgress)

    -- Gradually return to lane
    local currentOffset = state.dodgeOffset * (1 - recoveryProgress)
    if math.abs(currentOffset) > 0.1 then
      local sign = (state.dodgeDirection == "right") and 1 or -1
      vehObj:queueLuaCommand(string.format(
        'ai.driveUsingPath({avoidCars = "on", routeOffset = %.2f})',
        currentOffset * sign
      ))
    end

    -- Release controls gradually
    if recoveryProgress > 0.3 then
      vehObj:queueLuaCommand(string.format(
        'input.event("brake", %.3f, 2)', state.brakeForce
      ))
    end

    -- Turn off hazard lights after some time
    if recoveryProgress > 0.7 and state.hazardLightsOn then
      state.hazardLightsOn = false
      vehObj:queueLuaCommand('electrics.set("hazard", 0)')
    end

    -- Stop horn
    if state.hornActive then
      state.hornActive = false
      vehObj:queueLuaCommand('electrics.horn(false)')
    end

    -- Fully recovered
    if recoveryProgress >= 1.0 then
      state.phase = "none"
      state.brakeForce = 0
      state.steerOverride = 0
      state.dodgeOffset = 0
      state.panicBrakeActive = false
      state.threatVehId = nil
      state.threatType = nil

      -- Reset AI controls
      vehObj:queueLuaCommand('ai.driveUsingPath({avoidCars = "on", routeOffset = 0})')
      vehObj:queueLuaCommand('input.event("brake", 0, 2)')

      log("D", "TrafficAI.Avoidance",
        string.format("Veh %d: fully recovered from avoidance",
          aiState.vehicleId))
    end
  end

  -- ── Horn timer management ──────────────────────────────────────────────
  if state.hornActive then
    state.hornTimer = state.hornTimer - dt
    if state.hornTimer <= 0 then
      state.hornActive = false
      vehObj:queueLuaCommand('electrics.horn(false)')
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UPDATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Update emergency avoidance for a vehicle
---@param vehObj userdata
---@param aiState table
---@param dt number
---@param allVehicles table
function M.update(vehObj, aiState, dt, allVehicles)
  local vehId = aiState.vehicleId
  local state = getState(vehId)

  -- Detect threats
  local threats = detectThreats(vehObj, aiState, allVehicles)

  -- Process avoidance state machine
  processAvoidance(vehObj, aiState, state, threats, dt, allVehicles)

  -- Write avoidance state into aiState for other modules
  aiState.avoidancePhase = state.phase
  aiState.avoidanceBrake = state.brakeForce
  aiState.avoidanceSteer = state.steerOverride
  aiState.isInEmergency = (state.phase ~= "none" and state.phase ~= "recovering")
  aiState.hazardLightsOn = state.hazardLightsOn

  -- Override speed if in emergency
  if state.panicBrakeActive then
    aiState.waitingAtSignal = true -- force stop through existing mechanism
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

function M.getAvoidanceState(vehId)
  return avoidanceStates[vehId]
end

function M.getAvoidanceStats(vehId)
  local s = avoidanceStates[vehId]
  if not s then return nil end
  return {
    phase = s.phase,
    totalDodges = s.totalDodges,
    totalPanicBrakes = s.totalPanicBrakes,
    hazardLightsOn = s.hazardLightsOn,
  }
end

function M.removeVehicle(vehId)
  avoidanceStates[vehId] = nil
end

return M