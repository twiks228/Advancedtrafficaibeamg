-- ============================================================================
-- driverPersonality.lua
-- Driver personality system: Pensioner, Normal, Aggressive, Distracted
-- Each AI vehicle gets unique driving behavior based on risk profile
-- BeamNG.drive 0.38.3
-- ============================================================================

local M = {}

-- ══════════════════════════════════════════════════════════════════════════════
-- PERSONALITY ARCHETYPES
-- ══════════════════════════════════════════════════════════════════════════════

--[[
  Каждый архетип определяет набор параметров, влияющих на поведение водителя.
  
  Параметры:
    riskRange           = {min, max}  -- диапазон "риска" (0 = параноик, 1 = камикадзе)
    speedMultiplier     = {min, max}  -- множитель к лимиту скорости
    accelMultiplier     = {min, max}  -- множитель ускорения (1 = норма, <1 = вялый)
    brakeMultiplier     = {min, max}  -- множитель тормозной дистанции (>1 = тормозит раньше)
    followDistance      = {min, max}  -- дистанция до впередиидущего (метры)
    laneChangeSpeed     = {min, max}  -- скорость перестроения (сек на маневр)
    reactionTime        = {min, max}  -- время реакции (секунды)
    attentionLevel      = {min, max}  -- внимательность (1 = идеальная, 0 = слепой)
    aggressionAI        = {min, max}  -- BeamNG ai.setAggression() значение
    courtesyYield       = bool        -- уступает ли при спорных ситуациях
    honkProbability     = float       -- вероятность посигналить
    tailgateProbability = float       -- вероятность "висеть на бампере"
    overtakeAggression  = float       -- агрессивность обгона (0..1)
    errorProbability    = float       -- вероятность ошибки в секунду
    errorTypes          = {}          -- возможные типы ошибок
]]

