-- Real Fuel: keeps the fuel / battery level of a vehicle when it is reset (R)
-- or reloaded (Ctrl+R) instead of refilling it to the starting value.
-- Also runs a small trip computer (consumption, range, distance...) for the player vehicle,
-- and remembers the fuel level per vehicle configuration (kept by the GE side, realFuel_main):
-- a car spawned again later gets the fuel it had when the player last drove it.
-- Loaded automatically into every vehicle (lua/vehicle/extensions/auto).

local M = {}

local logTag = "realFuel"

local abs, min, max = math.abs, math.min, math.max

local STATE_INTERVAL = 0.5 -- seconds between UI state updates for the player vehicle
local RESTORE_FRAMES = 3 -- re-apply the saved level for a few frames after a reset
local BATTERY_EMERGENCY_KWH = 5 -- emergency charge for electric vehicles without a fuel tank
local J_PER_KWH = 3600000

local EMA_TAU = 1.5 -- seconds, smoothing of the instant consumption
local MOVING_SPEED = 1 -- m/s, below this the vehicle counts as standing
local INSTANT_MIN_SPEED = 1.5 -- m/s, below this instant L/100km is not shown
local RANGE_WINDOW = 10000 -- m, range estimate uses roughly the last 10 km of driving
local RANGE_MIN_DISTANCE = 1000 -- m, driven distance needed before a range is estimated
local MAX_SANE_SPEED = 150 -- m/s, ignore physics spikes for the max speed

local MEMORY_REPORT_INTERVAL = 2 -- s, the player vehicle reports its levels to the GE side this often
local MEMORY_CLAIM_DELAY = 1 -- s seated before asking: spawning resets the vehicle (spawn.safeTeleport) once more
local MEMORY_WAIT_TIMEOUT = 3 -- s, start remembering anyway if the GE side does not answer
local MEMORY_PROTECT = 3 -- s after a restore in which any reset keeps the restored level
local MEMORY_MESSAGE_MIN = 0.05 -- L / kWh, smaller restores are not announced

local enabled = true
local pendingLevels = nil
local pendingFrames = 0
local stateTimer = 0

-- per-configuration memory
local perConfig = true
local memoryState = "new" -- "new": not driven by the player yet, "waiting": asked the GE side, "active": reporting
local memoryWait = 0
local memorySeatedTime = 0
local memoryProtect = 0
local memoryReportTimer = 0
local memoryLastTotal = nil
local memoryWasSeated = false

-- trip computer
local function newTrip()
  return {distance = 0, used = 0, time = 0, movingTime = 0, maxSpeed = 0, added = 0}
end
local trip = newTrip()
local rangeUsed, rangeDistance = 0, 0
local flowEMA, speedEMA = 0, 0
local statsUnit = nil -- "fuel" (liters) or "battery" (kWh)
local prevLevel = nil
local skipSample = true
local wasSeated = false

local function isTracked(storage)
  return storage ~= nil
    and (storage.type == "fuelTank" or storage.type == "electricBattery")
    and type(storage.energyCapacity) == "number" and storage.energyCapacity > 0
end

-- Joules per liter of a fuel tank, 0 if unknown
local function joulesPerLiter(storage)
  local density = (storage.fuelLiquidDensity or 0) * (storage.energyDensity or 0)
  return density > 0 and density or 0
end

local function sortedStorageNames(filterType)
  local names = {}
  for name, storage in pairs(energyStorage.getStorages()) do
    if isTracked(storage) and (not filterType or storage.type == filterType) then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

-- fuel (L), fuel capacity (L), battery (kWh), battery capacity (kWh), fuel type
local function readLevels()
  local fuel, fuelCapacity, battery, batteryCapacity = 0, 0, 0, 0
  local fuelType
  for _, storage in pairs(energyStorage.getStorages()) do
    if isTracked(storage) then
      if storage.type == "fuelTank" then
        local jpl = joulesPerLiter(storage)
        if jpl > 0 then
          fuel = fuel + storage.storedEnergy / jpl
          fuelCapacity = fuelCapacity + (storage.capacity or 0)
          fuelType = fuelType or storage.energyType
        end
      else
        battery = battery + storage.storedEnergy / J_PER_KWH
        batteryCapacity = batteryCapacity + (storage.capacity or 0)
      end
    end
  end
  return fuel, fuelCapacity, battery, batteryCapacity, fuelType
