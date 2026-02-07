//
//  PluginSolarMQTT.mm
//  SolarMQTT Plugin for Solar2D
//
//  MQTT client plugin using libmosquitto (Eclipse Mosquitto C library).
//  Single connection model — one MQTT broker connection at a time.
//
//  Copyright (c) 2026 Platopus Systems. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <TargetConditionals.h>
#import "PluginSolarMQTT.h"

#include <CoronaRuntime.h>
#include <dispatch/dispatch.h>

#include "mosquitto.h"

// Embedded Mozilla CA certificate bundle for iOS/tvOS
#if !TARGET_OS_OSX
#include "cacert.h"
#endif

// ----------------------------------------------------------------------------
// TLS: CA certificate bundle helpers
// ----------------------------------------------------------------------------

static NSString *cachedCABundlePath = nil;

#if TARGET_OS_OSX

static NSString *getSystemCABundlePath(void)
{
	if (cachedCABundlePath && [[NSFileManager defaultManager] fileExistsAtPath:cachedCABundlePath]) {
		return cachedCABundlePath;
	}

	NSString *bundlePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"solarmqtt-ca-bundle.pem"];

	CFArrayRef certs = NULL;
	OSStatus status = SecTrustCopyAnchorCertificates(&certs);
	if (status != errSecSuccess || certs == NULL) {
		NSLog(@"SolarMQTT: Failed to get system root certificates (status=%d)", (int)status);
		return nil;
	}

	NSMutableString *pemBundle = [NSMutableString string];
	CFIndex count = CFArrayGetCount(certs);

	for (CFIndex i = 0; i < count; i++) {
		SecCertificateRef cert = (SecCertificateRef)CFArrayGetValueAtIndex(certs, i);
		CFDataRef certData = SecCertificateCopyData(cert);
		if (certData == NULL) continue;

		NSData *derData = (__bridge NSData *)certData;
		NSString *base64 = [derData base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
		[pemBundle appendString:@"-----BEGIN CERTIFICATE-----\n"];
		[pemBundle appendString:base64];
		[pemBundle appendString:@"\n-----END CERTIFICATE-----\n\n"];
		CFRelease(certData);
	}
	CFRelease(certs);

	NSError *error = nil;
	if (![pemBundle writeToFile:bundlePath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
		NSLog(@"SolarMQTT: Failed to write CA bundle: %@", error);
		return nil;
	}

	NSLog(@"SolarMQTT: Exported %ld system root certificates", (long)count);
	cachedCABundlePath = bundlePath;
	return bundlePath;
}

#else  // iOS / tvOS

static NSString *getSystemCABundlePath(void)
{
	if (cachedCABundlePath && [[NSFileManager defaultManager] fileExistsAtPath:cachedCABundlePath]) {
		return cachedCABundlePath;
	}

	NSString *bundlePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"solarmqtt-cacert.pem"];

	NSString *certData = [NSString stringWithUTF8String:cacert_pem];
	NSError *error = nil;
	if (![certData writeToFile:bundlePath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
		NSLog(@"SolarMQTT: Failed to write embedded CA bundle: %@", error);
		return nil;
	}

	NSLog(@"SolarMQTT: Using embedded Mozilla CA certificates");
	cachedCABundlePath = bundlePath;
	return bundlePath;
}

#endif

// ----------------------------------------------------------------------------
// Global state — single connection model (matches PlatopusDisplay usage)
// ----------------------------------------------------------------------------

static struct mosquitto *mosq_client = NULL;

// Lua state tracking
static lua_State *mosq_L = NULL;
static CoronaLuaRef mosq_fListener = NULL;
static BOOL mosq_L_valid = NO;
static int mosq_L_generation = 0;

// Serial dispatch queue for thread-safe Lua function calls
static dispatch_queue_t mosq_lua_queue = NULL;

// Track whether we've ever connected (to suppress spurious pre-connect disconnect events)
static BOOL mosq_ever_connected = NO;

// Track whether disconnect was user-initiated (so callback knows to clean up)
static BOOL mosq_user_disconnect = NO;

// Track whether disconnect event was already dispatched to Lua
static BOOL mosq_disconnect_event_sent = NO;

// Per-operation callback tracking (v1.3.0+)
// mid → CoronaLuaRef dictionaries for mapping message IDs to per-operation Lua callbacks
static NSMutableDictionary *mosq_publish_callbacks = nil;     // mid → @(CoronaLuaRef)
static NSMutableDictionary *mosq_subscribe_callbacks = nil;   // mid → @(CoronaLuaRef)
static NSMutableDictionary *mosq_unsubscribe_callbacks = nil; // mid → @(CoronaLuaRef)

// mid → topic dictionaries for tracking which topic each operation relates to
static NSMutableDictionary *mosq_subscribe_topics = nil;      // mid → NSString
static NSMutableDictionary *mosq_unsubscribe_topics = nil;    // mid → NSString

// Single-slot callbacks for connect and disconnect (only one at a time)
static CoronaLuaRef mosq_connect_callback = NULL;
static CoronaLuaRef mosq_disconnect_callback = NULL;

// ----------------------------------------------------------------------------
// Forward declarations for mosquitto callbacks
// ----------------------------------------------------------------------------

static void on_connect_callback(struct mosquitto *mosq, void *obj, int rc);
static void on_disconnect_callback(struct mosquitto *mosq, void *obj, int rc);
static void on_message_callback(struct mosquitto *mosq, void *obj, const struct mosquitto_message *msg);
static void on_subscribe_callback(struct mosquitto *mosq, void *obj, int mid, int qos_count, const int *granted_qos);
static void on_publish_callback(struct mosquitto *mosq, void *obj, int mid);
static void on_unsubscribe_callback(struct mosquitto *mosq, void *obj, int mid);
static void on_log_callback(struct mosquitto *mosq, void *obj, int level, const char *str);

// Helper to clean up all per-operation callback dictionaries
static void cleanupCallbackDictionaries(void);

// ----------------------------------------------------------------------------

class PluginSolarMQTT
{
	public:
		typedef PluginSolarMQTT Self;

	public:
		static const char kName[];
		static const char kEvent[];

	protected:
		PluginSolarMQTT();

	public:
		bool Initialize( CoronaLuaRef listener );

	public:
		CoronaLuaRef GetListener() const { return fListener; }

	public:
		static int Open( lua_State *L );

	protected:
		static int Finalizer( lua_State *L );

	public:
		static Self *ToLibrary( lua_State *L );

	public:
		static int init( lua_State *L );
		static int connect_broker( lua_State *L );
		static int disconnect_broker( lua_State *L );
		static int subscribe_topic( lua_State *L );
		static int unsubscribe_topic( lua_State *L );
		static int publish_message( lua_State *L );

	private:
		CoronaLuaRef fListener;
};

// ----------------------------------------------------------------------------

const char PluginSolarMQTT::kName[] = "plugin.solarmqtt";
const char PluginSolarMQTT::kEvent[] = "pluginsolarmqtt";

PluginSolarMQTT::PluginSolarMQTT()
:	fListener( NULL )
{
}

bool
PluginSolarMQTT::Initialize( CoronaLuaRef listener )
{
	bool result = ( NULL == fListener );

	if ( result )
	{
		fListener = listener;
		mosq_fListener = fListener;
	}

	return result;
}

int
PluginSolarMQTT::Open( lua_State *L )
{
	// Register __gc callback
	const char kMetatableName[] = __FILE__;
	CoronaLuaInitializeGCMetatable( L, kMetatableName, Finalizer );

	// Functions in library
	const luaL_Reg kVTable[] =
	{
		{ "init", init },
		{ "connect", connect_broker },
		{ "disconnect", disconnect_broker },
		{ "subscribe", subscribe_topic },
		{ "unsubscribe", unsubscribe_topic },
		{ "publish", publish_message },

		{ NULL, NULL }
	};

	mosq_L = L;
	mosq_L_valid = YES;
	mosq_L_generation++;

	// Initialize libmosquitto (safe to call multiple times)
	static BOOL mosq_lib_initialized = NO;
	if (!mosq_lib_initialized) {
		mosquitto_lib_init();
		mosq_lib_initialized = YES;
	}

	NSLog(@"SolarMQTT: Platopus v1.3.0 loaded (generation %d)", mosq_L_generation);

	// Create serial queue for thread-safe operations
	if (mosq_lua_queue == NULL) {
		mosq_lua_queue = dispatch_queue_create("com.solarmqtt.lua", DISPATCH_QUEUE_SERIAL);
	}

	// Set library as upvalue for each library function
	Self *library = new Self;
	CoronaLuaPushUserdata( L, library, kMetatableName );

	luaL_openlib( L, kName, kVTable, 1 );

	// Expose plugin version and build number to Lua
	lua_pushstring(L, "1.3.0");
	lua_setfield(L, -2, "VERSION");

	lua_pushinteger(L, 9);
	lua_setfield(L, -2, "BUILD");

	return 1;
}

int
PluginSolarMQTT::Finalizer( lua_State *L )
{
	NSLog(@"SolarMQTT: Finalizer called");

	// Mark Lua state as invalid before cleanup
	mosq_L_valid = NO;

	// Clean up active MQTT connection
	if (mosq_client != NULL) {
		NSLog(@"SolarMQTT: Finalizer cleaning up active MQTT connection");
		mosquitto_disconnect(mosq_client);
		mosquitto_loop_stop(mosq_client, true);  // force stop
		mosquitto_destroy(mosq_client);
		mosq_client = NULL;
	}

	// Clean up per-operation callback dictionaries
	cleanupCallbackDictionaries();

	Self *library = (Self *)CoronaLuaToUserdata( L, 1 );

	CoronaLuaDeleteRef( L, library->GetListener() );

	delete library;

	return 0;
}

PluginSolarMQTT *
PluginSolarMQTT::ToLibrary( lua_State *L )
{
	Self *library = (Self *)CoronaLuaToUserdata( L, lua_upvalueindex( 1 ) );
	return library;
}

// [Lua] mqtt.init( listener )
int
PluginSolarMQTT::init( lua_State *L )
{
	int listenerIndex = 1;

	if ( CoronaLuaIsListener( L, listenerIndex, kEvent ) )
	{
		Self *library = ToLibrary( L );

		CoronaLuaRef listener = CoronaLuaNewRef( L, listenerIndex );
		library->Initialize( listener );
	}

	return 0;
}

// [Lua] mqtt.connect({ broker=, port=, clientId=, username=, password=, cleanSession=, keepAlive= })
int
PluginSolarMQTT::connect_broker( lua_State *L )
{
	if (!lua_istable(L, 1)) {
		NSLog(@"SolarMQTT: connect() requires a table argument");
		return 0;
	}

	// Read options from Lua table
	lua_getfield(L, 1, "broker");
	const char *broker = luaL_optstring(L, -1, "localhost");
	lua_pop(L, 1);

	lua_getfield(L, 1, "port");
	int port = (int)luaL_optinteger(L, -1, 1883);
	lua_pop(L, 1);

	lua_getfield(L, 1, "clientId");
	const char *clientId = luaL_optstring(L, -1, NULL);
	lua_pop(L, 1);

	lua_getfield(L, 1, "username");
	const char *username = lua_tostring(L, -1);  // may be nil
	lua_pop(L, 1);

	lua_getfield(L, 1, "password");
	const char *password = lua_tostring(L, -1);  // may be nil
	lua_pop(L, 1);

	lua_getfield(L, 1, "cleanSession");
	bool cleanSession = lua_isboolean(L, -1) ? lua_toboolean(L, -1) : true;
	lua_pop(L, 1);

	lua_getfield(L, 1, "keepAlive");
	int keepAlive = (int)luaL_optinteger(L, -1, 60);
	lua_pop(L, 1);

	lua_getfield(L, 1, "useTLS");
	bool useTLS = lua_isboolean(L, -1) ? lua_toboolean(L, -1) : (port == 8883);
	lua_pop(L, 1);

	lua_getfield(L, 1, "caFile");
	const char *caFile = lua_tostring(L, -1);
	lua_pop(L, 1);

	lua_getfield(L, 1, "tlsInsecure");
	bool tlsInsecure = lua_isboolean(L, -1) && lua_toboolean(L, -1);
	lua_pop(L, 1);

	// Read optional onConnect callback
	CoronaLuaRef connectCallbackRef = NULL;
	lua_getfield(L, 1, "onConnect");
	if (lua_isfunction(L, -1)) {
		connectCallbackRef = CoronaLuaNewRef(L, -1);
	}
	lua_pop(L, 1);

	// Read optional Last Will and Testament (LWT)
	const char *willTopic = NULL;
	const char *willPayload = NULL;
	int willQos = 0;
	bool willRetain = false;
	bool hasWill = false;

	lua_getfield(L, 1, "will");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "topic");
		willTopic = lua_tostring(L, -1);
		lua_pop(L, 1);

		lua_getfield(L, -1, "payload");
		willPayload = luaL_optstring(L, -1, "");
		lua_pop(L, 1);

		lua_getfield(L, -1, "qos");
		willQos = (int)luaL_optinteger(L, -1, 0);
		lua_pop(L, 1);

		lua_getfield(L, -1, "retain");
		willRetain = lua_isboolean(L, -1) ? lua_toboolean(L, -1) : false;
		lua_pop(L, 1);

		if (willTopic != NULL) {
			hasWill = true;
		}
	}
	lua_pop(L, 1);

	// Capture generation for stale callback detection
	int connectGeneration = mosq_L_generation;

	// Copy strings for async use
	NSString *brokerStr = [NSString stringWithUTF8String:broker];
	NSString *clientIdStr = clientId ? [NSString stringWithUTF8String:clientId] : nil;
	NSString *usernameStr = username ? [NSString stringWithUTF8String:username] : nil;
	NSString *passwordStr = password ? [NSString stringWithUTF8String:password] : nil;
	NSString *caFileStr = caFile ? [NSString stringWithUTF8String:caFile] : nil;
	NSString *willTopicStr = hasWill ? [NSString stringWithUTF8String:willTopic] : nil;
	NSString *willPayloadStr = hasWill ? [NSString stringWithUTF8String:willPayload] : nil;

	dispatch_async(mosq_lua_queue, ^{
		mosq_ever_connected = NO;
		mosq_user_disconnect = NO;
		mosq_disconnect_event_sent = NO;

		// Clean up and re-initialize per-operation callback dictionaries
		cleanupCallbackDictionaries();
		mosq_publish_callbacks = [NSMutableDictionary new];
		mosq_subscribe_callbacks = [NSMutableDictionary new];
		mosq_unsubscribe_callbacks = [NSMutableDictionary new];
		mosq_subscribe_topics = [NSMutableDictionary new];
		mosq_unsubscribe_topics = [NSMutableDictionary new];
		mosq_connect_callback = connectCallbackRef;

		// Clean up existing connection if any
		if (mosq_client != NULL) {
			NSLog(@"SolarMQTT: Disconnecting old client before new connect");
			mosquitto_disconnect(mosq_client);
			mosquitto_loop_stop(mosq_client, true);
			mosquitto_destroy(mosq_client);
			mosq_client = NULL;
		}

		// Check generation — Finalizer may have run while we waited
		if (!mosq_L_valid || mosq_L_generation != connectGeneration) {
			NSLog(@"SolarMQTT: Lua state changed before connect, aborting (gen %d vs %d)", connectGeneration, mosq_L_generation);
			return;
		}

		// Create new mosquitto client
		mosq_client = mosquitto_new(
			clientIdStr ? [clientIdStr UTF8String] : NULL,
			cleanSession,
			(void *)(intptr_t)connectGeneration  // pass generation as userdata
		);

		if (mosq_client == NULL) {
			NSLog(@"SolarMQTT: Failed to create mosquitto client");
			dispatch_async(dispatch_get_main_queue(), ^{
				if (!mosq_L_valid || mosq_L_generation != connectGeneration) return;
				CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
				lua_pushstring(mosq_L, "error");
				lua_setfield(mosq_L, -2, "name");
				lua_pushstring(mosq_L, "Failed to create MQTT client");
				lua_setfield(mosq_L, -2, "errorMessage");
				CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);
			});
			return;
		}

		// Set callbacks
		mosquitto_connect_callback_set(mosq_client, on_connect_callback);
		mosquitto_disconnect_callback_set(mosq_client, on_disconnect_callback);
		mosquitto_message_callback_set(mosq_client, on_message_callback);
		mosquitto_subscribe_callback_set(mosq_client, on_subscribe_callback);
		mosquitto_publish_callback_set(mosq_client, on_publish_callback);
		mosquitto_unsubscribe_callback_set(mosq_client, on_unsubscribe_callback);
		mosquitto_log_callback_set(mosq_client, on_log_callback);

		// Set credentials
		if (usernameStr) {
			mosquitto_username_pw_set(mosq_client,
				[usernameStr UTF8String],
				passwordStr ? [passwordStr UTF8String] : NULL);
		}

		// Configure TLS if requested
		if (useTLS) {
			NSString *caPath = caFileStr ?: getSystemCABundlePath();
			if (caPath) {
				int tls_rc = mosquitto_tls_set(mosq_client,
					[caPath UTF8String], NULL, NULL, NULL, NULL);
				if (tls_rc != MOSQ_ERR_SUCCESS) {
					NSLog(@"SolarMQTT: TLS setup failed: %s", mosquitto_strerror(tls_rc));
					dispatch_async(dispatch_get_main_queue(), ^{
						if (!mosq_L_valid || mosq_L_generation != connectGeneration) return;
						CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
						lua_pushstring(mosq_L, "error");
						lua_setfield(mosq_L, -2, "name");
						lua_pushstring(mosq_L, "TLS setup failed");
						lua_setfield(mosq_L, -2, "errorMessage");
						CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);
					});
					mosquitto_destroy(mosq_client);
					mosq_client = NULL;
					return;
				}
			}
			if (tlsInsecure) {
				mosquitto_tls_insecure_set(mosq_client, true);
			}
			NSLog(@"SolarMQTT: TLS enabled for connection");
		}

		// Set Last Will and Testament (LWT) if provided
		if (hasWill && willTopicStr) {
			const char *willPayloadCStr = [willPayloadStr UTF8String];
			int will_rc = mosquitto_will_set(mosq_client,
				[willTopicStr UTF8String],
				(int)strlen(willPayloadCStr),
				willPayloadCStr,
				willQos,
				willRetain);
			if (will_rc != MOSQ_ERR_SUCCESS) {
				NSLog(@"SolarMQTT: Will set failed: %s", mosquitto_strerror(will_rc));
			} else {
				NSLog(@"SolarMQTT: Will set on topic '%@' qos=%d retain=%s",
					  willTopicStr, willQos, willRetain ? "YES" : "NO");
			}
		}

		// Note: do NOT call mosquitto_threaded_set(true) here.
		// That sets mosq->threaded = mosq_ts_external, but loop_start()
		// requires mosq_ts_none so it can manage its own thread.

		// Start the network loop thread BEFORE connect_async.
		// connect_async needs the loop running to handle the TCP connection.
		int rc = mosquitto_loop_start(mosq_client);
		if (rc != MOSQ_ERR_SUCCESS) {
			NSLog(@"SolarMQTT: loop_start failed: %s", mosquitto_strerror(rc));
			dispatch_async(dispatch_get_main_queue(), ^{
				if (!mosq_L_valid || mosq_L_generation != connectGeneration) return;
				CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
				lua_pushstring(mosq_L, "error");
				lua_setfield(mosq_L, -2, "name");
				lua_pushstring(mosq_L, "loop_start failed");
				lua_setfield(mosq_L, -2, "errorMessage");
				CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);
			});
			mosquitto_destroy(mosq_client);
			mosq_client = NULL;
			return;
		}

		// Now connect asynchronously — the loop thread handles the TCP connection
		rc = mosquitto_connect_async(mosq_client,
			[brokerStr UTF8String],
			port,
			keepAlive);

		if (rc != MOSQ_ERR_SUCCESS) {
			NSLog(@"SolarMQTT: Connect failed: %s", mosquitto_strerror(rc));
			mosquitto_loop_stop(mosq_client, true);
			dispatch_async(dispatch_get_main_queue(), ^{
				if (!mosq_L_valid || mosq_L_generation != connectGeneration) return;
				CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
				lua_pushstring(mosq_L, "error");
				lua_setfield(mosq_L, -2, "name");
				lua_pushstring(mosq_L, mosquitto_strerror(rc));
				lua_setfield(mosq_L, -2, "errorMessage");
				CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);
			});
			mosquitto_destroy(mosq_client);
			mosq_client = NULL;
			return;
		}

		NSLog(@"SolarMQTT: Connecting to %@:%d (TLS=%s)", brokerStr, port, useTLS ? "YES" : "NO");
	});

	return 0;
}

