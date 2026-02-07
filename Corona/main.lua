-- SolarMQTT Test Harness
-- Tests all MQTT plugin functions in the Solar2D simulator

local mqtt = require("plugin.solarmqtt")

-- ============================================================================
-- Build check — ensure the installed dylib matches this test harness
-- ============================================================================

local EXPECTED_BUILD = 9

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
-- UI Setup
-- ============================================================================

display.setDefault("background", 0.1, 0.1, 0.15)

-- Menu group — contains all interactive buttons and log area
local menuGroup = display.newGroup()

local titleText = display.newText({
    parent = menuGroup,
    text = "SolarMQTT Test Harness",
    x = display.contentCenterX,
    y = 20,
    fontSize = 16,
    font = native.systemFontBold,
})
titleText:setFillColor(0.3, 0.8, 1)

local versionText = display.newText({
    parent = menuGroup,
    text = "Plugin v" .. (mqtt.VERSION or "?") .. " build " .. tostring(mqtt.BUILD or "?"),
    x = display.contentCenterX,
    y = 38,
    fontSize = 11,
})
versionText:setFillColor(0.6, 0.6, 0.6)

-- Log area
local logLines = {}
local MAX_LOG_LINES = 12
local logGroup = display.newGroup()
menuGroup:insert(logGroup)
logGroup.y = 300

local logBg = display.newRect(logGroup, display.contentCenterX, 80, 300, 170)
logBg:setFillColor(0, 0, 0, 0.5)
logBg.strokeWidth = 1
logBg:setStrokeColor(0.3, 0.3, 0.3)

local function addLog(msg)
    print("CONSOLE: " .. msg)
    table.insert(logLines, os.date("%H:%M:%S") .. " " .. msg)
    while #logLines > MAX_LOG_LINES do
        table.remove(logLines, 1)
    end

    for i = logGroup.numChildren, 1, -1 do
        if logGroup[i].isLogLine then
            logGroup[i]:removeSelf()
        end
    end

    for i, line in ipairs(logLines) do
        local t = display.newText({
            parent = logGroup,
            text = line,
            x = 15,
            y = 5 + i * 13,
            fontSize = 9,
            font = native.systemFont,
            align = "left",
        })
        t.anchorX = 0
        t:setFillColor(0.8, 1, 0.8)
        t.isLogLine = true
    end
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

-- Forward declaration: markTestPassed is defined after testDefs but referenced
-- inside per-op callback closures (tests 18-19 passFromCallback pattern)
local markTestPassed

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

    -- Background
    local bg = display.newRect(testOverlayGroup, display.contentCenterX, display.contentCenterY, 320, 480)
    bg:setFillColor(0.1, 0.1, 0.15)

    -- Title
    local title = display.newText({
        parent = testOverlayGroup,
        text = "SolarMQTT Test Results",
        x = display.contentCenterX,
        y = 20,
        fontSize = 14,
        font = native.systemFontBold,
    })
    title:setFillColor(0.3, 0.8, 1)

    local ver = display.newText({
        parent = testOverlayGroup,
        text = "v" .. (mqtt.VERSION or "?") .. " build " .. tostring(mqtt.BUILD or "?"),
        x = display.contentCenterX,
        y = 35,
        fontSize = 10,
    })
    ver:setFillColor(0.6, 0.6, 0.6)

    -- Test rows (compact layout for 20 tests)
    local startY = 55
    local rowHeight = 19

    for i, test in ipairs(testDefs) do
        local y = startY + (i - 1) * rowHeight

        -- Indicator circle
        local indicator = display.newCircle(testOverlayGroup, 25, y, 5)
        local c = STATUS_COLORS.pending
        indicator:setFillColor(c[1], c[2], c[3])
        indicator.strokeWidth = 1
        indicator:setStrokeColor(0.3, 0.3, 0.3)
        testIndicators[i] = indicator

        -- Test label
        local label = display.newText({
            parent = testOverlayGroup,
            text = string.format("%2d. %s", i, test.name),
            x = 40,
            y = y,
            fontSize = 10,
            font = native.systemFont,
        })
        label.anchorX = 0
        label:setFillColor(0.85, 0.85, 0.85)
        testLabels[i] = label
    end

    -- Divider line
    local divY = startY + #testDefs * rowHeight + 5
    local divider = display.newLine(testOverlayGroup, 20, divY, 300, divY)
    divider:setStrokeColor(0.4, 0.4, 0.4)
    divider.strokeWidth = 1

    -- Summary text
    summaryText = display.newText({
        parent = testOverlayGroup,
        text = "Running...",
        x = display.contentCenterX,
        y = divY + 15,
        fontSize = 13,
        font = native.systemFontBold,
    })
    summaryText:setFillColor(0.6, 0.6, 0.6)

    -- Back button
    local backY = divY + 42
    local backBg = display.newRoundedRect(testOverlayGroup, display.contentCenterX, backY, 160, 28, 6)
    backBg:setFillColor(0.3, 0.3, 0.4)
    backBg.strokeWidth = 1
    backBg:setStrokeColor(0.5, 0.5, 0.6)

    local backTxt = display.newText({
        parent = testOverlayGroup,
        text = "Back to Menu",
        x = display.contentCenterX,
        y = backY,
        fontSize = 11,
        font = native.systemFontBold,
    })
    backTxt:setFillColor(0.8, 0.8, 0.9)

    backBg:addEventListener("tap", function()
        if testState.running then return true end  -- Don't allow back during tests
        if testOverlayGroup then
            testOverlayGroup:removeSelf()
            testOverlayGroup = nil
        end
        menuGroup.isVisible = true
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
-- Buttons
-- ============================================================================

local buttonY = 55
local buttonSpacing = 26
local buttonW = 140
local buttonH = 22

local function makeButton(label, x, y, onTap, color)
    local bg = display.newRoundedRect(menuGroup, x, y, buttonW, buttonH, 4)
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
        fontSize = 10,
        font = native.systemFontBold,
    })

    bg:addEventListener("tap", function()
        addLog("BUTTON: " .. label)
        onTap()
        return true
    end)

    return bg, txt
