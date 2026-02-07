# SolarMQTT

Native MQTT 3.1.1 client plugin for [Solar2D](https://solar2d.com/) (formerly Corona SDK).

Uses [libmosquitto](https://mosquitto.org/) (the Eclipse Mosquitto C library) on Apple platforms and [Eclipse Paho](https://eclipse.dev/paho/) (Java) on Android.

---

## Features

- **MQTT 3.1.1** publish/subscribe messaging
- **TLS/SSL** encryption with automatic CA certificate handling
- **Last Will and Testament (LWT)** for offline detection
- **Per-operation callbacks** -- optional callbacks on connect, subscribe, unsubscribe, publish, and disconnect
- **QoS 0, 1, and 2** quality of service levels
- **Username/password authentication**
- **Async event-driven API** matching Solar2D patterns
- **Single connection model** -- one MQTT broker connection at a time
- All Apple platforms (iOS, tvOS, macOS simulator) and Android

## Supported Platforms

| Platform | Library | Artifact |
|----------|---------|----------|
| iOS | libmosquitto (C) | Static library |
| tvOS | libmosquitto (C) | Static library |
| macOS (Solar2D Simulator) | libmosquitto (C) | Dynamic library |
| Android | Eclipse Paho Java | JAR |

Windows is **not** supported.

## Installation

Add the plugin to your project's `build.settings`:

```lua
settings = {
    plugins = {
        ["plugin.solarmqtt"] = {
            publisherId = "com.platopus",
            supportedPlatforms = {
                android   = { url="https://github.com/platopus-systems/SolarMQTT/releases/latest/download/solarmqtt_android.tgz" },
                iphone    = { url="https://github.com/platopus-systems/SolarMQTT/releases/latest/download/solarmqtt_iphone.tgz" },
                ["iphone-sim"] = { url="https://github.com/platopus-systems/SolarMQTT/releases/latest/download/solarmqtt_iphone-sim.tgz" },
                appletvos = { url="https://github.com/platopus-systems/SolarMQTT/releases/latest/download/solarmqtt_appletvos.tgz" },
                ["mac-sim"] = { url="https://github.com/platopus-systems/SolarMQTT/releases/latest/download/solarmqtt_mac-sim.tgz" },
            },
        },
    },
}
```

The URLs use GitHub's `releases/latest/download/` redirect, so they always resolve to the most recent release. No version bumps are needed in consuming projects when a new plugin version is published.

## Quick Start

```lua
local mqtt = require("plugin.solarmqtt")

local function onMqttEvent(event)
    if event.name == "connected" then
        print("Connected!")
        mqtt.subscribe("my/topic", 1)
    elseif event.name == "message" then
        print("Received: " .. event.payload)
    elseif event.name == "error" then
        print("Error: " .. event.errorMessage)
    end
end

mqtt.init(onMqttEvent)
mqtt.connect({
    broker = "broker.emqx.io",
    port = 1883,
    clientId = "my-device-" .. os.time(),
})
```

---

## API Reference

### `mqtt.init(listener)`

Initializes the plugin and registers the event listener. Must be called before any other plugin function.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `listener` | function | Callback function that receives all MQTT events |

```lua
mqtt.init(function(event)
    print(event.name)
end)
```

---

### `mqtt.connect(options)`

Connects to an MQTT broker. Only one connection can be active at a time. Calling `connect` while already connected will disconnect the previous connection first.

**Parameters:**

The `options` argument is a table with the following fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `broker` | string | `"localhost"` | Broker hostname or IP address |
| `port` | integer | `1883` | Broker port number |
| `clientId` | string | auto-generated | Unique client identifier |
| `username` | string | nil | Authentication username |
| `password` | string | nil | Authentication password |
| `cleanSession` | boolean | `true` | Start a clean session (discard prior subscriptions and queued messages) |
| `keepAlive` | integer | `60` | Keep-alive interval in seconds |
| `useTLS` | boolean | `true` if port == 8883 | Enable TLS/SSL encryption |
| `caFile` | string | nil | Path to a custom CA certificate file (PEM format) |
| `tlsInsecure` | boolean | `false` | Skip hostname verification (not recommended for production) |
| `will` | table | nil | Last Will and Testament configuration (see [LWT](#last-will-and-testament)) |
| `onConnect` | function | nil | Per-operation callback, fired on CONNACK or connection error |

```lua
mqtt.connect({
    broker = "broker.emqx.io",
    port = 1883,
    clientId = "device-" .. os.time(),
    username = "user",
    password = "pass",
    cleanSession = true,
    keepAlive = 60,
})
```

---

### `mqtt.subscribe(topic, qos [, callback])`

Subscribes to a topic. Wildcard topics (`#` and `+`) are supported per the MQTT specification.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `topic` | string | Topic filter to subscribe to |
| `qos` | integer | Requested QoS level (0, 1, or 2) |
| `callback` | function | Optional per-operation callback, fired on SUBACK |

```lua
mqtt.subscribe("sensors/#", 1)

-- With per-operation callback:
mqtt.subscribe("sensors/#", 1, function(event)
    print("Subscribed to " .. event.topic .. " with QoS " .. event.grantedQos)
end)
```

---

### `mqtt.unsubscribe(topic [, callback])`

Unsubscribes from a topic.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `topic` | string | Topic filter to unsubscribe from |
| `callback` | function | Optional per-operation callback, fired on UNSUBACK |

```lua
mqtt.unsubscribe("sensors/#")

-- With per-operation callback:
mqtt.unsubscribe("sensors/#", function(event)
    print("Unsubscribed from " .. event.topic)
end)
```

---

### `mqtt.publish(topic, payload, options [, callback])`

Publishes a message to a topic.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `topic` | string | Topic to publish to |
| `payload` | string | Message payload |
| `options` | table | Publish options (see below) |
| `callback` | function | Optional per-operation callback, fired on PUBACK/PUBCOMP |

**Options table:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `qos` | integer | `0` | QoS level (0, 1, or 2) |
| `retain` | boolean | `false` | Whether the broker should retain this message |

```lua
mqtt.publish("sensors/temperature", "22.5", { qos = 1, retain = false })

-- Fire-and-forget (QoS 0, no options):
mqtt.publish("sensors/heartbeat", "ping", {})

-- With per-operation callback:
mqtt.publish("sensors/temperature", "22.5", { qos = 1 }, function(event)
    print("Published, mid=" .. event.mid)
end)
```

---

### `mqtt.disconnect([callback])`

Disconnects from the broker.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `callback` | function | Optional per-operation callback, fired when disconnect completes |

```lua
mqtt.disconnect()

-- With per-operation callback:
mqtt.disconnect(function(event)
    print("Disconnected: " .. event.errorMessage)
end)
```

---

### `mqtt.VERSION`

String constant containing the plugin version. Currently `"1.3.0"`.

### `mqtt.BUILD`

Integer constant containing the build number. Currently `9`.

---

## Events

All events are dispatched to the listener registered with `mqtt.init()`. Every event has a `name` field that identifies its type.

| Event | Fields | Description |
|-------|--------|-------------|
| `connected` | `sessionPresent` (boolean) | CONNACK received -- successfully connected to the broker |
| `disconnected` | `errorCode` (integer), `errorMessage` (string) | Connection closed. `errorCode` is 0 for a clean disconnect. |
| `message` | `topic` (string), `payload` (string), `qos` (integer), `retained` (boolean) | Message received on a subscribed topic |
| `subscribed` | `topic` (string), `grantedQos` (integer) | SUBACK received -- subscription confirmed by the broker |
| `published` | `mid` (integer) | PUBACK or PUBCOMP received -- publish delivery confirmed (QoS 1+) |
| `unsubscribed` | `topic` (string) | UNSUBACK received -- unsubscription confirmed by the broker |
| `error` | `errorMessage` (string), `errorCode` (integer) | Connection or protocol error (e.g., auth failure, unreachable broker) |

---

## TLS/SSL

SolarMQTT supports encrypted connections using TLS/SSL. TLS is enabled automatically when connecting to port 8883, or manually by setting `useTLS = true`.

### How it works

- **macOS**: System root CA certificates are exported at runtime from the Keychain and passed to OpenSSL. Works automatically with CA-signed certificates.
- **iOS/tvOS**: Uses an embedded Mozilla CA certificate bundle compiled into the binary. Works automatically with CA-signed certificates.
- **Android**: Paho uses the system trust store automatically when connecting with the `ssl://` protocol.

### Example

```lua
-- TLS is auto-enabled on port 8883:
mqtt.connect({
    broker = "broker.emqx.io",
    port = 8883,
    clientId = "secure-device-" .. os.time(),
})

-- Explicit TLS with custom CA:
mqtt.connect({
    broker = "my-broker.example.com",
    port = 8883,
    clientId = "device-123",
    useTLS = true,
    caFile = system.pathForFile("my-ca.pem", system.ResourceDirectory),
})

-- Skip hostname verification (not recommended for production):
mqtt.connect({
    broker = "192.168.1.100",
    port = 8883,
    clientId = "local-device",
    useTLS = true,
    tlsInsecure = true,
})
```

---

## Last Will and Testament

MQTT Last Will and Testament (LWT) allows the broker to publish a message on your behalf if the connection drops unexpectedly. This is useful for presence and device status monitoring.

The LWT message is sent by the *broker* (not the client) when:

- The network connection is closed unexpectedly
- The client fails to send a keepalive within the configured interval
- The client does not disconnect cleanly

The LWT is **not** sent when the client calls `mqtt.disconnect()` (a clean disconnect).

### Example

```lua
mqtt.connect({
    broker = "broker.emqx.io",
    port = 1883,
    clientId = "kds-ipad-01",
    will = {
        topic = "devices/kds-ipad-01/status",
        payload = "offline-unexpected",
        qos = 1,
        retain = true,
    },
})
```

**Will table fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `topic` | string | *required* | Topic the will message is published to |
| `payload` | string | `""` | Will message payload |
| `qos` | integer | `0` | QoS level for the will message (0, 1, or 2) |
| `retain` | boolean | `false` | Whether the broker should retain the will message |

---

## Per-Operation Callbacks

Every operation supports an optional callback function in addition to the global event listener. This lets you write targeted response logic inline without routing everything through a single listener.

All per-operation callbacks are **optional**. If omitted, the operation still works and events are still dispatched to the global listener.

### Fire-and-forget style (global listener only)

```lua
local function onMqttEvent(event)
    if event.name == "connected" then
        mqtt.subscribe("my/topic", 1)
    elseif event.name == "subscribed" then
        print("Subscribed to " .. event.topic)
    elseif event.name == "message" then
        print(event.topic .. ": " .. event.payload)
    end
end

mqtt.init(onMqttEvent)
mqtt.connect({
    broker = "broker.emqx.io",
    port = 1883,
    clientId = "device-" .. os.time(),
})
```

### Per-operation callback style

```lua
mqtt.init(function(event)
    -- Global listener still receives all events
    if event.name == "message" then
        print(event.topic .. ": " .. event.payload)
    end
end)

mqtt.connect({
    broker = "broker.emqx.io",
    port = 1883,
    clientId = "device-" .. os.time(),
    onConnect = function(event)
        -- Fires only for this connect attempt
        if event.isError then
            print("Connect failed: " .. event.errorMessage)
        else
            mqtt.subscribe("my/topic", 1, function(subEvent)
                -- Fires only for this subscribe
                print("Subscribed with QoS " .. subEvent.grantedQos)
                mqtt.publish("my/topic", "hello", { qos = 1 }, function(pubEvent)
                    print("Published, mid=" .. pubEvent.mid)
                end)
            end)
        end
    end,
})
```

Both the global listener and the per-operation callback receive the same event. The global listener always fires first.

---

## Complete Example

A real-world example demonstrating TLS connection, authentication, LWT, subscribe, publish, message handling, and clean disconnect:

```lua
local mqtt = require("plugin.solarmqtt")

local DEVICE_ID = "kds-ipad-" .. system.getInfo("deviceID"):sub(1, 8)
local STATUS_TOPIC = "devices/" .. DEVICE_ID .. "/status"
local SCHEDULE_TOPIC = "schedules/" .. DEVICE_ID .. "/#"
local COMMAND_TOPIC = "commands/" .. DEVICE_ID

local function onMqttEvent(event)
    if event.name == "connected" then
        print("Connected to broker")

        -- Publish online status
        mqtt.publish(STATUS_TOPIC, "online", { qos = 1, retain = true })

        -- Subscribe to schedule updates and commands
        mqtt.subscribe(SCHEDULE_TOPIC, 1)
        mqtt.subscribe(COMMAND_TOPIC, 1)

    elseif event.name == "message" then
        print("Received on [" .. event.topic .. "]: " .. event.payload)

        if event.topic == COMMAND_TOPIC then
            -- Handle device commands
            if event.payload == "reboot" then
                mqtt.publish(STATUS_TOPIC, "rebooting", { qos = 1, retain = true })
                mqtt.disconnect()
            end
        end

    elseif event.name == "subscribed" then
        print("Subscribed to " .. event.topic .. " (QoS " .. event.grantedQos .. ")")

    elseif event.name == "disconnected" then
        print("Disconnected (code=" .. event.errorCode .. "): " .. event.errorMessage)

    elseif event.name == "error" then
        print("MQTT error: " .. event.errorMessage)
    end
end

mqtt.init(onMqttEvent)

mqtt.connect({
    broker = "my-broker.example.com",
    port = 8883,
    clientId = DEVICE_ID,
    username = "device-user",
    password = "device-pass",
    cleanSession = true,
    keepAlive = 30,
    will = {
        topic = STATUS_TOPIC,
        payload = "offline-unexpected",
        qos = 1,
        retain = true,
    },
})
```

---

## Building from Source

### CI (all platforms)

Push a version tag to trigger the CI workflow, which builds artifacts for all platforms and creates a GitHub release:

```bash
git tag v1.3.0
git push origin v1.3.0
```

The CI workflow (`.github/workflows/build-plugin.yml`) produces five artifacts:

- `solarmqtt_mac-sim.tgz` -- macOS simulator dylib
- `solarmqtt_iphone.tgz` -- iOS static library
- `solarmqtt_iphone-sim.tgz` -- iOS simulator static library
- `solarmqtt_appletvos.tgz` -- tvOS static library
- `solarmqtt_android.tgz` -- Android JAR

### Local macOS build (for simulator testing)

```bash
cd /path/to/SolarMQTT
xcodebuild -project mac/Plugin.xcodeproj -configuration Release -arch arm64 MACOSX_DEPLOYMENT_TARGET=10.13
codesign -s - -f mac/build/Release/libplugin_solarmqtt.dylib
cp mac/build/Release/libplugin_solarmqtt.dylib \
   ~/Library/Application\ Support/Corona/Simulator/Plugins/plugin_solarmqtt.dylib
```

Then open `Corona/main.lua` in the Solar2D Simulator to run the test harness.

---

## License

This project is licensed under the [Eclipse Public License 2.0](LICENSE) (EPL-2.0).

SolarMQTT embeds [libmosquitto](https://mosquitto.org/) (EPL-2.0) and uses [Eclipse Paho Java](https://eclipse.dev/paho/) (EPL-2.0) on Android.
