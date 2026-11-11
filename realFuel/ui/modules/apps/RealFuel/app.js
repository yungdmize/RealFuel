angular.module('beamng.apps')
.directive('realFuel', [function () {
  return {
    template: `<div class="rf-root">
  <style>
    .rf-root { width: 100%; height: 100%; pointer-events: none; font-size: 13px; color: #fff; user-select: none; }
    .rf-panel { pointer-events: auto; box-sizing: border-box; max-height: 100%; overflow-y: auto; padding: 6px 10px 9px; border-radius: 6px; background: rgba(0, 0, 0, 0.5); display: flex; flex-direction: column; gap: 7px; }
    .rf-panel.rf-collapsed { padding: 4px 6px 4px 10px; }
    .rf-row { display: flex; align-items: center; gap: 8px; }
    .rf-spacer { flex: 1; }
    .rf-head { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }
    .rf-title { font-weight: 600; opacity: 0.9; }
    .rf-value { font-variant-numeric: tabular-nums; white-space: nowrap; }
    .rf-value.rf-warn { color: #ff6b5b; }
    .rf-muted { opacity: 0.6; font-size: 12px; white-space: nowrap; }
    .rf-bar { height: 8px; border-radius: 4px; background: rgba(255, 255, 255, 0.15); overflow: hidden; flex: none; }
    .rf-bar.rf-bar-mini { height: 5px; width: 60px; border-radius: 3px; }
    .rf-fill { height: 100%; background: #ff6600; transition: width 0.3s; }
    .rf-fill.rf-low { background: #e53935; }
    .rf-btns { display: flex; gap: 6px; }
    .rf-btn { flex: 1; min-width: 0; padding: 6px 4px; margin: 0; border: none; border-radius: 4px; background: rgba(255, 255, 255, 0.14); color: #fff; font-size: 12px; line-height: 1.2; cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .rf-btn:hover:not([disabled]) { background: rgba(255, 102, 0, 0.85); }
    .rf-btn[disabled] { opacity: 0.4; cursor: default; }
    .rf-tabs { display: flex; align-items: center; gap: 2px; margin: 0 -4px; }
    .rf-tab { padding: 3px 6px 4px; margin: 0; border: none; border-bottom: 2px solid transparent; background: none; color: rgba(255, 255, 255, 0.6); font-size: 12px; font-weight: 600; cursor: pointer; }
    .rf-tab:hover { color: #fff; }
    .rf-tab.rf-active { color: #fff; border-bottom-color: #ff6600; }
    .rf-icon-btn { flex: none; width: 22px; height: 22px; padding: 0; margin: 0; border: none; border-radius: 4px; background: none; color: rgba(255, 255, 255, 0.75); cursor: pointer; display: flex; align-items: center; justify-content: center; }
    .rf-icon-btn:hover { background: rgba(255, 255, 255, 0.15); color: #fff; }
    .rf-icon-btn svg { width: 14px; height: 14px; }
    .rf-toggle { display: flex; align-items: center; gap: 8px; cursor: pointer; font-size: 12px; }
    .rf-switch { position: relative; flex: none; width: 28px; height: 16px; border-radius: 8px; background: rgba(255, 255, 255, 0.25); transition: background 0.2s; }
    .rf-switch::after { content: ''; position: absolute; top: 2px; left: 2px; width: 12px; height: 12px; border-radius: 50%; background: #fff; transition: left 0.2s; }
    .rf-switch.rf-on { background: #ff6600; }
    .rf-switch.rf-on::after { left: 14px; }
    .rf-grid { display: grid; grid-template-columns: auto 1fr; column-gap: 12px; row-gap: 3px; font-size: 12px; }
    .rf-grid .rf-k { opacity: 0.65; white-space: nowrap; }
    .rf-grid .rf-v { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .rf-grid .rf-big { font-size: 14px; font-weight: 600; }
    .rf-sep { grid-column: 1 / -1; height: 1px; margin: 2px 0; background: rgba(255, 255, 255, 0.12); }
  </style>

  <div class="rf-panel" ng-class="{'rf-collapsed': ui.collapsed}">

    <!-- collapsed: one compact line -->
    <div class="rf-row" ng-if="ui.collapsed">
      <span class="rf-value" ng-class="{'rf-warn': view.low}">{{ view.level }}</span>
      <div class="rf-bar rf-bar-mini" ng-if="view.hasTank">
        <div class="rf-fill" ng-class="{'rf-low': view.low}" ng-style="{width: (view.ratio * 100) + '%'}"></div>
      </div>
      <span class="rf-muted" ng-if="view.rangeShort">{{ view.rangeShort }}</span>
      <span class="rf-spacer"></span>
      <button class="rf-icon-btn" ng-click="setCollapsed(false)" title="{{ 'realFuel.expand' | translate }}">
        <svg viewBox="0 0 24 24"><path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
      </button>
    </div>

    <!-- expanded: tabs -->
    <div class="rf-tabs" ng-if="!ui.collapsed">
      <button class="rf-tab" ng-class="{'rf-active': ui.tab === 'fuel'}" ng-click="setTab('fuel')">{{ 'realFuel.tab.fuel' | translate }}</button>
      <button class="rf-tab" ng-class="{'rf-active': ui.tab === 'stats'}" ng-click="setTab('stats')">{{ 'realFuel.tab.stats' | translate }}</button>
      <span class="rf-spacer"></span>
      <button class="rf-icon-btn" ng-click="setCollapsed(true)" title="{{ 'realFuel.collapse' | translate }}">
        <svg viewBox="0 0 24 24"><path d="M6 15l6-6 6 6" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
      </button>
    </div>

    <!-- tab: refuel -->
    <div class="rf-head" ng-if="!ui.collapsed && ui.tab === 'fuel'">
      <span class="rf-title">{{ view.title }}</span>
      <span class="rf-value" ng-class="{'rf-warn': view.low}">{{ view.levelFull }}</span>
    </div>
    <div class="rf-bar" ng-if="!ui.collapsed && ui.tab === 'fuel'">
      <div class="rf-fill" ng-class="{'rf-low': view.low}" ng-style="{width: (view.ratio * 100) + '%'}"></div>
    </div>
    <div class="rf-btns" ng-if="!ui.collapsed && ui.tab === 'fuel'">
      <button class="rf-btn" ng-click="refuelEmergency()" ng-disabled="!view.hasTank"
              title="{{ 'realFuel.emergency.hint' | translate }}">{{ view.emergencyLabel }}</button>
      <button class="rf-btn" ng-click="refuelFull()" ng-disabled="!view.hasTank"
              title="{{ 'realFuel.fill.hint' | translate }}">{{ view.fullLabel }}</button>
    </div>
    <div class="rf-toggle" ng-if="!ui.collapsed && ui.tab === 'fuel'" ng-click="toggle()"
         title="{{ 'realFuel.noRefuel.hint' | translate }}">
      <div class="rf-switch" ng-class="{'rf-on': settings.enabled}"></div>
      <span>{{ 'realFuel.noRefuel' | translate }}</span>
    </div>

    <!-- tab: statistics -->
    <div class="rf-grid" ng-if="!ui.collapsed && ui.tab === 'stats'">
      <span class="rf-k">{{ 'realFuel.stats.now' | translate }}</span><span class="rf-v rf-big">{{ view.instant }}</span>
      <span class="rf-k">{{ 'realFuel.stats.average' | translate }}</span><span class="rf-v rf-big">{{ view.average }}</span>
      <span class="rf-k">{{ 'realFuel.stats.perHour' | translate }}</span><span class="rf-v">{{ view.flow }}</span>
      <span class="rf-k">{{ 'realFuel.stats.range' | translate }}</span><span class="rf-v">{{ view.range }}</span>
      <div class="rf-sep"></div>
      <span class="rf-k">{{ 'realFuel.stats.distance' | translate }}</span><span class="rf-v">{{ view.distance }}</span>
      <span class="rf-k">{{ 'realFuel.stats.time' | translate }}</span><span class="rf-v">{{ view.time }}</span>
      <span class="rf-k">{{ 'realFuel.stats.used' | translate }}</span><span class="rf-v">{{ view.used }}</span>
      <span class="rf-k">{{ 'realFuel.stats.speed' | translate }}</span><span class="rf-v">{{ view.speed }}</span>
      <span class="rf-k">{{ 'realFuel.stats.added' | translate }}</span><span class="rf-v">{{ view.added }}</span>
    </div>
    <div class="rf-btns" ng-if="!ui.collapsed && ui.tab === 'stats'">
      <button class="rf-btn" ng-click="resetTrip()" ng-disabled="!view.hasTank"
              title="{{ 'realFuel.resetTrip.hint' | translate }}">{{ 'realFuel.resetTrip' | translate }}</button>
    </div>
  </div>
</div>`,
    replace: true,
    restrict: 'EA',
    scope: true,
    controller: ['$scope', '$filter', '$rootScope', function ($scope, $filter, $rootScope) {
      const BATTERY_EMERGENCY_KWH = 5 // must match realFuelVeh.lua
      const DASH = '—'
      const tr = $filter('translate')

      $scope.settings = { enabled: true, emergencyLiters: 5 }
      $scope.ui = { collapsed: false, tab: 'fuel' }
      $scope.veh = null
      $scope.view = {}

      function num (x, digits) {
        return (typeof x === 'number' && isFinite(x)) ? x.toFixed(digits) : DASH
      }

      function pad2 (x) {
        return (x < 10 ? '0' : '') + x
      }

      function duration (seconds) {
        const s = Math.max(Math.floor(seconds || 0), 0)
        return Math.floor(s / 3600) + ':' + pad2(Math.floor(s / 60) % 60) + ':' + pad2(s % 60)
      }

      function updateView () {
        const veh = $scope.veh || {}
        const st = veh.stats || {}
        const hasFuel = veh.fuelCapacity > 0
        const hasBattery = !hasFuel && veh.batteryCapacity > 0
        const v = { hasTank: hasFuel || hasBattery }

        const u = tr(hasBattery ? 'realFuel.unit.kwh' : 'realFuel.unit.l')
        const km = tr('realFuel.unit.km')
        const kmh = tr('realFuel.unit.kmh')
        const per100 = tr('realFuel.unit.per100', { unit: u })
        const level = hasFuel ? veh.fuel : (hasBattery ? veh.battery : 0)
        const capacity = hasFuel ? veh.fuelCapacity : (hasBattery ? veh.batteryCapacity : 0)

        v.title = tr(hasBattery ? 'realFuel.battery' : 'realFuel.fuel')
        v.ratio = capacity > 0 ? Math.min(Math.max(level / capacity, 0), 1) : 0
        v.low = v.hasTank && v.ratio < 0.1
        v.level = v.hasTank ? num(level, 1) + ' ' + u : tr('realFuel.noTank')
        v.levelFull = v.hasTank ? num(level, 1) + ' / ' + num(capacity, 0) + ' ' + u : tr('realFuel.noTank')
        v.emergencyLabel = tr('realFuel.emergency', {
          amount: hasBattery
            ? '+' + BATTERY_EMERGENCY_KWH + ' ' + tr('realFuel.unit.kwh')
            : '+' + $scope.settings.emergencyLiters + ' ' + tr('realFuel.unit.l')
        })
        v.fullLabel = tr(hasBattery ? 'realFuel.charge' : 'realFuel.fill')

        v.instant = typeof st.instant === 'number' ? num(st.instant, 1) + ' ' + per100 : tr('realFuel.stats.standing')
        v.average = typeof st.average === 'number' ? num(st.average, 1) + ' ' + per100 : DASH
        v.flow = num(st.flow, 2) + ' ' + tr(hasBattery ? 'realFuel.unit.kw' : 'realFuel.unit.lph')
        v.range = typeof st.range === 'number' ? '≈ ' + Math.round(st.range) + ' ' + km : DASH
        v.rangeShort = typeof st.range === 'number' ? '≈ ' + Math.round(st.range) + ' ' + km : ''
        v.distance = num((st.distance || 0) / 1000, 1) + ' ' + km
        v.time = duration(st.time)
        v.used = num(st.used || 0, 2) + ' ' + u
        v.speed = Math.round((st.avgSpeed || 0) * 3.6) + ' / ' + Math.round((st.maxSpeed || 0) * 3.6) + ' ' + kmh
        v.added = num(st.added || 0, 1) + ' ' + u

        $scope.view = v
      }

      function lua (cmd) {
        bngApi.engineLua('extensions.realFuel_main.' + cmd)
      }

      function requestState () {
        lua('requestState()')
      }

      function saveUi () {
        lua('setUiState(' + $scope.ui.collapsed + ', "' + $scope.ui.tab + '")')
      }

      $scope.setCollapsed = function (value) {
        $scope.ui.collapsed = !!value
        saveUi()
      }

      $scope.setTab = function (tab) {
        $scope.ui.tab = tab === 'stats' ? 'stats' : 'fuel'
        saveUi()
      }

      $scope.refuelEmergency = function () { lua('refuelEmergency()') }
      $scope.refuelFull = function () { lua('refuelFull()') }
      $scope.resetTrip = function () { lua('resetTrip()') }
      $scope.toggle = function () { lua('toggleEnabled()') }

      $scope.$on('RealFuelSettings', function (event, data) {
        if (!data) return
        $scope.$evalAsync(function () {
          $scope.settings = data
          if (typeof data.uiCollapsed === 'boolean') $scope.ui.collapsed = data.uiCollapsed
          if (data.uiTab === 'fuel' || data.uiTab === 'stats') $scope.ui.tab = data.uiTab
          updateView()
        })
      })

      $scope.$on('RealFuelVehicleState', function (event, data) {
        if (!data) return
        $scope.$evalAsync(function () {
          $scope.veh = data
          updateView()
        })
      })

      $scope.$on('VehicleFocusChanged', function () {
        $scope.$evalAsync(function () {
          $scope.veh = null
          updateView()
        })
        requestState()
      })

      $scope.$on('VehicleChange', requestState)
      $scope.$on('VehicleReset', requestState)

      // the game language was changed or the translations finished loading
      const offTranslate = $rootScope.$on('$translateChangeSuccess', function () {
        $scope.$evalAsync(updateView)
      })
      $scope.$on('$destroy', offTranslate)

      updateView()
      requestState()
    }]
  }
}])
