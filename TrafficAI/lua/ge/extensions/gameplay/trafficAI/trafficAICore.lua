-- ============================================================================
-- trafficAICore.lua v3.5.0
-- ALL FIXES APPLIED: real collisions, real police, real go-around,
-- real notifications, no wheel jitter
-- ============================================================================

local M = {}
M.version = "3.5.0"

-- Modules
local speedLimits         = require("gameplay/trafficAI/speedLimits")
local laneDiscipline      = require("gameplay/trafficAI/laneDiscipline")
local trafficSignals      = require("gameplay/trafficAI/trafficSignals")
local driverPersonality   = require("gameplay/trafficAI/driverPersonality")
local vehicleDiversity    = require("gameplay/trafficAI/vehicleDiversity")
local emergencyAvoidance  = require("gameplay/trafficAI/emergencyAvoidance")
local accidentReaction    = require("gameplay/trafficAI/accidentReaction")
local dynamicLaneChanging = require("gameplay/trafficAI/dynamicLaneChanging")
local vehicleStability    = require("gameplay/trafficAI/vehicleStability")
local aiAccidents         = require("gameplay/trafficAI/aiAccidents")
local policeResponse      = require("gameplay/trafficAI/policeResponse")
local playerInteraction   = require("gameplay/trafficAI/playerInteraction")
local uiNotifications     = require("gameplay/trafficAI/uiNotifications")

local initialized = false
local managed = {}
local updateTimer = 0
local UPDATE_INTERVAL = 0.1
local simTime = 0

-- ══════════════════════════════════════════════════════════════════════════════
-- INIT
-- ══════════════════════════════════════════════════════════════════════════════

local function initialize()
  if initialized then return end
  log("I", "TrafficAI", "═══ Advanced Traffic AI v" .. M.version .. " ═══")

  speedLimits.init()
  laneDiscipline.init()
  trafficSignals.init()
  driverPersonality.init()
  vehicleDiversity.init()
  emergencyAvoidance.init()
  accidentReaction.init()
  dynamicLaneChanging.init()
  vehicleStability.init()
  aiAccidents.init()
  policeResponse.init()
  playerInteraction.init()
  uiNotifications.init()

  aiAccidents.setPoliceModule(policeResponse)
  policeResponse.setAIAccidentsModule(aiAccidents)

  uiNotifications.notify("info", "Traffic AI v" .. M.version .. " загружен ✓", 4)
  initialized = true
end

-- ══════════════════════════════════════════════════════════════════════════════
-- VEHICLE STATE
-- ══════════════════════════════════════════════════════════════════════════════

local function newState(vehId)
  return {
    vehicleId = vehId,
    currentSpeedLimit = 60, roadZoneType = "urban",
    currentLaneIndex = 1, laneCount = 2,
    isOncoming = false, canOvertake = false,
    overtakeState = "none", overtakeTimer = 0,
    nextSignalType = "none", distToNextSignal = math.huge,
    waitingAtSignal = false, rightOfWayCheck = false,
    greenStartDelay = 0.5,
    brakeMultiplier = 1.0, followDistance = 12,
    reactionTime = 0.5, laneChangeSpeed = 2.0,
    attentionLevel = 0.9, lateralOffset = 0,
    personality = nil, archetypeId = nil,
    avoidancePhase = "none", avoidanceBrake = 0,
    isInEmergency = false, hazardLightsOn = false,
    accidentReaction = "none", accidentDistance = math.huge,
    isInJam = false, isInAccident = false,
    laneChangePhase = "none", laneChangeDirection = nil,
    laneChangeReason = nil, laneChangeOffset = 0,
    upcomingTurnDir = nil, upcomingTurnDist = math.huge,
    playerInteraction = nil,
    _now = 0,
    currentSpeed = 0, desiredSpeed = 60,
    position = vec3(0,0,0), direction = vec3(0,1,0),
  }
end

