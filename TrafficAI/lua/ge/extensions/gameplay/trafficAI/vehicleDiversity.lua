-- ============================================================================
-- vehicleDiversity.lua
-- Vehicle class diversity, spawn configuration, vehicle condition simulation
-- BeamNG.drive 0.38.3
-- ============================================================================

local M = {}

-- ══════════════════════════════════════════════════════════════════════════════
-- VEHICLE CLASS DEFINITIONS
-- ══════════════════════════════════════════════════════════════════════════════

--[[
  Классы транспорта с весами для спавна:
    60% — седаны/хэтчбеки
    15% — кроссоверы/внедорожники
    10% — коммерческий транспорт (грузовики, фургоны)
     5% — автобусы
    10% — спорткары или автохлам
]]

local VEHICLE_CLASSES = {

  -- ────────────────────────────────────────────────────────────────────────────
  sedan = {
    name = "Sedan / Hatchback",
    nameRU = "Седан / Хэтчбек",
    weight = 60,
    -- BeamNG model names that fit this class
    models = {
      "pessima",       -- Ibishu Pessima (sedan)
      "fullsize",      -- Gavril Grand Marshal (fullsize sedan)
      "midsize",       -- ETK 800 Series (midsize sedan)
      "compact",       -- Ibishu Covet (compact hatchback)
      "legran",        -- Cherrier FCV (sedan)
      "etk800",        -- ETK 800
      "etkc",          -- ETK C-Series
      "vivace",        -- Cherrier Vivace
    },
    -- Config preferences for this class
    configs = {
      preferStock = true,   -- prefer stock configurations
      allowModified = true,
    },
    -- Physics modifiers for this class
    physicsModifiers = {
      mass = { min = 0.95, max = 1.05 },       -- ±5% mass variation
      brakeForce = { min = 0.90, max = 1.05 },  -- slight brake variation
      enginePower = { min = 0.90, max = 1.05 },
    },
    -- Preferred personality types (weighted)
    personalityWeights = {
      pensioner = 15,
      normal = 60,
      aggressive = 15,
      distracted = 10,
    },
  },

  -- ────────────────────────────────────────────────────────────────────────────
  suv = {
    name = "SUV / Crossover",
    nameRU = "Кроссовер / Внедорожник",
    weight = 15,
    models = {
      "moonhawk",       -- Gavril Roamer-like
      "roamer",         -- Gavril Roamer
      "pickup",         -- Gavril D-Series (pickup, close to SUV)
      "lansdale",       -- if available
    },
    configs = {
      preferStock = true,
      allowModified = true,
    },
    physicsModifiers = {
      mass = { min = 1.0, max = 1.15 },
      brakeForce = { min = 0.85, max = 1.00 },
      enginePower = { min = 0.90, max = 1.05 },
    },
    personalityWeights = {
      pensioner = 10,
      normal = 55,
      aggressive = 20,
      distracted = 15,
    },
  },

  -- ────────────────────────────────────────────────────────────────────────────
  commercial = {
    name = "Commercial Vehicle",
    nameRU = "Коммерческий транспорт",
    weight = 10,
    models = {
      "van",            -- Gavril H-Series (van)
      "pickup",         -- D-Series with bed
      "boxutility",     -- box utility truck
      "semi",           -- T-Series semi (if appropriate)
    },
    configs = {
      preferStock = true,
      allowModified = false,
      preferLoaded = true,  -- prefer loaded/heavy variants
    },
    physicsModifiers = {
      mass = { min = 1.10, max = 1.50 },          -- heavier due to cargo
      brakeForce = { min = 0.65, max = 0.85 },     -- worse brakes under load
      enginePower = { min = 0.80, max = 0.95 },    -- struggles with weight
    },
    personalityWeights = {
      pensioner = 5,
      normal = 70,
      aggressive = 10,
      distracted = 15,
    },
    -- Special: slower acceleration, longer stopping distance
    maxSpeedMultiplier = 0.85,  -- won't go above 85% of road limit
  },

  -- ────────────────────────────────────────────────────────────────────────────
  bus = {
    name = "Bus",
    nameRU = "Автобус",
    weight = 5,
    models = {
      "citybus",        -- if available
      "bus",            -- generic
      "van",            -- large van as substitute
    },
    configs = {
      preferStock = true,
      allowModified = false,
    },
    physicsModifiers = {
      mass = { min = 1.30, max = 1.80 },
      brakeForce = { min = 0.55, max = 0.75 },
      enginePower = { min = 0.70, max = 0.85 },
    },
    personalityWeights = {
      pensioner = 20,
      normal = 70,
      aggressive = 0,
      distracted = 10,
    },
    maxSpeedMultiplier = 0.75,  -- buses are slow
    makesStops = true,          -- periodic stops at bus-stop-like locations
    stopDuration = { min = 5, max = 15 }, -- seconds at each stop
  },

  -- ────────────────────────────────────────────────────────────────────────────
  sporty = {
    name = "Sports Car / Junker",
    nameRU = "Спорткар / Автохлам",
    weight = 10,
    models = {
      -- Sports cars
      "coupe",          -- ETK K-Series
      "sunburst",       -- Hirochi Sunburst
      "200bx",          -- Ibishu 200BX
      "sbr",            -- Hirochi SBR4
      -- Junkers (old, rusty)
      "burnside",       -- Burnside Special (old car)
      "moonhawk",       -- Bruckell Moonhawk (classic muscle/junker)
      "wigeon",         -- Autobello Piccolina (tiny old car)
    },
    configs = {
      preferStock = false,
      allowModified = true,
      -- 50% chance of being a sports car, 50% chance of being a junker
      junkerChance = 0.5,
    },
    physicsModifiers = {
      -- Sports car modifiers
      sports = {
        mass = { min = 0.85, max = 0.95 },
        brakeForce = { min = 1.05, max = 1.20 },
        enginePower = { min = 1.10, max = 1.30 },
      },
      -- Junker modifiers
      junker = {
        mass = { min = 1.00, max = 1.10 },
        brakeForce = { min = 0.50, max = 0.75 },   -- старые тормоза!
        enginePower = { min = 0.60, max = 0.85 },   -- мотор дымит
      },
    },
    personalityWeights = {
      -- Sports: mostly aggressive
      sports = { pensioner = 0, normal = 25, aggressive = 65, distracted = 10 },
      -- Junker: mostly cautious (knows car is bad)
      junker = { pensioner = 35, normal = 40, aggressive = 5, distracted = 20 },
    },
  },
}

