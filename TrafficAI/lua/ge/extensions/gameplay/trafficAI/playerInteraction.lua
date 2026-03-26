-- ============================================================================
-- playerInteraction.lua v2.0
-- Reads player electrics, detects blocking/wrong-side, AI reacts
-- FIXED: real go-around logic that actually works
-- ============================================================================

local M = {}

local stability = nil
local function getStab()
  if not stability then
    stability = require("gameplay/trafficAI/vehicleStability")
  end
  return stability
end

-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIG
-- ══════════════════════════════════════════════════════════════════════════════

local RANGE = {
  HORN       = 40,
  FLASH      = 80,
  SIGNAL     = 30,
  HAZARD     = 60,
  WRONG_SIDE = 100,
  BLOCKING   = 20,
}

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

local player = {
  pos = nil, dir = nil, speed = 0,
  horn = false, flash = false,
  signalL = false, signalR = false,
  hazard = false, wrongSide = false,
  blocking = false, blockTime = 0,
  isPolice = false,
}

local reactions = {} -- per AI vehicle
local simTime = 0
local electrics_received = false
local recv = { horn=false, high=false, sigL=false, sigR=false, haz=false }

function M.init()
  reactions = {}
  player = {
    pos = nil, dir = nil, speed = 0,
    horn = false, flash = false,
    signalL = false, signalR = false,
    hazard = false, wrongSide = false,
    blocking = false, blockTime = 0,
    isPolice = false,
  }
  simTime = 0
  log("I", "TrafficAI.Player", "Player interaction v2.0 initialized.")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- RECEIVE ELECTRICS FROM PLAYER VEHICLE (callback)
-- ══════════════════════════════════════════════════════════════════════════════

function M.receivePlayerElectrics(horn, high, sigL, sigR, haz)
  recv.horn = (horn == true or horn == "true")
  recv.high = (high == true or high == "true")
  recv.sigL = (sigL == true or sigL == "true")
  recv.sigR = (sigR == true or sigR == "true")
  recv.haz  = (haz == true or haz == "true")
  electrics_received = true
end

-- ══════════════════════════════════════════════════════════════════════════════
-- UPDATE PLAYER STATE (called once per tick from core)
-- ══════════════════════════════════════════════════════════════════════════════

