-- SolarMQTT Test Harness
-- Tests all MQTT plugin functions in the Solar2D simulator

local mqtt = require("plugin.solarmqtt")

-- ============================================================================
-- Build check — ensure the installed dylib matches this test harness
-- ============================================================================

local EXPECTED_BUILD = 10

if (mqtt.BUILD or 0) ~= EXPECTED_BUILD then
    print("[SolarMQTT] ERROR: Plugin build mismatch! Expected BUILD=" ..
          EXPECTED_BUILD .. " but got BUILD=" .. tostring(mqtt.BUILD or "nil"))
    print("[SolarMQTT] Rebuild and reinstall the dylib before testing.")
    local msg = display.newText({
        text = "PLUGIN BUILD MISMATCH\n\nExpected build " .. EXPECTED_BUILD ..
               ", got " .. tostring(mqtt.BUILD or "nil") ..
               "\n\nRebuild & reinstall the dylib",
        x = display.contentCenterX,
        y = display.contentCenterY,
        width = 280,
        fontSize = 14,
        font = native.systemFontBold,
        align = "center",
    })
    msg:setFillColor(1, 0.3, 0.3)
    display.setDefault("background", 0.15, 0, 0)
    return
end

-- ============================================================================
-- Configuration
-- ============================================================================

local MQTT_BROKER   = "broker.emqx.io"
local MQTT_PORT     = 1883
local MQTT_PORT_TLS = 8883
local MQTT_TOPIC    = "solarmqtt/test/" .. os.time()
local MQTT_BAD_HOST = "nonexistent.invalid"

-- Private EMQX Cloud broker (TLS-only, requires auth)
local MQTT_PRIVATE_BROKER = "xbb61507.ala.eu-central-1.emqxsl.com"
local MQTT_PRIVATE_PORT   = 8883
local MQTT_PRIVATE_USER   = "solar2d"
local MQTT_PRIVATE_PASS   = "solar2d"

-- ============================================================================
-- UI Setup — all positions derived from screen dimensions
-- ============================================================================

display.setDefault("background", 0.1, 0.1, 0.15)

-- Layout metrics — recalculated on orientation change
local L = {}   -- layout table: holds all computed metrics

local function recalcLayout()
    L.LEFT = display.screenOriginX
    L.TOP = display.screenOriginY
    L.W = display.actualContentWidth
    L.H = display.actualContentHeight
    L.CX = display.contentCenterX
    L.CY = display.contentCenterY
    L.RIGHT = L.LEFT + L.W
    L.BOTTOM = L.TOP + L.H
    L.isLandscape = (L.W > L.H)

    local BUTTON_ROWS = 6
    L.HEADER_ZONE = L.H * 0.12
    local logFrac = L.isLandscape and 0.35 or 0.38
    L.LOG_ZONE_HEIGHT = L.H * logFrac
    local buttonZone = L.H - L.HEADER_ZONE - L.LOG_ZONE_HEIGHT
    L.BUTTON_SPACING = buttonZone / (BUTTON_ROWS + 0.5)
    L.BUTTON_W = L.W * 0.42
    L.BUTTON_H = math.min(L.BUTTON_SPACING * 0.8, L.H * 0.06)
    L.BUTTON_FONT = math.max(7, L.BUTTON_H * 0.45)
    L.COL1_X = L.CX - L.W * 0.24
    L.COL2_X = L.CX + L.W * 0.24
    L.MAX_LOG_LINES = math.max(6, math.floor(L.LOG_ZONE_HEIGHT / 13) - 1)
    L.LOG_LINE_HEIGHT = math.max(10, (L.LOG_ZONE_HEIGHT - 20) / L.MAX_LOG_LINES)
    L.LOG_FONT = math.max(7, L.LOG_LINE_HEIGHT * 0.7)
end

recalcLayout()  -- initial calculation

-- Menu group — contains all interactive buttons and log area
local menuGroup = display.newGroup()

local titleText = display.newText({
    parent = menuGroup,
    text = "SolarMQTT Test Harness",
    x = L.CX,
    y = L.TOP + L.H * 0.04,
    fontSize = math.max(10, L.H * 0.035),
    font = native.systemFontBold,
})
titleText:setFillColor(0.3, 0.8, 1)

local versionText = display.newText({
    parent = menuGroup,
    text = "Plugin v" .. (mqtt.VERSION or "?") .. " build " .. tostring(mqtt.BUILD or "?"),
    x = L.CX,
    y = L.TOP + L.H * 0.08,
    fontSize = math.max(8, L.H * 0.025),
})
versionText:setFillColor(0.6, 0.6, 0.6)