function M.registerVehicle(vehId)
  if managed[vehId] then return end
  if policeResponse.isPoliceVehicle(vehId) then return end
  managed[vehId] = newState(vehId)
  local p = vehicleDiversity.getVehicleProfile(vehId)
  driverPersonality.generatePersonality(vehId, p and p.suggestedPersonality)
end

function M.unregisterVehicle(vehId)
  managed[vehId] = nil
  driverPersonality.removePersonality(vehId)
  vehicleDiversity.removeVehicle(vehId)
  emergencyAvoidance.removeVehicle(vehId)
  accidentReaction.removeVehicle(vehId)
  dynamicLaneChanging.removeVehicle(vehId)
  vehicleStability.removeVehicle(vehId)
  aiAccidents.removeVehicle(vehId)
  playerInteraction.removeVehicle(vehId)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UPDATE
-- ══════════════════════════════════════════════════════════════════════════════

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not initialized then initialize() end

  updateTimer = updateTimer + dtSim
  if updateTimer < UPDATE_INTERVAL then return end
  local dt = updateTimer
  updateTimer = 0
  simTime = simTime + dt

  -- ── Global updates ─────────────────────────────────────────────────────
  playerInteraction.updatePlayerState(dt)
  policeResponse.update(dt)
  uiNotifications.update(dt)

  -- Blocking/wrong side notifications
  if playerInteraction.isPlayerBlocking() then
    uiNotifications.playerBlockingWarning(playerInteraction.getPlayerBlockTime())
  end
  if playerInteraction.isPlayerOnWrongSide() then
    uiNotifications.wrongSideWarning()
  end

  -- ── Auto-discover vehicles ─────────────────────────────────────────────
  local allVeh = getAllVehicles and getAllVehicles() or {}
  for _, v in ipairs(allVeh) do
    local id = v:getId()
    if id ~= be:getPlayerVehicleID(0) and not managed[id]
       and not policeResponse.isPoliceVehicle(id) then
      if be:getObjectByID(id) then M.registerVehicle(id) end
    end
  end

  -- ══════════════════════════════════════════════════════════════════════════
  -- PER-VEHICLE PIPELINE
  -- ══════════════════════════════════════════════════════════════════════════

  for vehId, ai in pairs(managed) do
    local obj = be:getObjectByID(vehId)
    if not obj then
      managed[vehId] = nil
    else
      -- Read
      local pos = obj:getPosition()
      local vel = obj:getVelocity()
      local spd = vel:length()
      ai.position = pos
      ai.currentSpeed = spd * 3.6
      if spd > 0.5 then ai.direction = vel:normalized() end
      ai._now = simTime

      -- ── Pipeline (ALL modules communicate via aiState fields) ──────────
      -- RULE: modules set ai.currentSpeedLimit, ai.waitingAtSignal, etc.
      -- ONLY vehicleStability actually sends commands to BeamNG

      vehicleStability.update(obj, ai, dt, simTime)             -- init
      speedLimits.update(obj, ai, dt)                            -- base limit
      vehicleDiversity.update(obj, ai, dt)                       -- class adj
      driverPersonality.update(obj, ai, dt, managed)             -- personality
      trafficSignals.update(obj, ai, dt)                         -- signals
      dynamicLaneChanging.update(obj, ai, dt, managed)           -- lanes
      laneDiscipline.update(obj, ai, dt, managed)                -- lane keep
      emergencyAvoidance.update(obj, ai, dt, managed)            -- dodge
      accidentReaction.update(obj, ai, dt, managed)              -- jams
      aiAccidents.update(obj, ai, dt, managed)                   -- crashes
      playerInteraction.update(obj, ai, dt, managed)             -- player

      -- ── FINAL: Apply everything through stability ──────────────────────
      M.applyFinal(obj, ai, dt)
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- FINAL APPLICATION — THE ONLY PLACE THAT SENDS COMMANDS
-- ══════════════════════════════════════════════════════════════════════════════

