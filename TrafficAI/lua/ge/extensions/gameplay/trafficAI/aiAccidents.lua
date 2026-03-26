-- ============================================================================
-- aiAccidents.lua v2.0
-- FIXED: Actual collision detection that WORKS, police dispatch that WORKS
-- ============================================================================

local M = {}

local stability = nil
local policeModule = nil
local uiModule = nil

local function getStab()
  if not stability then stability = require("gameplay/trafficAI/vehicleStability") end
  return stability
end

-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIG
-- ══════════════════════════════════════════════════════════════════════════════

local COLLISION_DECEL = 20          -- km/h/s sudden decel = crash
local COLLISION_PROX = 4.0          -- meters close + speed diff = crash
local COLLISION_COOLDOWN = 15       -- seconds between detections per vehicle
local ACCIDENT_AUTO_RESOLVE = 120   -- seconds before auto-resolving

local PHASES = {
  IMPACT = 1, STOPPING = 2, SHOCK = 3, WAITING = 4,
  POLICE = 5, CLEARING = 6, DONE = 7,
}
local PHASE_NAMES = {
  [1]="impact",[2]="stopping",[3]="shock",[4]="waiting",
  [5]="police",[6]="clearing",[7]="done",
}

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

local accidents = {}
local tracking = {}  -- per-vehicle { prevSpeed, cooldown }
local nextId = 0
local simTime = 0

function M.init()
  accidents = {}
  tracking = {}
  nextId = 0
  simTime = 0
  log("I", "TrafficAI.Accidents", "AI accidents v2.0 initialized.")
end

function M.setPoliceModule(mod) policeModule = mod end

local function getUI()
  if not uiModule then
    pcall(function() uiModule = require("gameplay/trafficAI/uiNotifications") end)
  end
  return uiModule
end

local function getTrack(vehId)
  if not tracking[vehId] then
    tracking[vehId] = { prevSpeed = 0, cooldown = 0 }
  end
  return tracking[vehId]
end

-- ══════════════════════════════════════════════════════════════════════════════
-- COLLISION DETECTION (ACTUALLY WORKS)
-- ══════════════════════════════════════════════════════════════════════════════

--- Detect if this vehicle just collided with something
---@return table|nil collision info
local function detectCollision(vehObj, aiState, allVehicles, dt)
  local vehId = aiState.vehicleId
  local t = getTrack(vehId)

  if t.cooldown > 0 then
    t.cooldown = t.cooldown - dt
    t.prevSpeed = aiState.currentSpeed
    return nil
  end

  -- Already in accident?
  for _, acc in pairs(accidents) do
    if not acc.resolved and acc.participants[vehId] then
      t.prevSpeed = aiState.currentSpeed
      return nil
    end
  end

  local speed = aiState.currentSpeed
  local pos = aiState.position

  -- ── Method 1: Sudden deceleration ──────────────────────────────────────
  local decel = (t.prevSpeed - speed) / math.max(0.01, dt)
  if decel > COLLISION_DECEL and t.prevSpeed > 15 then
    t.cooldown = COLLISION_COOLDOWN
    t.prevSpeed = speed

    -- Find what we hit
    local hitId = nil
    local hitDist = COLLISION_PROX + 2

    -- Check player
    local pid = be:getPlayerVehicleID(0)
    if pid then
      local pObj = be:getObjectByID(pid)
      if pObj then
        local d = (pos - pObj:getPosition()):length()
        if d < hitDist then
          hitDist = d
          hitId = pid
        end
      end
    end

    -- Check other AI
    for oid, oState in pairs(allVehicles) do
      if oid ~= vehId then
        local d = (pos - oState.position):length()
        if d < hitDist then
          hitDist = d
          hitId = oid
        end
      end
    end

    return {
      vehId = vehId,
      otherId = hitId,
      isPlayer = (hitId == pid),
      speed = t.prevSpeed,
      decel = decel,
      pos = pos,
    }
  end

  -- ── Method 2: Very close proximity with speed difference ───────────────
  -- Check against player
  if pid then
    local pObj = be:getObjectByID(pid)
    if pObj then
      local pPos = pObj:getPosition()
      local d = (pos - pPos):length()
      if d < COLLISION_PROX then
        local pVel = pObj:getVelocity()
        local pSpeed = pVel:length() * 3.6
        local relSpeed = math.abs(speed - pSpeed)
        if relSpeed > 15 or (speed > 5 and pSpeed < 2 and d < 3) then
          t.cooldown = COLLISION_COOLDOWN
          t.prevSpeed = speed
          return {
            vehId = vehId, otherId = pid, isPlayer = true,
            speed = speed, decel = relSpeed / dt, pos = pos,
          }
        end
      end
    end
  end

  -- Check against other AI
  for oid, oState in pairs(allVehicles) do
    if oid ~= vehId then
      local d = (pos - oState.position):length()
      if d < COLLISION_PROX then
        local relSpeed = math.abs(speed - oState.currentSpeed)
        if relSpeed > 15 then
          t.cooldown = COLLISION_COOLDOWN
          t.prevSpeed = speed
          return {
            vehId = vehId, otherId = oid, isPlayer = false,
            speed = speed, decel = relSpeed / dt, pos = pos,
          }
        end
      end
    end
  end

  t.prevSpeed = speed
  return nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- CREATE ACCIDENT
