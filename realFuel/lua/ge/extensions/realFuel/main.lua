-- Real Fuel: game engine side.
-- Stores the settings (on/off, window state), forwards the on/off flag to every
-- vehicle and routes the buttons of the UI app to the player vehicle.

local M = {}

local logTag = "realFuel"
local settingsPath = "/settings/realFuel.json"

local validTabs = {fuel = true, stats = true}

local settings = {
  enabled = true, -- true = no free refuel on reset
  emergencyLiters = 5,
  uiCollapsed = false,
  uiTab = "fuel"
}

local function loadSettings()
  local data = jsonReadFile(settingsPath)
  if type(data) ~= "table" then
    return
  end
  if type(data.enabled) == "boolean" then
    settings.enabled = data.enabled
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

local function sendSettings()
  guihooks.trigger("RealFuelSettings", {
    enabled = settings.enabled,
    emergencyLiters = settings.emergencyLiters,
    uiCollapsed = settings.uiCollapsed,
    uiTab = settings.uiTab
  })
end

local function pushToVehicle(veh)
  if veh then
    veh:queueLuaCommand(string.format("if realFuelVeh then realFuelVeh.setEnabled(%s) end", tostring(settings.enabled)))
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
  pushToAllVehicles()
  sendSettings()
  log("I", logTag, "loaded, no refuel on reset: " .. tostring(settings.enabled))
end

local function onVehicleSpawned(vid, veh)
  pushToVehicle(veh or getObjectByID(vid))
end

local function onVehicleSwitched()
  requestState()
end

M.onExtensionLoaded = onExtensionLoaded
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched

M.setEnabled = setEnabled
M.toggleEnabled = toggleEnabled
M.isEnabled = isEnabled
M.setUiState = setUiState
M.refuelEmergency = refuelEmergency
M.refuelFull = refuelFull
M.resetTrip = resetTrip
M.requestState = requestState

return M