// [Lua] mqtt.disconnect( [callback] )
int
PluginSolarMQTT::disconnect_broker( lua_State *L )
{
	// Optional disconnect callback
	CoronaLuaRef disconnectRef = NULL;
	if (lua_isfunction(L, 1)) {
		disconnectRef = CoronaLuaNewRef(L, 1);
	}

	int gen = mosq_L_generation;

	dispatch_async(mosq_lua_queue, ^{
		mosq_disconnect_callback = disconnectRef;
		if (mosq_client != NULL) {
			NSLog(@"SolarMQTT: Disconnecting");
			mosq_user_disconnect = YES;
			mosq_disconnect_event_sent = NO;
			mosquitto_disconnect(mosq_client);
			// Force-stop the loop thread. We can't use graceful stop (false)
			// because after TLS disconnect, the loop thread hangs in OpenSSL
			// error processing. The on_disconnect_callback may or may not have
			// fired before the force-stop — we check the flag afterwards.
			mosquitto_loop_stop(mosq_client, true);
			mosquitto_destroy(mosq_client);
			mosq_client = NULL;

			// If the callback didn't fire (force-stopped before it ran),
			// dispatch the disconnect event to Lua ourselves.
			if (!mosq_disconnect_event_sent) {
				NSLog(@"SolarMQTT: Callback didn't fire, dispatching disconnect event");
				CoronaLuaRef disconnectRef = mosq_disconnect_callback;
				mosq_disconnect_callback = NULL;
				dispatch_async(dispatch_get_main_queue(), ^{
					if (!mosq_L_valid || mosq_L_generation != gen) {
						if (disconnectRef) CoronaLuaDeleteRef(mosq_L, disconnectRef);
						return;
					}

					CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
					lua_pushstring(mosq_L, "disconnected");
					lua_setfield(mosq_L, -2, "name");
					lua_pushinteger(mosq_L, 0);
					lua_setfield(mosq_L, -2, "errorCode");
					lua_pushstring(mosq_L, "Clean disconnect");
					lua_setfield(mosq_L, -2, "errorMessage");
					CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);

					// Fire per-operation callback if provided
					if (disconnectRef) {
						CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
						lua_pushstring(mosq_L, "disconnected");
						lua_setfield(mosq_L, -2, "name");
						lua_pushinteger(mosq_L, 0);
						lua_setfield(mosq_L, -2, "errorCode");
						lua_pushstring(mosq_L, "Clean disconnect");
						lua_setfield(mosq_L, -2, "errorMessage");
						CoronaLuaDispatchEvent(mosq_L, disconnectRef, 0);
						CoronaLuaDeleteRef(mosq_L, disconnectRef);
					}
				});
			}
		}
	});

	return 0;
}

