-- ============================================================================
-- policeAPI.lua
-- Clean API layer for future police patrol mod integration.
-- This file provides a stable interface that won't change between versions.
-- BeamNG.drive 0.38.3
-- ============================================================================

local M = {}

--[[
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║  POLICE API — Interface for External Police Patrol Mod                 ║
  ║                                                                        ║
  ║  Мод патруля может использовать этот API для:                          ║
  ║  • Регистрации своих полицейских машин                                ║
  ║  • Получения информации о ДТП                                        ║
  ║  • Управления реакцией на ДТП                                         ║
  ║  • Перехвата dispatch-запросов                                        ║
  ║  • Управления сиреной/мигалкой                                        ║
  ║                                                                        ║
  ║  Пример использования из мода патруля:                                ║
  ║                                                                        ║
  ║  local policeAPI = require("gameplay/trafficAI/policeAPI")             ║
  ║  policeAPI.init()                                                      ║
  ║  local unitId = policeAPI.registerPatrolCar(myVehId)                  ║
  ║  policeAPI.onAccidentCallback(function(accident)                      ║
  ║    -- решить, ехать ли на вызов                                       ║
  ║  end)                                                                  ║
  ╚══════════════════════════════════════════════════════════════════════════╝
]]

-- ── Module references ─────────────────────────────────────────────────────
local policeResponse = nil
local aiAccidents = nil

--- Callbacks registered by external mod
local callbacks = {
  onAccident = nil,           -- function(accidentData)
  onDispatchRequest = nil,    -- function(dispatchData) → return true to handle
  onPoliceArrived = nil,      -- function(unitId, accidentId)
  onAccidentResolved = nil,   -- function(accidentId)
  onPlayerBlocking = nil,     -- function(position, duration)
}

-- ══════════════════════════════════════════════════════════════════════════════
-- INIT
-- ══════════════════════════════════════════════════════════════════════════════

function M.init()
  policeResponse = require("gameplay/trafficAI/policeResponse")
  aiAccidents = require("gameplay/trafficAI/aiAccidents")
  log("I", "TrafficAI.PoliceAPI", "Police API initialized. Ready for patrol mod.")
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PATROL CAR MANAGEMENT
-- ══════════════════════════════════════════════════════════════════════════════

--- Register a patrol car (from external mod)
---@param vehId number  BeamNG vehicle ID
---@param updateCallback function|nil  optional per-frame update callback
---@return string unitId  unique identifier for this unit
function M.registerPatrolCar(vehId, updateCallback)
  if not policeResponse then M.init() end
  return policeResponse.registerExternalUnit(vehId, updateCallback)
end

--- Unregister a patrol car
---@param unitId string
function M.unregisterPatrolCar(unitId)
  if policeResponse then
    policeResponse.unregisterExternalUnit(unitId)
  end
end

--- Get all registered police units (both auto-spawned and external)
---@return table units
function M.getAllUnits()
  if not policeResponse then return {} end
  return policeResponse.getPoliceUnits()
end

--- Get the state of a specific unit
---@param unitId string
---@return table|nil unit
function M.getUnitState(unitId)
  local units = M.getAllUnits()
  return units[unitId]
end

--- Check if a vehicle is a registered police vehicle
---@param vehId number
---@return boolean
function M.isPoliceVehicle(vehId)
  if not policeResponse then return false end
  return policeResponse.isPoliceVehicle(vehId)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- ACCIDENT INFORMATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Get all active accidents
---@return table accidents { [accId] = accidentData }
function M.getActiveAccidents()
  if not aiAccidents then return {} end
  return aiAccidents.getActiveAccidents()
end

--- Get a specific accident
---@param accidentId string
---@return table|nil accident
function M.getAccident(accidentId)
  local accidents = M.getActiveAccidents()
  return accidents[accidentId]
end

--- Get the number of active (unresolved) accidents
---@return number
function M.getActiveAccidentCount()
  if not aiAccidents then return 0 end
  return aiAccidents.getAccidentCount()
end

--- Get pending dispatch requests (accidents waiting for police)
---@return table dispatches
function M.getPendingDispatches()
  if not policeResponse then return {} end
  return policeResponse.getPendingDispatches()
end

--- Get post-accident phase definitions
---@return table phases
function M.getPostAccidentPhases()
  if not aiAccidents then return {} end
  return aiAccidents.getPostAccidentPhases()
end

-- ══════════════════════════════════════════════════════════════════════════════
-- DISPATCH CONTROL
-- ══════════════════════════════════════════════════════════════════════════════

