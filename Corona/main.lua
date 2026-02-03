-- SolarMQTT Test Harness
-- Tests all MQTT plugin functions in the Solar2D simulator

local mqtt = require("plugin.solarmqtt")

-- ============================================================================
-- Configuration — change these to match your MQTT broker
-- ============================================================================

local MQTT_BROKER   = "broker.emqx.io"   -- Public EMQX test broker
local MQTT_PORT     = 1883
local MQTT_USER     = nil                 -- Set for auth brokers
local MQTT_PASS     = nil
local MQTT_TOPIC    = "solarmqtt/test/" .. os.time()  -- Unique topic per session
local MQTT_BAD_HOST = "nonexistent.invalid"

-- ============================================================================
-- UI Setup
-- ============================================================================

display.setDefault("background", 0.1, 0.1, 0.15)

local titleText = display.newText({
    text = "SolarMQTT Test Harness",
    x = display.contentCenterX,
    y = 20,
    fontSize = 16,
    font = native.systemFontBold,
})
titleText:setFillColor(0.3, 0.8, 1)

local versionText = display.newText({
    text = "Plugin v" .. (mqtt.VERSION or "?"),
    x = display.contentCenterX,
    y = 38,
    fontSize = 11,
})
versionText:setFillColor(0.6, 0.6, 0.6)

-- Log area
local logLines = {}
local MAX_LOG_LINES = 12
local logGroup = display.newGroup()
logGroup.y = 300

local logBg = display.newRect(logGroup, display.contentCenterX, 80, 300, 170)
logBg:setFillColor(0, 0, 0, 0.5)
logBg.strokeWidth = 1
logBg:setStrokeColor(0.3, 0.3, 0.3)

local function addLog(msg)
    print("[SolarMQTT] " .. msg)
    table.insert(logLines, os.date("%H:%M:%S") .. " " .. msg)
    while #logLines > MAX_LOG_LINES do
        table.remove(logLines, 1)
    end

    -- Redraw log
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
-- MQTT Event Listener
-- ============================================================================

local function mqttListener(event)
    local name = event.name or "unknown"

    if name == "connected" then
        addLog("CONNECTED (session=" .. tostring(event.sessionPresent) .. ")")
    elseif name == "disconnected" then
        addLog("DISCONNECTED: " .. (event.errorMessage or "") .. " (code=" .. tostring(event.errorCode) .. ")")
    elseif name == "message" then
        addLog("MSG [" .. (event.topic or "?") .. "]: " .. (event.payload or ""))
    elseif name == "subscribed" then
        addLog("SUBSCRIBED: " .. (event.topic or "?") .. " qos=" .. tostring(event.grantedQos))
    elseif name == "error" then
        addLog("ERROR: " .. (event.errorMessage or "unknown"))
    else
        addLog("EVENT: " .. name)
    end
end

mqtt.init(mqttListener)
addLog("Plugin loaded, VERSION=" .. (mqtt.VERSION or "?"))

-- ============================================================================
-- Buttons
-- ============================================================================

local buttonY = 60
local buttonSpacing = 30
local buttonW = 140
local buttonH = 24

local function makeButton(label, x, y, onTap)
    local bg = display.newRoundedRect(x, y, buttonW, buttonH, 4)
    bg:setFillColor(0.2, 0.5, 0.8)
    bg.strokeWidth = 1
    bg:setStrokeColor(0.3, 0.7, 1)

    local txt = display.newText({
        text = label,
        x = x,
        y = y,
        fontSize = 11,
        font = native.systemFontBold,
    })

    bg:addEventListener("tap", function()
        addLog("> " .. label)
        onTap()
        return true
    end)

    return bg, txt
end

local col1 = display.contentCenterX - 78
local col2 = display.contentCenterX + 78

-- Row 1: Connect / Disconnect
makeButton("Connect", col1, buttonY, function()
    mqtt.connect({
        broker = MQTT_BROKER,
        port = MQTT_PORT,
        clientId = "solarmqtt-test-" .. math.random(1000, 9999),
        username = MQTT_USER,
        password = MQTT_PASS,
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

-- Row 3: Publish / Publish QoS 2
buttonY = buttonY + buttonSpacing
makeButton("Publish QoS 0", col1, buttonY, function()
    mqtt.publish(MQTT_TOPIC, "Hello from SolarMQTT! " .. os.time())
end)

makeButton("Publish QoS 1", col2, buttonY, function()
    mqtt.publish(MQTT_TOPIC, "QoS 1 message " .. os.time(), { qos = 1 })
end)

-- Row 4: Connect Bad Host / Sub+Pub Test
buttonY = buttonY + buttonSpacing
makeButton("Bad Host", col1, buttonY, function()
    mqtt.connect({
        broker = MQTT_BAD_HOST,
        port = 1883,
        clientId = "bad-test",
        cleanSession = true,
        keepAlive = 10,
    })
end)

makeButton("Sub+Pub Test", col2, buttonY, function()
    -- Connect, subscribe, publish in sequence
    mqtt.connect({
        broker = MQTT_BROKER,
        port = MQTT_PORT,
        clientId = "solarmqtt-subpub-" .. math.random(1000, 9999),
        cleanSession = true,
        keepAlive = 60,
    })
    -- Subscribe and publish after a delay to let connect complete
    timer.performWithDelay(2000, function()
        mqtt.subscribe(MQTT_TOPIC, 1)
        timer.performWithDelay(500, function()
            mqtt.publish(MQTT_TOPIC, "Round-trip test " .. os.time(), { qos = 1 })
        end)
    end)
end)

-- Row 5: Double Connect / Rapid Reconnect
buttonY = buttonY + buttonSpacing
makeButton("Double Connect", col1, buttonY, function()
    mqtt.connect({
        broker = MQTT_BROKER,
        port = MQTT_PORT,
        clientId = "double-1",
        cleanSession = true,
    })
    -- Immediately connect again (tests old client cleanup)
    timer.performWithDelay(100, function()
        mqtt.connect({
            broker = MQTT_BROKER,
            port = MQTT_PORT,
            clientId = "double-2",
            cleanSession = true,
        })
    end)
end)

makeButton("Reconnect x3", col2, buttonY, function()
    for i = 1, 3 do
        timer.performWithDelay(i * 500, function()
            addLog("Reconnect #" .. i)
            mqtt.connect({
                broker = MQTT_BROKER,
                port = MQTT_PORT,
                clientId = "reconnect-" .. i,
                cleanSession = true,
            })
        end)
    end
end)

-- Topic info
buttonY = buttonY + buttonSpacing + 10
local topicInfo = display.newText({
    text = "Topic: " .. MQTT_TOPIC,
    x = display.contentCenterX,
    y = buttonY,
    fontSize = 9,
    font = native.systemFont,
})
topicInfo:setFillColor(0.5, 0.5, 0.5)

addLog("Tap Connect to start")
