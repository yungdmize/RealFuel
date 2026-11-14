-- Real Fuel: game engine side.
-- Stores the settings (on/off switches, window state), forwards them to every vehicle,
-- routes the buttons of the UI app to the player vehicle and keeps the fuel level of every
-- vehicle configuration the player has driven (settings/realFuel_levels.json), so a car
-- spawned again later gets the fuel it had when the player left it.

local M = {}

local logTag = "realFuel"
local settingsPath = "/settings/realFuel.json"
local levelsPath = "/settings/realFuel_levels.json"

local validTabs = {fuel = true, stats = true}

local MAX_CONFIGS = 300 -- remembered configurations, the oldest are dropped
local SAVE_DELAY = 10 -- s, remembered levels are written at most this often

local settings = {
  enabled = true, -- true = no free refuel on reset
  perConfig = true, -- true = remember the fuel level of every vehicle configuration
  emergencyLiters = 5,
  uiCollapsed = false,
  uiTab = "fuel"
}

-- configuration key ("model|vehicles/model/config.pc") -> {levels = {[storage] = {energy, energyType}}, time}
local remembered = {}
local rememberedDirty = false
local saveTimer = 0

local function loadSettings()
  local data = jsonReadFile(settingsPath)
  if type(data) ~= "table" then
    return
  end
  if type(data.enabled) == "boolean" then
    settings.enabled = data.enabled
  end
  if type(data.perConfig) == "boolean" then
    settings.perConfig = data.perConfig
  end
  if type(data.emergencyLiters) == "number" and data.emergencyLiters > 0 then
    settings.emergencyLiters = data.emergencyLiters
  end
  if type(data.uiCollapsed) == "boolean" then
    settings.uiCollapsed = data.uiCollapsed
  end
  if validTabs[data.uiTab] then
    settings.uiTab = data.uiTab
  end
end

local function saveSettings()
  jsonWriteFile(settingsPath, settings, true)
end

-- "model|vehicles/model/config.pc" in lower case without a leading slash (the same config is named
-- "/vehicles/..." or "vehicles/..." depending on how it was spawned)
local function normKey(key)
  if type(key) ~= "string" then
    return nil
  end
  key = string.lower(key):gsub("\\", "/"):gsub("|/+", "|")
  return key
end

-- only {[name] = {energy = number >= 0, energyType = string}} is kept
local function cleanLevels(levels)
  if type(levels) ~= "table" then
    return nil
  end
  local out, count = {}, 0
  for name, l in pairs(levels) do
    if type(name) == "string" and type(l) == "table" and type(l.energy) == "number" and l.energy >= 0
      and l.energy == l.energy and type(l.energyType) == "string" then
      out[name] = {energy = l.energy, energyType = l.energyType}
      count = count + 1
    end
  end
  return count > 0 and out or nil
end

local function loadRemembered()
  remembered = {}
  local data = jsonReadFile(levelsPath)
  if type(data) ~= "table" or type(data.configs) ~= "table" then
    return
  end
  for rawKey, entry in pairs(data.configs) do
    local key = normKey(rawKey)
    local levels = key and type(entry) == "table" and cleanLevels(entry.levels)
    if levels then
      local time = tonumber(entry.time) or 0
      if not remembered[key] or remembered[key].time < time then -- two spellings of one config: the newest wins
        remembered[key] = {levels = levels, time = time}
      end
    end
  end
end

local function saveRemembered()
  jsonWriteFile(levelsPath, {format = 1, configs = remembered}, true)
  rememberedDirty = false
  saveTimer = 0
end

local function dropOldest()
  local keys = {}
  for key in pairs(remembered) do
    table.insert(keys, key)
  end
  if #keys <= MAX_CONFIGS then
    return
  end
  table.sort(keys, function(a, b) return remembered[a].time < remembered[b].time end)
  for i = 1, #keys - MAX_CONFIGS do
    remembered[keys[i]] = nil
  end
end

-- career has its own fuel (and money for it): the per-config memory stays out of it
local function careerActive()
  return career_career ~= nil and career_career.isActive ~= nil and career_career.isActive() == true
end

local function memoryActive()
  return settings.perConfig and not careerActive()
end

local function sendSettings()
  guihooks.trigger("RealFuelSettings", {
    enabled = settings.enabled,
    perConfig = settings.perConfig,
    emergencyLiters = settings.emergencyLiters,
    uiCollapsed = settings.uiCollapsed,
    uiTab = settings.uiTab
  })
end

local function pushToVehicle(veh)
  if veh then
    veh:queueLuaCommand(string.format("if realFuelVeh then realFuelVeh.setOptions(%s, %s) end",
      tostring(settings.enabled), tostring(settings.perConfig)))
  end