function M.applyFinal(obj, ai, dt)
  local now = ai._now

  -- ── Accident → full stop ───────────────────────────────────────────────
  if ai.isInAccident then
    vehicleStability.setSpeed(obj, 0, dt, now, true)
    vehicleStability.setMode(obj, "stop", now)
    ai.desiredSpeed = 0
    return
  end

  -- ── Emergency → stop (no steering!) ────────────────────────────────────
  if ai.isInEmergency then
    vehicleStability.setSpeed(obj, 0, dt, now, true)
    ai.desiredSpeed = 0
    return
  end

  -- ── Calculate final speed from all constraints ─────────────────────────
  local speed = ai.currentSpeedLimit

  if ai.waitingAtSignal then speed = 0 end

  -- Yellow
  if ai.nextSignalType == "yellow" then
    local p = ai.personality
    if not (p and p.ignoreYellow) then
      speed = math.min(speed, speed * math.min(1, ai.distToNextSignal / 40))
    end
  end

  -- Yield
  if ai.nextSignalType == "yield" and ai.distToNextSignal < 30 then
    speed = math.min(speed, 15)
  end

  -- Stop sign
  if ai.nextSignalType == "stop_sign" then
    local bd = 20 * (ai.brakeMultiplier or 1)
    if ai.distToNextSignal < bd then
      speed = math.min(speed, 5)
      if ai.distToNextSignal < 5 then speed = 0 end
    end
  end

  -- Overtake
  if ai.overtakeState == "overtaking" then
    speed = math.min(speed * 1.15, ai.currentSpeedLimit + 15)
  end

  -- Jam
  if ai.isInJam then speed = math.min(speed, 8) end

  speed = math.max(0, speed)
  ai.desiredSpeed = speed

  -- ── Send through stability (smoothed, rate-limited) ────────────────────
  vehicleStability.setSpeed(obj, speed, dt, now, false)

  if ai.followDistance then
    vehicleStability.setFollow(obj, ai.followDistance, now)
  end

  if ai.laneChangeOffset and math.abs(ai.laneChangeOffset) > 0.1 then
    vehicleStability.setOffset(obj, ai.laneChangeOffset, true, dt, now)
  end

  if ai.personality then
    vehicleStability.setAggression(obj, ai.personality.aggressionAI, now)
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- HOOKS
-- ══════════════════════════════════════════════════════════════════════════════

function M.onVehicleSpawned(vehId)
  if vehId ~= be:getPlayerVehicleID(0) then M.registerVehicle(vehId) end
end
function M.onVehicleDestroyed(vehId) M.unregisterVehicle(vehId) end
function M.onClientEndMission()
  managed = {}
  initialized = false
end

-- ══════════════════════════════════════════════════════════════════════════════
-- DEBUG
-- ══════════════════════════════════════════════════════════════════════════════

function M.debugFullStatus()
  local msg = string.format(
    "AI: %d авто | %d ДТП | %d полиция | Player: police=%s block=%s(%.0fs) wrong=%s",
    M.countVehicles(), aiAccidents.getAccidentCount(),
    policeResponse.getActivePoliceCount(),
    tostring(playerInteraction.isPlayerInPoliceCar()),
    tostring(playerInteraction.isPlayerBlocking()),
    playerInteraction.getPlayerBlockTime(),
    tostring(playerInteraction.isPlayerOnWrongSide())
  )
  log("I", "TrafficAI", msg)
  uiNotifications.notify("info", msg, 6)

  for vehId, ai in pairs(managed) do
    local ps = driverPersonality.getPersonalityStats(vehId)
    log("I", "TrafficAI", string.format(
      "  Veh %d: %s | %.0f/%.0f km/h | %s%s%s",
      vehId, ps and ps.archetype or "?",
      ai.currentSpeed, ai.desiredSpeed,
      ai.isInAccident and "ACCIDENT " or "",
      ai.isInJam and "JAM " or "",
      (ai.playerInteraction and ai.playerInteraction.goingAround) and "GO-AROUND " or ""
    ))
  end
end

function M.countVehicles()
  local c = 0; for _ in pairs(managed) do c = c + 1 end; return c
end

function M.getAllManagedVehicles() return managed end
function M.getVehicleState(vehId) return managed[vehId] end

return M