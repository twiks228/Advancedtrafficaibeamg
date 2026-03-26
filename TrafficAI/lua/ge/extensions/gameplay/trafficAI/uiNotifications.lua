-- ============================================================================
-- uiNotifications.lua v2.0
-- Actually shows notifications using BeamNG 0.38.3 API
-- ============================================================================

local M = {}

local cooldowns = {}
local COOLDOWN = 8

function M.init()
  cooldowns = {}
  log("I", "TrafficAI.UI", "UI notifications v2.0 initialized.")
end

--- Send notification to screen
function M.notify(category, message, duration, key)
  -- Cooldown check
  if key then
    local now = os.clock()
    if cooldowns[key] and now - cooldowns[key] < COOLDOWN then return end
    cooldowns[key] = now
  end

  duration = duration or 4

  local icons = {
    police = "🚔", accident = "⚠️", warning = "⚠️",
    info = "ℹ️", traffic = "🚗",
  }
  local prefixes = {
    police = "ПОЛИЦИЯ", accident = "ДТП", warning = "ВНИМАНИЕ",
    info = "ИНФО", traffic = "ТРАФИК",
  }

  local icon = icons[category] or "ℹ️"
  local prefix = prefixes[category] or "ИНФО"
  local full = string.format("%s %s: %s", icon, prefix, message)

  -- ── Method 1: ui_message (most reliable in 0.38.3) ─────────────────────
  if ui_message then
    ui_message(full, duration, category)
    log("I", "TrafficAI.UI", "[NOTIFY] " .. full)
    return
  end

  -- ── Method 2: guihooks toast ───────────────────────────────────────────
  if guihooks and guihooks.trigger then
    guihooks.trigger('toastrMsg', {
      type = (category == "warning" or category == "accident") and "warning" or "info",
      title = prefix,
      msg = message,
      config = { timeOut = duration * 1000 },
    })
    log("I", "TrafficAI.UI", "[NOTIFY] " .. full)
    return
  end

  -- ── Method 3: guihooks Message ─────────────────────────────────────────
  if guihooks and guihooks.trigger then
    guihooks.trigger('Message', {
      ttl = duration, msg = full, category = "trafficAI",
    })
    log("I", "TrafficAI.UI", "[NOTIFY] " .. full)
    return
  end

  -- Fallback: just log
  log("I", "TrafficAI.UI", "[NOTIFY] " .. full)
end

function M.update(dt)
  -- Clean old cooldowns
  local now = os.clock()
  for k, t in pairs(cooldowns) do
    if now - t > COOLDOWN * 3 then cooldowns[k] = nil end
  end
end

-- Convenience
function M.policeDispatched(t, d)
  M.notify("police", "Полиция выехала на место ДТП", 5, "pdispatch")
end
function M.policeArrived()
  M.notify("police", "🚔 Полиция прибыла на место!", 5, "parrive")
end
function M.policeDeparting()
  M.notify("police", "Полиция покидает место ДТП", 4, "pdepart")
end
function M.accidentDetected(t, isP, d)
  if isP then M.notify("accident", "Вы попали в ДТП!", 5, "pcrash")
  else M.notify("accident", "ДТП обнаружено рядом", 4, "aicrash") end
end
function M.playerBlockingWarning(bt)
  if bt > 5 and bt < 7 then M.notify("warning", "Вы блокируете движение!", 3, "bw1")
  elseif bt > 10 and bt < 12 then M.notify("warning", "ИИ объезжает вас", 3, "bw2")
  elseif bt > 15 and bt < 17 then M.notify("police", "Полиция вызвана!", 5, "bw3") end
end
function M.wrongSideWarning()
  M.notify("warning", "Вы на встречной полосе!", 3, "wrongside")
end

return M