-- ══════════════════════════════════════════════════════════════════════════════

function M.createAccident(collision)
  nextId = nextId + 1
  local accId = "acc_" .. nextId

  local participants = {}
  participants[collision.vehId] = {
    phase = PHASES.IMPACT, timer = 0, isPlayer = false,
  }
  if collision.otherId then
    participants[collision.otherId] = {
      phase = PHASES.IMPACT, timer = 0,
      isPlayer = (collision.otherId == be:getPlayerVehicleID(0)),
    }
  end

  local involvesPlayer = collision.isPlayer
  if collision.otherId == be:getPlayerVehicleID(0) then
    involvesPlayer = true
  end

  local acc = {
    id = accId,
    position = vec3(collision.pos.x, collision.pos.y, collision.pos.z),
    participants = participants,
    involvesPlayer = involvesPlayer,
    createdAt = simTime,
    resolved = false,
    policeRequested = false,
    policeArrived = false,
    policeVehId = nil,
  }

  accidents[accId] = acc

  -- ── UI Notification ────────────────────────────────────────────────────
  local ui = getUI()
  if ui then
    if involvesPlayer then
      ui.notify("accident", "Вы попали в ДТП!", 5, "player_crash")
    else
      ui.notify("accident",
        string.format("ДТП обнаружено (veh %d)", collision.vehId),
        4, "ai_crash_" .. accId)
    end
  end

  -- ── Request police ─────────────────────────────────────────────────────
  -- Check if player is in police car
  local playerInteraction = nil
  pcall(function()
    playerInteraction = require("gameplay/trafficAI/playerInteraction")
  end)

  local playerIsPolice = playerInteraction and playerInteraction.isPlayerInPoliceCar()

  if involvesPlayer and playerIsPolice then
    -- Player IS police — no dispatch
    if ui then
      ui.notify("info", "Вы в полицейской машине — наряд не вызван", 3, "no_police")
    end
  else
    -- Request police
    acc.policeRequested = true
    if policeModule then
      policeModule.requestResponse(acc)
    end
    if ui then
      local delay = involvesPlayer and 8 or 15
      ui.notify("police",
        string.format("Полиция выезжает на место ДТП (≈%dс)", delay),
        5, "dispatch_" .. accId)
    end
  end

  -- Register with accidentReaction for traffic jam
  pcall(function()
    local ar = require("gameplay/trafficAI/accidentReaction")
    ar.registerAccident(collision.pos, collision.decel > 50 and "major" or "minor")
  end)

  log("I", "TrafficAI.Accidents",
    string.format("ACCIDENT %s: veh=%d other=%s player=%s decel=%.0f",
      accId, collision.vehId, tostring(collision.otherId),
      tostring(involvesPlayer), collision.decel))

  return accId
end

-- ══════════════════════════════════════════════════════════════════════════════
-- POST-ACCIDENT BEHAVIOR
-- ══════════════════════════════════════════════════════════════════════════════

local PHASE_DURATIONS = {
  [PHASES.STOPPING] = 2,
  [PHASES.SHOCK]    = 4,
  [PHASES.WAITING]  = 30,
  [PHASES.POLICE]   = 60,
  [PHASES.CLEARING] = 10,
}

