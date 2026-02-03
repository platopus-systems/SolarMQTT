# SolarMQTT

Native MQTT client plugin for [Solar2D](https://solar2d.com/) (formerly Corona SDK).

Uses [libmosquitto](https://mosquitto.org/) (C) on Apple platforms and [Eclipse Paho](https://eclipse.dev/paho/) (Java) on Android.

## Features

- MQTT 3.1.1 publish and subscribe
- Username/password authentication
- QoS 0, 1, 2
- Single connection model (one broker connection at a time)
- Async event-driven API matching Solar2D patterns
- All platforms: iOS, tvOS, macOS simulator, Android

## Usage

```lua
local mqtt = require("plugin.solarmqtt")

local function mqttListener(event)
    if event.name == "connected" then
        print("Connected to broker")
        mqtt.subscribe("my/topic", 1)
    elseif event.name == "message" then
        print("Topic: " .. event.topic .. " Payload: " .. event.payload)
    elseif event.name == "disconnected" then
        print("Disconnected: " .. (event.errorMessage or ""))
    elseif event.name == "error" then
        print("Error: " .. event.errorMessage)
    end
end

mqtt.init(mqttListener)

mqtt.connect({
    broker = "broker.emqx.io",
    port = 1883,
    clientId = "my-device",
    username = "user",
    password = "pass",
    cleanSession = true,
    keepAlive = 60,
})
```

## Building

Push a version tag to trigger CI:
```bash
git tag v1.0.0
git push origin v1.0.0
```

## License

MIT License. Embeds libmosquitto (EPL-2.0/EDL-1.0).