end

local function setEnergy(storage, energy)
  energy = clamp(energy, 0, storage.energyCapacity)
  if storage.setStoredEnergy then
    storage:setStoredEnergy(energy) -- electric battery, updates derived values itself
  else
    storage.storedEnergy = energy
    local jpl = joulesPerLiter(storage)
    if jpl > 0 then
      storage.remainingVolume = energy / jpl
    end
    storage.remainingRatio = energy / storage.energyCapacity
  end
end

local function captureLevels()
  local levels = {}
  local count = 0
  for name, storage in pairs(energyStorage.getStorages()) do
    if isTracked(storage) then
      levels[name] = {energy = storage.storedEnergy, energyType = storage.energyType}
      count = count + 1
    end
  end
  return count > 0 and levels or nil
end

local function applyLevels(levels)
  for name, saved in pairs(levels) do
    local storage = energyStorage.getStorage(name)
    if isTracked(storage) and type(saved) == "table" and type(saved.energy) == "number" and saved.energyType == storage.energyType then
      setEnergy(storage, saved.energy)
    end
  end
end

-- AI traffic / police / opponents are left alone: they rely on resets to keep running
local function isAiDriven()
  return not playerInfo.anyPlayerSeated and ai and ai.mode ~= nil and ai.mode ~= "disabled"
end

-- per-configuration memory ----------------------------------------------------------

-- "model|vehicles/model/config.pc": what the remembered level belongs to
-- (lower case, no leading slash: the same config is named "/vehicles/..." or "vehicles/..." depending on how it was spawned)
local function configKey()
  local dir = (v.data and v.data.vehicleDirectory) or ""
  local model = dir:match("/vehicles/([^/]+)") or dir
  local config = tostring((v.config and v.config.partConfigFilename) or ""):gsub("\\", "/"):gsub("^/+", "")
  return string.lower(model .. "|" .. config)
end

local function reportLevels(force)
  if not perConfig or memoryState ~= "active" then
    return
  end
  local levels = captureLevels()
  if not levels then
    return
  end
  local total = 0
  for _, l in pairs(levels) do
    total = total + l.energy
  end
  if not force and memoryLastTotal and abs(total - memoryLastTotal) < 1 then
    return -- unchanged (1 J is far below a millilitre)
  end
  memoryLastTotal = total
  obj:queueGameEngineLua(string.format("if realFuel_main then realFuel_main.storeLevels(%q, %s) end", configKey(), serialize(levels)))
end

local function updateMemory(dt)
  local seated = playerInfo.anyPlayerSeated
  if memoryWasSeated and not seated then
    reportLevels(true) -- the player got out or switched to another vehicle
  end
  memoryWasSeated = seated
  if not perConfig or not seated then
    memorySeatedTime = 0
    return
  end

  if memoryState == "new" then
    -- first time the player drives this vehicle since it was spawned: ask for its configuration's level,
    -- once the spawn has settled (it resets the vehicle again when it places it)
    memorySeatedTime = memorySeatedTime + dt
    if memorySeatedTime < MEMORY_CLAIM_DELAY then
      return
    end
    memoryState = "waiting"
    memoryWait = 0
    obj:queueGameEngineLua(string.format("if realFuel_main then realFuel_main.onVehicleSeated(%d, %q) end", obj:getId(), configKey()))
  elseif memoryState == "waiting" then
    memoryWait = memoryWait + dt
    if memoryWait > MEMORY_WAIT_TIMEOUT then
      memoryState = "active"
    end
  else
    memoryReportTimer = memoryReportTimer - dt
    if memoryReportTimer <= 0 then
      memoryReportTimer = MEMORY_REPORT_INTERVAL
      reportLevels(false)
    end
  end
end

-- trip computer -------------------------------------------------------------------