function M.updatePlayerState(dt)
  simTime = simTime + dt

  local pid = be:getPlayerVehicleID(0)
  if not pid then return end
  local pObj = be:getObjectByID(pid)
  if not pObj then return end

  local pos = pObj:getPosition()
  local vel = pObj:getVelocity()
  local spd = vel:length()

  player.pos = pos
  player.speed = spd * 3.6
  if spd > 0.5 then
    player.dir = vel:normalized()
  end

  -- ── Request electrics ──────────────────────────────────────────────────
  pObj:queueLuaCommand([[
    local e = electrics.values or {}
    local h = e.horn and true or false
    local hb = (e.highbeam == 1 or e.highbeam == true) and true or false
    local sl = (e.signal_L == 1 or e.signal_L == true) and true or false
    local sr = (e.signal_R == 1 or e.signal_R == true) and true or false
    local hz = (e.hazard_enabled == 1 or e.hazard_enabled == true) and true or false
    obj:queueGameEngineLua(string.format(
      'gameplay_trafficAI_playerInteraction.receivePlayerElectrics(%s,%s,%s,%s,%s)',
      tostring(h), tostring(hb), tostring(sl), tostring(sr), tostring(hz)
    ))
  ]])

  if electrics_received then
    player.horn = recv.horn
    player.flash = recv.high
    player.signalL = recv.sigL
    player.signalR = recv.sigR
    player.hazard = recv.haz
    electrics_received = false
  end

  -- ── Police detection ───────────────────────────────────────────────────
  player.isPolice = false
  if core_vehicles and core_vehicles.getVehicleData then
    local d = core_vehicles.getVehicleData(pid)
    if d then
      local s = string.lower(tostring(d.config or "") .. tostring(d.model or ""))
      player.isPolice = s:find("police") ~= nil or s:find("cop") ~= nil
        or s:find("sheriff") ~= nil
    end
  end

  -- ── Wrong side ─────────────────────────────────────────────────────────
  player.wrongSide = false
  if player.dir and player.speed > 15 then
    local mapData = map and map.getMap() or nil
    if mapData and mapData.nodes then
      local best, bestD = nil, math.huge
      for _, n in pairs(mapData.nodes) do
        if n.pos then
          local d = (pos - n.pos):length()
          if d < bestD then bestD = d; best = n end
        end
      end
      if best and bestD < 15 then
        local roadDir = nil
        if best.links then
          for lid, _ in pairs(best.links) do
            local ln = mapData.nodes[lid]
            if ln and ln.pos then
              roadDir = (ln.pos - best.pos):normalized()
              break
            end
          end
        end
        if roadDir then
          local rightV = vec3(roadDir.y, -roadDir.x, 0):normalized()
          local lat = (pos - best.pos):dot(rightV)
          local flowDot = player.dir:dot(roadDir)
          -- Against flow AND on wrong side
          if flowDot < -0.3 and lat > 1 then
            player.wrongSide = true
          elseif flowDot > 0.3 and lat < -2 then
            player.wrongSide = true
          end
        end
      end
    end
  end

  -- ── Blocking detection ─────────────────────────────────────────────────
  if player.speed < 3 then
    -- Check if on road
    local onRoad = false
    local mapData = map and map.getMap() or nil
    if mapData and mapData.nodes then
      for _, n in pairs(mapData.nodes) do
        if n.pos and (pos - n.pos):length() < (n.radius or 4) + 2 then
          onRoad = true
          break
        end
      end
    end
    if onRoad then
      player.blockTime = player.blockTime + dt
      player.blocking = player.blockTime > 2
    else
      player.blockTime = 0
      player.blocking = false
    end
  else
    player.blockTime = math.max(0, player.blockTime - dt * 3)
    player.blocking = false
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- REACTION STATE
-- ══════════════════════════════════════════════════════════════════════════════

local function getR(vehId)
  if not reactions[vehId] then
    reactions[vehId] = {
      hornCD = 0, flashCD = 0,
      yielding = false, yieldTimer = 0,
      goAround = false, goAroundTimer = 0, goAroundSide = 1,
      honkCD = 0, honked = false,
      wrongSideDodge = false, wrongSideTimer = 0,
    }
  end
  return reactions[vehId]
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PER-VEHICLE AI REACTION (called from core pipeline)
-- ══════════════════════════════════════════════════════════════════════════════