// [Lua] mqtt.subscribe( topic, qos [, callback] )
int
PluginSolarMQTT::subscribe_topic( lua_State *L )
{
	const char *topic = luaL_checkstring(L, 1);
	int qos = (int)luaL_optinteger(L, 2, 0);

	if (!topic) return 0;

	// Optional per-operation callback (3rd arg)
	CoronaLuaRef callbackRef = NULL;
	if (lua_isfunction(L, 3)) {
		callbackRef = CoronaLuaNewRef(L, 3);
	}

	// Copy topic string for async use
	NSString *topicStr = [NSString stringWithUTF8String:topic];

	dispatch_async(mosq_lua_queue, ^{
		if (mosq_client == NULL) {
			NSLog(@"SolarMQTT: subscribe called but not connected");
			if (callbackRef) CoronaLuaDeleteRef(mosq_L, callbackRef);
			return;
		}

		int mid = 0;
		int rc = mosquitto_subscribe(mosq_client, &mid, [topicStr UTF8String], qos);
		if (rc != MOSQ_ERR_SUCCESS) {
			NSLog(@"SolarMQTT: subscribe failed: %s", mosquitto_strerror(rc));
			if (callbackRef) CoronaLuaDeleteRef(mosq_L, callbackRef);
		} else {
			NSLog(@"SolarMQTT: Subscribing to '%@' qos=%d mid=%d", topicStr, qos, mid);
			// Track topic and optional callback by message ID
			[mosq_subscribe_topics setObject:topicStr forKey:@(mid)];
			if (callbackRef) {
				[mosq_subscribe_callbacks setObject:@((intptr_t)callbackRef) forKey:@(mid)];
			}
		}
	});

	return 0;
}