local function updateStats(dt)
  if not playerInfo.anyPlayerSeated then
    wasSeated = false
    return
  end
  if not wasSeated then
    wasSeated = true
    skipSample = true -- levels may have changed while nobody was driving
  end
  if dt <= 0 then
    return
  end

  local fuel, fuelCapacity, battery, batteryCapacity = readLevels()
  local level, unit
  if fuelCapacity > 0 then
    level, unit = fuel, "fuel"
  elseif batteryCapacity > 0 then
    level, unit = battery, "battery"
  else
    prevLevel = nil
    statsUnit = nil
    return
  end
  if unit ~= statsUnit then
    statsUnit = unit
    skipSample = true
  end

  local used = 0
  local validSample = not skipSample and prevLevel ~= nil
  if validSample then
    used = prevLevel - level
    if unit == "fuel" and used < 0 then
      used = 0 -- a tank only gains fuel from refuelling, never count that as negative consumption
    end
  end
  prevLevel = level
  skipSample = false

  local wheelSpeed = abs(electrics.values.wheelspeed or 0) -- same source as the game odometer
  local groundSpeed = abs(electrics.values.airspeed or 0)
  local distance = wheelSpeed * dt

  trip.time = trip.time + dt
  trip.distance = trip.distance + distance
  trip.used = trip.used + used
  if groundSpeed > MOVING_SPEED then
    trip.movingTime = trip.movingTime + dt
  end
  if validSample and groundSpeed > trip.maxSpeed and groundSpeed < MAX_SANE_SPEED then
    trip.maxSpeed = groundSpeed
  end

  -- exponentially weighted consumption over roughly the last RANGE_WINDOW meters
  local decay = max(1 - distance / RANGE_WINDOW, 0)
  rangeUsed = rangeUsed * decay + used
  rangeDistance = rangeDistance * decay + distance

  local a = min(dt / EMA_TAU, 1)
  flowEMA = flowEMA + (used / dt - flowEMA) * a
  speedEMA = speedEMA + (wheelSpeed - speedEMA) * a
end

local function buildStats(level)
  local stats = {
    unit = statsUnit,
    flow = flowEMA * 3600, -- per hour
    distance = trip.distance,
    used = trip.used,
    time = trip.time,
    movingTime = trip.movingTime,
    maxSpeed = trip.maxSpeed,
    added = trip.added,
    avgSpeed = trip.movingTime > 1 and trip.distance / trip.movingTime or 0
  }
  if speedEMA > INSTANT_MIN_SPEED then
    stats.instant = flowEMA / speedEMA * 100000 -- per 100 km
  end
  if trip.distance > 100 then
    stats.average = trip.used / trip.distance * 100000
  end
  if level and rangeDistance > RANGE_MIN_DISTANCE and rangeUsed > 0 then
    stats.range = level / (rangeUsed / rangeDistance) / 1000 -- km
    stats.rangeConsumption = rangeUsed / rangeDistance * 100000
  end
  return stats
end

local function resetTrip()
  trip = newTrip()
  skipSample = true
  M.sendState()
end

-- UI -------------------------------------------------------------------------------

local function sendState()
  if not playerInfo.firstPlayerSeated then
    return
  end

  local fuel, fuelCapacity, battery, batteryCapacity, fuelType = readLevels()
  local level = fuelCapacity > 0 and fuel or (batteryCapacity > 0 and battery or nil)

  guihooks.trigger("RealFuelVehicleState", {
    enabled = enabled,
    fuel = fuel,
    fuelCapacity = fuelCapacity,
    fuelType = fuelType,
    battery = battery,
    batteryCapacity = batteryCapacity,
    stats = buildStats(level)
  })
end

-- key: a translation key from locales/translations/<lang>/realFuel.translation.json
local function showMessage(key, context)
  guihooks.message({txt = key, context = context or {}}, 4, "realFuel")
end

