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
#import "PluginSolarMQTT.h"

#include <CoronaRuntime.h>
#include <dispatch/dispatch.h>

#include "mosquitto.h"

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

// Track subscribed topic for dispatch to Lua (mosquitto subscribe callback only gets mid)
static char *mosq_pending_subscribe_topic = NULL;

// ----------------------------------------------------------------------------
// Forward declarations for mosquitto callbacks
// ----------------------------------------------------------------------------

static void on_connect_callback(struct mosquitto *mosq, void *obj, int rc);
static void on_disconnect_callback(struct mosquitto *mosq, void *obj, int rc);
static void on_message_callback(struct mosquitto *mosq, void *obj, const struct mosquitto_message *msg);
static void on_subscribe_callback(struct mosquitto *mosq, void *obj, int mid, int qos_count, const int *granted_qos);
static void on_log_callback(struct mosquitto *mosq, void *obj, int level, const char *str);

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

	NSLog(@"SolarMQTT: Platopus v1.0.0 loaded (generation %d)", mosq_L_generation);

	// Create serial queue for thread-safe operations
	if (mosq_lua_queue == NULL) {
		mosq_lua_queue = dispatch_queue_create("com.solarmqtt.lua", DISPATCH_QUEUE_SERIAL);
	}

	// Set library as upvalue for each library function
	Self *library = new Self;
	CoronaLuaPushUserdata( L, library, kMetatableName );

	luaL_openlib( L, kName, kVTable, 1 );

	// Expose plugin version to Lua as SolarMQTT.VERSION
	lua_pushstring(L, "1.0.0");
	lua_setfield(L, -2, "VERSION");

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
		mosquitto_loop_stop(mosq_client, true);  // force stop
		mosquitto_disconnect(mosq_client);
		mosquitto_destroy(mosq_client);
		mosq_client = NULL;
	}

	// Clean up pending subscribe topic
	if (mosq_pending_subscribe_topic != NULL) {
		free(mosq_pending_subscribe_topic);
		mosq_pending_subscribe_topic = NULL;
	}

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

	// Capture generation for stale callback detection
	int connectGeneration = mosq_L_generation;

	// Copy strings for async use
	NSString *brokerStr = [NSString stringWithUTF8String:broker];
	NSString *clientIdStr = clientId ? [NSString stringWithUTF8String:clientId] : nil;
	NSString *usernameStr = username ? [NSString stringWithUTF8String:username] : nil;
	NSString *passwordStr = password ? [NSString stringWithUTF8String:password] : nil;

	dispatch_async(mosq_lua_queue, ^{
		// Clean up existing connection if any
		if (mosq_client != NULL) {
			NSLog(@"SolarMQTT: Disconnecting old client before new connect");
			mosquitto_loop_stop(mosq_client, true);
			mosquitto_disconnect(mosq_client);
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
		mosquitto_log_callback_set(mosq_client, on_log_callback);

		// Set credentials
		if (usernameStr) {
			mosquitto_username_pw_set(mosq_client,
				[usernameStr UTF8String],
				passwordStr ? [passwordStr UTF8String] : NULL);
		}

		// Note: do NOT call mosquitto_threaded_set(true) here.
		// That sets mosq->threaded = mosq_ts_external, but loop_start()
		// requires mosq_ts_none so it can manage its own thread.

		// Connect asynchronously
		int rc = mosquitto_connect_async(mosq_client,
			[brokerStr UTF8String],
			port,
			keepAlive);

		if (rc != MOSQ_ERR_SUCCESS) {
			NSLog(@"SolarMQTT: Connect failed: %s", mosquitto_strerror(rc));
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

		// Start the network loop thread
		rc = mosquitto_loop_start(mosq_client);
		if (rc != MOSQ_ERR_SUCCESS) {
			NSLog(@"SolarMQTT: loop_start failed: %s", mosquitto_strerror(rc));
			mosquitto_destroy(mosq_client);
			mosq_client = NULL;
		}

		NSLog(@"SolarMQTT: Connecting to %@:%d", brokerStr, port);
	});

	return 0;
}

// [Lua] mqtt.disconnect()
int
PluginSolarMQTT::disconnect_broker( lua_State *L )
{
	dispatch_async(mosq_lua_queue, ^{
		if (mosq_client != NULL) {
			NSLog(@"SolarMQTT: Disconnecting");
			mosquitto_disconnect(mosq_client);
			// Don't destroy here — the disconnect callback will fire
			// and then we can clean up. But stop the loop.
			mosquitto_loop_stop(mosq_client, false);
			mosquitto_destroy(mosq_client);
			mosq_client = NULL;
		}
	});

	return 0;
}

// [Lua] mqtt.subscribe( topic, qos )
int
PluginSolarMQTT::subscribe_topic( lua_State *L )
{
	const char *topic = luaL_checkstring(L, 1);
	int qos = (int)luaL_optinteger(L, 2, 0);

	if (!topic) return 0;

	// Copy topic string for async use
	NSString *topicStr = [NSString stringWithUTF8String:topic];

	dispatch_async(mosq_lua_queue, ^{
		if (mosq_client == NULL) {
			NSLog(@"SolarMQTT: subscribe called but not connected");
			return;
		}

		// Store topic for the subscribe callback
		if (mosq_pending_subscribe_topic) {
			free(mosq_pending_subscribe_topic);
		}
		mosq_pending_subscribe_topic = strdup([topicStr UTF8String]);

		int mid = 0;
		int rc = mosquitto_subscribe(mosq_client, &mid, [topicStr UTF8String], qos);
		if (rc != MOSQ_ERR_SUCCESS) {
			NSLog(@"SolarMQTT: subscribe failed: %s", mosquitto_strerror(rc));
		} else {
			NSLog(@"SolarMQTT: Subscribing to '%@' qos=%d mid=%d", topicStr, qos, mid);
		}
	});

	return 0;
}

// [Lua] mqtt.unsubscribe( topic )
int
PluginSolarMQTT::unsubscribe_topic( lua_State *L )
{
	const char *topic = luaL_checkstring(L, 1);
	if (!topic) return 0;

	NSString *topicStr = [NSString stringWithUTF8String:topic];

	dispatch_async(mosq_lua_queue, ^{
		if (mosq_client == NULL) {
			NSLog(@"SolarMQTT: unsubscribe called but not connected");
			return;
		}

		int mid = 0;
		int rc = mosquitto_unsubscribe(mosq_client, &mid, [topicStr UTF8String]);
		if (rc != MOSQ_ERR_SUCCESS) {
			NSLog(@"SolarMQTT: unsubscribe failed: %s", mosquitto_strerror(rc));
		} else {
			NSLog(@"SolarMQTT: Unsubscribed from '%@'", topicStr);
		}
	});

	return 0;
}

// [Lua] mqtt.publish( topic, payload, { qos=, retain= } )
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

	// Copy strings for async use
	NSString *topicStr = [NSString stringWithUTF8String:topic];
	NSString *payloadStr = [NSString stringWithUTF8String:payload];

	dispatch_async(mosq_lua_queue, ^{
		if (mosq_client == NULL) {
			NSLog(@"SolarMQTT: publish called but not connected");
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

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!mosq_L_valid || mosq_L_generation != gen) {
			NSLog(@"SolarMQTT: Stale on_connect callback (gen %d vs %d), skipping", gen, mosq_L_generation);
			return;
		}

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
	});
}