// [Lua] mqtt.unsubscribe( topic [, callback] )
int
PluginSolarMQTT::unsubscribe_topic( lua_State *L )
{
	const char *topic = luaL_checkstring(L, 1);
	if (!topic) return 0;

	// Optional per-operation callback (2nd arg)
	CoronaLuaRef callbackRef = NULL;
	if (lua_isfunction(L, 2)) {
		callbackRef = CoronaLuaNewRef(L, 2);
	}

	NSString *topicStr = [NSString stringWithUTF8String:topic];

	dispatch_async(mosq_lua_queue, ^{
		if (mosq_client == NULL) {
			NSLog(@"SolarMQTT: unsubscribe called but not connected");
			if (callbackRef) CoronaLuaDeleteRef(mosq_L, callbackRef);
			return;
		}

		int mid = 0;
		int rc = mosquitto_unsubscribe(mosq_client, &mid, [topicStr UTF8String]);
		if (rc != MOSQ_ERR_SUCCESS) {
			NSLog(@"SolarMQTT: unsubscribe failed: %s", mosquitto_strerror(rc));
			if (callbackRef) CoronaLuaDeleteRef(mosq_L, callbackRef);
		} else {
			NSLog(@"SolarMQTT: Unsubscribing from '%@' mid=%d", topicStr, mid);
			// Track topic and optional callback by message ID
			[mosq_unsubscribe_topics setObject:topicStr forKey:@(mid)];
			if (callbackRef) {
				[mosq_unsubscribe_callbacks setObject:@((intptr_t)callbackRef) forKey:@(mid)];
			}
		}
	});

	return 0;
}