end

local col1 = display.contentCenterX - 78
local col2 = display.contentCenterX + 78

-- Row 1: Connect (non-TLS) / Disconnect
makeButton("Connect", col1, buttonY, function()
    mqtt.connect({
        broker = MQTT_BROKER,
        port = MQTT_PORT,
        clientId = "solarmqtt-" .. math.random(1000, 9999),
        cleanSession = true,
        keepAlive = 60,
    })
end)

makeButton("Disconnect", col2, buttonY, function()
    mqtt.disconnect()
end)

-- Row 2: Subscribe / Unsubscribe
buttonY = buttonY + buttonSpacing
makeButton("Subscribe", col1, buttonY, function()
    mqtt.subscribe(MQTT_TOPIC, 1)
end)

makeButton("Unsubscribe", col2, buttonY, function()
    mqtt.unsubscribe(MQTT_TOPIC)
end)

-- Row 3: Publish QoS 0 / Publish QoS 1
buttonY = buttonY + buttonSpacing
makeButton("Publish QoS 0", col1, buttonY, function()
    mqtt.publish(MQTT_TOPIC, "Hello " .. os.time())
end)

makeButton("Publish QoS 1", col2, buttonY, function()
    mqtt.publish(MQTT_TOPIC, "QoS1 " .. os.time(), { qos = 1 })
end)

-- Row 4: Bad Host / Sub+Pub round-trip (non-TLS)
buttonY = buttonY + buttonSpacing
makeButton("Bad Host", col1, buttonY, function()
    mqtt.connect({
        broker = MQTT_BAD_HOST,
        port = 1883,
        clientId = "bad-test",
        cleanSession = true,
        keepAlive = 10,
    })
end, "red")

makeButton("Sub+Pub Test", col2, buttonY, function()
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
buttonY = buttonY + buttonSpacing
makeButton("TLS Connect", col1, buttonY, function()
    mqtt.connect({
        broker = MQTT_BROKER,
        port = MQTT_PORT_TLS,
        clientId = "solarmqtt-tls-" .. math.random(1000, 9999),
        cleanSession = true,
        keepAlive = 60,
    })
end)

makeButton("TLS Sub+Pub", col2, buttonY, function()
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
buttonY = buttonY + buttonSpacing
makeButton("TLS Bad Auth", col1, buttonY, function()
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

makeButton("Run All Tests", col2, buttonY, startTestSuite, "green")

-- Topic info
buttonY = buttonY + buttonSpacing + 5
local topicInfo = display.newText({
    parent = menuGroup,
    text = "Topic: " .. MQTT_TOPIC,
    x = display.contentCenterX,
    y = buttonY,
    fontSize = 9,
    font = native.systemFont,
})
topicInfo:setFillColor(0.5, 0.5, 0.5)

addLog("Tap Run All Tests or individual buttons")
