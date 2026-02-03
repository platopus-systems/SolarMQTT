# CLAUDE.md - SolarMQTT

## Project Overview

SolarMQTT is a native MQTT client plugin for **Solar2D (formerly Corona SDK)**. It provides publish/subscribe messaging over MQTT 3.1.1, targeting digital signage applications (PlatopusDisplay). Single connection model — one MQTT broker connection at a time.

**Repository**: https://github.com/platopus-systems/SolarMQTT

## Target Platforms

- macOS (Solar2D simulator — dylib)
- iOS (static library)
- tvOS (static library)
- Android (JAR via Gradle)
- **Not supported**: Windows

## MQTT Libraries

Both libraries are maintained by the **Eclipse IoT Foundation** — the same organisation behind the MQTT specification.

- **Apple (iOS/macOS/tvOS)**: **libmosquitto** — the reference MQTT C client library from Eclipse Mosquitto. Source files from `lib/` embedded directly into Xcode projects (same pattern as Jetfire in SolarWebSockets). ~60 C source files + headers.
- **Android**: **Eclipse Paho Java** `org.eclipse.paho.client.mqttv3:1.2.5` — pure Java client (NOT the Android Service wrapper). Gradle dependency.

### Why libmosquitto over alternatives?
- **MQTT-Client-Framework**: Last release 2018, effectively abandoned
- **CocoaMQTT**: Swift — requires bridging layer, adds Swift runtime dependency
- **libmosquitto**: Actively maintained, pure C, compiles directly in Obj-C++, reference implementation

### TLS
Built **without TLS** (`WITH_TLS` not defined). EMQX supports non-TLS on port 1883. TLS is a natural v1.1.0 enhancement (would require linking OpenSSL or Apple Security framework).

## Building

### macOS (local testing in simulator)

```bash
cd /path/to/SolarMQTT
xcodebuild -project mac/Plugin.xcodeproj -configuration Release -arch arm64 MACOSX_DEPLOYMENT_TARGET=10.13
codesign -s - -f mac/build/Release/libplugin_solarmqtt.dylib
cp mac/build/Release/libplugin_solarmqtt.dylib \
   ~/Library/Application\ Support/Corona/Simulator/Plugins/plugin_solarmqtt.dylib
```

Then open `Corona/main.lua` in the Solar2D Simulator.

### CI (all platforms)

Push a version tag to trigger CI:
```bash
git tag v1.0.0
git push origin v1.0.0
```

CI workflow (`.github/workflows/build-plugin.yml`) builds 5 artifacts:
- `solarmqtt_mac-sim.tgz` — macOS simulator dylib
- `solarmqtt_iphone.tgz` — iOS static library
- `solarmqtt_iphone-sim.tgz` — iOS simulator static library
- `solarmqtt_appletvos.tgz` — tvOS static library
- `solarmqtt_android.tgz` — Android JAR

Artifacts are attached to the GitHub release created by the `release` job.

## Project Structure