// [Lua] mqtt.publish( topic, payload, { qos=, retain= } [, callback] )
int
PluginSolarMQTT::publish_message( lua_State *L )
{
	const char *topic = luaL_checkstring(L, 1);
	const char *payload = luaL_optstring(L, 2, "");
	if (!topic) return 0;

	int qos = 0;
	bool retain = false;

	// Optional third argument: options table
	if (lua_istable(L, 3)) {
		lua_getfield(L, 3, "qos");
		qos = (int)luaL_optinteger(L, -1, 0);
		lua_pop(L, 1);

		lua_getfield(L, 3, "retain");
		retain = lua_isboolean(L, -1) ? lua_toboolean(L, -1) : false;
		lua_pop(L, 1);
	}

	// Optional per-operation callback (4th arg)
	CoronaLuaRef callbackRef = NULL;
	if (lua_isfunction(L, 4)) {
		callbackRef = CoronaLuaNewRef(L, 4);
	}

	// Copy strings for async use
	NSString *topicStr = [NSString stringWithUTF8String:topic];
	NSString *payloadStr = [NSString stringWithUTF8String:payload];

	dispatch_async(mosq_lua_queue, ^{
		if (mosq_client == NULL) {
			NSLog(@"SolarMQTT: publish called but not connected");
			if (callbackRef) CoronaLuaDeleteRef(mosq_L, callbackRef);
			return;
		}

		const char *payloadCStr = [payloadStr UTF8String];
		int mid = 0;
		int rc = mosquitto_publish(mosq_client, &mid,
			[topicStr UTF8String],
			(int)strlen(payloadCStr),
			payloadCStr,
			qos,
			retain);

		if (rc != MOSQ_ERR_SUCCESS) {
			NSLog(@"SolarMQTT: publish failed: %s", mosquitto_strerror(rc));
			if (callbackRef) CoronaLuaDeleteRef(mosq_L, callbackRef);
		} else {
			NSLog(@"SolarMQTT: Publishing to '%@' qos=%d mid=%d", topicStr, qos, mid);
			if (callbackRef) {
				[mosq_publish_callbacks setObject:@((intptr_t)callbackRef) forKey:@(mid)];
			}
		}
	});

	return 0;
}