local ARCHETYPES = {

  -- ────────────────────────────────────────────────────────────────────────────
  -- "ПЕНСИОНЕР" — осторожный водитель
  -- Едет строго по правилам, медленно разгоняется, рано тормозит
  -- ────────────────────────────────────────────────────────────────────────────
  pensioner = {
    name = "Pensioner",
    nameRU = "Пенсионер",
    weight = 10,  -- % вероятность появления в трафике

    riskRange           = { min = 0.2, max = 0.4 },
    speedMultiplier     = { min = 0.78, max = 0.90 },
    accelMultiplier     = { min = 0.45, max = 0.65 },
    brakeMultiplier     = { min = 1.6,  max = 2.2  },
    followDistance      = { min = 18,   max = 30   },
    laneChangeSpeed     = { min = 3.5,  max = 5.0  },
    reactionTime        = { min = 0.8,  max = 1.5  },
    attentionLevel      = { min = 0.65, max = 0.85 },
    aggressionAI        = { min = 0.15, max = 0.30 },

    courtesyYield       = true,
    honkProbability     = 0.01,
    tailgateProbability = 0.0,
    overtakeAggression  = 0.05,
    errorProbability    = 0.008,
    errorTypes          = {
      "slow_reaction",     -- поздно замечает изменение ситуации
      "wide_turn",         -- слишком широко входит в поворот
      "unnecessary_stop",  -- останавливается, когда не нужно
    },

    -- Специфическое поведение
    useTurnSignals      = true,  -- всегда включает поворотники
    fullStopAtYield     = true,  -- полная остановка даже у "Уступи дорогу"
    creepSpeed          = 3,     -- скорость "ползания" в пробке (км/ч)
    startDelay          = 2.5,   -- задержка на зеленый свет (сек)
  },

  -- ────────────────────────────────────────────────────────────────────────────
  -- "ОБЫЧНЫЙ ВОДИТЕЛЬ" — основной поток
  -- Едет в темпе лимита, плавно перестраивается
  -- ────────────────────────────────────────────────────────────────────────────
  normal = {
    name = "Normal Driver",
    nameRU = "Обычный водитель",
    weight = 55,  -- 55% трафика

    riskRange           = { min = 0.5, max = 0.7 },
    speedMultiplier     = { min = 0.95, max = 1.05 },
    accelMultiplier     = { min = 0.80, max = 1.00 },
    brakeMultiplier     = { min = 1.0,  max = 1.3  },
    followDistance      = { min = 10,   max = 18   },
    laneChangeSpeed     = { min = 2.0,  max = 3.0  },
    reactionTime        = { min = 0.4,  max = 0.8  },
    attentionLevel      = { min = 0.80, max = 0.95 },
    aggressionAI        = { min = 0.35, max = 0.55 },

    courtesyYield       = true,
    honkProbability     = 0.05,
    tailgateProbability = 0.05,
    overtakeAggression  = 0.3,
    errorProbability    = 0.003,
    errorTypes          = {
      "slow_reaction",
      "slight_swerve",     -- слегка виляет при отвлечении
    },

    useTurnSignals      = true,
    fullStopAtYield     = false,
    creepSpeed          = 8,
    startDelay          = 0.8,
  },

  -- ────────────────────────────────────────────────────────────────────────────
  -- "СПЕШАЩИЙ / АГРЕССИВНЫЙ" — торопится, нарушает
  -- Превышает лимит на 10-20%, шашкует, висит на бампере
  -- ────────────────────────────────────────────────────────────────────────────
  aggressive = {
    name = "Aggressive Driver",
    nameRU = "Агрессивный водитель",
    weight = 20,  -- 20% трафика

    riskRange           = { min = 0.8, max = 0.95 },
    speedMultiplier     = { min = 1.10, max = 1.25 },
    accelMultiplier     = { min = 1.10, max = 1.40 },
    brakeMultiplier     = { min = 0.6,  max = 0.85 },
    followDistance      = { min = 4,    max = 8    },
    laneChangeSpeed     = { min = 0.8,  max = 1.5  },
    reactionTime        = { min = 0.2,  max = 0.5  },
    attentionLevel      = { min = 0.85, max = 1.00 },
    aggressionAI        = { min = 0.70, max = 0.95 },

    courtesyYield       = false,
    honkProbability     = 0.25,
    tailgateProbability = 0.45,
    overtakeAggression  = 0.85,
    errorProbability    = 0.005,
    errorTypes          = {
      "cut_off",           -- подрезает при перестроении
      "run_yellow",        -- проезжает на жёлтый/красный
      "brake_late",        -- поздно тормозит
    },

    useTurnSignals      = false,  -- забивает на поворотники
    fullStopAtYield     = false,
    creepSpeed          = 15,
    startDelay          = 0.2,

    -- Специфическое поведение агрессора
    weaveThroughTraffic = true,   -- шашки между полосами
    flashHighBeams      = true,   -- моргает дальним
    forceMerge          = true,   -- вклинивается в поток силой
    ignoreYellow        = true,   -- проезжает на жёлтый
    closePassDistance    = 1.5,    -- минимальное расстояние при обгоне (м)
  },

  -- ────────────────────────────────────────────────────────────────────────────
  -- "ОШИБАЮЩИЙСЯ" — пониженная внимательность
  -- Отвлекается, поздно тормозит, не замечает при перестроении
  -- ────────────────────────────────────────────────────────────────────────────
  distracted = {
    name = "Distracted Driver",
    nameRU = "Невнимательный водитель",
    weight = 15,  -- 15% трафика

    riskRange           = { min = 0.4, max = 0.7 },
    speedMultiplier     = { min = 0.90, max = 1.10 },
    accelMultiplier     = { min = 0.70, max = 1.00 },
    brakeMultiplier     = { min = 0.7,  max = 1.0  },
    followDistance      = { min = 8,    max = 14   },
    laneChangeSpeed     = { min = 1.5,  max = 2.5  },
    reactionTime        = { min = 0.8,  max = 2.0  },
    attentionLevel      = { min = 0.30, max = 0.60 },
    aggressionAI        = { min = 0.30, max = 0.50 },

    courtesyYield       = true,
    honkProbability     = 0.02,
    tailgateProbability = 0.10,
    overtakeAggression  = 0.2,
    errorProbability    = 0.025,  -- высокая вероятность ошибки!
    errorTypes          = {
      "late_brake",        -- поздно жмёт тормоз перед пробкой
      "blind_lane_change", -- не проверяет слепую зону при перестроении
      "drift_in_lane",     -- плавает в полосе
      "missed_signal",     -- не замечает сигнал/знак
      "sudden_brake",      -- внезапный тормоз без причины (отвлёкся)
      "wrong_speed",       -- не соблюдает скоростной режим (то быстро, то медленно)
    },

    useTurnSignals      = false,
    fullStopAtYield     = false,
    creepSpeed          = 10,
    startDelay          = 1.5,

    -- Специфическое поведение
    phoneDistraction     = true,   -- "смотрит в телефон"
    driftAmplitude       = 0.8,    -- амплитуда виляния в полосе (м)
    driftFrequency       = 0.3,    -- частота виляния (Гц)
    blindSpotFailRate    = 0.35,   -- 35% шанс не заметить в слепой зоне
    attentionDropInterval = { min = 10, max = 30 },  -- интервал "отвлечений" (сек)
    attentionDropDuration = { min = 2,  max = 6  },  -- длительность "отвлечения" (сек)
  },
}

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Per-vehicle personality data: { [vehId] = personalityInstance }
local vehiclePersonalities = {}

