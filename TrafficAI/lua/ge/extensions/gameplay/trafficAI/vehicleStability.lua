-- ============================================================================
-- vehicleStability.lua v3.0
-- CRITICAL: The ONLY module allowed to send commands to AI vehicles.
-- All other modules set values in aiState, this module sends them.
-- NEVER send input.event("steering"/"brake"/"throttle") to AI!
-- BeamNG.drive 0.38.3
-- ============================================================================

local M = {}

-- ══════════════════════════════════════════════════════════════════════════════
-- RULES:
--   1. AI drives itself — we only set speed and route offset
--   2. Steering: NEVER touch it. ai handles steering
--   3. Braking: ONLY via ai.setSpeed(0), never input.event("brake")
--   4. Throttle: ONLY via ai.setSpeed(X), never input.event("throttle")
--   5. Route offset: ai.driveUsingPath({routeOffset=X})
--   6. Every command is rate-limited and deduplicated
-- ══════════════════════════════════════════════════════════════════════════════

local INTERVALS = {
  speed      = 0.2,
  offset     = 0.3,
  aggression = 3.0,
  mode       = 1.0,
  electric   = 0.4,
  follow     = 1.0,
}

local THRESHOLDS = {
  speed      = 0.8,
  offset     = 0.15,
  aggression = 0.05,
}

local SMOOTH = {
  speed  = 0.55,
  offset = 0.65,
}

local states = {}

function M.init()
  states = {}
  log("I", "TrafficAI.Stability", "v3.0 initialized — single command authority")
end

local function getS(vehId)
  if not states[vehId] then
    states[vehId] = {
      sSpeed = 60, sOffset = 0,
      sentSpeed = -999, sentOffset = -999,
      sentAggr = -1, sentMode = "", sentAvoid = "",
      sentFollow = -1,
      ts = {},
    }
  end
  return states[vehId]
end

local function canSend(s, cat, now)
  local last = s.ts[cat] or 0
  return (now - last) >= (INTERVALS[cat] or 0.2)
end

local function mark(s, cat, now) s.ts[cat] = now end

local function lerp(cur, tgt, factor, dt)
  local a = 1.0 - math.pow(factor, dt * 10)
  return cur + (tgt - cur) * a
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC COMMAND FUNCTIONS — other modules call these
-- ══════════════════════════════════════════════════════════════════════════════

function M.setSpeed(vehObj, targetKMH, dt, now, emergency)
  local s = getS(vehObj:getId())

  if emergency then
    s.sSpeed = 0
    vehObj:queueLuaCommand('ai.setSpeedMode("limit"); ai.setSpeed(0)')
    mark(s, "speed", now)
    s.sentSpeed = 0
    return
  end

  s.sSpeed = lerp(s.sSpeed, targetKMH, SMOOTH.speed, dt)

  if math.abs(s.sSpeed - s.sentSpeed) < THRESHOLDS.speed then return end
  if not canSend(s, "speed", now) then return end

  local ms = math.max(0, s.sSpeed) / 3.6
  vehObj:queueLuaCommand(string.format(
    'ai.setSpeedMode("limit"); ai.setSpeed(%.2f)', ms))
  mark(s, "speed", now)
  s.sentSpeed = s.sSpeed
end

function M.setOffset(vehObj, target, avoidCars, dt, now)
  local s = getS(vehObj:getId())
  s.sOffset = lerp(s.sOffset, target, SMOOTH.offset, dt)

  local avoid = avoidCars and '"on"' or '"off"'
  if math.abs(s.sOffset - s.sentOffset) < THRESHOLDS.offset and avoid == s.sentAvoid then
    return
  end
  if not canSend(s, "offset", now) then return end

  vehObj:queueLuaCommand(string.format(
    'ai.driveUsingPath({avoidCars = %s, routeOffset = %.2f})',
    avoid, s.sOffset))
  mark(s, "offset", now)
  s.sentOffset = s.sOffset
  s.sentAvoid = avoid
end

function M.resetOffset(vehObj, now)
  local s = getS(vehObj:getId())
  if math.abs(s.sentOffset) < 0.1 and s.sentAvoid == '"on"' then return end
  if not canSend(s, "offset", now) then return end
  vehObj:queueLuaCommand('ai.driveUsingPath({avoidCars = "on", routeOffset = 0})')
  mark(s, "offset", now)
  s.sentOffset = 0
  s.sOffset = 0
  s.sentAvoid = '"on"'
end

function M.setAggression(vehObj, val, now)
  local s = getS(vehObj:getId())
  if math.abs(val - s.sentAggr) < THRESHOLDS.aggression then return end
  if not canSend(s, "aggression", now) then return end
  vehObj:queueLuaCommand(string.format('ai.setAggression(%.3f)', val))
  mark(s, "aggression", now)
  s.sentAggr = val
end

function M.setMode(vehObj, mode, now)
  local s = getS(vehObj:getId())
  if mode == s.sentMode then return end
  if not canSend(s, "mode", now) then return end
  vehObj:queueLuaCommand(string.format('ai.setMode("%s")', mode))
  mark(s, "mode", now)
  s.sentMode = mode
end

function M.setFollow(vehObj, dist, now)
  local s = getS(vehObj:getId())
  if math.abs(dist - s.sentFollow) < 1.0 then return end
  if not canSend(s, "follow", now) then return end
  vehObj:queueLuaCommand(string.format('ai.setFollowDistance(%.1f)', dist))
  mark(s, "follow", now)
  s.sentFollow = dist
end

function M.setElectric(vehObj, name, value, now)
  local s = getS(vehObj:getId())
  if not canSend(s, "electric", now) then return end
  vehObj:queueLuaCommand(string.format(
    'electrics.set("%s", %s)', name, tostring(value)))
  mark(s, "electric", now)
end

function M.horn(vehObj, on, now)
  local s = getS(vehObj:getId())
  if not canSend(s, "electric", now) then return end
  vehObj:queueLuaCommand(string.format(
    'electrics.horn(%s)', on and "true" or "false"))
  mark(s, "electric", now)
end

function M.update(vehObj, aiState, dt, now)
  aiState._now = now
end

function M.finalize(vehObj, aiState) end
function M.removeVehicle(vehId) states[vehId] = nil end

return M