// ============================================================================
// Mosquitto callbacks — these fire on mosquitto's background thread.
// We dispatch to main thread for Lua access.
// ============================================================================

static void on_connect_callback(struct mosquitto *mosq, void *obj, int rc)
{
	int gen = (int)(intptr_t)obj;
	NSLog(@"SolarMQTT: on_connect rc=%d (%s)", rc, mosquitto_connack_string(rc));

	if (rc == 0) {
		mosq_ever_connected = YES;
	} else {
		// Connection refused by broker (bad credentials, not authorised, etc.)
		// Call mosquitto_disconnect to stop libmosquitto's automatic reconnect loop.
		// Safe to call from the callback thread (runs on mosquitto's loop thread).
		NSLog(@"SolarMQTT: Connection refused (rc=%d), stopping reconnect", rc);
		mosquitto_disconnect(mosq);
	}

	// Capture and clear the per-op connect callback ref
	CoronaLuaRef connectRef = mosq_connect_callback;
	mosq_connect_callback = NULL;

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!mosq_L_valid || mosq_L_generation != gen) {
			NSLog(@"SolarMQTT: Stale on_connect callback (gen %d vs %d), skipping", gen, mosq_L_generation);
			if (connectRef) CoronaLuaDeleteRef(mosq_L, connectRef);
			return;
		}

		// Dispatch global event to listener
		CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);

		if (rc == 0) {
			lua_pushstring(mosq_L, "connected");
			lua_setfield(mosq_L, -2, "name");
			lua_pushboolean(mosq_L, false);  // sessionPresent not available in MQTT 3.1.1 callback
			lua_setfield(mosq_L, -2, "sessionPresent");
		} else {
			lua_pushstring(mosq_L, "error");
			lua_setfield(mosq_L, -2, "name");
			lua_pushstring(mosq_L, mosquitto_connack_string(rc));
			lua_setfield(mosq_L, -2, "errorMessage");
			lua_pushinteger(mosq_L, rc);
			lua_setfield(mosq_L, -2, "errorCode");
		}

		CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);

		// Fire per-operation callback if provided
		if (connectRef) {
			CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
			if (rc == 0) {
				lua_pushstring(mosq_L, "connected");
				lua_setfield(mosq_L, -2, "name");
				lua_pushboolean(mosq_L, false);
				lua_setfield(mosq_L, -2, "sessionPresent");
				lua_pushboolean(mosq_L, false);
				lua_setfield(mosq_L, -2, "isError");
			} else {
				lua_pushstring(mosq_L, "error");
				lua_setfield(mosq_L, -2, "name");
				lua_pushstring(mosq_L, mosquitto_connack_string(rc));
				lua_setfield(mosq_L, -2, "errorMessage");
				lua_pushinteger(mosq_L, rc);
				lua_setfield(mosq_L, -2, "errorCode");
				lua_pushboolean(mosq_L, true);
				lua_setfield(mosq_L, -2, "isError");
			}
			CoronaLuaDispatchEvent(mosq_L, connectRef, 0);
			CoronaLuaDeleteRef(mosq_L, connectRef);
		}
	});
}