```
SolarMQTT/
├── .github/workflows/build-plugin.yml    # CI: 5 build jobs + release
├── .gitignore
├── CLAUDE.md
├── LICENSE                                # EPL-2.0 (matching mosquitto)
├── README.md
├── Corona/                                # Test harness for simulator
│   ├── main.lua                           # Buttons: Connect, Subscribe, Publish, etc.
│   ├── config.lua                         # 320x480, zoomEven
│   └── build.settings                     # plugin.solarmqtt, ATS disabled
├── mac/                                   # macOS plugin (dylib)
│   ├── Plugin.xcodeproj/
│   └── CoronaNative.xcconfig
├── ios/                                   # iOS plugin (static lib)
│   ├── Plugin.xcodeproj/
│   ├── metadata.lua
│   └── CoronaNative.xcconfig
├── tvos/                                  # tvOS plugin (static lib + framework)
│   ├── Plugin.xcodeproj/
│   ├── Plugin/Corona_plugin_library.h, Info.plist
│   ├── metadata.lua
│   └── CoronaNative.xcconfig
├── android/                               # Android plugin (JAR)
│   ├── build.gradle.kts
│   ├── settings.gradle, gradle.properties
│   ├── metadata.lua
│   ├── gradlew, gradle/
│   └── plugin/
│       ├── build.gradle                   # Paho dependency here
│       ├── src/main/AndroidManifest.xml
│       └── src/main/java/plugin/solarmqtt/
│           └── LuaLoader.java             # Android plugin implementation
├── shared_objc_PluginSolarMQTT/           # Plugin wrapper (Obj-C++)
│   ├── PluginSolarMQTT.h
│   └── PluginSolarMQTT.mm                # Apple platforms implementation
└── shared_mosquitto/                      # libmosquitto C source (from Eclipse Mosquitto)
    ├── config.h                           # Custom: WITH_THREADING, no TLS
    ├── mosquitto.h
    ├── mosquitto_internal.h
    ├── mosquitto/                          # Public headers (include/mosquitto/)
    ├── libcommon/                          # Shared utility code (libcommon/)
    ├── cjson/cJSON.h                      # Stub header (SolarMQTT doesn't use cJSON)
    ├── utlist.h, uthash.h                 # From mosquitto/deps/
    ├── libmosquitto.c, connect.c, loop.c  # ~30 compiled C files
    └── tls_mosq.c, srv_mosq.c, ...        # Present but NOT compiled (TLS/SRV disabled)
```

## Lua API

```lua
local mqtt = require("plugin.solarmqtt")

mqtt.init(listener)

mqtt.connect({
    broker = "broker.emqx.io",
    port = 1883,
    clientId = "device-123",
    username = "user",        -- optional
    password = "pass",        -- optional
    cleanSession = true,      -- default: true
    keepAlive = 60,           -- default: 60 seconds
})

mqtt.subscribe("topic/#", 1)       -- topic, qos (0-2)
mqtt.unsubscribe("topic/#")
mqtt.publish("topic", "payload", { qos = 1, retain = false })
mqtt.disconnect()
print(mqtt.VERSION)  -- "1.0.0"
```

### Events dispatched to listener

| Event name     | Fields                               | When                              |
|----------------|--------------------------------------|-----------------------------------|
| `connected`    | `sessionPresent` (bool)              | Broker accepts CONNACK            |
| `disconnected` | `errorCode`, `errorMessage`          | Connection lost or closed         |
| `message`      | `topic`, `payload`, `qos`, `retained`| Message received on subscribed topic |
| `subscribed`   | `topic`, `grantedQos`                | SUBACK received                   |
| `error`        | `errorMessage`, `errorCode`          | Connection/protocol error         |

## Architecture

### Apple Platforms (PluginSolarMQTT.mm)

- **C++ class pattern** identical to SolarWebSockets: `PluginSolarMQTT` class with static Lua function methods
- **Global state**: `mosq_client`, `mosq_L`, `mosq_fListener`, `mosq_L_valid`, `mosq_L_generation`
- **Serial dispatch queue** (`mosq_lua_queue`) for thread-safe Lua function calls — connect, disconnect, publish, subscribe all dispatch async to this queue
- **Mosquitto background thread**: `mosquitto_loop_start()` spawns a thread for network I/O and keepalive
- **Callbacks**: Fire on mosquitto's background thread → `dispatch_async(dispatch_get_main_queue())` → `CoronaLuaDispatchEvent`
- **Generation counter**: Incremented in `Open()`, captured by `connect()`, checked in every async callback. Prevents SIGSEGV from stale callbacks after Lua state reload (proven pattern from SolarWebSockets)
- **Finalizer**: Calls `mosquitto_loop_stop(force)`, `mosquitto_disconnect()`, `mosquitto_destroy()` before Lua state destruction

### Android (LuaLoader.java)

