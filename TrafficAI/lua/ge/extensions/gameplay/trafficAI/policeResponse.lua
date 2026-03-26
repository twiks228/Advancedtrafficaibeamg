-- ============================================================================
-- policeResponse.lua v3.0
-- FIXED: police actually spawns, actually drives to scene, notifications
-- ============================================================================

local M = {}

local stability = nil
local aiAccidentsModule = nil
local uiModule = nil

local function getStab()
  if not stability then stability = require("gameplay/trafficAI/vehicleStability") end
  return stability
end
local function getUI()
  if not uiModule then
    pcall(function() uiModule = require("gameplay/trafficAI/uiNotifications") end)
  end
  return uiModule
end

-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIG
-- ══════════════════════════════════════════════════════════════════════════════

local POLICE_MODELS = { "fullsize", "midsize", "etk800" }

local DISPATCH_DELAY = {
  player   = 8,
  major    = 5,
  minor    = 15,
  blocking = 20,
}

local MAX_POLICE = 3
local RESPONSE_SPEED = 100 / 3.6  -- m/s
local APPROACH_SPEED = 25 / 3.6
local PARK_DIST = 12
local INVESTIGATE_TIME = { 60, 180 }
local TIMEOUT_ENROUTE = 60

local STATE = {
  DISPATCH = 1, ENROUTE = 2, APPROACH = 3,
  ONSCENE = 4, INVESTIGATE = 5,
  DEPART = 6, RETURN = 7,
}

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

local units = {}
local queue = {}
local nextId = 0
local simTime = 0

function M.init()
  units = {}
  queue = {}
  nextId = 0
  simTime = 0
  log("I", "TrafficAI.Police", "Police response v3.0 initialized.")
end

function M.setAIAccidentsModule(mod) aiAccidentsModule = mod end

-- ══════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════════════════════════════════

local function countActive()
  local c = 0
  for _, u in pairs(units) do
    if u.state >= STATE.ENROUTE and u.state <= STATE.INVESTIGATE then c = c + 1 end
  end
  return c
end

function M.isPoliceVehicle(vehId)
  for _, u in pairs(units) do
    if u.vehId == vehId then return true end
  end
  return false
end

--- Is player in a police car?
function M.isPlayerInPoliceCar()
  local pi = nil
  pcall(function() pi = require("gameplay/trafficAI/playerInteraction") end)
  if pi then return pi.isPlayerInPoliceCar() end
  return false
end

-- ══════════════════════════════════════════════════════════════════════════════
-- SPAWN
-- ══════════════════════════════════════════════════════════════════════════════