-- ══════════════════════════════════════════════════════════════════════════════
-- VEHICLE CONDITION SYSTEM
-- Симуляция состояния автомобиля: изношенные тормоза, нагрузка, и т.д.
-- ══════════════════════════════════════════════════════════════════════════════

local CONDITION_PRESETS = {
  -- Brand new car from dealership
  new = {
    nameRU = "Новый",
    probability = 0.15,
    brakeEfficiency   = { min = 0.95, max = 1.00 },
    tireGrip          = { min = 0.95, max = 1.00 },
    engineHealth      = { min = 0.95, max = 1.00 },
    suspensionQuality = { min = 0.95, max = 1.00 },
    steeringPlay      = { min = 0.00, max = 0.02 },  -- minimal play
    alignment         = { min = -0.5, max = 0.5 },     -- degrees off-center
  },

  -- Well-maintained used car
  good = {
    nameRU = "Хорошее",
    probability = 0.40,
    brakeEfficiency   = { min = 0.82, max = 0.95 },
    tireGrip          = { min = 0.85, max = 0.95 },
    engineHealth      = { min = 0.85, max = 0.95 },
    suspensionQuality = { min = 0.80, max = 0.95 },
    steeringPlay      = { min = 0.01, max = 0.05 },
    alignment         = { min = -1.5, max = 1.5 },
  },

  -- Average condition, some wear
  average = {
    nameRU = "Среднее",
    probability = 0.30,
    brakeEfficiency   = { min = 0.65, max = 0.85 },
    tireGrip          = { min = 0.70, max = 0.88 },
    engineHealth      = { min = 0.70, max = 0.88 },
    suspensionQuality = { min = 0.65, max = 0.85 },
    steeringPlay      = { min = 0.03, max = 0.10 },
    alignment         = { min = -3.0, max = 3.0 },
  },

  -- Poor condition — the junker
  poor = {
    nameRU = "Плохое",
    probability = 0.12,
    brakeEfficiency   = { min = 0.40, max = 0.65 },  -- опасно!
    tireGrip          = { min = 0.50, max = 0.72 },
    engineHealth      = { min = 0.45, max = 0.70 },
    suspensionQuality = { min = 0.40, max = 0.65 },
    steeringPlay      = { min = 0.08, max = 0.20 },
    alignment         = { min = -5.0, max = 5.0 },
  },

  -- Terrible — should be in a junkyard
  terrible = {
    nameRU = "Ужасное",
    probability = 0.03,
    brakeEfficiency   = { min = 0.25, max = 0.45 },
    tireGrip          = { min = 0.35, max = 0.55 },
    engineHealth      = { min = 0.30, max = 0.55 },
    suspensionQuality = { min = 0.25, max = 0.50 },
    steeringPlay      = { min = 0.15, max = 0.35 },
    alignment         = { min = -8.0, max = 8.0 },
  },
}