-- add fuel (liters) to the fuel tanks; EVs without a tank get a small charge instead
local function addFuel(liters)
  liters = max(tonumber(liters) or 0, 0)
  local tankNames = sortedStorageNames("fuelTank")

  if #tankNames > 0 then
    local remaining = liters
    local added = 0
    for _, name in ipairs(tankNames) do
      if remaining <= 0 then
        break
      end
      local storage = energyStorage.getStorage(name)
      local jpl = joulesPerLiter(storage)
      if jpl > 0 then
        local volume = storage.storedEnergy / jpl
        local add = min(max((storage.capacity or 0) - volume, 0), remaining)
        if add > 0 then
          setEnergy(storage, (volume + add) * jpl)
          remaining = remaining - add
          added = added + add
        end
      end
    end
    if added > 0.01 then
      trip.added = trip.added + added
      showMessage("realFuel.msg.emergencyFuel", {amount = string.format("%.1f", added)})
    else
      showMessage("realFuel.msg.tankFull")
    end
  else
    local batteryNames = sortedStorageNames("electricBattery")
    if #batteryNames == 0 then
      showMessage("realFuel.msg.noTank")
      sendState()
      return
    end
    local remaining = BATTERY_EMERGENCY_KWH * J_PER_KWH
    local added = 0
    for _, name in ipairs(batteryNames) do
      if remaining <= 0 then
        break
      end
      local storage = energyStorage.getStorage(name)
      local add = min(max(storage.energyCapacity - storage.storedEnergy, 0), remaining)
      if add > 0 then
        setEnergy(storage, storage.storedEnergy + add)
        remaining = remaining - add
        added = added + add
      end
    end
    if added > 0 then
      trip.added = trip.added + added / J_PER_KWH
      showMessage("realFuel.msg.emergencyCharge", {amount = string.format("%.1f", added / J_PER_KWH)})
    else
      showMessage("realFuel.msg.batteryFull")
    end
  end

  pendingLevels = nil
  skipSample = true
  sendState()
  reportLevels(true)
end

-- fill every fuel tank and battery to capacity
local function fillUp()
  local liters, kwh = 0, 0
  local found = false
  for _, name in ipairs(sortedStorageNames()) do
    local storage = energyStorage.getStorage(name)
    found = true
    local missing = max(storage.energyCapacity - storage.storedEnergy, 0)
    if storage.type == "fuelTank" then
      local jpl = joulesPerLiter(storage)
      if jpl > 0 then
        liters = liters + missing / jpl
      end
    else
      kwh = kwh + missing / J_PER_KWH
    end
    setEnergy(storage, storage.energyCapacity)
  end

  if not found then
    showMessage("realFuel.msg.noTank")
  elseif liters > 0.01 or kwh > 0.01 then
    local context = {liters = string.format("%.1f", liters), kwh = string.format("%.1f", kwh)}
    if liters > 0.01 and kwh > 0.01 then
      showMessage("realFuel.msg.fillBoth", context)
    elseif liters > 0.01 then
      showMessage("realFuel.msg.fillFuel", context)
    else
      showMessage("realFuel.msg.fillCharge", context)
    end
    trip.added = trip.added + (liters > 0.01 and liters or kwh)
  else
    showMessage("realFuel.msg.tankFull")
  end

  pendingLevels = nil
  skipSample = true
  sendState()
  reportLevels(true)
end