--- Assign a patrol car to respond to an accident
---@param unitId string  your patrol car unit ID
---@param accidentId string  accident to respond to
function M.respondToAccident(unitId, accidentId)
  if policeResponse then
    policeResponse.assignToAccident(unitId, accidentId)
  end
end

--- Cancel automatic dispatch for an accident (your mod will handle it)
---@param accidentId string
---@return boolean success
function M.cancelAutoDispatch(accidentId)
  if policeResponse then
    return policeResponse.cancelDispatch(accidentId)
  end
  return false
end

--- Notify that your patrol car arrived at accident scene
---@param accidentId string
---@param policeVehId number
function M.notifyArrival(accidentId, policeVehId)
  if aiAccidents then
    aiAccidents.policeArrived(accidentId, policeVehId)
  end
end

--- Notify that accident is resolved (from patrol mod's perspective)
---@param accidentId string
function M.notifyResolved(accidentId)
  if policeResponse then
    policeResponse.notifyAccidentResolved(accidentId)
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- VEHICLE CONTROLS (for patrol car)
-- ══════════════════════════════════════════════════════════════════════════════

--- Set lightbar state
---@param vehId number
---@param on boolean
function M.setLightbar(vehId, on)
  local vehObj = be:getObjectByID(vehId)
  if vehObj then
    vehObj:queueLuaCommand(string.format(
      'electrics.set("lightbar", %d)', on and 1 or 0
    ))
  end
end

--- Set siren state
---@param vehId number
---@param on boolean
function M.setSiren(vehId, on)
  local vehObj = be:getObjectByID(vehId)
  if vehObj then
    vehObj:queueLuaCommand(string.format(
      'electrics.set("siren", %d)', on and 1 or 0
    ))
  end
end

--- Set hazard lights
---@param vehId number
---@param on boolean
function M.setHazards(vehId, on)
  local vehObj = be:getObjectByID(vehId)
  if vehObj then
    vehObj:queueLuaCommand(string.format(
      'electrics.set("hazard", %d)', on and 1 or 0
    ))
  end
end

--- Horn
---@param vehId number
---@param on boolean
function M.setHorn(vehId, on)
  local vehObj = be:getObjectByID(vehId)
  if vehObj then
    vehObj:queueLuaCommand(string.format(
      'electrics.horn(%s)', on and "true" or "false"
    ))
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- CALLBACK REGISTRATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Register callback for when a new accident occurs
---@param callback function(accidentData)
function M.onAccidentCallback(callback)
  callbacks.onAccident = callback
end

--- Register callback for dispatch requests (return true to handle yourself)
---@param callback function(dispatchData) → boolean
function M.onDispatchRequestCallback(callback)
  callbacks.onDispatchRequest = callback
end

--- Register callback for when police arrives at scene
---@param callback function(unitId, accidentId)
function M.onPoliceArrivedCallback(callback)
  callbacks.onPoliceArrived = callback
end

--- Register callback for when accident is resolved
---@param callback function(accidentId)
function M.onAccidentResolvedCallback(callback)
  callbacks.onAccidentResolved = callback
end

--- Register callback for player blocking traffic
---@param callback function(position, duration)
function M.onPlayerBlockingCallback(callback)
  callbacks.onPlayerBlocking = callback
end

--- Get all registered callbacks (internal use)
function M.getCallbacks()
  return callbacks
end

-- ══════════════════════════════════════════════════════════════════════════════
-- UTILITY
-- ══════════════════════════════════════════════════════════════════════════════

--- Get distance from a position to nearest active accident
---@param pos vec3
---@return number distance
---@return string|nil nearestAccidentId
function M.distanceToNearestAccident(pos)
  local nearest = math.huge
  local nearestId = nil

  for accId, acc in pairs(M.getActiveAccidents()) do
    if not acc.isResolved then
      local dist = (pos - acc.position):length()
      if dist < nearest then
        nearest = dist
        nearestId = accId
      end
    end
  end

  return nearest, nearestId
end

--- Get info about player blocking state
---@return table blockingState
function M.getPlayerBlockingInfo()
  if aiAccidents then
    return aiAccidents.getPlayerBlockingState()
  end
  return { isBlocking = false, blockTimer = 0 }
end

--- Get police response configuration (for patrol mod to read/adjust)
---@return table config
function M.getResponseConfig()
  return {
    maxPoliceVehicles = 3,
    dispatchDelayMinor = 15,
    dispatchDelayMajor = 5,
    dispatchDelayPlayer = 8,
    responseSpeed = 100,
    investigationTime = { min = 60, max = 180 },
  }
end

return M