end

local function pushToAllVehicles()
  for _, veh in ipairs(getAllVehicles()) do
    pushToVehicle(veh)
  end
end

local function playerVehicleCommand(cmd)
  local veh = getPlayerVehicle(0)
  if veh then
    veh:queueLuaCommand(cmd)
    return true
  end
  return false
end

-- called from the vehicle side ------------------------------------------------

-- a vehicle is driven by the player for the first time since it was spawned: send it the level its
-- configuration had (nil: nothing remembered, keep the starting fuel)
local function onVehicleSeated(vid, key)
  local veh = getObjectByID(vid)
  if not veh then
    return
  end
  key = normKey(key)
  local entry = memoryActive() and key and remembered[key] or nil
  log("I", logTag, string.format("vehicle %d seated, config %s: %s", vid, tostring(key), entry and "remembered level sent" or "nothing remembered"))
  veh:queueLuaCommand("if realFuelVeh then realFuelVeh.onRememberedLevels(" .. (entry and serialize(entry.levels) or "nil") .. ") end")
end

-- the player vehicle reports its levels (every few seconds while driven, after refuelling, before a respawn)
local function storeLevels(key, levels)
  key = normKey(key)
  if not memoryActive() or not key or key == "" then
    return
  end
  levels = cleanLevels(levels)
  if not levels then
    return
  end
  remembered[key] = {levels = levels, time = os.time()}
  rememberedDirty = true
  dropOldest()
end

-- public API (used by the UI app) ----------------------------------------------

local function setEnabled(value)
  settings.enabled = value and true or false
  saveSettings()
  pushToAllVehicles()
  sendSettings()
  log("I", logTag, "no refuel on reset: " .. tostring(settings.enabled))
end

local function toggleEnabled()
  setEnabled(not settings.enabled)
end

local function isEnabled()
  return settings.enabled
end

local function setPerConfig(value)
  settings.perConfig = value and true or false
  saveSettings()
  pushToAllVehicles()
  sendSettings()
  log("I", logTag, "remember fuel per configuration: " .. tostring(settings.perConfig))
end

local function togglePerConfig()
  setPerConfig(not settings.perConfig)
end

local function forgetRemembered()
  remembered = {}
  saveRemembered()
  log("I", logTag, "remembered fuel levels cleared")
end

local function setUiState(collapsed, tab)
  if type(collapsed) == "boolean" then
    settings.uiCollapsed = collapsed
  end
  if validTabs[tab] then
    settings.uiTab = tab
  end
  saveSettings()
  sendSettings()
end

local function refuelEmergency()
  playerVehicleCommand(string.format("if realFuelVeh then realFuelVeh.addFuel(%.3f) end", settings.emergencyLiters))
end

local function refuelFull()
  playerVehicleCommand("if realFuelVeh then realFuelVeh.fillUp() end")
end

local function resetTrip()
  playerVehicleCommand("if realFuelVeh then realFuelVeh.resetTrip() end")
end

local function requestState()
  sendSettings()
  playerVehicleCommand("if realFuelVeh then realFuelVeh.sendState() end")
end

-- hooks -----------------------------------------------------------------------

local function onExtensionLoaded()
  loadSettings()
  loadRemembered()
  pushToAllVehicles()
  sendSettings()
  log("I", logTag, string.format("loaded, no refuel on reset: %s, remember per config: %s",
    tostring(settings.enabled), tostring(settings.perConfig)))
end

local function onExtensionUnloaded()
  if rememberedDirty then
    saveRemembered()
  end
end

local function onUpdate(dtReal)
  if not rememberedDirty then
    return
  end
  saveTimer = saveTimer + (dtReal or 0)
  if saveTimer >= SAVE_DELAY then
    saveRemembered()
  end
end

local function onPreExit()
  if rememberedDirty then
    saveRemembered()
  end
end

local function onVehicleSpawned(vid, veh)
  pushToVehicle(veh or getObjectByID(vid))
end

local function onVehicleSwitched()
  requestState()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onPreExit = onPreExit
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched

M.onVehicleSeated = onVehicleSeated
M.storeLevels = storeLevels

M.setEnabled = setEnabled
M.toggleEnabled = toggleEnabled
M.isEnabled = isEnabled
M.setPerConfig = setPerConfig
M.togglePerConfig = togglePerConfig
M.forgetRemembered = forgetRemembered
M.setUiState = setUiState
M.refuelEmergency = refuelEmergency
M.refuelFull = refuelFull
M.resetTrip = resetTrip
M.requestState = requestState

return M