static void on_disconnect_callback(struct mosquitto *mosq, void *obj, int rc)
{
	int gen = (int)(intptr_t)obj;
	NSLog(@"SolarMQTT: on_disconnect rc=%d", rc);

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!mosq_L_valid || mosq_L_generation != gen) {
			NSLog(@"SolarMQTT: Stale on_disconnect callback (gen %d vs %d), skipping", gen, mosq_L_generation);
			return;
		}

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

	// Capture the pending topic (may be NULL if subscribe was called multiple times rapidly)
	NSString *topic = mosq_pending_subscribe_topic
		? [NSString stringWithUTF8String:mosq_pending_subscribe_topic]
		: @"unknown";
	int grantedQos = qos_count > 0 ? granted_qos[0] : 0;

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!mosq_L_valid || mosq_L_generation != gen) {
			return;
		}

		CoronaLuaNewEvent(mosq_L, PluginSolarMQTT::kEvent);

		lua_pushstring(mosq_L, "subscribed");
		lua_setfield(mosq_L, -2, "name");

		lua_pushstring(mosq_L, [topic UTF8String]);
		lua_setfield(mosq_L, -2, "topic");

		lua_pushinteger(mosq_L, grantedQos);
		lua_setfield(mosq_L, -2, "grantedQos");

		CoronaLuaDispatchEvent(mosq_L, mosq_fListener, 0);
	});
}

static void on_log_callback(struct mosquitto *mosq, void *obj, int level, const char *str)
{
	// Forward mosquitto internal logs to NSLog for debugging
	NSLog(@"SolarMQTT [mosq %d]: %s", level, str);
}

// ----------------------------------------------------------------------------

CORONA_EXPORT int luaopen_plugin_solarmqtt( lua_State *L )
{
	return PluginSolarMQTT::Open( L );
}