--- Weighted archetype list for random selection
local archetypePool = {}

-- ══════════════════════════════════════════════════════════════════════════════
-- INIT
-- ══════════════════════════════════════════════════════════════════════════════

function M.init()
  vehiclePersonalities = {}
  archetypePool = {}

  -- Build weighted pool
  for archetypeId, archetype in pairs(ARCHETYPES) do
    for i = 1, archetype.weight do
      table.insert(archetypePool, archetypeId)
    end
  end

  log("I", "TrafficAI.Personality",
    string.format("Personality system initialized. Pool size: %d entries, %d archetypes.",
      #archetypePool, M.getArchetypeCount()))
end

-- ══════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════════════════════════════════

--- Pick a random value within a {min, max} range
---@param range table {min, max}
---@return number
local function randRange(range)
  return range.min + math.random() * (range.max - range.min)
end

--- Deep-copy a table (one level)
local function shallowCopy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PERSONALITY GENERATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Generate a unique personality instance for a vehicle
---@param vehId number
---@param forceArchetype string|nil  force a specific archetype (optional)
---@return table personalityInstance
function M.generatePersonality(vehId, forceArchetype)
  -- Select archetype
  local archetypeId
  if forceArchetype and ARCHETYPES[forceArchetype] then
    archetypeId = forceArchetype
  else
    archetypeId = archetypePool[math.random(#archetypePool)]
  end

  local archetype = ARCHETYPES[archetypeId]

  -- Generate individualized parameters from archetype ranges
  local personality = {
    vehicleId         = vehId,
    archetypeId       = archetypeId,
    archetypeName     = archetype.name,
    archetypeNameRU   = archetype.nameRU,

    -- ── Core driving parameters (rolled individually) ────────────────────
    risk              = randRange(archetype.riskRange),
    speedMultiplier   = randRange(archetype.speedMultiplier),
    accelMultiplier   = randRange(archetype.accelMultiplier),
    brakeMultiplier   = randRange(archetype.brakeMultiplier),
    followDistance    = randRange(archetype.followDistance),
    laneChangeSpeed   = randRange(archetype.laneChangeSpeed),
    reactionTime      = randRange(archetype.reactionTime),
    attentionLevel    = randRange(archetype.attentionLevel),
    aggressionAI      = randRange(archetype.aggressionAI),

    -- ── Behavioral flags (direct copy) ───────────────────────────────────
    courtesyYield       = archetype.courtesyYield,
    honkProbability     = archetype.honkProbability,
    tailgateProbability = archetype.tailgateProbability,
    overtakeAggression  = archetype.overtakeAggression,
    errorProbability    = archetype.errorProbability,
    errorTypes          = shallowCopy(archetype.errorTypes),
    useTurnSignals      = archetype.useTurnSignals,
    fullStopAtYield     = archetype.fullStopAtYield,
    creepSpeed          = archetype.creepSpeed,
    startDelay          = archetype.startDelay,

    -- ── Archetype-specific extras ────────────────────────────────────────
    weaveThroughTraffic  = archetype.weaveThroughTraffic or false,
    flashHighBeams       = archetype.flashHighBeams or false,
    forceMerge           = archetype.forceMerge or false,
    ignoreYellow         = archetype.ignoreYellow or false,
    closePassDistance     = archetype.closePassDistance or 3.0,
    phoneDistraction     = archetype.phoneDistraction or false,
    driftAmplitude       = archetype.driftAmplitude or 0,
    driftFrequency       = archetype.driftFrequency or 0,
    blindSpotFailRate    = archetype.blindSpotFailRate or 0.05,

    -- ── Runtime state ────────────────────────────────────────────────────
    currentError         = nil,    -- active error type or nil
    errorTimer           = 0,      -- time remaining for current error
    errorCooldown        = 0,      -- cooldown before next error can occur
    attentionState       = "focused", -- focused / distracted
    attentionTimer       = 0,
    nextAttentionDrop    = 0,
    attentionDropDuration = 0,
    tailgateTarget       = nil,    -- vehId we're tailgating
    weavePhase           = 0,      -- for weaving behavior
    honkCooldown         = 0,
    lastSpeedCommand     = 0,
    driftPhase           = math.random() * math.pi * 2, -- random start phase

    -- ── Statistics ───────────────────────────────────────────────────────
    totalErrors          = 0,
    totalOvertakes       = 0,
    totalHonks           = 0,
    timeDriving          = 0,
  }

  -- Set up distraction timers for distracted drivers
  if archetype.attentionDropInterval then
    personality.nextAttentionDrop = randRange(archetype.attentionDropInterval)
  else
    personality.nextAttentionDrop = 999999
  end
  if archetype.attentionDropDuration then
    personality.attentionDropDuration = randRange(archetype.attentionDropDuration)
  end

  vehiclePersonalities[vehId] = personality

  log("I", "TrafficAI.Personality",
    string.format("Veh %d: assigned personality '%s' (risk=%.2f spd=%.2f accel=%.2f brake=%.2f follow=%.1fm react=%.2fs)",
      vehId, personality.archetypeNameRU,
      personality.risk, personality.speedMultiplier, personality.accelMultiplier,
      personality.brakeMultiplier, personality.followDistance, personality.reactionTime))

  return personality
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PERSONALITY ACCESS
-- ══════════════════════════════════════════════════════════════════════════════

--- Get personality for a vehicle (auto-generate if missing)
---@param vehId number
---@return table personality
function M.getPersonality(vehId)
  if not vehiclePersonalities[vehId] then
    M.generatePersonality(vehId)
  end
  return vehiclePersonalities[vehId]
end

--- Remove personality when vehicle is destroyed
---@param vehId number
function M.removePersonality(vehId)
  vehiclePersonalities[vehId] = nil
end

--- Get all personalities (for debug)
function M.getAllPersonalities()
  return vehiclePersonalities
end

--- Count archetypes
function M.getArchetypeCount()
  local count = 0
  for _ in pairs(ARCHETYPES) do count = count + 1 end
  return count
end

-- ══════════════════════════════════════════════════════════════════════════════
-- ERROR SYSTEM
-- Имитирует человеческие ошибки: поздний тормоз, не заметил, вильнул и т.д.
-- ══════════════════════════════════════════════════════════════════════════════

--- Error handlers: each returns modifications to the AI state
local errorHandlers = {

  -- Поздняя реакция на торможение (перед пробкой/машиной впереди)
  late_brake = function(personality, aiState, dt)
    -- Уменьшаем тормозной множитель временно — тормозит ПОЗЖЕ
    return {
      brakeMultiplierOverride = personality.brakeMultiplier * 0.4,
      reactionTimeOverride    = personality.reactionTime * 2.5,
      duration = 2.0,
    }
  end,

  slow_reaction = function(personality, aiState, dt)
    return {
      reactionTimeOverride = personality.reactionTime * 2.0,
      duration = 3.0,
    }
  end,

  -- Не проверяет слепую зону при перестроении
  blind_lane_change = function(personality, aiState, dt)
    return {
      attentionOverride    = 0.1,  -- почти слепой к соседней полосе
      laneChangeSpeedOverride = personality.laneChangeSpeed * 0.6,
      duration = 2.5,
    }
  end,

  -- Виляние в полосе
  drift_in_lane = function(personality, aiState, dt)
    return {
      lateralDrift = math.sin(personality.driftPhase) * (personality.driftAmplitude or 0.5),
      duration = 4.0,
    }
  end,

  -- Не замечает сигнал/знак
  missed_signal = function(personality, aiState, dt)
    return {
      ignoreNextSignal = true,
      duration = 3.0,
    }
  end,

  -- Внезапный тормоз без причины
  sudden_brake = function(personality, aiState, dt)
    return {
      forceBrake = true,
      brakeForce = 0.5 + math.random() * 0.3,
      duration = 1.5,
    }
  end,

  -- Непостоянная скорость
  wrong_speed = function(personality, aiState, dt)
    local variation = (math.random() > 0.5) and 1.2 or 0.7
    return {
      speedMultiplierOverride = personality.speedMultiplier * variation,
      duration = 5.0,
    }
  end,

  -- Слишком широко входит в поворот
  wide_turn = function(personality, aiState, dt)
    return {
      lateralDrift = 1.5,  -- метр наружу поворота
      duration = 3.0,
    }
  end,

  -- Останавливается когда не нужно
  unnecessary_stop = function(personality, aiState, dt)
    return {
      forceBrake = true,
      brakeForce = 0.8,
      duration = 2.0 + math.random() * 2.0,
    }
  end,

  -- Лёгкое виляние
  slight_swerve = function(personality, aiState, dt)
    return {
      lateralDrift = (math.random() > 0.5 and 0.4 or -0.4),
      duration = 1.0,
    }
  end,

  -- Подрезает при обгоне/перестроении
  cut_off = function(personality, aiState, dt)
    return {
      laneChangeSpeedOverride = 0.5,  -- очень быстрое перестроение
      followDistanceOverride  = 3,    -- возвращается очень близко
      duration = 2.0,
    }
  end,

  -- Проезжает на жёлтый/красный
  run_yellow = function(personality, aiState, dt)
    return {
      ignoreNextSignal = true,
      speedMultiplierOverride = personality.speedMultiplier * 1.15,
      duration = 3.0,
    }
  end,

  -- Тормозит слишком поздно
  brake_late = function(personality, aiState, dt)
    return {
      brakeMultiplierOverride = personality.brakeMultiplier * 0.3,
      duration = 2.0,
    }
  end,
}

--- Process errors for a vehicle
---@param personality table
---@param aiState table
---@param dt number
---@return table|nil  activeErrorEffects
local function processErrors(personality, aiState, dt)
  -- Cooldown
  if personality.errorCooldown > 0 then
    personality.errorCooldown = personality.errorCooldown - dt
    return nil
  end

  -- Active error in progress
  if personality.currentError then
    personality.errorTimer = personality.errorTimer - dt
    if personality.errorTimer <= 0 then
      -- Error resolved
      log("D", "TrafficAI.Personality",
        string.format("Veh %d: error '%s' resolved", personality.vehicleId, personality.currentError))
      personality.currentError = nil
      personality.errorCooldown = 3.0 + math.random() * 5.0 -- 3-8 sec cooldown
      return nil
    end

    -- Apply error effects
    local handler = errorHandlers[personality.currentError]
    if handler then
      return handler(personality, aiState, dt)
    end
    return nil
  end

  -- Check if a new error should occur
  if math.random() < personality.errorProbability * dt then
    -- Trigger a random error from this personality's error types
    local errorList = personality.errorTypes
    if #errorList > 0 then
      local errorType = errorList[math.random(#errorList)]
      local handler = errorHandlers[errorType]
      if handler then
        local effects = handler(personality, aiState, dt)
        personality.currentError = errorType
        personality.errorTimer = effects.duration or 2.0
        personality.totalErrors = personality.totalErrors + 1

        log("D", "TrafficAI.Personality",
          string.format("Veh %d (%s): ERROR triggered: '%s' (duration: %.1fs)",
            personality.vehicleId, personality.archetypeNameRU,
            errorType, personality.errorTimer))

        return effects
      end
    end
  end

  return nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- ATTENTION SYSTEM (для distracted водителей)
-- Периодически "отвлекается", снижая внимательность
-- ══════════════════════════════════════════════════════════════════════════════

--- Update attention state for a vehicle
---@param personality table
---@param dt number
local function updateAttention(personality, dt)
  if not personality.phoneDistraction then
    personality.attentionState = "focused"
    return
  end

  personality.attentionTimer = personality.attentionTimer + dt

  if personality.attentionState == "focused" then
    if personality.attentionTimer >= personality.nextAttentionDrop then
      -- Start distraction
      personality.attentionState = "distracted"
      personality.attentionTimer = 0
      -- How long will the distraction last?
      personality.attentionDropDuration = 2.0 + math.random() * 4.0

      log("D", "TrafficAI.Personality",
        string.format("Veh %d: DISTRACTED (duration: %.1fs)",
          personality.vehicleId, personality.attentionDropDuration))
    end
  elseif personality.attentionState == "distracted" then
    if personality.attentionTimer >= personality.attentionDropDuration then
      -- Regain focus
      personality.attentionState = "focused"
      personality.attentionTimer = 0
      -- Schedule next distraction
      personality.nextAttentionDrop = 10 + math.random() * 20
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- TAILGATING (для агрессивных водителей)
-- "Висит на бампере" впередиидущего
-- ══════════════════════════════════════════════════════════════════════════════

--- Check if this vehicle should tailgate
---@param personality table
---@param aiState table
---@param allVehicles table
---@return boolean isTailgating
---@return number adjustedFollowDist
local function checkTailgating(personality, aiState, allVehicles)
  if math.random() > personality.tailgateProbability then
    return false, personality.followDistance
  end

  local pos = aiState.position
  local dir = aiState.direction

  -- Find vehicle directly ahead
  for otherId, otherState in pairs(allVehicles) do
    if otherId ~= personality.vehicleId then
      local toOther = otherState.position - pos
      local distAhead = toOther:dot(dir)

      if distAhead > 2 and distAhead < personality.followDistance * 1.5 then
        local lateral = math.sqrt(math.max(0, toOther:lengthSquared() - distAhead * distAhead))
        if lateral < 2.5 then
          -- There's a vehicle ahead — tailgate it!
          local tailgateDist = personality.closePassDistance + math.random() * 2
          return true, math.min(tailgateDist, personality.followDistance * 0.3)
        end
      end
    end
  end

  return false, personality.followDistance
end

-- ══════════════════════════════════════════════════════════════════════════════
-- WEAVING (шашки для агрессивных)
-- ══════════════════════════════════════════════════════════════════════════════

--- Update weaving phase for aggressive drivers
---@param personality table
---@param aiState table
---@param dt number
---@return number lateralOffset  for weaving (0 if not weaving)
local function processWeaving(personality, aiState, dt)
  if not personality.weaveThroughTraffic then
    return 0
  end

  -- Only weave when there's traffic ahead and we're going fast enough
  if aiState.currentSpeed < 30 then
    return 0
  end

  personality.weavePhase = personality.weavePhase + dt * 1.5

  -- Weave amplitude depends on speed (more careful at high speed)
  local amplitude = 2.5
  if aiState.currentSpeed > 80 then
    amplitude = 1.5
  end

  return math.sin(personality.weavePhase) * amplitude
end

-- ══════════════════════════════════════════════════════════════════════════════
-- HONKING
-- ══════════════════════════════════════════════════════════════════════════════

--- Check if vehicle should honk
---@param personality table
---@param aiState table
---@param dt number
---@param vehObj userdata
local function processHonking(personality, aiState, dt, vehObj)
  personality.honkCooldown = math.max(0, personality.honkCooldown - dt)

  if personality.honkCooldown > 0 then return end

  -- Conditions to honk:
  local shouldHonk = false

  -- 1. Stuck behind slow vehicle and aggressive
  if aiState.currentSpeed < aiState.desiredSpeed * 0.5 and
     aiState.currentSpeed < aiState.currentSpeedLimit * 0.6 then
    if math.random() < personality.honkProbability * dt then
      shouldHonk = true
    end
  end

  -- 2. Waiting at green light too long (behind someone)
  if aiState.waitingAtSignal == false and aiState.currentSpeed < 3 and
     aiState.nextSignalType == "green" then
    if math.random() < personality.honkProbability * 2 * dt then
      shouldHonk = true
    end
  end

  if shouldHonk then
    -- BeamNG horn command
    vehObj:queueLuaCommand('electrics.horn(true)')
    -- Short honk
    personality.honkCooldown = 0.3 + math.random() * 0.5
    personality.totalHonks = personality.totalHonks + 1

    -- Schedule horn release
    vehObj:queueLuaCommand(string.format(
      'local t = hptimer(); while hptimer() - t < %f do end; electrics.horn(false)',
      personality.honkCooldown
    ))

    -- Longer cooldown before next honk
    personality.honkCooldown = 3.0 + math.random() * 5.0
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN UPDATE
-- ══════════════════════════════════════════════════════════════════════════════

--- Main update function — modifies aiState based on personality
---@param vehObj userdata
---@param aiState table  the vehicle's AI state from trafficAICore
---@param dt number
---@param allVehicles table  all managed vehicle states
function M.update(vehObj, aiState, dt, allVehicles)
  local vehId = aiState.vehicleId
  local personality = M.getPersonality(vehId)

  personality.timeDriving = personality.timeDriving + dt

  -- ── 1. Update attention state ──────────────────────────────────────────
  updateAttention(personality, dt)

  -- ── 2. Update drift phase for distracted drivers ───────────────────────
  if personality.driftFrequency > 0 then
    personality.driftPhase = personality.driftPhase + dt * personality.driftFrequency * math.pi * 2
  end

  -- ── 3. Process errors ──────────────────────────────────────────────────
  local errorEffects = processErrors(personality, aiState, dt)

  -- ── 4. Apply personality to speed limit ────────────────────────────────
  local speedMult = personality.speedMultiplier
  if errorEffects and errorEffects.speedMultiplierOverride then
    speedMult = errorEffects.speedMultiplierOverride
  end
  -- Distracted drivers vary speed more
  if personality.attentionState == "distracted" then
    speedMult = speedMult * (0.8 + math.sin(personality.attentionTimer * 0.5) * 0.2)
  end
  aiState.currentSpeedLimit = aiState.currentSpeedLimit * speedMult

  -- ── 5. Apply brake multiplier ──────────────────────────────────────────
  local brakeMult = personality.brakeMultiplier
  if errorEffects and errorEffects.brakeMultiplierOverride then
    brakeMult = errorEffects.brakeMultiplierOverride
  end
  -- Store for use by other modules
  aiState.brakeMultiplier = brakeMult

  -- ── 6. Apply follow distance ───────────────────────────────────────────
  local followDist = personality.followDistance
  if errorEffects and errorEffects.followDistanceOverride then
    followDist = errorEffects.followDistanceOverride
  end

  -- Tailgating check for aggressive drivers
  local isTailgating, tailgateDist = checkTailgating(personality, aiState, allVehicles)
  if isTailgating then
    followDist = tailgateDist
  end
  aiState.followDistance = followDist

  -- ── 7. Apply reaction time ─────────────────────────────────────────────
  local reaction = personality.reactionTime
  if errorEffects and errorEffects.reactionTimeOverride then
    reaction = errorEffects.reactionTimeOverride
  end
  if personality.attentionState == "distracted" then
    reaction = reaction * 2.0
  end
  aiState.reactionTime = reaction

  -- ── 8. Apply lane change speed ─────────────────────────────────────────
  local lcSpeed = personality.laneChangeSpeed
  if errorEffects and errorEffects.laneChangeSpeedOverride then
    lcSpeed = errorEffects.laneChangeSpeedOverride
  end
  aiState.laneChangeSpeed = lcSpeed

  -- ── 9. Apply attention level ───────────────────────────────────────────
  local attention = personality.attentionLevel
  if errorEffects and errorEffects.attentionOverride then
    attention = errorEffects.attentionOverride
  end
  if personality.attentionState == "distracted" then
    attention = attention * 0.3
  end
  aiState.attentionLevel = attention

  -- ── 10. Signal behavior ────────────────────────────────────────────────
  -- Ignore signals during certain errors
  if errorEffects and errorEffects.ignoreNextSignal then
    aiState.nextSignalType = "none"
    aiState.waitingAtSignal = false
  end

  -- Aggressive: ignore yellow
  if personality.ignoreYellow and aiState.nextSignalType == "yellow" then
    aiState.nextSignalType = "green"
  end

  -- Pensioner: full stop at yield
  if personality.fullStopAtYield and aiState.nextSignalType == "yield" then
    if aiState.distToNextSignal < 10 then
      aiState.waitingAtSignal = true
    end
  end

  -- Start delay override
  aiState.greenStartDelay = personality.startDelay

  -- ── 11. Force brake from error ─────────────────────────────────────────
  if errorEffects and errorEffects.forceBrake then
    aiState.waitingAtSignal = true  -- abuse this to force stop
    -- Also directly command brake
    vehObj:queueLuaCommand(string.format(
      'input.event("brake", %f, 1)', errorEffects.brakeForce or 0.5
    ))
  end

  -- ── 12. Lateral drift from errors/distraction ──────────────────────────
  local lateralDrift = 0
  if errorEffects and errorEffects.lateralDrift then
    lateralDrift = errorEffects.lateralDrift
  end
  -- Distracted lane drift
  if personality.attentionState == "distracted" and personality.driftAmplitude > 0 then
    lateralDrift = lateralDrift + math.sin(personality.driftPhase) * personality.driftAmplitude
  end

  -- ── 13. Weaving for aggressive drivers ─────────────────────────────────
  local weaveOffset = processWeaving(personality, aiState, dt)
  lateralDrift = lateralDrift + weaveOffset

  -- Apply lateral offset if any
  if math.abs(lateralDrift) > 0.1 then
    aiState.lateralOffset = lateralDrift
    vehObj:queueLuaCommand(string.format(
      'ai.driveUsingPath({routeOffset = %.2f})', lateralDrift
    ))
  end

  -- ── 14. Apply BeamNG AI aggression ─────────────────────────────────────
  vehObj:queueLuaCommand(string.format(
    'ai.setAggression(%.3f)', personality.aggressionAI
  ))

  -- ── 15. Honking ────────────────────────────────────────────────────────
  processHonking(personality, aiState, dt, vehObj)

  -- ── 16. Store personality reference in aiState ─────────────────────────
  aiState.personality = personality
  aiState.archetypeId = personality.archetypeId
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

--- Get archetype definitions (for UI/debug)
function M.getArchetypes()
  return ARCHETYPES
end

--- Override archetype weights at runtime
---@param weights table  { pensioner = 10, normal = 55, aggressive = 20, distracted = 15 }
function M.setArchetypeWeights(weights)
  for id, weight in pairs(weights) do
    if ARCHETYPES[id] then
      ARCHETYPES[id].weight = weight
    end
  end
  -- Rebuild pool
  archetypePool = {}
  for archetypeId, archetype in pairs(ARCHETYPES) do
    for i = 1, archetype.weight do
      table.insert(archetypePool, archetypeId)
    end
  end
  log("I", "TrafficAI.Personality", "Archetype weights updated.")
end

--- Force a personality on a specific vehicle
---@param vehId number
---@param archetypeId string
function M.forcePersonality(vehId, archetypeId)
  M.generatePersonality(vehId, archetypeId)
end

--- Get stats for a vehicle personality
---@param vehId number
---@return table|nil stats
function M.getPersonalityStats(vehId)
  local p = vehiclePersonalities[vehId]
  if not p then return nil end
  return {
    archetype = p.archetypeNameRU,
    risk = p.risk,
    totalErrors = p.totalErrors,
    totalOvertakes = p.totalOvertakes,
    totalHonks = p.totalHonks,
    timeDriving = p.timeDriving,
    attentionState = p.attentionState,
    currentError = p.currentError,
  }
end

return M