static void on_disconnect_callback(struct mosquitto *mosq, void *obj, int rc)
{
	int gen = (int)(intptr_t)obj;
	BOOL userDisconnect = mosq_user_disconnect;
	mosq_user_disconnect = NO;

	NSLog(@"SolarMQTT: on_disconnect rc=%d ever_connected=%d user_disconnect=%d", rc, mosq_ever_connected, userDisconnect);

	// Suppress spurious disconnect events that fire before we ever connected.
	// libmosquitto's async connect sometimes triggers a transient disconnect
	// (rc=14/MOSQ_ERR_ERRNO) before the TCP handshake completes — it retries
	// internally and connects successfully. Don't leak this to Lua.
	if (!mosq_ever_connected && !userDisconnect) {
		NSLog(@"SolarMQTT: Pre-connect disconnect (rc=%d), suppressing event", rc);
		return;
	}

	// Cleanup (loop_stop + destroy) is handled by disconnect_broker() after
	// this callback returns. We only dispatch the Lua event here.
	if (userDisconnect) {
		mosq_disconnect_event_sent = YES;
	}

	// Capture and clear the per-op disconnect callback ref
	CoronaLuaRef disconnectRef = mosq_disconnect_callback;
	mosq_disconnect_callback = NULL;

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!mosq_L_valid || mosq_L_generation != gen) {
			NSLog(@"SolarMQTT: Stale on_disconnect callback (gen %d vs %d), skipping", gen, mosq_L_generation);
			if (disconnectRef) CoronaLuaDeleteRef(mosq_L, disconnectRef);
			return;
		}

		// Dispatch global event to listener
		CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);

		lua_pushstring(mosq_L, "disconnected");
		lua_setfield(mosq_L, -2, "name");

		lua_pushinteger(mosq_L, rc);
		lua_setfield(mosq_L, -2, "errorCode");

		if (rc == 0) {
			lua_pushstring(mosq_L, "Clean disconnect");
		} else {
			lua_pushstring(mosq_L, "Unexpected disconnect");
		}
		lua_setfield(mosq_L, -2, "errorMessage");

		CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);

		// Fire per-operation callback if provided
		if (disconnectRef) {
			CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
			lua_pushstring(mosq_L, "disconnected");
			lua_setfield(mosq_L, -2, "name");
			lua_pushinteger(mosq_L, rc);
			lua_setfield(mosq_L, -2, "errorCode");
			lua_pushstring(mosq_L, rc == 0 ? "Clean disconnect" : "Unexpected disconnect");
			lua_setfield(mosq_L, -2, "errorMessage");
			CoronaLuaDispatchEvent(mosq_L, disconnectRef, 0);
			CoronaLuaDeleteRef(mosq_L, disconnectRef);
		}
	});
}

static void on_message_callback(struct mosquitto *mosq, void *obj, const struct mosquitto_message *msg)
{
	int gen = (int)(intptr_t)obj;

	// Copy message data for dispatch to main thread
	NSString *topic = [NSString stringWithUTF8String:msg->topic];
	NSString *payload = msg->payloadlen > 0
		? [[NSString alloc] initWithBytes:msg->payload length:msg->payloadlen encoding:NSUTF8StringEncoding]
		: @"";
	int qos = msg->qos;
	bool retained = msg->retain;

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!mosq_L_valid || mosq_L_generation != gen) {
			return;
		}

		CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);

		lua_pushstring(mosq_L, "message");
		lua_setfield(mosq_L, -2, "name");

		lua_pushstring(mosq_L, [topic UTF8String]);
		lua_setfield(mosq_L, -2, "topic");

		lua_pushstring(mosq_L, payload ? [payload UTF8String] : "");
		lua_setfield(mosq_L, -2, "payload");

		lua_pushinteger(mosq_L, qos);
		lua_setfield(mosq_L, -2, "qos");

		lua_pushboolean(mosq_L, retained);
		lua_setfield(mosq_L, -2, "retained");

		CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);
	});
}

static void on_subscribe_callback(struct mosquitto *mosq, void *obj, int mid, int qos_count, const int *granted_qos)
{
	int gen = (int)(intptr_t)obj;
	NSLog(@"SolarMQTT: on_subscribe mid=%d qos_count=%d", mid, qos_count);

	// Look up topic by message ID (supports concurrent subscribes)
	NSNumber *midKey = @(mid);
	NSString *topic = [mosq_subscribe_topics objectForKey:midKey] ?: @"unknown";
	[mosq_subscribe_topics removeObjectForKey:midKey];

	// Capture and remove per-op callback ref if present
	NSNumber *refNum = [mosq_subscribe_callbacks objectForKey:midKey];
	CoronaLuaRef callbackRef = refNum ? (CoronaLuaRef)(intptr_t)[refNum integerValue] : NULL;
	if (refNum) [mosq_subscribe_callbacks removeObjectForKey:midKey];

	int grantedQos = qos_count > 0 ? granted_qos[0] : 0;

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!mosq_L_valid || mosq_L_generation != gen) {
			if (callbackRef) CoronaLuaDeleteRef(mosq_L, callbackRef);
			return;
		}

		// Dispatch global event to listener
		CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);

		lua_pushstring(mosq_L, "subscribed");
		lua_setfield(mosq_L, -2, "name");

		lua_pushstring(mosq_L, [topic UTF8String]);
		lua_setfield(mosq_L, -2, "topic");

		lua_pushinteger(mosq_L, grantedQos);
		lua_setfield(mosq_L, -2, "grantedQos");

		CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);

		// Fire per-operation callback if provided
		if (callbackRef) {
			CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
			lua_pushstring(mosq_L, "subscribed");
			lua_setfield(mosq_L, -2, "name");
			lua_pushstring(mosq_L, [topic UTF8String]);
			lua_setfield(mosq_L, -2, "topic");
			lua_pushinteger(mosq_L, grantedQos);
			lua_setfield(mosq_L, -2, "grantedQos");
			CoronaLuaDispatchEvent(mosq_L, callbackRef, 0);
			CoronaLuaDeleteRef(mosq_L, callbackRef);
		}
	});
}