local function processParticipant(acc, vehId, p, dt, now)
  if p.isPlayer then
    -- Don't control player
    return
  end

  local vehObj = be:getObjectByID(vehId)
  if not vehObj then return end

  local stab = getStab()
  p.timer = p.timer + dt

  if p.phase == PHASES.IMPACT then
    p.phase = PHASES.STOPPING
    p.timer = 0
    stab.setMode(vehObj, "stop", now)
    stab.setElectric(vehObj, "hazard", 1, now)

  elseif p.phase == PHASES.STOPPING then
    stab.setSpeed(vehObj, 0, dt, now, true)
    if p.timer > PHASE_DURATIONS[PHASES.STOPPING] then
      p.phase = PHASES.SHOCK
      p.timer = 0
    end

  elseif p.phase == PHASES.SHOCK then
    stab.setSpeed(vehObj, 0, dt, now, true)
    if p.timer > PHASE_DURATIONS[PHASES.SHOCK] then
      if acc.policeRequested and not acc.policeArrived then
        p.phase = PHASES.WAITING
      else
        p.phase = PHASES.CLEARING
      end
      p.timer = 0
    end

  elseif p.phase == PHASES.WAITING then
    stab.setSpeed(vehObj, 0, dt, now, true)
    if acc.policeArrived then
      p.phase = PHASES.POLICE
      p.timer = 0
    end
    -- Timeout
    if p.timer > PHASE_DURATIONS[PHASES.WAITING] then
      p.phase = PHASES.CLEARING
      p.timer = 0
    end

  elseif p.phase == PHASES.POLICE then
    stab.setSpeed(vehObj, 0, dt, now, true)
    if p.timer > PHASE_DURATIONS[PHASES.POLICE] then
      p.phase = PHASES.CLEARING
      p.timer = 0
    end

  elseif p.phase == PHASES.CLEARING then
    stab.setElectric(vehObj, "hazard", 0, now)
    stab.setMode(vehObj, "traffic", now)
    stab.setSpeed(vehObj, 20, dt, now, false)
    if p.timer > PHASE_DURATIONS[PHASES.CLEARING] then
      p.phase = PHASES.DONE
    end

  elseif p.phase == PHASES.DONE then
    -- Normal driving resumes
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UPDATE
-- ══════════════════════════════════════════════════════════════════════════════

function M.update(vehObj, aiState, dt, allVehicles)
  simTime = simTime + dt
  local now = aiState._now or simTime
  local vehId = aiState.vehicleId

  -- ── Detect collisions ──────────────────────────────────────────────────
  local collision = detectCollision(vehObj, aiState, allVehicles, dt)
  if collision then
    M.createAccident(collision)
  end

  -- ── Process post-accident for this vehicle ─────────────────────────────
  aiState.isInAccident = false
  for accId, acc in pairs(accidents) do
    if not acc.resolved then
      local p = acc.participants[vehId]
      if p then
        processParticipant(acc, vehId, p, dt, now)

        if p.phase ~= PHASES.DONE and p.phase ~= PHASES.CLEARING then
          aiState.isInAccident = true
          aiState.waitingAtSignal = true
        end
      end
    end
  end

  -- ── Global: resolve accidents (run once per tick) ──────────────────────
  if vehId == next(allVehicles) then
    for accId, acc in pairs(accidents) do
      if not acc.resolved then
        local allDone = true
        for _, p in pairs(acc.participants) do
          if p.phase ~= PHASES.DONE then
            allDone = false
            break
          end
        end
        if allDone or (simTime - acc.createdAt > ACCIDENT_AUTO_RESOLVE) then
          acc.resolved = true
          if policeModule then
            policeModule.notifyAccidentResolved(accId)
          end
          local ui = getUI()
          if ui then
            ui.notify("info", "ДТП разрешено", 3, "resolved_" .. accId)
          end
          log("I", "TrafficAI.Accidents",
            string.format("Accident %s resolved (%.0fs)",
              accId, simTime - acc.createdAt))
        end
      end
    end

    -- Cleanup old
    for accId, acc in pairs(accidents) do
      if acc.resolved and simTime - acc.createdAt > 180 then
        accidents[accId] = nil
      end
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

function M.getActiveAccidents() return accidents end

function M.getAccidentCount()
  local c = 0
  for _, a in pairs(accidents) do
    if not a.resolved then c = c + 1 end
  end
  return c
end

function M.policeArrived(accidentId, policeVehId)
  local acc = accidents[accidentId]
  if acc then
    acc.policeArrived = true
    acc.policeVehId = policeVehId
    local ui = getUI()
    if ui then
      ui.notify("police", "Полиция прибыла на место ДТП", 5, "arrived_" .. accidentId)
    end
  end
end

function M.removeVehicle(vehId) tracking[vehId] = nil end
function M.getPostAccidentPhases() return PHASE_NAMES end

return M