local function findSpawnPos(target)
  local mapData = map and map.getMap() or nil
  local candidates = {}

  if mapData and mapData.nodes then
    for _, n in pairs(mapData.nodes) do
      if n.pos then
        local d = (n.pos - target):length()
        if d > 80 and d < 250 and (n.radius or 0) > 3 then
          table.insert(candidates, n.pos)
        end
      end
    end
  end

  if #candidates > 0 then
    local p = candidates[math.random(#candidates)]
    return p + vec3(0, 0, 0.5), (target - p):normalized()
  end

  -- Fallback
  local a = math.random() * 6.28
  local p = target + vec3(math.cos(a) * 120, math.sin(a) * 120, 0.5)
  return p, (target - p):normalized()
end

local function spawnPolice(targetPos)
  local sp, sd = findSpawnPos(targetPos)
  local model = POLICE_MODELS[math.random(#POLICE_MODELS)]
  local vehId = nil

  -- ── Try multiple spawn methods ─────────────────────────────────────────
  -- Method 1: core_vehicles
  if not vehId and core_vehicles and core_vehicles.spawnNewVehicle then
    pcall(function()
      local obj = core_vehicles.spawnNewVehicle(model, {
        pos = sp,
        rot = sd and quatFromDir(sd) or nil,
        autoEnterVehicle = false,
      })
      if obj then vehId = obj:getId() end
    end)
  end

  -- Method 2: spawn
  if not vehId and spawn then
    pcall(function()
      if spawn.spawnVehicle then
        local obj = spawn.spawnVehicle(model, "", sp, sd and quatFromDir(sd) or nil)
        if obj then vehId = obj:getId() end
      end
    end)
  end

  -- Method 3: gameplay_vehicles
  if not vehId and gameplay_vehicles and gameplay_vehicles.spawnNewVehicle then
    pcall(function()
      vehId = gameplay_vehicles.spawnNewVehicle(model, { pos = sp })
    end)
  end

  -- Method 4: commandline / direct
  if not vehId then
    pcall(function()
      local cmd = string.format(
        'local v = spawn.spawnVehicle("%s", "", vec3(%.1f,%.1f,%.1f)); '..
        'if v then return v:getId() end', model, sp.x, sp.y, sp.z)
      be:queueAllObjectLua(cmd)
    end)
  end

  if vehId then
    local obj = be:getObjectByID(vehId)
    if obj then
      obj:queueLuaCommand('ai.setMode("traffic")')
      obj:queueLuaCommand(string.format('ai.setSpeed(%.2f)', RESPONSE_SPEED))
      obj:queueLuaCommand('ai.setAggression(0.65)')
      obj:queueLuaCommand('electrics.set("lightbar", 1)')
      obj:queueLuaCommand('electrics.set("hazard", 1)')
    end
    log("I", "TrafficAI.Police",
      string.format("Police spawned: veh=%d model=%s", vehId, model))
  else
    log("W", "TrafficAI.Police", "Could not spawn police vehicle!")
  end

  return vehId
end

-- ══════════════════════════════════════════════════════════════════════════════
-- REQUEST
-- ══════════════════════════════════════════════════════════════════════════════

function M.requestResponse(accident)
  if not accident then return end

  -- Don't dispatch if player IS police
  if accident.involvesPlayer and M.isPlayerInPoliceCar() then
    log("I", "TrafficAI.Police", "Player is police — skipping dispatch")
    return
  end

  local delay = DISPATCH_DELAY.minor
  if accident.involvesPlayer then delay = DISPATCH_DELAY.player
  elseif accident.type == "major" then delay = DISPATCH_DELAY.major end

  table.insert(queue, {
    accId = accident.id,
    pos = accident.position,
    dispatchAt = simTime + delay,
  })

  local ui = getUI()
  if ui then
    ui.notify("police",
      string.format("Полиция выезжает через ≈%dс", delay),
      5, "queued_" .. accident.id)
  end
end

function M.requestBlockingResponse(position, playerVehId)
  if M.isPlayerInPoliceCar() then return end

  for _, q in ipairs(queue) do
    if q.accId == "block" then return end
  end

  table.insert(queue, {
    accId = "block",
    pos = position,
    dispatchAt = simTime + DISPATCH_DELAY.blocking,
  })
end

-- ══════════════════════════════════════════════════════════════════════════════
-- UNIT STATE MACHINE
-- ══════════════════════════════════════════════════════════════════════════════

local function updateUnit(uid, u, dt)
  local obj = be:getObjectByID(u.vehId)
  if not obj then
    units[uid] = nil
    return
  end

  u.timer = u.timer + dt
  local pos = obj:getPosition()
  local dist = (pos - u.target):length()
  local stab = getStab()
  local now = simTime

  -- ── ENROUTE ────────────────────────────────────────────────────────────
  if u.state == STATE.ENROUTE then
    -- Drive fast toward target
    stab.setSpeed(obj, 100, dt, now, false)

    if dist < 60 then
      u.state = STATE.APPROACH
      u.timer = 0
    end

    -- Timeout → teleport
    if u.timer > TIMEOUT_ENROUTE then
      obj:setPosition(u.target + vec3(8, 8, 0.5))
      u.state = STATE.APPROACH
      u.timer = 0
      log("W", "TrafficAI.Police", "Police teleported to scene (timeout)")
    end

  -- ── APPROACH ───────────────────────────────────────────────────────────
  elseif u.state == STATE.APPROACH then
    stab.setSpeed(obj, 25, dt, now, false)

    if dist < PARK_DIST then
      u.state = STATE.ONSCENE
      u.timer = 0
      stab.setMode(obj, "stop", now)
      stab.setElectric(obj, "hazard", 1, now)

      -- Notify accident module
      if aiAccidentsModule then
        aiAccidentsModule.policeArrived(u.accId, u.vehId)
      end

      local ui = getUI()
      if ui then
        ui.notify("police", "🚔 Полиция прибыла на место ДТП!", 5, "arrived_" .. u.accId)
      end

      log("I", "TrafficAI.Police", string.format("Police %s ON SCENE", uid))
    end

    if u.timer > 30 then
      -- Still can't reach, teleport closer
      obj:setPosition(u.target + vec3(5, 0, 0.5))
      u.state = STATE.ONSCENE
      u.timer = 0
    end

  -- ── ON SCENE ───────────────────────────────────────────────────────────
  elseif u.state == STATE.ONSCENE then
    stab.setSpeed(obj, 0, dt, now, true)
    if u.timer > 5 then
      u.state = STATE.INVESTIGATE
      u.timer = 0
    end

  -- ── INVESTIGATE ────────────────────────────────────────────────────────
  elseif u.state == STATE.INVESTIGATE then
    stab.setSpeed(obj, 0, dt, now, true)

    if u.timer >= u.investTime then
      u.state = STATE.DEPART
      u.timer = 0
      local ui = getUI()
      if ui then
        ui.notify("police", "Полиция покидает место ДТП", 4, "depart_" .. uid)
      end
    end

    -- Check if accident resolved
    if aiAccidentsModule then
      local accs = aiAccidentsModule.getActiveAccidents()
      local a = accs[u.accId]
      if a and a.resolved then
        u.state = STATE.DEPART
        u.timer = 0
      end
    end

  -- ── DEPART ─────────────────────────────────────────────────────────────
  elseif u.state == STATE.DEPART then
    if u.timer > 2 then
      stab.setElectric(obj, "hazard", 0, now)
      stab.setElectric(obj, "lightbar", 0, now)
    end
    if u.timer > 4 then
      stab.setMode(obj, "traffic", now)
      stab.setSpeed(obj, 60, dt, now, false)
      u.state = STATE.RETURN
      u.timer = 0
    end

  -- ── RETURN ─────────────────────────────────────────────────────────────
  elseif u.state == STATE.RETURN then
    if u.timer > 40 then
      -- Despawn if far from player
      local pid = be:getPlayerVehicleID(0)
      local canDespawn = true
      if pid then
        local pObj = be:getObjectByID(pid)
        if pObj and (pos - pObj:getPosition()):length() < 100 then
          canDespawn = false
        end
      end
      if canDespawn or u.timer > 90 then
        obj:delete()
        units[uid] = nil
        log("I", "TrafficAI.Police", string.format("Police %s despawned", uid))
        return
      end
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UPDATE
-- ══════════════════════════════════════════════════════════════════════════════

function M.update(dt)
  simTime = simTime + dt

  -- ── Process queue ──────────────────────────────────────────────────────
  local i = 1
  while i <= #queue do
    local q = queue[i]
    if simTime >= q.dispatchAt then
      if countActive() < MAX_POLICE then
        local vehId = spawnPolice(q.pos)
        if vehId then
          nextId = nextId + 1
          local uid = "pu_" .. nextId
          units[uid] = {
            vehId = vehId,
            accId = q.accId,
            target = q.pos,
            state = STATE.ENROUTE,
            timer = 0,
            investTime = INVESTIGATE_TIME[1] + math.random() *
              (INVESTIGATE_TIME[2] - INVESTIGATE_TIME[1]),
          }
          log("I", "TrafficAI.Police",
            string.format("Police %s dispatched (veh=%d)", uid, vehId))
        end
      end
      table.remove(queue, i)
    else
      i = i + 1
    end
  end

  -- ── Update units ───────────────────────────────────────────────────────
  for uid, u in pairs(units) do
    updateUnit(uid, u, dt)
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

function M.getPoliceUnits() return units end
function M.getActivePoliceCount() return countActive() end
function M.getPoliceStates() return STATE end
function M.getPendingDispatches() return queue end

function M.notifyAccidentResolved(accId)
  for uid, u in pairs(units) do
    if u.accId == accId and u.state == STATE.INVESTIGATE then
      u.state = STATE.DEPART
      u.timer = 0
    end
  end
end

function M.registerExternalUnit(vehId, cb)
  nextId = nextId + 1
  local uid = "ext_" .. nextId
  units[uid] = {
    vehId = vehId, accId = nil, target = vec3(0,0,0),
    state = 0, timer = 0, investTime = 0,
    external = true, externalCb = cb,
  }
  return uid
end

function M.unregisterExternalUnit(uid) units[uid] = nil end
function M.cancelDispatch(accId)
  for i, q in ipairs(queue) do
    if q.accId == accId then table.remove(queue, i); return true end
  end
  return false
end

return M