static void on_publish_callback(struct mosquitto *mosq, void *obj, int mid)
{
	int gen = (int)(intptr_t)obj;
	NSLog(@"SolarMQTT: on_publish mid=%d", mid);

	// Capture and remove per-op callback ref if present
	NSNumber *midKey = @(mid);
	NSNumber *refNum = [mosq_publish_callbacks objectForKey:midKey];
	CoronaLuaRef callbackRef = refNum ? (CoronaLuaRef)(intptr_t)[refNum integerValue] : NULL;
	if (refNum) [mosq_publish_callbacks removeObjectForKey:midKey];

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!mosq_L_valid || mosq_L_generation != gen) {
			if (callbackRef) CoronaLuaDeleteRef(mosq_L, callbackRef);
			return;
		}

		// Dispatch global "published" event to listener
		CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
		lua_pushstring(mosq_L, "published");
		lua_setfield(mosq_L, -2, "name");
		lua_pushinteger(mosq_L, mid);
		lua_setfield(mosq_L, -2, "mid");
		CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);

		// Fire per-operation callback if provided
		if (callbackRef) {
			CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
			lua_pushstring(mosq_L, "published");
			lua_setfield(mosq_L, -2, "name");
			lua_pushinteger(mosq_L, mid);
			lua_setfield(mosq_L, -2, "mid");
			CoronaLuaDispatchEvent(mosq_L, callbackRef, 0);
			CoronaLuaDeleteRef(mosq_L, callbackRef);
		}
	});
}

static void on_unsubscribe_callback(struct mosquitto *mosq, void *obj, int mid)
{
	int gen = (int)(intptr_t)obj;
	NSLog(@"SolarMQTT: on_unsubscribe mid=%d", mid);

	// Look up topic by message ID
	NSNumber *midKey = @(mid);
	NSString *topic = [mosq_unsubscribe_topics objectForKey:midKey] ?: @"unknown";
	[mosq_unsubscribe_topics removeObjectForKey:midKey];

	// Capture and remove per-op callback ref if present
	NSNumber *refNum = [mosq_unsubscribe_callbacks objectForKey:midKey];
	CoronaLuaRef callbackRef = refNum ? (CoronaLuaRef)(intptr_t)[refNum integerValue] : NULL;
	if (refNum) [mosq_unsubscribe_callbacks removeObjectForKey:midKey];

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!mosq_L_valid || mosq_L_generation != gen) {
			if (callbackRef) CoronaLuaDeleteRef(mosq_L, callbackRef);
			return;
		}

		// Dispatch global "unsubscribed" event to listener
		CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
		lua_pushstring(mosq_L, "unsubscribed");
		lua_setfield(mosq_L, -2, "name");
		lua_pushstring(mosq_L, [topic UTF8String]);
		lua_setfield(mosq_L, -2, "topic");
		CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);

		// Fire per-operation callback if provided
		if (callbackRef) {
			CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);
			lua_pushstring(mosq_L, "unsubscribed");
			lua_setfield(mosq_L, -2, "name");
			lua_pushstring(mosq_L, [topic UTF8String]);
			lua_setfield(mosq_L, -2, "topic");
			CoronaLuaDispatchEvent(mosq_L, callbackRef, 0);
			CoronaLuaDeleteRef(mosq_L, callbackRef);
		}
	});
}

static void on_log_callback(struct mosquitto *mosq, void *obj, int level, const char *str)
{
	// Forward mosquitto internal logs to NSLog for debugging
	NSLog(@"SolarMQTT [mosq %d]: %s", level, str);
}

// Helper to clean up all per-operation callback dictionaries and refs
static void cleanupCallbackDictionaries(void)
{
	// Note: We don't delete individual CoronaLuaRefs here because Lua state
	// may already be invalid during Finalizer. The refs will be GC'd with the state.
	mosq_publish_callbacks = nil;
	mosq_subscribe_callbacks = nil;
	mosq_unsubscribe_callbacks = nil;
	mosq_subscribe_topics = nil;
	mosq_unsubscribe_topics = nil;
	mosq_connect_callback = NULL;
	mosq_disconnect_callback = NULL;
}

// ----------------------------------------------------------------------------

CORONA_EXPORT int luaopen_plugin_solarmqtt( lua_State *L )
{
	return PluginSolarMQTT::Open( L );
}
