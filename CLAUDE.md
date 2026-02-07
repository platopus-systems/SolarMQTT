# CLAUDE.md - SolarMQTT

## Project Overview

SolarMQTT is a native MQTT client plugin for **Solar2D (formerly Corona SDK)**. It provides publish/subscribe messaging over MQTT 3.1.1, targeting digital signage applications (PlatopusDisplay). Single connection model — one MQTT broker connection at a time.

**PlatopusDisplay context**: PlatopusDisplay is not just a kiosk-mode app — it runs as a KDS (Kitchen Display System) on iPads and other devices that may be backgrounded/foregrounded regularly. SolarMQTT is intended to replace SolarWebSockets in PlatopusDisplay, retaining all resilience while gaining the ability to send events directly to devices and have devices subscribe to changes in their schedules. The plugin must handle iOS app lifecycle (suspend/resume) gracefully.

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

### TLS/SSL Support (v1.1.0)

TLS is enabled via OpenSSL static libraries from [apotocki/openssl-iosx](https://github.com/nicoschwabe/OpenSSL-iOS). The `shared_openssl/` directory contains:
- `ssl.xcframework/` and `crypto.xcframework` — OpenSSL 3.x static libraries for all Apple platforms
- `include/openssl/` — Complete OpenSSL headers

**Lua API for TLS:**
```lua
mqtt.connect({
    broker = "broker.emqx.io",
    port = 8883,              -- Port 8883 auto-enables TLS
    clientId = "device-123",
    -- Optional TLS options:
    useTLS = true,            -- Default: true if port == 8883
    caFile = "/path/ca.pem",  -- Custom CA certificate file
    tlsInsecure = false,      -- Skip hostname verification (NOT recommended)
})
```

**Platform-specific behavior:**
- **macOS**: System root CA certificates are exported at runtime from the Keychain using `SecTrustCopyAnchorCertificates()` and passed to OpenSSL. Works automatically with CA-signed certificates.
- **iOS/tvOS**: Uses the embedded Mozilla CA certificate bundle (`cacert.h`, ~225KB compiled into the binary). Works automatically with CA-signed certificates.
- **Android**: Paho uses `ssl://` URI protocol and leverages the system trust store automatically.

**OpenSSL on macOS quirk**: OpenSSL's `SSL_CTX_set_default_verify_paths()` doesn't work because it looks for certs in `/etc/ssl/certs/` which doesn't exist on macOS. The plugin exports system certs to a temp file and passes it to `mosquitto_tls_set()`.

**Mozilla CA bundle**: The `shared_openssl/cacert.pem` file is from https://curl.se/ca/cacert.pem. The `cacert.h` header is auto-generated from it and embedded in the iOS/tvOS binaries.

## Current Version

- **Plugin version**: 1.3.0
- **Build number**: 9 (exposed as `mqtt.BUILD` in Lua, matched by `EXPECTED_BUILD` in `Corona/main.lua`)
- Both `PluginSolarMQTT.mm`, `LuaLoader.java`, and `Corona/main.lua` track BUILD numbers. Bump all when changing plugin code.

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
├── shared_openssl/                        # OpenSSL for TLS (v1.1.0+)
│   ├── ssl.xcframework/                   # OpenSSL SSL library (all Apple platforms)
│   ├── crypto.xcframework/                # OpenSSL crypto library
│   ├── include/openssl/                   # OpenSSL headers
│   ├── cacert.pem                         # Mozilla CA certificate bundle
│   └── cacert.h                           # Auto-generated C header with embedded certs
└── shared_mosquitto/                      # libmosquitto C source (from Eclipse Mosquitto)
    ├── config.h                           # Custom: WITH_THREADING, WITH_TLS
    ├── mosquitto.h
    ├── mosquitto_internal.h
    ├── mosquitto/                          # Public headers (include/mosquitto/)
    ├── libcommon/                          # Shared utility code (libcommon/)
    ├── cjson/cJSON.h                      # Stub header (SolarMQTT doesn't use cJSON)
    ├── utlist.h, uthash.h                 # From mosquitto/deps/
    ├── libmosquitto.c, connect.c, loop.c  # ~30 compiled C files
    └── tls_mosq.c, net_mosq_ocsp.c        # TLS source files (compiled for TLS support)
```

## Lua API

All callbacks are **optional**. Every function works without them (fire-and-forget mode). When a per-operation callback is provided, it fires **in addition to** the global listener — the global listener always fires first.

```lua
local mqtt = require("plugin.solarmqtt")

mqtt.init(listener)

-- FIRE-AND-FORGET (all callbacks optional):
mqtt.connect({
    broker = "broker.emqx.io",
    port = 1883,              -- use 8883 for TLS
    clientId = "device-123",
    username = "user",        -- optional
    password = "pass",        -- optional
    cleanSession = true,      -- default: true
    keepAlive = 60,           -- default: 60 seconds
    -- TLS options (optional):
    useTLS = false,           -- default: true if port == 8883
    caFile = nil,             -- custom CA certificate file path
    tlsInsecure = false,      -- skip hostname verification (NOT recommended)
    -- Last Will and Testament (optional, v1.2.0+):
    will = {
        topic = "devices/device-123/status",  -- required if will table present
        payload = "offline-unexpected",        -- optional, default ""
        qos = 1,                              -- optional, default 0
        retain = true,                        -- optional, default false
    },
    -- Per-operation callback (optional, v1.3.0+):
    onConnect = function(event)
        print("CONNACK: " .. (event.isError and event.errorMessage or "connected"))
    end,
})

mqtt.subscribe("topic/#", 1)       -- topic, qos (0-2)
mqtt.subscribe("topic/#", 1, function(event)   -- with optional SUBACK callback
    print("Subscribed with QoS " .. event.grantedQos)
end)

mqtt.unsubscribe("topic/#")
mqtt.unsubscribe("topic/#", function(event)    -- with optional UNSUBACK callback
    print("Unsubscribed from " .. event.topic)
end)

mqtt.publish("topic", "payload", { qos = 1, retain = false })
mqtt.publish("topic", "payload", { qos = 1 }, function(event)  -- with optional PUBACK callback
    print("Published, mid=" .. event.mid)
end)

mqtt.disconnect()
mqtt.disconnect(function(event)                -- with optional disconnect callback
    print("Disconnected: " .. event.errorMessage)
end)

print(mqtt.VERSION)  -- "1.3.0"
print(mqtt.BUILD)    -- 9
```

### MQTT 3.1.1 Server Acknowledgements Coverage (v1.3.0)

| Client sends | Server responds | Global event | Per-op callback |
|---|---|---|---|
| CONNECT | **CONNACK** | `connected` or `error` | `onConnect` in options table |
| SUBSCRIBE | **SUBACK** | `subscribed` | 3rd arg to `subscribe()` |
| PUBLISH (QoS 1) | **PUBACK** | `published` | 4th arg to `publish()` |
| PUBLISH (QoS 2) | **PUBCOMP** | `published` | 4th arg to `publish()` |
| PUBLISH (QoS 0) | *(none)* | `published` (fires when handed to OS) | 4th arg to `publish()` |
| UNSUBSCRIBE | **UNSUBACK** | `unsubscribed` | 2nd arg to `unsubscribe()` |
| DISCONNECT | *(no ACK in MQTT 3.1.1)* | `disconnected` (fires on TCP close) | 1st arg to `disconnect()` |
| PINGREQ | PINGRESP | *(internal)* | N/A |

### Events dispatched to listener

| Event name      | Fields                               | When                              |
|-----------------|--------------------------------------|-----------------------------------|
| `connected`     | `sessionPresent` (bool)              | Broker accepts CONNACK            |
| `disconnected`  | `errorCode`, `errorMessage`          | Connection lost or closed         |
| `message`       | `topic`, `payload`, `qos`, `retained`| Message received on subscribed topic |
| `subscribed`    | `topic`, `grantedQos`                | SUBACK received                   |
| `published`     | `mid`                                | PUBACK/PUBCOMP received (QoS 1/2) or handed to OS (QoS 0) |
| `unsubscribed`  | `topic`                              | UNSUBACK received                 |
| `error`         | `errorMessage`, `errorCode`          | Connection/protocol error         |

## Architecture

### Apple Platforms (PluginSolarMQTT.mm)

- **C++ class pattern** identical to SolarWebSockets: `PluginSolarMQTT` class with static Lua function methods
- **Global state**: `mosq_client`, `mosq_L`, `mosq_fListener`, `mosq_L_valid`, `mosq_L_generation`
- **Serial dispatch queue** (`mosq_lua_queue`) for thread-safe Lua function calls — connect, disconnect, publish, subscribe all dispatch async to this queue
- **Mosquitto background thread**: `mosquitto_loop_start()` spawns a thread for network I/O and keepalive
- **Callbacks**: Fire on mosquitto's background thread → `dispatch_async(dispatch_get_main_queue())` → `CoronaLuaDispatchEvent`
- **Generation counter**: Incremented in `Open()`, captured by `connect()`, checked in every async callback. Prevents SIGSEGV from stale callbacks after Lua state reload (proven pattern from SolarWebSockets)
- **Finalizer**: Calls `mosquitto_loop_stop(force)`, `mosquitto_disconnect()`, `mosquitto_destroy()` before Lua state destruction. Also calls `cleanupCallbackDictionaries()` to free all per-op callback refs.
- **`mosq_ever_connected` flag**: Suppresses spurious pre-connect disconnect events (rc=14/MOSQ_ERR_ERRNO) that libmosquitto fires during async TCP handshake
- **Auth failure handling**: `on_connect_callback` calls `mosquitto_disconnect()` when rc!=0 to stop libmosquitto's automatic reconnect loop

#### Per-operation callback tracking (v1.3.0)

libmosquitto uses global callbacks (one per event type), each receiving only a message ID (`mid`). To support per-operation Lua callbacks, the plugin maps `mid` → `CoronaLuaRef` using `NSMutableDictionary`:

```objc
static NSMutableDictionary *mosq_publish_callbacks;     // mid → @(CoronaLuaRef)
static NSMutableDictionary *mosq_subscribe_callbacks;    // mid → @(CoronaLuaRef)
static NSMutableDictionary *mosq_unsubscribe_callbacks;  // mid → @(CoronaLuaRef)
static NSMutableDictionary *mosq_subscribe_topics;       // mid → NSString
static NSMutableDictionary *mosq_unsubscribe_topics;     // mid → NSString
static CoronaLuaRef mosq_connect_callback;               // single ref (one connect at a time)
static CoronaLuaRef mosq_disconnect_callback;             // single ref (one disconnect at a time)
```

**CoronaLuaRef boxing**: `CoronaLuaRef` is `void*` (8 bytes on arm64). Must use `@((intptr_t)ref)` to box and `(CoronaLuaRef)(intptr_t)[num integerValue]` to unbox. Using `(int)` would truncate the pointer.

**Mosquitto callbacks registered**: `on_connect_callback`, `on_disconnect_callback`, `on_subscribe_callback` (all pre-existing), plus `on_publish_callback` and `on_unsubscribe_callback` (new in v1.3.0).

**Thread safety**: Dictionary writes happen on `mosq_lua_queue`. Dictionary reads in mosquitto callbacks are synchronous (mosquitto thread), then the ref is captured and used on main queue. The `mid` is assigned synchronously by `mosquitto_subscribe/publish/unsubscribe`, and the callback fires only after the broker responds — no race.

**Cleanup**: `cleanupCallbackDictionaries()` iterates all dictionaries, calls `CoronaLuaDeleteRef()` for each stored ref, and clears all dictionaries. Called in `connect_broker()` (new connection) and `Finalizer()`.

### Android (LuaLoader.java)

- **Standard Corona plugin pattern**: `LuaLoader` implements `JavaFunction`, registers Lua functions in `invoke()`
- **Paho `MqttAsyncClient`** with `MemoryPersistence` for non-blocking operations
- **`MqttCallbackExtended`** for lifecycle events: `connectComplete`, `connectionLost`, `messageArrived`
- **`IMqttActionListener`** for per-operation callbacks (connect, subscribe, publish, unsubscribe, disconnect)
- **Per-operation callbacks (v1.3.0)**: Paho natively supports `IMqttActionListener` per operation, making per-op callbacks simpler than Apple. Each function reads an optional Lua function arg → `CoronaLua.newRef()` → fires in the listener's `onSuccess`/`onFailure` → `CoronaLua.deleteRef()`.
- **New dispatch helpers (v1.3.0)**: `dispatchPublishedEvent()`, `dispatchUnsubscribedEvent()`, `dispatchPerOpCallback()`, `dispatchPerOpSubscribedCallback()`, `dispatchPerOpUnsubscribedCallback()`, `dispatchPerOpPublishedCallback()`, `dispatchPerOpDisconnectCallback()`
- **Dispatch to Lua**: All events dispatched via `CoronaRuntimeTask` with null-check on `CoronaEnvironment.getCoronaActivity()`
- **Exception logging**: All catch blocks use `Log.e("SolarMQTT", ...)` — no swallowed exceptions
- **TLS**: Uses `ssl://` vs `tcp://` URI protocol; Paho leverages system trust store automatically

### libmosquitto Source Embedding

The `shared_mosquitto/` directory contains source files from the Eclipse Mosquitto `lib/`, `include/`, `libcommon/`, and `deps/` directories. These compile as part of each Xcode target (same pattern as Jetfire `.m` files in SolarWebSockets).

**Custom `config.h`**:
- `#define WITH_THREADING` — required for `mosquitto_loop_start()`
- `#define WITH_TLS` — TLS/SSL support via OpenSSL (v1.1.0+)
- `#undef WITH_SRV`, `WITH_SOCKS`, `WITH_BROKER`, `WITH_WEBSOCKETS`, `WITH_ADNS`

**Files NOT compiled** (present but excluded from Xcode targets):
- `srv_mosq.c` — SRV lookup disabled
- `socks_mosq.c` — SOCKS proxy disabled
- `http_client.c`, `net_ws.c`, `extended_auth.c` — not needed
- `cjson_common.c`, `base64_common.c`, `password_common.c` — libcommon utilities not used

**Files compiled for TLS** (added in v1.1.0):
- `tls_mosq.c` — TLS connection handling
- `net_mosq_ocsp.c` — OCSP stapling support
- `file_common.c` — file operations for CA certificate loading
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
- `$(SRCROOT)/../shared_openssl/include` — OpenSSL headers (v1.1.0+)

**Linked frameworks** (v1.1.0+):
- `ssl.xcframework` — OpenSSL SSL library
- `crypto.xcframework` — OpenSSL crypto library

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

**Build check**: main.lua has `EXPECTED_BUILD` constant that must match `mqtt.BUILD` from the plugin. If mismatched, shows red error screen and refuses to run tests. Prevents testing stale dylibs.

Buttons for testing all functionality:
- **Connect** / **Disconnect** — basic lifecycle (port 1883)
- **Subscribe** / **Unsubscribe** — topic subscription
- **Publish QoS 0** / **Publish QoS 1** — message publishing
- **Bad Host** — error handling (connect to nonexistent broker)
- **Sub+Pub Test** — connect → subscribe → publish → receive round-trip
- **TLS Connect** — TLS connection to port 8883
- **TLS Sub+Pub** — TLS round-trip test
- **TLS Bad Auth** — TLS with wrong credentials against private broker (should get auth rejected)
- **Run All Tests** — event-driven test suite with visual traffic light display (20 tests)

**Two brokers used for testing:**
- `broker.emqx.io` — public EMQX broker (no auth required, accepts any credentials)
- `xbb61507.ala.eu-central-1.emqxsl.com` — private EMQX Cloud broker (TLS-only, user/pass: `solar2d`/`solar2d`)

Configurable at top of file: `MQTT_BROKER`, `MQTT_PORT`, `MQTT_PORT_TLS`, `MQTT_PRIVATE_BROKER`, `MQTT_PRIVATE_PORT`, `MQTT_PRIVATE_USER`, `MQTT_PRIVATE_PASS`

On-screen scrolling event log shows all MQTT events with timestamps. All `addLog()` calls print with `CONSOLE:` prefix to distinguish from native `SolarMQTT:` debug lines.

### Visual Test Page (v1.2.0+, expanded v1.3.0)

"Run All Tests" switches from the button menu to a full-screen test overlay with traffic light indicators per test. Each test has a pass condition validated by the MQTT event listener.

**v1.3.0**: Expanded from 11 to 20 tests. Tests now cover all MQTT 3.1.1 server acknowledgements individually (CONNACK, SUBACK, PUBACK, UNSUBACK) plus per-operation callback verification. Compact UI with 19px row height and 10px font to fit 20 rows.

| # | Group | Test | Pass condition |
|---|-------|------|---------------|
| 1 | Public | Connect | `connected` event |
| 2 | Public | Subscribe | `subscribed` event |
| 3 | Public | Pub+Recv | `published` + `message` with matching payload |
| 4 | Public | Unsubscribe | `unsubscribed` event |
| 5 | Public | Disconnect | `disconnected` with errorCode==0 |
| 6 | TLS | Connect | `connected` event |
| 7 | TLS | Subscribe | `subscribed` event |
| 8 | TLS | Pub+Recv | `published` + `message` with matching payload |
| 9 | TLS | Unsubscribe | `unsubscribed` event |
| 10 | TLS | Disconnect | `disconnected` with errorCode==0 |
| 11 | Auth | Bad Auth | `error` event (connection refused) |
| 12 | Auth | Connect | `connected` event |
| 13 | Auth | Subscribe | `subscribed` event |
| 14 | Auth | Pub+Recv | `published` + `message` with matching payload |
| 15 | Auth | Unsubscribe | `unsubscribed` event |
| 16 | Auth | Disconnect | `disconnected` with errorCode==0 |
| 17 | Callbacks | Connect+Sub | `connected` + `subscribed` via `onConnect` callback, fresh non-TLS connection |
| 18 | Callbacks | Pub Callback | per-op callback fires on publish (`callbackFired` flag) |
| 19 | Callbacks | Unsub Callback | per-op callback fires on unsubscribe (`callbackFired` flag) |
| 20 | Error | Bad Host | `error` event |

**Callback test mechanism (tests 17-19)**: The test action passes a Lua function to `subscribe()/publish()/unsubscribe()`. Inside that function, `testState.callbackFired = true` is set. The test's `validate` function checks that the flag is `true` when the corresponding global event arrives.

**`afterConnect` pattern**: Test 17 uses `afterConnect` function on the test definition to subscribe after the connect event arrives, since it needs a fresh connection first.

Indicator colours: grey (pending), amber (running), green (pass), red (fail/timeout). Summary line shows "X/20 PASSED" or "X/20 PASSED, Y FAILED". "Back to Menu" button returns to the interactive button view. Works on devices without console access (iPads, Apple TV).

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

11. **`cast from pointer to smaller type 'int' loses information`** — `CoronaLuaRef` is `void*` (8 bytes on arm64) but was being cast to `int` (4 bytes) when boxing into `NSNumber` via `@((int)callbackRef)`. Fixed by using `@((intptr_t)callbackRef)` for boxing and `(CoronaLuaRef)(intptr_t)[refNum integerValue]` for unboxing.

### Correct mosquitto connect sequence (PluginSolarMQTT.mm)

The connect sequence must be:
1. `mosquitto_new()` — create client
2. Set callbacks (`mosquitto_connect_callback_set`, etc.)
3. `mosquitto_username_pw_set()` — if credentials provided
4. `mosquitto_tls_set()` — if TLS enabled (v1.1.0+)
5. `mosquitto_will_set()` — if LWT provided (v1.2.0+)
6. `mosquitto_loop_start()` — start the network thread (**before** connect)
7. `mosquitto_connect_async()` — initiate TCP connection (loop thread handles it)

**Do NOT call `mosquitto_threaded_set(true)`** — that sets `mosq_ts_external` which conflicts with `loop_start()`.

### Disconnect pattern (build 5+)

**Problem**: `disconnect_broker()` needs to call `mosquitto_loop_stop()` after `mosquitto_disconnect()`, but:
- `loop_stop(false)` (graceful/pthread_join) **hangs** after TLS disconnect — known mosquitto bugs (Issues #2328, #2594, #2421) where the loop thread gets stuck in OpenSSL error processing
- `loop_stop(true)` (force/pthread_cancel) works but may kill the loop thread before `on_disconnect_callback` fires

**Research findings**: The `on_disconnect_callback` fires during `mosquitto_loop()` on the loop thread (in `mosquitto__loop_rc_handle()`), BEFORE `mosquitto_loop_forever()` returns and BEFORE `loop_stop` runs. The official mosquitto `pub_client.c` uses Pattern B: disconnect, poll for callback, then `loop_stop(false)`. However, `loop_stop(false)` with TLS has known hanging bugs. `MOSQ_ERR_INVAL` from `loop_stop` after disconnect is expected (Issue #2905 — loop thread may self-terminate before `loop_stop` can join it).

**Current approach** (Pattern C — force-stop): `disconnect() → loop_stop(true) → destroy()` with `mosq_disconnect_event_sent` flag. The callback usually fires before `pthread_cancel` kills the thread. If it doesn't, `disconnect_broker()` dispatches the Lua event manually. This is the pragmatic choice for TLS connections given the known hanging bugs.

**Correct call order**: Always `mosquitto_disconnect()` BEFORE `mosquitto_loop_stop()`. The Finalizer was fixed in build 6 (was previously calling them in the wrong order).

### Test results (build 9)

All 20 tests pass. Tests run event-driven with per-test timeouts and visual traffic light indicators:
- Tests 1-5: Public broker — connect, subscribe, publish+receive (PUBACK + message), unsubscribe (UNSUBACK), disconnect ✓
- Tests 6-10: TLS (public broker) — same 5-step pattern ✓
- Test 11: TLS bad auth against private broker — CONNACK rc=5 "Connection Refused: not authorised" ✓
- Tests 12-16: Private broker with auth — connect, subscribe, publish+receive, unsubscribe, disconnect ✓
- Test 17: Per-op connect callback — fresh non-TLS connection with `onConnect`, then subscribe ✓
- Test 18: Per-op publish callback — `callbackFired` flag verified ✓
- Test 19: Per-op unsubscribe callback — `callbackFired` flag verified ✓
- Test 20: Bad host — "Lookup error" ✓

All disconnect events reach Lua correctly via the `mosq_disconnect_event_sent` flag pattern.

## Cross-Machine Plugin Installation

An installer script (`install-plugins.sh`) is available for quickly deploying the latest macOS simulator plugins across multiple Macs:

```bash
bash install-plugins.sh
```

The script uses `curl` (no `gh` CLI required) to download the latest releases from GitHub using `releases/latest/download/` URLs, extracts the dylibs, ad-hoc codesigns them, and installs to `~/Library/Application Support/Corona/Simulator/Plugins/`. The script lives in the shared Dropbox folder alongside the Corona projects.

## Future Enhancements

- **App lifecycle handling (background/foreground)** — Critical for PlatopusDisplay KDS on iPads. Plugin should detect background (`UIApplicationDidEnterBackgroundNotification` on Apple, `onSuspended()` on Android), fire `backgrounding` event to Lua (app publishes "offline"), clean disconnect (so will doesn't fire), then auto-reconnect on foreground with saved config and re-subscribe all active topics. Needs to store: last connect config + active subscription list.
- **Auto-reconnect with backoff** — For in-foreground network blips. libmosquitto has `mosquitto_reconnect_async()`, Paho has `setAutomaticReconnect(true)`.
- **MQTT 5.0 features** — libmosquitto supports MQTT 5.0; expose reason codes, properties