- **Standard Corona plugin pattern**: `LuaLoader` implements `JavaFunction`, registers Lua functions in `invoke()`
- **Paho `MqttAsyncClient`** with `MemoryPersistence` for non-blocking operations
- **`MqttCallbackExtended`** for lifecycle events: `connectComplete`, `connectionLost`, `messageArrived`
- **`IMqttActionListener`** for per-operation callbacks (connect, subscribe)
- **Dispatch to Lua**: All events dispatched via `CoronaRuntimeTask` with null-check on `CoronaEnvironment.getCoronaActivity()`
- **Exception logging**: All catch blocks use `Log.e("SolarMQTT", ...)` — no swallowed exceptions

### libmosquitto Source Embedding

The `shared_mosquitto/` directory contains source files from the Eclipse Mosquitto `lib/`, `include/`, `libcommon/`, and `deps/` directories. These compile as part of each Xcode target (same pattern as Jetfire `.m` files in SolarWebSockets).

**Custom `config.h`**:
- `#define WITH_THREADING` — required for `mosquitto_loop_start()`
- `#undef WITH_TLS` — no OpenSSL dependency
- `#undef WITH_SRV`, `WITH_SOCKS`, `WITH_BROKER`, `WITH_WEBSOCKETS`, `WITH_ADNS`

**Files NOT compiled** (present but excluded from Xcode targets):
- `tls_mosq.c`, `net_mosq_ocsp.c` — TLS disabled
- `srv_mosq.c` — SRV lookup disabled
- `socks_mosq.c` — SOCKS proxy disabled
- `http_client.c`, `net_ws.c`, `extended_auth.c` — not needed
- `cjson_common.c`, `base64_common.c`, `password_common.c`, `file_common.c` — libcommon utilities not used
- Note: `mqtt_common.c` (libcommon) IS compiled — provides `mosquitto_varint_bytes()` needed at runtime

**Patches applied to mosquitto source**:
- `libcommon/random_common.c`: Added `#elif defined(__APPLE__)` branch using `arc4random_buf()` — original code only handled TLS (OpenSSL RAND_bytes), Linux (getrandom), and Windows (CryptGenRandom)
- `cjson/cJSON.h`: Stub header with minimal `cJSON` typedef — satisfies `#include` in `libcommon_cjson.h` without pulling in real cJSON library

### Xcode Header Search Paths

All three Xcode projects (mac, ios, tvos) include these header search paths:
- `$(SRCROOT)/../shared_mosquitto`
- `$(SRCROOT)/../shared_mosquitto/mosquitto`
- `$(SRCROOT)/../shared_mosquitto/libcommon`
- `$(SRCROOT)/../shared_mosquitto/cjson`
- `$(SRCROOT)/../shared_objc_PluginSolarMQTT`

## Key Design Decisions

1. **libmosquitto over MQTT-Client-Framework** — actively maintained vs abandoned in 2018. For business-critical infrastructure, the reference implementation backed by Eclipse Foundation.
2. **Single connection model** — like SolarWebSockets. One MQTT connection at a time (global/static state). Matches PlatopusDisplay usage pattern.
3. **Client-only** — MQTT is broker-based; no server mode needed.
4. **Paho Java (not Android Service)** — Corona manages its own activity lifecycle. Pure Java client avoids Service/Manifest complexity.
5. **Source embedding** — libmosquitto source compiled directly into plugin (like Jetfire). No external build step or dependency manager.
6. **Generation counter** — proven pattern from SolarWebSockets for stale callback prevention across Lua state reloads.
7. **`connect()` takes a Lua table** — extensible for future options (TLS, Last Will, etc.)
8. **No TLS initially** — simplifies first release. EMQX supports non-TLS on port 1883.

## Plugin Distribution (build.settings)

```lua
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
```

Uses GitHub's `releases/latest/download/` redirect URL — always resolves to the most recent release. No version bumps needed in consuming projects when a new plugin version is released.

## Test Harness (Corona/main.lua)