-- ══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════════

local classPool = {}              -- weighted pool for random class selection
local vehicleRegistry = {}        -- { [vehId] = { class, condition, subtype, ... } }
local spawnedClassCounts = {}     -- { sedan = 5, suv = 2, ... }
local totalSpawned = 0

-- ══════════════════════════════════════════════════════════════════════════════
-- INIT
-- ══════════════════════════════════════════════════════════════════════════════

function M.init()
  vehicleRegistry = {}
  spawnedClassCounts = {}
  totalSpawned = 0
  classPool = {}

  -- Build weighted class pool
  for classId, classDef in pairs(VEHICLE_CLASSES) do
    for i = 1, classDef.weight do
      table.insert(classPool, classId)
    end
    spawnedClassCounts[classId] = 0
  end

  log("I", "TrafficAI.VehicleDiversity",
    string.format("Vehicle diversity initialized. %d classes, pool size %d.",
      M.getClassCount(), #classPool))
end

-- ══════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════════════════════════════════

local function randRange(range)
  return range.min + math.random() * (range.max - range.min)
end

--- Select a condition preset based on probability weights
---@return string conditionId
---@return table conditionDef
local function selectCondition()
  local roll = math.random()
  local cumulative = 0

  for condId, condDef in pairs(CONDITION_PRESETS) do
    cumulative = cumulative + condDef.probability
    if roll <= cumulative then
      return condId, condDef
    end
  end

  -- Fallback
  return "average", CONDITION_PRESETS.average
end

-- ══════════════════════════════════════════════════════════════════════════════
-- VEHICLE PROFILE GENERATION
-- ══════════════════════════════════════════════════════════════════════════════

--- Generate a complete vehicle profile (class, model, condition, modifiers)
---@param vehId number|nil  optional, for tracking
---@param forceClass string|nil  force a specific class
---@return table profile
function M.generateVehicleProfile(vehId, forceClass)
  -- ── 1. Select vehicle class ────────────────────────────────────────────
  local classId
  if forceClass and VEHICLE_CLASSES[forceClass] then
    classId = forceClass
  else
    classId = classPool[math.random(#classPool)]
  end
  local classDef = VEHICLE_CLASSES[classId]

  -- ── 2. Select model from class ─────────────────────────────────────────
  local models = classDef.models
  local modelName = models[math.random(#models)]

  -- ── 3. Determine subtype (for sporty class: sports vs junker) ──────────
  local subtype = "standard"
  if classId == "sporty" and classDef.configs.junkerChance then
    if math.random() < classDef.configs.junkerChance then
      subtype = "junker"
    else
      subtype = "sports"
    end
  end

  -- ── 4. Select condition ────────────────────────────────────────────────
  local conditionId, conditionDef = selectCondition()

  -- Junkers are always in poor/terrible condition
  if subtype == "junker" then
    if math.random() > 0.3 then
      conditionId = "poor"
      conditionDef = CONDITION_PRESETS.poor
    else
      conditionId = "terrible"
      conditionDef = CONDITION_PRESETS.terrible
    end
  end
  -- Sports cars tend to be in better condition
  if subtype == "sports" then
    if math.random() > 0.5 then
      conditionId = "new"
      conditionDef = CONDITION_PRESETS.new
    else
      conditionId = "good"
      conditionDef = CONDITION_PRESETS.good
    end
  end

  -- ── 5. Generate condition parameters ───────────────────────────────────
  local condition = {
    id               = conditionId,
    nameRU           = conditionDef.nameRU,
    brakeEfficiency  = randRange(conditionDef.brakeEfficiency),
    tireGrip         = randRange(conditionDef.tireGrip),
    engineHealth     = randRange(conditionDef.engineHealth),
    suspensionQuality = randRange(conditionDef.suspensionQuality),
    steeringPlay     = randRange(conditionDef.steeringPlay),
    alignment        = randRange(conditionDef.alignment),
  }

  -- ── 6. Generate physics modifiers ──────────────────────────────────────
  local physMods
  if classId == "sporty" then
    physMods = classDef.physicsModifiers[subtype] or classDef.physicsModifiers.sports
  else
    physMods = classDef.physicsModifiers
  end

  local physics = {
    massMultiplier   = randRange(physMods.mass),
    brakeMultiplier  = randRange(physMods.brakeForce) * condition.brakeEfficiency,
    powerMultiplier  = randRange(physMods.enginePower) * condition.engineHealth,
  }

  -- ── 7. Determine preferred personality ─────────────────────────────────
  local persWeights
  if classId == "sporty" then
    persWeights = classDef.personalityWeights[subtype] or classDef.personalityWeights.sports
  else
    persWeights = classDef.personalityWeights
  end

  -- Build personality pool for this vehicle
  local persPool = {}
  for persId, w in pairs(persWeights) do
    for i = 1, w do
      table.insert(persPool, persId)
    end
  end
  local suggestedPersonality = persPool[math.random(#persPool)]

  -- ── 8. Build profile ──────────────────────────────────────────────────
  local profile = {
    vehicleId            = vehId,
    classId              = classId,
    className            = classDef.name,
    classNameRU          = classDef.nameRU,
    modelName            = modelName,
    subtype              = subtype,
    condition            = condition,
    physics              = physics,
    suggestedPersonality = suggestedPersonality,
    maxSpeedMultiplier   = classDef.maxSpeedMultiplier or 1.0,
    makesStops           = classDef.makesStops or false,
    stopDuration         = classDef.stopDuration or { min = 0, max = 0 },
    useSimplified        = true,    -- always use simplified for traffic
    isLoaded             = classDef.configs.preferLoaded or false,
  }

  -- Track spawn counts
  if vehId then
    vehicleRegistry[vehId] = profile
    spawnedClassCounts[classId] = (spawnedClassCounts[classId] or 0) + 1
    totalSpawned = totalSpawned + 1
  end

  log("I", "TrafficAI.VehicleDiversity",
    string.format("Profile: class=%s(%s) model=%s condition=%s brake=%.0f%% power=%.0f%% personality=%s",
      profile.classNameRU, subtype, modelName, condition.nameRU,
      physics.brakeMultiplier * 100, physics.powerMultiplier * 100,
      suggestedPersonality))

  return profile
end

-- ══════════════════════════════════════════════════════════════════════════════
-- SPAWN FUNCTIONS
-- ══════════════════════════════════════════════════════════════════════════════

--- Spawn a traffic vehicle with diversity applied
---@param spawnPoint vec3|table  position {x, y, z}
---@param spawnDir vec3|table|nil  direction (optional)
---@param forceClass string|nil  force vehicle class
---@return number|nil vehId  spawned vehicle ID or nil
function M.spawnTrafficVehicle(spawnPoint, spawnDir, forceClass)
  local profile = M.generateVehicleProfile(nil, forceClass)

  -- Build spawn options for BeamNG
  local spawnOptions = {
    model = profile.modelName,
    pos = spawnPoint,
    rot = spawnDir or nil,
    autoEnterVehicle = false,
    -- Use simplified model for traffic
    vehicleConfig = nil,  -- will be set below
  }

  -- ── Simplified vehicle configuration ───────────────────────────────────
  -- BeamNG 0.38.3 supports traffic model simplification
  -- This is CRITICAL for performance with 10-15 traffic vehicles
  local configData = {
    -- Request simplified mesh/physics when available
    simplifyPhysics = profile.useSimplified,
    -- Paints and visual variation
    paintDesign = M.getRandomPaint(),
  }

  -- ── Attempt spawn via BeamNG API ───────────────────────────────────────
  local vehObj = nil

  -- Method 1: gameplay_traffic spawn (preferred)
  if gameplay_traffic and gameplay_traffic.spawnTrafficVehicle then
    vehObj = gameplay_traffic.spawnTrafficVehicle(spawnOptions)
  end

  -- Method 2: core spawn
  if not vehObj then
    local spawner = spawn or core_vehicles
    if spawner and spawner.spawnVehicle then
      vehObj = spawner.spawnVehicle(
        profile.modelName,
        configData.vehicleConfig or "",
        spawnPoint,
        spawnDir and quatFromDir(spawnDir) or nil
      )
    end
  end

  if vehObj then
    local vehId = vehObj:getId()
    profile.vehicleId = vehId
    vehicleRegistry[vehId] = profile
    spawnedClassCounts[profile.classId] = (spawnedClassCounts[profile.classId] or 0) + 1
    totalSpawned = totalSpawned + 1

    -- Apply physical modifications
    M.applyPhysicsModifiers(vehObj, profile)

    -- Set up AI driving
    M.setupVehicleAI(vehObj, profile)

    log("I", "TrafficAI.VehicleDiversity",
      string.format("Spawned vehicle %d: %s %s (condition: %s)",
        vehId, profile.classNameRU, profile.modelName, profile.condition.nameRU))

    return vehId
  else
    log("W", "TrafficAI.VehicleDiversity",
      string.format("Failed to spawn vehicle: model=%s", profile.modelName))
    return nil
  end
end

--- Get a random paint for visual diversity
---@return table paintData
function M.getRandomPaint()
  -- Common car colors with real-world distribution
  local colors = {
    { r = 0.95, g = 0.95, b = 0.95, weight = 20 }, -- white
    { r = 0.10, g = 0.10, b = 0.10, weight = 18 }, -- black
    { r = 0.50, g = 0.50, b = 0.55, weight = 16 }, -- silver/gray
    { r = 0.30, g = 0.30, b = 0.30, weight = 10 }, -- dark gray
    { r = 0.70, g = 0.10, b = 0.10, weight = 8  }, -- red
    { r = 0.10, g = 0.15, b = 0.50, weight = 8  }, -- blue
    { r = 0.85, g = 0.85, b = 0.80, weight = 5  }, -- beige
    { r = 0.15, g = 0.30, b = 0.15, weight = 4  }, -- green
    { r = 0.60, g = 0.30, b = 0.05, weight = 3  }, -- brown
    { r = 0.95, g = 0.80, b = 0.00, weight = 3  }, -- yellow
    { r = 0.90, g = 0.45, b = 0.00, weight = 3  }, -- orange
    { r = 0.35, g = 0.00, b = 0.55, weight = 2  }, -- purple
  }

  -- Weighted selection
  local totalWeight = 0
  for _, c in ipairs(colors) do totalWeight = totalWeight + c.weight end
  local roll = math.random() * totalWeight
  local cumulative = 0
  for _, c in ipairs(colors) do
    cumulative = cumulative + c.weight
    if roll <= cumulative then
      -- Add slight variation
      return {
        r = math.max(0, math.min(1, c.r + (math.random() - 0.5) * 0.08)),
        g = math.max(0, math.min(1, c.g + (math.random() - 0.5) * 0.08)),
        b = math.max(0, math.min(1, c.b + (math.random() - 0.5) * 0.08)),
      }
    end
  end
  return { r = 0.5, g = 0.5, b = 0.5 }
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PHYSICS MODIFIERS
-- Применяем физические изменения к транспорту (изношенные тормоза и т.д.)
-- ══════════════════════════════════════════════════════════════════════════════

--- Apply physics modifiers to a spawned vehicle
---@param vehObj userdata
---@param profile table
function M.applyPhysicsModifiers(vehObj, profile)
  local phys = profile.physics
  local cond = profile.condition

  -- ── Brake force adjustment ─────────────────────────────────────────────
  -- Modifies the brake force multiplier
  -- Lower efficiency = longer stopping distance
  local brakeCmd = string.format([[
    local bc = v.data.brakes
    if bc then
      for _, brake in pairs(bc) do
        if brake.brakeTorque then
          brake.brakeTorque = brake.brakeTorque * %.3f
        end
      end
    end
  ]], phys.brakeMultiplier)

  vehObj:queueLuaCommand(brakeCmd)

  -- ── Engine power adjustment ────────────────────────────────────────────
  -- Simulate worn engine or high-performance engine
  local engineCmd = string.format([[
    if controller and controller.mainController then
      local engine = controller.mainController
      if engine.setEnginePowerFactor then
        engine.setEnginePowerFactor(%.3f)
      end
    end
  ]], phys.powerMultiplier)

  vehObj:queueLuaCommand(engineCmd)

  -- ── Tire grip adjustment ───────────────────────────────────────────────
  -- Worn tires = less grip
  local gripCmd = string.format([[
    local wheels = v.data.wheels
    if wheels then
      for _, wheel in pairs(wheels) do
        if wheel.frictionCoef then
          wheel.frictionCoef = wheel.frictionCoef * %.3f
        end
      end
    end
  ]], cond.tireGrip)

  vehObj:queueLuaCommand(gripCmd)

  -- ── Steering play ──────────────────────────────────────────────────────
  -- Worn steering = slight wandering
  if cond.steeringPlay > 0.05 then
    local steerCmd = string.format([[
      if hydros then
        for _, hydro in pairs(hydros.hydros or {}) do
          if hydro.inputSource == "steering_input" then
            hydro.steeringDeadzone = %.3f
          end
        end
      end
    ]], cond.steeringPlay)

    vehObj:queueLuaCommand(steerCmd)
  end

  -- ── Wheel alignment ────────────────────────────────────────────────────
  -- Misaligned wheels cause the car to pull to one side
  if math.abs(cond.alignment) > 1.0 then
    local alignCmd = string.format([[
      if controller and controller.setSteeringOffset then
        controller.setSteeringOffset(%.4f)
      end
    ]], math.rad(cond.alignment) * 0.01)

    vehObj:queueLuaCommand(alignCmd)
  end

  -- ── Mass adjustment (loaded vehicles) ──────────────────────────────────
  if phys.massMultiplier ~= 1.0 then
    local massCmd = string.format([[
      local nodes = v.data.nodes
      if nodes then
        for _, node in pairs(nodes) do
          if node.nodeWeight then
            node.nodeWeight = node.nodeWeight * %.3f
          end
        end
      end
    ]], phys.massMultiplier)

    vehObj:queueLuaCommand(massCmd)
  end

  -- ── Enable simplified rendering for traffic ────────────────────────────
  if profile.useSimplified then
    vehObj:queueLuaCommand([[
      if obj.setMeshAlpha then
        -- Reduce LOD for traffic vehicles
        obj:setMeshAlpha(1, "", false)
      end
      -- Disable unnecessary systems for performance
      if mapmgr then mapmgr.enableTracking(false) end
    ]])
  end

  log("D", "TrafficAI.VehicleDiversity",
    string.format("Veh %d physics: brake=%.0f%% power=%.0f%% grip=%.0f%% mass=%.0f%% steerPlay=%.3f align=%.1f°",
      profile.vehicleId,
      phys.brakeMultiplier * 100, phys.powerMultiplier * 100,
      cond.tireGrip * 100, phys.massMultiplier * 100,
      cond.steeringPlay, cond.alignment))
end

-- ══════════════════════════════════════════════════════════════════════════════
-- AI SETUP
-- ══════════════════════════════════════════════════════════════════════════════

--- Set up the AI driver for a spawned vehicle
---@param vehObj userdata
---@param profile table
function M.setupVehicleAI(vehObj, profile)
  -- Enable AI
  vehObj:queueLuaCommand('ai.setMode("traffic")')

  -- Set aggression based on suggested personality
  local aggressionMap = {
    pensioner  = 0.25,
    normal     = 0.45,
    aggressive = 0.85,
    distracted = 0.40,
  }
  local aggression = aggressionMap[profile.suggestedPersonality] or 0.45
  vehObj:queueLuaCommand(string.format('ai.setAggression(%.3f)', aggression))

  -- Speed limit based on vehicle class
  if profile.maxSpeedMultiplier < 1.0 then
    vehObj:queueLuaCommand(string.format(
      'ai.setSpeedMode("limit"); ai.setSpeed(%.2f)',
      120 / 3.6 * profile.maxSpeedMultiplier  -- max highway speed adjusted
    ))
  end

  -- Avoid cars by default
  vehObj:queueLuaCommand('ai.setAvoidCars("on")')
end

-- ══════════════════════════════════════════════════════════════════════════════
-- RUNTIME UPDATE
-- Обновляет состояние машин (автобусные остановки, износ и т.д.)
-- ══════════════════════════════════════════════════════════════════════════════

--- Per-vehicle bus stop state
local busStopStates = {} -- { [vehId] = { nextStopTimer, isStopped, stopTimer } }

--- Update vehicle diversity effects
---@param vehObj userdata
---@param aiState table
---@param dt number
function M.update(vehObj, aiState, dt)
  local vehId = aiState.vehicleId
  local profile = vehicleRegistry[vehId]

  if not profile then return end

  -- ── Apply max speed multiplier from vehicle class ──────────────────────
  if profile.maxSpeedMultiplier < 1.0 then
    aiState.currentSpeedLimit = aiState.currentSpeedLimit * profile.maxSpeedMultiplier
  end

  -- ── Bus stop behavior ──────────────────────────────────────────────────
  if profile.makesStops then
    if not busStopStates[vehId] then
      busStopStates[vehId] = {
        nextStopTimer = 30 + math.random() * 60,  -- 30-90 sec between stops
        isStopped = false,
        stopTimer = 0,
      }
    end

    local bss = busStopStates[vehId]

    if not bss.isStopped then
      bss.nextStopTimer = bss.nextStopTimer - dt
      if bss.nextStopTimer <= 0 then
        -- Time to make a stop
        bss.isStopped = true
        bss.stopTimer = randRange(profile.stopDuration)
        -- Command vehicle to stop
        aiState.waitingAtSignal = true
        log("D", "TrafficAI.VehicleDiversity",
          string.format("Veh %d (bus): making stop for %.1fs", vehId, bss.stopTimer))
      end
    else
      bss.stopTimer = bss.stopTimer - dt
      aiState.waitingAtSignal = true  -- keep stopped

      if bss.stopTimer <= 0 then
        bss.isStopped = false
        bss.nextStopTimer = 30 + math.random() * 60
        aiState.waitingAtSignal = false
        log("D", "TrafficAI.VehicleDiversity",
          string.format("Veh %d (bus): departing stop", vehId))
      end
    end
  end

  -- ── Steering play effect (runtime drift) ───────────────────────────────
  local cond = profile.condition
  if cond.steeringPlay > 0.08 then
    -- Apply slight random steering input to simulate play
    local steerNoise = (math.random() - 0.5) * cond.steeringPlay * 2
    vehObj:queueLuaCommand(string.format(
      'electrics.values.steeringUnassisted = (electrics.values.steeringUnassisted or 0) + %.4f',
      steerNoise
    ))
  end

  -- ── Alignment pull effect ──────────────────────────────────────────────
  if math.abs(cond.alignment) > 2.0 then
    local pullForce = cond.alignment * 0.0005
    vehObj:queueLuaCommand(string.format(
      'electrics.values.steeringUnassisted = (electrics.values.steeringUnassisted or 0) + %.5f',
      pullForce
    ))
  end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ══════════════════════════════════════════════════════════════════════════════

--- Get vehicle profile by ID
---@param vehId number
---@return table|nil
function M.getVehicleProfile(vehId)
  return vehicleRegistry[vehId]
end

--- Remove vehicle from registry
---@param vehId number
function M.removeVehicle(vehId)
  local profile = vehicleRegistry[vehId]
  if profile then
    spawnedClassCounts[profile.classId] = math.max(0,
      (spawnedClassCounts[profile.classId] or 1) - 1)
    totalSpawned = math.max(0, totalSpawned - 1)
  end
  vehicleRegistry[vehId] = nil
  busStopStates[vehId] = nil
end

--- Get spawn statistics
function M.getSpawnStats()
  return {
    total = totalSpawned,
    byClass = shallowCopy(spawnedClassCounts),
  }
end

--- Get all class definitions
function M.getVehicleClasses()
  return VEHICLE_CLASSES
end

--- Get class count
function M.getClassCount()
  local count = 0
  for _ in pairs(VEHICLE_CLASSES) do count = count + 1 end
  return count
end

--- Get condition presets
function M.getConditionPresets()
  return CONDITION_PRESETS
end

-- Utility
local function shallowCopy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

return M