-- Log area
local logLines = {}
local logGroup = display.newGroup()
menuGroup:insert(logGroup)
logGroup.y = L.BOTTOM - L.LOG_ZONE_HEIGHT

local logBg = display.newRect(logGroup, L.CX, L.LOG_ZONE_HEIGHT * 0.5, L.W * 0.92, L.LOG_ZONE_HEIGHT - 10)
logBg:setFillColor(0, 0, 0, 0.5)
logBg.strokeWidth = 1
logBg:setStrokeColor(0.3, 0.3, 0.3)

local function refreshLogDisplay()
    for i = logGroup.numChildren, 1, -1 do
        if logGroup[i].isLogLine then
            logGroup[i]:removeSelf()
        end
    end

    -- Only show as many lines as fit
    local visibleLines = {}
    local start = math.max(1, #logLines - L.MAX_LOG_LINES + 1)
    for i = start, #logLines do
        visibleLines[#visibleLines + 1] = logLines[i]
    end

    for i, line in ipairs(visibleLines) do
        local t = display.newText({
            parent = logGroup,
            text = line,
            x = L.LEFT + L.W * 0.06,
            y = 5 + i * L.LOG_LINE_HEIGHT,
            fontSize = L.LOG_FONT,
            font = native.systemFont,
            align = "left",
        })
        t.anchorX = 0
        t:setFillColor(0.8, 1, 0.8)
        t.isLogLine = true
    end
end

local function addLog(msg)
    print("CONSOLE: " .. msg)
    table.insert(logLines, os.date("%H:%M:%S") .. " " .. msg)
    -- Cap total stored lines (keep more than visible for orientation changes)
    while #logLines > 100 do
        table.remove(logLines, 1)
    end
    refreshLogDisplay()
end

-- ============================================================================
-- Test State Machine
-- ============================================================================

local testState = {
    running = false,
    currentIndex = 0,
    results = {},
    pendingExpects = {},
    timeoutTimer = nil,
    callbackFired = false,  -- flag for per-op callback tests
}

-- Test overlay group (created when tests start)
local testOverlayGroup = nil
local testIndicators = {}
local testLabels = {}
local summaryText = nil

local STATUS_COLORS = {
    pending = { 0.4, 0.4, 0.4 },
    running = { 1.0, 0.8, 0.0 },
    pass    = { 0.2, 0.9, 0.2 },
    fail    = { 1.0, 0.2, 0.2 },
}

-- ============================================================================
-- Test Definitions (20 granular tests)
-- ============================================================================

-- Forward declarations: these are defined later but referenced inside closures
-- that execute at runtime (not at load time)
local markTestPassed
local updateFocusRing

-- Focus system variables (declared early so closures can capture them)
local buttonList = {}       -- ordered list of { bg, label, onTap, col }
local focusIndex = 1        -- currently focused button (1-based)
local focusRing = nil       -- highlight ring display object (created later)
local focusMode = "menu"    -- "menu" or "overlay" (which set of buttons is active)
local overlayBackButton = nil  -- the "Back to Menu" button in test overlay
local COLS = 2              -- number of columns in button grid

local testDefs = {
    -- Group 1: Public broker (non-TLS)
    {
        name = "Connect",
        action = function()
            mqtt.connect({
                broker = MQTT_BROKER,
                port = MQTT_PORT,
                clientId = "test-nontls-" .. math.random(1000, 9999),
                cleanSession = true,
                keepAlive = 60,
            })
        end,
        expect = { { name = "connected" } },
        timeout = 8,
    },
    {
        name = "Subscribe",
        action = function()
            mqtt.subscribe(MQTT_TOPIC, 1)
        end,
        expect = { { name = "subscribed" } },
        timeout = 5,
    },
    {
        name = "Pub+Recv",
        action = function()
            mqtt.publish(MQTT_TOPIC, "nontls-test " .. os.time(), { qos = 1 })
        end,
        expect = {
            { name = "published" },
            { name = "message", validate = function(event)
                return event.payload and event.payload:find("nontls%-test") ~= nil
            end },
        },
        timeout = 8,
    },
    {
        name = "Unsubscribe",
        action = function()
            mqtt.unsubscribe(MQTT_TOPIC)
        end,
        expect = { { name = "unsubscribed" } },
        timeout = 5,
    },
    {
        name = "Disconnect",
        action = function() mqtt.disconnect() end,
        expect = { { name = "disconnected", validate = function(event)
            return event.errorCode == 0
        end } },
        timeout = 5,
    },

    -- Group 2: Public broker (TLS)
    {
        name = "TLS Connect",
        action = function()
            mqtt.connect({
                broker = MQTT_BROKER,
                port = MQTT_PORT_TLS,
                clientId = "test-tls-" .. math.random(1000, 9999),
                cleanSession = true,
                keepAlive = 60,
            })
        end,
        expect = { { name = "connected" } },
        timeout = 8,
    },
    {
        name = "TLS Subscribe",
        action = function()
            mqtt.subscribe(MQTT_TOPIC, 1)
        end,
        expect = { { name = "subscribed" } },
        timeout = 5,
    },
    {
        name = "TLS Pub+Recv",
        action = function()
            mqtt.publish(MQTT_TOPIC, "tls-test " .. os.time(), { qos = 1 })
        end,
        expect = {
            { name = "published" },
            { name = "message", validate = function(event)
                return event.payload and event.payload:find("tls%-test") ~= nil
            end },
        },
        timeout = 8,
    },
    {
        name = "TLS Unsub",
        action = function()
            mqtt.unsubscribe(MQTT_TOPIC)
        end,
        expect = { { name = "unsubscribed" } },
        timeout = 5,
    },
    {
        name = "TLS Disconnect",
        action = function() mqtt.disconnect() end,
        expect = { { name = "disconnected", validate = function(event)
            return event.errorCode == 0
        end } },
        timeout = 5,
    },

    -- Group 3: Auth (private broker)
    {
        name = "Bad Auth",
        action = function()
            mqtt.connect({
                broker = MQTT_PRIVATE_BROKER,
                port = MQTT_PRIVATE_PORT,
                clientId = "test-badauth-" .. math.random(1000, 9999),
                username = "wrong_user",
                password = "wrong_pass",
                cleanSession = true,
                keepAlive = 10,
            })
        end,
        expect = { { name = "error" } },
        timeout = 10,
    },
    {
        name = "Auth Connect",
        action = function()
            mqtt.connect({
                broker = MQTT_PRIVATE_BROKER,
                port = MQTT_PRIVATE_PORT,
                clientId = "test-auth-" .. math.random(1000, 9999),
                username = MQTT_PRIVATE_USER,
                password = MQTT_PRIVATE_PASS,
                cleanSession = true,
                keepAlive = 60,
            })
        end,
        expect = { { name = "connected" } },
        timeout = 8,
    },
    {
        name = "Priv Subscribe",
        action = function()
            mqtt.subscribe(MQTT_TOPIC, 1)
        end,
        expect = { { name = "subscribed" } },
        timeout = 5,
    },
    {
        name = "Priv Pub+Recv",
        action = function()
            mqtt.publish(MQTT_TOPIC, "priv-test " .. os.time(), { qos = 1 })
        end,
        expect = {
            { name = "published" },
            { name = "message", validate = function(event)
                return event.payload and event.payload:find("priv%-test") ~= nil
            end },
        },
        timeout = 8,
    },
    {
        name = "Priv Unsub",
        action = function()
            mqtt.unsubscribe(MQTT_TOPIC)
        end,
        expect = { { name = "unsubscribed" } },
        timeout = 5,
    },
    {
        name = "Priv Disconnect",
        action = function() mqtt.disconnect() end,
        expect = { { name = "disconnected", validate = function(event)
            return event.errorCode == 0
        end } },
        timeout = 5,
    },

    -- Group 4: Per-operation callback tests
    {
        name = "CB Connect+Sub",
        action = function()
            testState.callbackFired = false
            mqtt.connect({
                broker = MQTT_BROKER,
                port = MQTT_PORT,
                clientId = "test-cb-" .. math.random(1000, 9999),
                cleanSession = true,
                keepAlive = 60,
                onConnect = function(event)
                    addLog("CB: onConnect fired")
                    testState.callbackFired = true
                end,
            })
        end,
        expect = {
            { name = "connected" },
            { name = "subscribed" },
        },
        -- After connect, subscribe (so we're ready for pub callback test)
        afterConnect = function()
            mqtt.subscribe(MQTT_TOPIC, 1)
        end,
        timeout = 10,
    },
    {
        name = "Pub Callback",
        action = function()
            testState.callbackFired = false
            mqtt.publish(MQTT_TOPIC, "cb-pub " .. os.time(), { qos = 1 }, function(event)
                addLog("CB: publish callback fired mid=" .. tostring(event.mid))
                testState.callbackFired = true
                -- Per-op callback fires AFTER global listener.
                -- Mark the test passed directly from the callback.
                if testState.running then
                    markTestPassed(testState.currentIndex)
                end
            end)
        end,
        -- Use special flag to skip auto-pass from global listener
        passFromCallback = true,
        expect = {
            { name = "published" },
        },
        timeout = 8,
    },
    {
        name = "Unsub Callback",
        action = function()
            testState.callbackFired = false
            mqtt.unsubscribe(MQTT_TOPIC, function(event)
                addLog("CB: unsubscribe callback fired topic=" .. tostring(event.topic))
                testState.callbackFired = true
                -- Mark test passed directly from the callback
                if testState.running then
                    markTestPassed(testState.currentIndex)
                end
            end)
        end,
        passFromCallback = true,
        expect = {
            { name = "unsubscribed" },
        },
        timeout = 5,
    },

    -- Group 5: Error handling
    {
        name = "Bad Host",
        action = function()
            mqtt.connect({
                broker = MQTT_BAD_HOST,
                port = 1883,
                clientId = "test-badhost",
                cleanSession = true,
                keepAlive = 10,
            })
        end,
        expect = { { name = "error" } },
        timeout = 10,
    },
}

-- ============================================================================
-- Test Runner Functions
-- ============================================================================

local function updateIndicator(index, status)
    if testIndicators[index] then
        local c = STATUS_COLORS[status] or STATUS_COLORS.pending
        testIndicators[index]:setFillColor(c[1], c[2], c[3])
    end
    testState.results[index] = status
end

local function updateSummary()
    if not summaryText then return end
    local passed, failed, total = 0, 0, #testDefs
    for i = 1, total do
        if testState.results[i] == "pass" then passed = passed + 1
        elseif testState.results[i] == "fail" then failed = failed + 1
        end
    end
    if failed > 0 then
        summaryText.text = passed .. "/" .. total .. " PASSED, " .. failed .. " FAILED"
        summaryText:setFillColor(1, 0.4, 0.3)
    elseif passed == total then
        summaryText.text = passed .. "/" .. total .. " PASSED"
        summaryText:setFillColor(0.2, 0.9, 0.2)
    else
        summaryText.text = passed .. "/" .. total .. " completed..."
        summaryText:setFillColor(0.6, 0.6, 0.6)
    end
end

local function runNextTest()
    testState.currentIndex = testState.currentIndex + 1
    local idx = testState.currentIndex

    if idx > #testDefs then
        -- All tests done
        addLog("=== TEST SUITE DONE ===")
        testState.running = false
        updateSummary()
        return
    end

    local test = testDefs[idx]
    addLog("-- Test " .. idx .. ": " .. test.name .. " --")
    updateIndicator(idx, "running")

    -- Reset per-test state
    testState.afterConnectFired = false
    -- Copy expected events for this test
    testState.pendingExpects = {}
    for i, exp in ipairs(test.expect) do
        testState.pendingExpects[i] = { name = exp.name, validate = exp.validate }
    end

    -- Start timeout
    testState.timeoutTimer = timer.performWithDelay(test.timeout * 1000, function()
        testState.timeoutTimer = nil
        addLog("TIMEOUT: " .. test.name)
        updateIndicator(idx, "fail")
        updateSummary()
        -- Attempt cleanup before next test
        pcall(function() mqtt.disconnect() end)
        timer.performWithDelay(1000, runNextTest)
    end)

    -- Execute the test action
    test.action()
end

markTestPassed = function(idx)
    if testState.timeoutTimer then
        timer.cancel(testState.timeoutTimer)
        testState.timeoutTimer = nil
    end
    updateIndicator(idx, "pass")
    updateSummary()

    -- Check if this test has an afterConnect action (used by CB Connect+Sub test)
    local test = testDefs[idx]
    -- afterConnect is not used here — it's triggered by connected event in the listener

    -- Brief delay before next test to let state settle
    timer.performWithDelay(500, runNextTest)
end

-- ============================================================================
-- Visual Test Overlay
-- ============================================================================

local function createTestOverlay()
    testOverlayGroup = display.newGroup()
    testIndicators = {}
    testLabels = {}

    -- Background (cover full visible area)
    local bg = display.newRect(testOverlayGroup, L.CX, L.CY, L.W + 10, L.H + 10)
    bg:setFillColor(0.1, 0.1, 0.15)

    -- Title
    local titleFontSize = math.max(10, L.H * 0.035)
    local title = display.newText({
        parent = testOverlayGroup,
        text = "SolarMQTT Test Results",
        x = L.CX,
        y = L.TOP + L.H * 0.04,
        fontSize = titleFontSize,
        font = native.systemFontBold,
    })
    title:setFillColor(0.3, 0.8, 1)

    local verFontSize = math.max(8, L.H * 0.025)
    local ver = display.newText({
        parent = testOverlayGroup,
        text = "v" .. (mqtt.VERSION or "?") .. " build " .. tostring(mqtt.BUILD or "?"),
        x = L.CX,
        y = L.TOP + L.H * 0.08,
        fontSize = verFontSize,
    })
    ver:setFillColor(0.6, 0.6, 0.6)

    -- Test rows — two-column layout for landscape, single column for portrait
    local startY = L.TOP + L.H * 0.13
    local footerSpace = L.H * 0.18
    local testsPerCol = L.isLandscape and math.ceil(#testDefs / 2) or #testDefs
    local availableH = L.H - (startY - L.TOP) - footerSpace
    local rowHeight = math.min(availableH / testsPerCol, L.H * 0.06)
    local colWidth = L.isLandscape and (L.W / 2) or L.W
    local indicatorR = math.max(3, rowHeight * 0.22)
    local testFontSize = math.max(7, rowHeight * 0.5)

    for i, test in ipairs(testDefs) do
        local col, row
        if L.isLandscape then
            col = (i <= testsPerCol) and 0 or 1
            row = (i <= testsPerCol) and (i - 1) or (i - testsPerCol - 1)
        else
            col = 0
            row = i - 1
        end

        local xOffset = L.LEFT + col * colWidth
        local y = startY + row * rowHeight

        -- Indicator circle
        local indicator = display.newCircle(testOverlayGroup, xOffset + L.W * 0.06, y, indicatorR)
        local c = STATUS_COLORS.pending
        indicator:setFillColor(c[1], c[2], c[3])
        indicator.strokeWidth = 1
        indicator:setStrokeColor(0.3, 0.3, 0.3)
        testIndicators[i] = indicator

        -- Restore saved result colour if we have one (rotation during/after tests)
        if testState.results[i] then
            local sc = STATUS_COLORS[testState.results[i]] or STATUS_COLORS.pending
            indicator:setFillColor(sc[1], sc[2], sc[3])
        end

        -- Test label
        local label = display.newText({
            parent = testOverlayGroup,
            text = string.format("%2d. %s", i, test.name),
            x = xOffset + L.W * 0.10,
            y = y,
            fontSize = testFontSize,
            font = native.systemFont,
        })
        label.anchorX = 0
        label:setFillColor(0.85, 0.85, 0.85)
        testLabels[i] = label
    end

    -- Divider and summary below the test rows
    local divY = startY + testsPerCol * rowHeight + L.H * 0.02
    local divider = display.newLine(testOverlayGroup, L.LEFT + L.W * 0.05, divY, L.RIGHT - L.W * 0.05, divY)
    divider:setStrokeColor(0.4, 0.4, 0.4)
    divider.strokeWidth = 1

    -- Summary text
    local summaryFontSize = math.max(9, L.H * 0.032)
    summaryText = display.newText({
        parent = testOverlayGroup,
        text = "Running...",
        x = L.CX,
        y = divY + L.H * 0.04,
        fontSize = summaryFontSize,
        font = native.systemFontBold,
    })
    summaryText:setFillColor(0.6, 0.6, 0.6)

    -- Back button
    local backBtnW = L.W * 0.4
    local backBtnH = math.max(20, L.H * 0.06)
    local backY = divY + L.H * 0.10
    local backBg = display.newRoundedRect(testOverlayGroup, L.CX, backY, backBtnW, backBtnH, 6)
    backBg:setFillColor(0.3, 0.3, 0.4)
    backBg.strokeWidth = 1
    backBg:setStrokeColor(0.5, 0.5, 0.6)

    local backTxt = display.newText({
        parent = testOverlayGroup,
        text = "Back to Menu",
        x = L.CX,
        y = backY,
        fontSize = math.max(8, backBtnH * 0.42),
        font = native.systemFontBold,
    })
    backTxt:setFillColor(0.8, 0.8, 0.9)

    -- Store for focus navigation
    overlayBackButton = backBg

    backBg:addEventListener("tap", function()
        if testState.running then return true end  -- Don't allow back during tests
        if testOverlayGroup then
            testOverlayGroup:removeSelf()
            testOverlayGroup = nil
        end
        overlayBackButton = nil
        menuGroup.isVisible = true
        focusMode = "menu"
        menuGroup:insert(focusRing)
        updateFocusRing()
        return true
    end)
end

local function startTestSuite()
    if testState.running then
        addLog("Tests already running")
        return
    end

    -- Hide menu, show test overlay
    menuGroup.isVisible = false
    createTestOverlay()

    -- Move focus to overlay
    focusMode = "overlay"
    if testOverlayGroup and focusRing then
        testOverlayGroup:insert(focusRing)
    end
    updateFocusRing()

    -- Reset state
    testState.running = true
    testState.currentIndex = 0
    testState.results = {}
    testState.pendingExpects = {}
    testState.timeoutTimer = nil
    testState.callbackFired = false
    testState.afterConnectFired = false

    for i = 1, #testDefs do
        testState.results[i] = "pending"
    end

    addLog("=== TEST SUITE START ===")

    -- Start first test after brief delay
    timer.performWithDelay(200, runNextTest)
end

-- ============================================================================
-- MQTT Event Listener
-- ============================================================================

local function mqttListener(event)
    local name = event.name or "unknown"

    -- Always log the event
    if name == "connected" then
        addLog("CONNECTED")
    elseif name == "disconnected" then
        addLog("DISCONNECTED: " .. (event.errorMessage or "") .. " (code=" .. tostring(event.errorCode) .. ")")
    elseif name == "message" then
        addLog("MSG [" .. (event.topic or "?") .. "]: " .. (event.payload or ""))
    elseif name == "subscribed" then
        addLog("SUBSCRIBED: " .. (event.topic or "?") .. " qos=" .. tostring(event.grantedQos))
    elseif name == "unsubscribed" then
        addLog("UNSUBSCRIBED: " .. (event.topic or "?"))
    elseif name == "published" then
        addLog("PUBLISHED: mid=" .. tostring(event.mid))
    elseif name == "error" then
        addLog("ERROR: " .. (event.errorMessage or "unknown"))
    else
        addLog("EVENT: " .. name)
    end

    -- Test validation mode
    if testState.running and #testState.pendingExpects > 0 then
        local nextExpect = testState.pendingExpects[1]
        if name == nextExpect.name then
            local valid = true
            if nextExpect.validate then
                valid = nextExpect.validate(event)
            end
            if valid then
                table.remove(testState.pendingExpects, 1)
                if #testState.pendingExpects == 0 then
                    -- Check if this test wants the per-op callback to trigger pass
                    local test = testDefs[testState.currentIndex]
                    if not (test and test.passFromCallback) then
                        markTestPassed(testState.currentIndex)
                    end
                    -- If passFromCallback, the callback itself calls markTestPassed
                end
            end
        end
    end

    -- Special handling: CB Connect+Sub test needs to subscribe after connected
    if testState.running and name == "connected" then
        local test = testDefs[testState.currentIndex]
        if test and test.afterConnect and not testState.afterConnectFired then
            testState.afterConnectFired = true
            test.afterConnect()
        end
    end
end

mqtt.init(mqttListener)
addLog("v" .. (mqtt.VERSION or "?") .. " build " .. tostring(mqtt.BUILD or "?"))

-- ============================================================================
-- Buttons + Focus Navigation (tvOS Apple TV remote support)
-- ============================================================================

-- Store button definitions for relayout: { label, colIndex (1 or 2), onTap, color, bg, txt }
local buttonDefs = {}
local topicInfo  -- forward declaration

local function makeButton(label, colIndex, rowIndex, onTap, color)
    local x = (colIndex == 1) and L.COL1_X or L.COL2_X
    local y = L.TOP + L.HEADER_ZONE + L.BUTTON_SPACING * (rowIndex - 0.5)
    local bg = display.newRoundedRect(menuGroup, x, y, L.BUTTON_W, L.BUTTON_H, 4)
    local r, g, b = 0.2, 0.5, 0.8
    if color == "green" then r, g, b = 0.2, 0.7, 0.3
    elseif color == "red" then r, g, b = 0.8, 0.3, 0.2
    end
    bg:setFillColor(r, g, b)
    bg.strokeWidth = 1
    bg:setStrokeColor(r + 0.1, g + 0.2, b + 0.2)

    local txt = display.newText({
        parent = menuGroup,
        text = label,
        x = x,
        y = y,
        fontSize = L.BUTTON_FONT,
        font = native.systemFontBold,
    })

    bg:addEventListener("tap", function()
        addLog("BUTTON: " .. label)
        onTap()
        return true
    end)

    -- Register for focus navigation
    local col = (colIndex == 1) and 1 or 2
    buttonList[#buttonList + 1] = { bg = bg, label = label, onTap = onTap, col = col }

    -- Store for relayout
    buttonDefs[#buttonDefs + 1] = { label = label, colIndex = colIndex, rowIndex = rowIndex, onTap = onTap, color = color, bg = bg, txt = txt }

    return bg, txt
end

-- Row 1: Connect (non-TLS) / Disconnect
makeButton("Connect", 1, 1, function()
    mqtt.connect({
        broker = MQTT_BROKER,
        port = MQTT_PORT,
        clientId = "solarmqtt-" .. math.random(1000, 9999),
        cleanSession = true,
        keepAlive = 60,
    })
end)

makeButton("Disconnect", 2, 1, function()
    mqtt.disconnect()
end)

-- Row 2: Subscribe / Unsubscribe
makeButton("Subscribe", 1, 2, function()
    mqtt.subscribe(MQTT_TOPIC, 1)
end)

makeButton("Unsubscribe", 2, 2, function()
    mqtt.unsubscribe(MQTT_TOPIC)
end)

-- Row 3: Publish QoS 0 / Publish QoS 1
makeButton("Publish QoS 0", 1, 3, function()
    mqtt.publish(MQTT_TOPIC, "Hello " .. os.time())
end)

makeButton("Publish QoS 1", 2, 3, function()
    mqtt.publish(MQTT_TOPIC, "QoS1 " .. os.time(), { qos = 1 })
end)

-- Row 4: Bad Host / Sub+Pub round-trip (non-TLS)
makeButton("Bad Host", 1, 4, function()
    mqtt.connect({
        broker = MQTT_BAD_HOST,
        port = 1883,
        clientId = "bad-test",
        cleanSession = true,
        keepAlive = 10,
    })
end, "red")

makeButton("Sub+Pub Test", 2, 4, function()
    mqtt.connect({
        broker = MQTT_BROKER,
        port = MQTT_PORT,
        clientId = "solarmqtt-subpub-" .. math.random(1000, 9999),
        cleanSession = true,
        keepAlive = 60,
    })
    timer.performWithDelay(2000, function()
        mqtt.subscribe(MQTT_TOPIC, 1)
        timer.performWithDelay(500, function()
            mqtt.publish(MQTT_TOPIC, "Round-trip " .. os.time(), { qos = 1 })
        end)
    end)
end)

-- Row 5: TLS Connect / TLS Sub+Pub
makeButton("TLS Connect", 1, 5, function()
    mqtt.connect({
        broker = MQTT_BROKER,
        port = MQTT_PORT_TLS,
        clientId = "solarmqtt-tls-" .. math.random(1000, 9999),
        cleanSession = true,
        keepAlive = 60,
    })
end)

makeButton("TLS Sub+Pub", 2, 5, function()
    mqtt.connect({
        broker = MQTT_BROKER,
        port = MQTT_PORT_TLS,
        clientId = "solarmqtt-tlssp-" .. math.random(1000, 9999),
        cleanSession = true,
        keepAlive = 60,
    })
    timer.performWithDelay(2000, function()
        mqtt.subscribe(MQTT_TOPIC, 1)
        timer.performWithDelay(500, function()
            mqtt.publish(MQTT_TOPIC, "TLS round-trip " .. os.time(), { qos = 1 })
        end)
    end)
end)

-- Row 6: TLS Bad Auth / Run All Tests
makeButton("TLS Bad Auth", 1, 6, function()
    mqtt.connect({
        broker = MQTT_PRIVATE_BROKER,
        port = MQTT_PRIVATE_PORT,
        clientId = "solarmqtt-badauth-" .. math.random(1000, 9999),
        username = "wrong_user",
        password = "wrong_pass",
        cleanSession = true,
        keepAlive = 10,
    })
end, "red")

makeButton("Run All Tests", 2, 6, startTestSuite, "green")

-- Topic info
topicInfo = display.newText({
    parent = menuGroup,
    text = "Topic: " .. MQTT_TOPIC,
    x = L.CX,
    y = L.TOP + L.HEADER_ZONE + L.BUTTON_SPACING * 6.5,
    fontSize = math.max(7, L.BUTTON_FONT * 0.85),
    font = native.systemFont,
})
topicInfo:setFillColor(0.5, 0.5, 0.5)

-- ============================================================================
-- Focus Ring + Key Event Navigation (for tvOS / keyboard)
-- ============================================================================

-- Create focus ring (bright border, no fill)
focusRing = display.newRoundedRect(menuGroup, 0, 0, L.BUTTON_W + 6, L.BUTTON_H + 6, 6)
focusRing:setFillColor(0, 0, 0, 0)
focusRing.strokeWidth = 2
focusRing:setStrokeColor(1, 1, 0.3)

updateFocusRing = function()
    if focusMode == "menu" then
        local btn = buttonList[focusIndex]
        if btn and btn.bg then
            focusRing.x = btn.bg.x
            focusRing.y = btn.bg.y
            focusRing.width = L.BUTTON_W + 6
            focusRing.height = L.BUTTON_H + 6
            focusRing.isVisible = menuGroup.isVisible
        end
    elseif focusMode == "overlay" and overlayBackButton then
        focusRing.x = overlayBackButton.x
        focusRing.y = overlayBackButton.y
        focusRing.width = overlayBackButton.width + 6
        focusRing.height = overlayBackButton.height + 6
        focusRing.isVisible = true
    end
end

local function setFocusIndex(newIndex)
    if newIndex < 1 then newIndex = #buttonList end
    if newIndex > #buttonList then newIndex = 1 end
    focusIndex = newIndex
    updateFocusRing()
end

-- Initialize focus ring on first button
setFocusIndex(1)

local function onKeyEvent(event)
    if event.phase ~= "down" then return false end

    local keyName = event.keyName

    -- Select button (Apple TV remote select, keyboard space/enter)
    if keyName == "buttonA" or keyName == "buttonSelect" or keyName == "space" or keyName == "enter" or keyName == "center" then
        if focusMode == "menu" then
            local btn = buttonList[focusIndex]
            if btn then
                addLog("BUTTON: " .. btn.label)
                -- Visual press feedback
                transition.to(btn.bg, { time = 50, xScale = 0.9, yScale = 0.9, onComplete = function()
                    transition.to(btn.bg, { time = 50, xScale = 1, yScale = 1 })
                end })
                btn.onTap()
            end
        elseif focusMode == "overlay" then
            -- Activate the Back to Menu button (only if tests are done)
            if not testState.running and testOverlayGroup then
                testOverlayGroup:removeSelf()
                testOverlayGroup = nil
                overlayBackButton = nil
                menuGroup.isVisible = true
                focusMode = "menu"
                menuGroup:insert(focusRing)
                updateFocusRing()
            end
        end
        return true

    -- D-pad navigation
    elseif keyName == "up" then
        if focusMode == "menu" then
            -- Move up one row (skip 2 for 2-column layout)
            setFocusIndex(focusIndex - COLS)
        end
        return true

    elseif keyName == "down" then
        if focusMode == "menu" then
            setFocusIndex(focusIndex + COLS)
        end
        return true

    elseif keyName == "left" then
        if focusMode == "menu" then
            setFocusIndex(focusIndex - 1)
        end
        return true

    elseif keyName == "right" then
        if focusMode == "menu" then
            setFocusIndex(focusIndex + 1)
        end
        return true
    end

    return false
end

Runtime:addEventListener("key", onKeyEvent)

-- ============================================================================
-- Orientation Change Handler — relayout everything on rotation
-- ============================================================================

local function relayoutMenu()
    -- Reposition title + version
    titleText.x = L.CX
    titleText.y = L.TOP + L.H * 0.04
    titleText.size = math.max(10, L.H * 0.035)

    versionText.x = L.CX
    versionText.y = L.TOP + L.H * 0.08
    versionText.size = math.max(8, L.H * 0.025)

    -- Reposition log area
    logGroup.y = L.BOTTOM - L.LOG_ZONE_HEIGHT
    logBg.x = L.CX
    logBg.y = L.LOG_ZONE_HEIGHT * 0.5
    logBg.width = L.W * 0.92
    logBg.height = L.LOG_ZONE_HEIGHT - 10
    refreshLogDisplay()

    -- Reposition buttons
    for _, def in ipairs(buttonDefs) do
        local x = (def.colIndex == 1) and L.COL1_X or L.COL2_X
        local y = L.TOP + L.HEADER_ZONE + L.BUTTON_SPACING * (def.rowIndex - 0.5)
        def.bg.x = x
        def.bg.y = y
        def.bg.width = L.BUTTON_W
        def.bg.height = L.BUTTON_H
        def.txt.x = x
        def.txt.y = y
        def.txt.size = L.BUTTON_FONT
    end

    -- Reposition topic info
    if topicInfo then
        topicInfo.x = L.CX
        topicInfo.y = L.TOP + L.HEADER_ZONE + L.BUTTON_SPACING * 6.5
        topicInfo.size = math.max(7, L.BUTTON_FONT * 0.85)
    end

    -- Resize focus ring and reposition
    focusRing.width = L.BUTTON_W + 6
    focusRing.height = L.BUTTON_H + 6
    updateFocusRing()
end

local function doRelayout()
    recalcLayout()

    -- Always relayout menu (even if hidden, so it's correct when shown)
    relayoutMenu()

    -- If test overlay is showing, rebuild it with new layout
    if testOverlayGroup then
        testOverlayGroup:removeSelf()
        createTestOverlay()
        -- Restore summary text
        updateSummary()
        -- Re-parent focus ring
        if focusMode == "overlay" and focusRing then
            testOverlayGroup:insert(focusRing)
            updateFocusRing()
        end
    end
end

-- Solar2D fires "orientation" on Runtime when device rotates.
-- Delay briefly to let Solar2D finish updating display metrics.
Runtime:addEventListener("orientation", function()
    timer.performWithDelay(100, doRelayout)
end)

-- Also handle window resize (Solar2D simulator on desktop)
Runtime:addEventListener("resize", function()
    timer.performWithDelay(100, doRelayout)
end)

addLog("Tap buttons or use remote/keyboard")