-- the GE side's answer to onVehicleSeated: the level this configuration had (nil: nothing remembered)
local function onRememberedLevels(levels)
  if memoryState ~= "waiting" then
    return
  end
  memoryState = "active"
  memoryReportTimer = MEMORY_REPORT_INTERVAL
  if perConfig and type(levels) == "table" then
    local fuelBefore, _, batteryBefore = readLevels()
    applyLevels(levels)
    -- re-apply it for a few frames instead of whatever a reset just before captured (the spawn's full tank),
    -- and keep it through any reset in the next seconds
    pendingLevels = levels
    pendingFrames = RESTORE_FRAMES
    memoryProtect = MEMORY_PROTECT
    skipSample = true
    local fuel, fuelCapacity, battery, batteryCapacity = readLevels()
    log("I", logTag, string.format("restored %s: fuel %.2f -> %.2f L, battery %.2f -> %.2f kWh", configKey(), fuelBefore, fuel, batteryBefore, battery))
    if fuelCapacity > 0 and abs(fuel - fuelBefore) > MEMORY_MESSAGE_MIN then
      showMessage("realFuel.msg.restoredFuel", {liters = string.format("%.1f", fuel)})
    elseif fuelCapacity <= 0 and batteryCapacity > 0 and abs(battery - batteryBefore) > MEMORY_MESSAGE_MIN then
      showMessage("realFuel.msg.restoredCharge", {kwh = string.format("%.1f", battery)})
    end
    sendState()
  end
  reportLevels(true)
end

local function setOptions(enabledValue, perConfigValue)
  enabled = enabledValue and true or false
  if not enabled then
    pendingLevels = nil
  end
  if perConfigValue ~= nil then
    perConfig = perConfigValue and true or false
  end
  sendState()
end

local function setEnabled(value)
  setOptions(value, nil)
end

local function isEnabled()
  return enabled
end

-- hooks ---------------------------------------------------------------------

-- called by main.lua BEFORE energyStorage.reset(), so the tanks still hold the old values here
local function onReset()
  skipSample = true -- the reset changes the levels, don't count that as consumption
  speedEMA = 0
  -- right after a per-config restore a reset (the spawn placing the vehicle) must not refill it either
  local keep = enabled or memoryProtect > 0
  if not keep or isAiDriven() then
    pendingLevels = nil
    return
  end
  if memoryProtect > 0 then
    log("I", logTag, "reset right after a per-config restore: fuel level kept")
  end
  -- if several resets happen before a frame passes, keep the first (real) snapshot
  if not pendingLevels then
    pendingLevels = captureLevels()
  end
  pendingFrames = RESTORE_FRAMES
end

local function updateGFX(dt)
  if pendingLevels then
    applyLevels(pendingLevels)
    skipSample = true
    pendingFrames = pendingFrames - 1
    if pendingFrames <= 0 then
      pendingLevels = nil
    end
  end

  if memoryProtect > 0 then
    memoryProtect = memoryProtect - dt
  end

  updateStats(dt)
  updateMemory(dt)

  stateTimer = stateTimer - dt
  if stateTimer <= 0 then
    stateTimer = STATE_INTERVAL
    sendState()
  end
end

-- Ctrl+R / part changes / replacing the vehicle rebuild the vehicle Lua: carry the levels and the trip over
-- to the same configuration, and hand the last level of this configuration to the per-config memory
local function onSerialize()
  reportLevels(true)
  return {
    enabled = enabled,
    perConfig = perConfig,
    memoryState = memoryState,
    levels = (enabled and not isAiDriven()) and captureLevels() or nil,
    vehicleDirectory = v.data and v.data.vehicleDirectory,
    configKey = configKey(),
    trip = trip,
    rangeUsed = rangeUsed,
    rangeDistance = rangeDistance
  }
end

local function onDeserialize(data)
  if type(data) ~= "table" then
    return
  end
  if type(data.enabled) == "boolean" then
    enabled = data.enabled
  end
  if type(data.perConfig) == "boolean" then
    perConfig = data.perConfig
  end
  -- only restore into the same configuration: another car (or config) gets its own remembered level
  -- from the per-config memory when the player first drives it
  local same
  if type(data.configKey) == "string" then
    same = data.configKey == configKey()
  else
    same = data.vehicleDirectory == (v.data and v.data.vehicleDirectory)
  end
  if not same then
    return
  end
  if data.memoryState == "active" or data.memoryState == "waiting" then
    memoryState = "active" -- the same car reloaded: no need to ask the memory again
  end
  if enabled and type(data.levels) == "table" then
    pendingLevels = data.levels
    pendingFrames = RESTORE_FRAMES
  end
  if type(data.trip) == "table" then
    local restored = newTrip()
    for k in pairs(restored) do
      if type(data.trip[k]) == "number" then
        restored[k] = data.trip[k]
      end
    end
    trip = restored
  end
  if type(data.rangeUsed) == "number" and type(data.rangeDistance) == "number" then
    rangeUsed, rangeDistance = data.rangeUsed, data.rangeDistance
  end
  skipSample = true
end

local function onExtensionLoaded()
  log("D", logTag, "vehicle extension loaded")
end

M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.updateGFX = updateGFX
M.onSerialize = onSerialize
M.onDeserialize = onDeserialize

M.setEnabled = setEnabled
M.setOptions = setOptions
M.isEnabled = isEnabled
M.onRememberedLevels = onRememberedLevels
M.addFuel = addFuel
M.fillUp = fillUp
M.resetTrip = resetTrip
M.sendState = sendState

return M