function M.update(vehObj, aiState, dt, allVehicles)
  if not player.pos then return end

  local stab = getStab()
  local vehId = aiState.vehicleId
  local r = getR(vehId)
  local now = aiState._now or simTime
  local pos = aiState.position
  local dir = aiState.direction

  local toP = player.pos - pos
  local dist = toP:length()
  local toPN = dist > 0.1 and toP / dist or vec3(0,0,0)
  local ahead = toPN:dot(dir) -- >0 = player is ahead

  -- Update cooldowns
  r.hornCD = math.max(0, r.hornCD - dt)
  r.flashCD = math.max(0, r.flashCD - dt)
  r.honkCD = math.max(0, r.honkCD - dt)

  local pers = aiState.personality
  local isAggr = pers and pers.archetypeId == "aggressive"

  -- ══════════════════════════════════════════════════════════════════════════
  -- 1. PLAYER HORN → AI reacts
  -- ══════════════════════════════════════════════════════════════════════════
  if player.horn and dist < RANGE.HORN and r.hornCD <= 0 then
    r.hornCD = 4
    if isAggr then
      stab.horn(vehObj, true, now)
    elseif ahead < 0 then
      -- Player behind us honking → speed up slightly
      aiState.currentSpeedLimit = aiState.currentSpeedLimit * 1.1
    end
  end

  -- ══════════════════════════════════════════════════════════════════════════
  -- 2. PLAYER FLASHES HEADLIGHTS → yield
  -- ══════════════════════════════════════════════════════════════════════════
  if player.flash and dist < RANGE.FLASH and r.flashCD <= 0 then
    r.flashCD = 6
    if ahead < -0.2 and not isAggr then
      -- Player behind flashing = wants to pass
      r.yielding = true
      r.yieldTimer = 5
      stab.setOffset(vehObj, -3.0, true, dt, now)
      aiState.currentSpeedLimit = aiState.currentSpeedLimit * 0.8
    elseif ahead > 0.3 and aiState.waitingAtSignal then
      -- Player ahead flashing at intersection = "go ahead"
      aiState.waitingAtSignal = false
    end
  end

  if r.yielding then
    r.yieldTimer = r.yieldTimer - dt
    if r.yieldTimer <= 0 then
      r.yielding = false
      stab.resetOffset(vehObj, now)
    end
  end

  -- ══════════════════════════════════════════════════════════════════════════
  -- 3. PLAYER TURN SIGNALS → AI yields for lane change
  -- ══════════════════════════════════════════════════════════════════════════
  if dist < RANGE.SIGNAL and (player.signalL or player.signalR) then
    local rightV = vec3(dir.y, -dir.x, 0):normalized()
    local latP = toP:dot(rightV)

    -- Player signaling toward our lane
    if (player.signalR and latP < -1 and latP > -6) or
       (player.signalL and latP > 1 and latP < 6) then
      if not isAggr then
        aiState.currentSpeedLimit = aiState.currentSpeedLimit * 0.85
      end
    end
  end

  -- ══════════════════════════════════════════════════════════════════════════
  -- 4. PLAYER HAZARDS → slow down, go around if stopped
  -- ══════════════════════════════════════════════════════════════════════════
  if player.hazard and dist < RANGE.HAZARD and ahead > 0 then
    aiState.currentSpeedLimit = math.min(aiState.currentSpeedLimit, 25)
    if dist < 15 and player.speed < 3 then
      M._startGoAround(vehObj, aiState, r, pos, dir, player.pos, dt, now)
    end
  end

  -- ══════════════════════════════════════════════════════════════════════════
  -- 5. PLAYER ON WRONG SIDE → dodge + honk + flash
  -- ══════════════════════════════════════════════════════════════════════════
  if player.wrongSide and dist < RANGE.WRONG_SIDE and ahead > 0 then
    if player.dir and dir:dot(player.dir) < -0.3 then
      -- Head-on risk!
      stab.horn(vehObj, true, now)
      stab.setElectric(vehObj, "highbeam", 1, now)
      stab.setOffset(vehObj, -4.5, true, dt, now) -- dodge right
      r.wrongSideDodge = true
      r.wrongSideTimer = 4

      if dist < 30 then
        aiState.currentSpeedLimit = 0
        aiState.waitingAtSignal = true
      else
        aiState.currentSpeedLimit = math.min(aiState.currentSpeedLimit, 15)
      end
    end
  end

  if r.wrongSideDodge then
    r.wrongSideTimer = r.wrongSideTimer - dt
    if r.wrongSideTimer <= 0 then
      r.wrongSideDodge = false
      stab.resetOffset(vehObj, now)
      stab.setElectric(vehObj, "highbeam", 0, now)
      stab.horn(vehObj, false, now)
    end
  end

  -- ══════════════════════════════════════════════════════════════════════════
  -- 6. PLAYER BLOCKING ROAD → honk then go around (ACTUALLY WORKS!)
  -- ══════════════════════════════════════════════════════════════════════════
  if player.blocking and dist < RANGE.BLOCKING and ahead > 0
     and aiState.currentSpeed < 3 then

    local bt = player.blockTime

    -- Phase 1: honk (3-5 sec)
    if bt > 3 and not r.honked and r.honkCD <= 0 then
      stab.horn(vehObj, true, now)
      r.honked = true
      r.honkCD = 3
    end
    if r.honked and r.honkCD < 2 then
      stab.horn(vehObj, false, now)
      r.honked = false
    end

    -- Phase 2: go around (>5 sec)
    if bt > 5 then
      M._startGoAround(vehObj, aiState, r, pos, dir, player.pos, dt, now)
    end
  end

  -- ══════════════════════════════════════════════════════════════════════════
  -- GO-AROUND STATE MACHINE
  -- ══════════════════════════════════════════════════════════════════════════
  if r.goAround then
    r.goAroundTimer = r.goAroundTimer + dt

    -- Keep offset and slow speed — avoidCars OFF so AI can pass
    local offset = r.goAroundSide * 4.5
    stab.setOffset(vehObj, offset, false, dt, now) -- avoidCars OFF!
    stab.setSpeed(vehObj, 10, dt, now, false) -- 10 km/h crawl

    -- Check if we passed the player
    local nowToP = player.pos - vehObj:getPosition()
    local nowAhead = nowToP:dot(dir)
    if nowAhead < -5 then
      -- Passed! Reset
      r.goAround = false
      r.goAroundTimer = 0
      stab.resetOffset(vehObj, now)
      stab.setElectric(vehObj, "signal_left_input", 0, now)
      stab.setElectric(vehObj, "signal_right_input", 0, now)
      log("D", "TrafficAI.Player", string.format("Veh %d: passed obstacle", vehId))
    end

    -- Timeout: try other side after 12 sec
    if r.goAroundTimer > 12 then
      r.goAroundSide = -r.goAroundSide
      r.goAroundTimer = 0
      log("D", "TrafficAI.Player",
        string.format("Veh %d: go-around timeout, trying other side", vehId))
    end

    -- Override speed limit
    aiState.currentSpeedLimit = 10
    aiState.waitingAtSignal = false

    return -- skip normal processing while going around
  end

  -- ── Write to aiState ───────────────────────────────────────────────────
  aiState.playerInteraction = {
    reacting = r.yielding or r.goAround or r.wrongSideDodge,
    goingAround = r.goAround,
    playerWrongSide = player.wrongSide,
    playerBlocking = player.blocking,
    playerBlockTime = player.blockTime,
  }