Buttons for testing all functionality:
- **Connect** / **Disconnect** — basic lifecycle
- **Subscribe** / **Unsubscribe** — topic subscription
- **Publish QoS 0** / **Publish QoS 1** — message publishing
- **Bad Host** — error handling (connect to nonexistent broker)
- **Sub+Pub Test** — connect → subscribe → publish → receive round-trip
- **Double Connect** — old client cleanup
- **Reconnect x3** — rapid reconnection stress test

Configurable at top of file: `MQTT_BROKER`, `MQTT_PORT`, `MQTT_USER`, `MQTT_PASS`

On-screen scrolling event log shows all MQTT events with timestamps.

## Build Errors Fixed During Development

1. **`cjson/cJSON.h` not found** — Created stub header at `shared_mosquitto/cjson/cJSON.h`
2. **`property_common.h` not found** — Added libcommon directory to Xcode HEADER_SEARCH_PATHS
3. **`NSLog`/`NSString` undeclared** — Added `#import <Foundation/Foundation.h>` to PluginSolarMQTT.mm
4. **`utlist.h` not found** — Copied from mosquitto/deps/ to shared_mosquitto/
5. **`random_common.c` "No suitable random function found"** — Added `#elif defined(__APPLE__)` branch using `arc4random_buf()`

### Runtime Errors Fixed During Testing

6. **CI: macOS dylib name mismatch** — Xcode builds `libplugin_solarmqtt.dylib` (with `lib` prefix) but CI scripts referenced `plugin_solarmqtt.dylib`. Fixed all references in `build-plugin.yml`.
7. **CI: Android `final` variable error** — `topic` and `qos` local variables accessed from inner class. Made them `final`.
8. **`dlopen` missing `_mosquitto_varint_bytes` symbol** — `mqtt_common.c` (in `shared_mosquitto/libcommon/`) was not included in Xcode builds. Added to all three Xcode projects (mac, ios, tvos).
9. **`loop_start failed: Invalid input`** — `mosquitto_threaded_set(mosq_client, true)` sets `mosq->threaded = mosq_ts_external`, but `mosquitto_loop_start()` requires `mosq_ts_none`. Removed the `mosquitto_threaded_set()` call entirely.
10. **`Connect failed: Socket is not connected`** — `mosquitto_connect_async()` was called before `mosquitto_loop_start()`. The async connect needs the loop thread already running to handle TCP. Fixed by calling `mosquitto_loop_start()` first, then `mosquitto_connect_async()`.

### Correct mosquitto connect sequence (PluginSolarMQTT.mm)

The connect sequence must be:
1. `mosquitto_new()` — create client
2. Set callbacks (`mosquitto_connect_callback_set`, etc.)
3. `mosquitto_username_pw_set()` — if credentials provided
4. `mosquitto_loop_start()` — start the network thread (**before** connect)
5. `mosquitto_connect_async()` — initiate TCP connection (loop thread handles it)

**Do NOT call `mosquitto_threaded_set(true)`** — that sets `mosq_ts_external` which conflicts with `loop_start()`.

## Cross-Machine Plugin Installation

An installer script (`install-plugins.sh`) is available for quickly deploying the latest macOS simulator plugins across multiple Macs:

```bash
bash install-plugins.sh
```

The script uses `curl` (no `gh` CLI required) to download the latest releases from GitHub using `releases/latest/download/` URLs, extracts the dylibs, ad-hoc codesigns them, and installs to `~/Library/Application Support/Corona/Simulator/Plugins/`. The script lives in the shared Dropbox folder alongside the Corona projects.

## Future Enhancements

- **TLS support** (v1.1.0) — Link OpenSSL or Apple Security framework, define `WITH_TLS`
- **Last Will and Testament** — Add `will` option to `connect()` table
- **MQTT 5.0 features** — libmosquitto supports MQTT 5.0; expose reason codes, properties
- **Multiple subscriptions** — Track pending subscribe topics by message ID (currently single pending topic)
- **Reconnect with backoff** — Automatic reconnection on unexpected disconnect (Lua layer or native)