end

-- ══════════════════════════════════════════════════════════════════════════════
-- GO AROUND — start the maneuver
-- ══════════════════════════════════════════════════════════════════════════════

function M._startGoAround(vehObj, aiState, r, pos, dir, obstPos, dt, now)
  if r.goAround then return end -- already going around

  local stab = getStab()

  -- Determine side: go to opposite side of obstacle
  local rightV = vec3(dir.y, -dir.x, 0):normalized()
  local obstLat = (obstPos - pos):dot(rightV)

  if obstLat > 0 then
    r.goAroundSide = -1 -- obstacle right → go left
  else
    r.goAroundSide = 1  -- obstacle left → go right
  end

  r.goAround = true
  r.goAroundTimer = 0

  -- Turn signal
  if r.goAroundSide > 0 then
    stab.setElectric(vehObj, "signal_right_input", 1, now)
  else
    stab.setElectric(vehObj, "signal_left_input", 1, now)
  end

  log("I", "TrafficAI.Player",
    string.format("Veh %d: starting go-around (%s)",
      aiState.vehicleId, r.goAroundSide > 0 and "right" or "left"))
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

function M.getPlayerEvents() return player end
function M.isPlayerInPoliceCar() return player.isPolice end
function M.isPlayerOnWrongSide() return player.wrongSide end
function M.isPlayerBlocking() return player.blocking end
function M.getPlayerBlockTime() return player.blockTime end
function M.removeVehicle(vehId) reactions[vehId] = nil end

return M