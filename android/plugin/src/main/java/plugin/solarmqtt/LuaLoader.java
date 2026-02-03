//
//  LuaLoader.java
//  SolarMQTT Plugin for Solar2D
//
//  Copyright (c) 2026 Platopus Systems. All rights reserved.
//

package plugin.solarmqtt;

import android.util.Log;

import com.ansca.corona.CoronaActivity;
import com.ansca.corona.CoronaEnvironment;
import com.ansca.corona.CoronaLua;
import com.ansca.corona.CoronaRuntime;
import com.ansca.corona.CoronaRuntimeListener;
import com.ansca.corona.CoronaRuntimeTask;
import com.naef.jnlua.JavaFunction;
import com.naef.jnlua.LuaState;
import com.naef.jnlua.NamedJavaFunction;

import org.eclipse.paho.client.mqttv3.IMqttActionListener;
import org.eclipse.paho.client.mqttv3.IMqttDeliveryToken;
import org.eclipse.paho.client.mqttv3.IMqttToken;
import org.eclipse.paho.client.mqttv3.MqttAsyncClient;
import org.eclipse.paho.client.mqttv3.MqttCallbackExtended;
import org.eclipse.paho.client.mqttv3.MqttConnectOptions;
import org.eclipse.paho.client.mqttv3.MqttException;
import org.eclipse.paho.client.mqttv3.MqttMessage;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;

/**
 * MQTT client plugin for Solar2D using Eclipse Paho Java.
 * Single connection model — one MQTT broker connection at a time.
 */
@SuppressWarnings("WeakerAccess")
public class LuaLoader implements JavaFunction, CoronaRuntimeListener {
	private static final String TAG = "SolarMQTT";
	private static final String VERSION = "1.0.0";

	public static int fListener;
	public static final String EVENT_NAME = "pluginsolarmqtt";

	private MqttAsyncClient mqttClient;

	@SuppressWarnings("unused")
	public LuaLoader() {
		fListener = CoronaLua.REFNIL;
		CoronaEnvironment.addRuntimeListener(this);
	}

	@Override
	public int invoke(LuaState L) {
		NamedJavaFunction[] luaFunctions = new NamedJavaFunction[] {
			new InitWrapper(),
			new ConnectWrapper(),
			new DisconnectWrapper(),
			new SubscribeWrapper(),
			new UnsubscribeWrapper(),
			new PublishWrapper(),
		};
		String libName = L.toString(1);
		L.register(libName, luaFunctions);

		// Expose plugin version
		L.pushString(VERSION);
		L.setField(-2, "VERSION");

		return 1;
	}

	// ========================================================================
	// Corona Runtime Lifecycle
	// ========================================================================

	@Override
	public void onLoaded(CoronaRuntime runtime) { }

	@Override
	public void onStarted(CoronaRuntime runtime) { }

	@Override
	public void onSuspended(CoronaRuntime runtime) { }

	@Override
	public void onResumed(CoronaRuntime runtime) { }

	@Override
	public void onExiting(CoronaRuntime runtime) {
		Log.i(TAG, "onExiting: cleaning up MQTT connection");
		if (mqttClient != null) {
			try {
				if (mqttClient.isConnected()) {
					mqttClient.disconnect();
				}
				mqttClient.close();
			} catch (Exception e) {
				Log.e(TAG, "onExiting: Failed to clean up MQTT client", e);
			}
			mqttClient = null;
		}

		CoronaLua.deleteRef(runtime.getLuaState(), fListener);
		fListener = CoronaLua.REFNIL;
	}

	// ========================================================================
	// Lua functions
	// ========================================================================

	/** library.init( listener ) */
	public int init(LuaState L) {
		int listenerIndex = 1;
		if (CoronaLua.isListener(L, listenerIndex, EVENT_NAME)) {
			fListener = CoronaLua.newRef(L, listenerIndex);
		}
		return 0;
	}

	/** library.connect({ broker=, port=, clientId=, username=, password=, cleanSession=, keepAlive= }) */
	public int connect(LuaState L) {
		CoronaActivity activity = CoronaEnvironment.getCoronaActivity();
		if (activity == null) return 0;

		if (!L.isTable(1)) {
			Log.e(TAG, "connect: requires a table argument");
			return 0;
		}

		// Read options from Lua table
		L.getField(1, "broker");
		String broker = L.isString(-1) ? L.toString(-1) : "localhost";
		L.pop(1);

		L.getField(1, "port");
		int port = L.isNumber(-1) ? (int)L.toNumber(-1) : 1883;
		L.pop(1);

		L.getField(1, "clientId");
		String clientId = L.isString(-1) ? L.toString(-1) : MqttAsyncClient.generateClientId();
		L.pop(1);

		L.getField(1, "username");
		String username = L.isString(-1) ? L.toString(-1) : null;
		L.pop(1);

		L.getField(1, "password");
		String password = L.isString(-1) ? L.toString(-1) : null;
		L.pop(1);

		L.getField(1, "cleanSession");
		boolean cleanSession = !L.isBoolean(-1) || L.toBoolean(-1);
		L.pop(1);

		L.getField(1, "keepAlive");
		int keepAlive = L.isNumber(-1) ? (int)L.toNumber(-1) : 60;
		L.pop(1);

		final String serverUri = "tcp://" + broker + ":" + port;

		// Clean up existing client
		if (mqttClient != null) {
			try {
				if (mqttClient.isConnected()) {
					mqttClient.disconnect();
				}
				mqttClient.close();
			} catch (Exception e) {
				Log.e(TAG, "connect: Failed to clean up old client", e);
			}
			mqttClient = null;
		}

		try {
			mqttClient = new MqttAsyncClient(serverUri, clientId, new MemoryPersistence());

			mqttClient.setCallback(new MqttCallbackExtended() {
				@Override
				public void connectComplete(boolean reconnect, String serverURI) {
					Log.i(TAG, "Connected to " + serverURI + " (reconnect=" + reconnect + ")");
					dispatchConnectedEvent(reconnect);
				}

				@Override
				public void connectionLost(Throwable cause) {
					String msg = cause != null ? cause.getMessage() : "Unknown";
					Log.w(TAG, "Connection lost: " + msg);
					dispatchDisconnectedEvent(1, msg);
				}

				@Override
				public void messageArrived(String topic, MqttMessage message) {
					Log.d(TAG, "Message on " + topic + ": " + new String(message.getPayload()));
					dispatchMessageEvent(topic, new String(message.getPayload()),
						message.getQos(), message.isRetained());
				}

				@Override
				public void deliveryComplete(IMqttDeliveryToken token) {
					// QoS delivery confirmed
				}
			});

			MqttConnectOptions options = new MqttConnectOptions();
			options.setCleanSession(cleanSession);
			options.setKeepAliveInterval(keepAlive);
			options.setAutomaticReconnect(false);

			if (username != null) {
				options.setUserName(username);
				if (password != null) {
					options.setPassword(password.toCharArray());
				}
			}

			Log.i(TAG, "Connecting to " + serverUri);
			mqttClient.connect(options, null, new IMqttActionListener() {
				@Override
				public void onSuccess(IMqttToken asyncActionToken) {
					// connectComplete callback will fire
				}

				@Override
				public void onFailure(IMqttToken asyncActionToken, Throwable exception) {
					String msg = exception != null ? exception.getMessage() : "Connection failed";
					Log.e(TAG, "Connect failed: " + msg);
					dispatchErrorEvent(msg);
				}
			});

		} catch (MqttException e) {
			Log.e(TAG, "connect: MqttException", e);
			dispatchErrorEvent(e.getMessage());
		}

		return 0;
	}

	/** library.disconnect() */
	public int disconnect(LuaState L) {
		if (mqttClient != null && mqttClient.isConnected()) {
			try {
				mqttClient.disconnect(null, new IMqttActionListener() {
					@Override
					public void onSuccess(IMqttToken asyncActionToken) {
						Log.i(TAG, "Disconnected cleanly");
						dispatchDisconnectedEvent(0, "Clean disconnect");
					}

					@Override
					public void onFailure(IMqttToken asyncActionToken, Throwable exception) {
						Log.e(TAG, "Disconnect failed", exception);
					}
				});
			} catch (MqttException e) {
				Log.e(TAG, "disconnect: MqttException", e);
			}
		}
		return 0;
	}

	/** library.subscribe( topic, qos ) */
	public int subscribe(LuaState L) {
		if (mqttClient == null || !mqttClient.isConnected()) {
			Log.w(TAG, "subscribe: not connected");
			return 0;
		}

		final String topic = L.checkString(1);
		final int qos = L.isNumber(2) ? (int)L.toNumber(2) : 0;

		try {
			mqttClient.subscribe(topic, qos, null, new IMqttActionListener() {
				@Override
				public void onSuccess(IMqttToken asyncActionToken) {
					Log.i(TAG, "Subscribed to " + topic);
					dispatchSubscribedEvent(topic, qos);
				}

				@Override
				public void onFailure(IMqttToken asyncActionToken, Throwable exception) {
					Log.e(TAG, "Subscribe failed for " + topic, exception);
					dispatchErrorEvent("Subscribe failed: " + (exception != null ? exception.getMessage() : "unknown"));
				}
			});
		} catch (MqttException e) {
			Log.e(TAG, "subscribe: MqttException", e);
		}

		return 0;
	}

	/** library.unsubscribe( topic ) */
	public int unsubscribe(LuaState L) {
		if (mqttClient == null || !mqttClient.isConnected()) {
			Log.w(TAG, "unsubscribe: not connected");
			return 0;
		}

		String topic = L.checkString(1);

		try {
			mqttClient.unsubscribe(topic);
			Log.i(TAG, "Unsubscribed from " + topic);
		} catch (MqttException e) {
			Log.e(TAG, "unsubscribe: MqttException", e);
		}

		return 0;
	}

	/** library.publish( topic, payload, { qos=, retain= } ) */
	public int publish(LuaState L) {
		if (mqttClient == null || !mqttClient.isConnected()) {
			Log.w(TAG, "publish: not connected");
			return 0;
		}

		String topic = L.checkString(1);
		String payload = L.isString(2) ? L.toString(2) : "";

		int qos = 0;
		boolean retain = false;

		if (L.isTable(3)) {
			L.getField(3, "qos");
			qos = L.isNumber(-1) ? (int)L.toNumber(-1) : 0;
			L.pop(1);

			L.getField(3, "retain");
			retain = L.isBoolean(-1) && L.toBoolean(-1);
			L.pop(1);
		}

		try {
			MqttMessage msg = new MqttMessage(payload.getBytes());
			msg.setQos(qos);
			msg.setRetained(retain);
			mqttClient.publish(topic, msg);
		} catch (MqttException e) {
			Log.e(TAG, "publish: MqttException", e);
		}

		return 0;
	}

	// ========================================================================
	// Event dispatch helpers
	// ========================================================================

	private void dispatchConnectedEvent(final boolean reconnect) {
		CoronaActivity activity = CoronaEnvironment.getCoronaActivity();
		if (activity == null) return;
		activity.getRuntimeTaskDispatcher().send(new CoronaRuntimeTask() {
			@Override
			public void executeUsing(CoronaRuntime runtime) {
				LuaState L = runtime.getLuaState();
				CoronaLua.newEvent(L, EVENT_NAME);
				L.pushString("connected");
				L.setField(-2, "name");
				L.pushBoolean(reconnect);
				L.setField(-2, "sessionPresent");
				try {
					CoronaLua.dispatchEvent(L, fListener, 0);
				} catch (Exception e) {
					Log.e(TAG, "dispatchConnectedEvent failed", e);
				}
			}
		});
	}

	private void dispatchDisconnectedEvent(final int code, final String message) {
		CoronaActivity activity = CoronaEnvironment.getCoronaActivity();
		if (activity == null) return;
		activity.getRuntimeTaskDispatcher().send(new CoronaRuntimeTask() {
			@Override
			public void executeUsing(CoronaRuntime runtime) {
				LuaState L = runtime.getLuaState();
				CoronaLua.newEvent(L, EVENT_NAME);
				L.pushString("disconnected");
				L.setField(-2, "name");
				L.pushInteger(code);
				L.setField(-2, "errorCode");
				L.pushString(message != null ? message : "");
				L.setField(-2, "errorMessage");
				try {
					CoronaLua.dispatchEvent(L, fListener, 0);
				} catch (Exception e) {
					Log.e(TAG, "dispatchDisconnectedEvent failed", e);
				}
			}
		});
	}

	private void dispatchMessageEvent(final String topic, final String payload, final int qos, final boolean retained) {
		CoronaActivity activity = CoronaEnvironment.getCoronaActivity();
		if (activity == null) return;
		activity.getRuntimeTaskDispatcher().send(new CoronaRuntimeTask() {
			@Override
			public void executeUsing(CoronaRuntime runtime) {
				LuaState L = runtime.getLuaState();
				CoronaLua.newEvent(L, EVENT_NAME);
				L.pushString("message");
				L.setField(-2, "name");
				L.pushString(topic);
				L.setField(-2, "topic");
				L.pushString(payload);
				L.setField(-2, "payload");
				L.pushInteger(qos);
				L.setField(-2, "qos");
				L.pushBoolean(retained);
				L.setField(-2, "retained");
				try {
					CoronaLua.dispatchEvent(L, fListener, 0);
				} catch (Exception e) {
					Log.e(TAG, "dispatchMessageEvent failed", e);
				}
			}
		});
	}

	private void dispatchSubscribedEvent(final String topic, final int grantedQos) {
		CoronaActivity activity = CoronaEnvironment.getCoronaActivity();
		if (activity == null) return;
		activity.getRuntimeTaskDispatcher().send(new CoronaRuntimeTask() {
			@Override
			public void executeUsing(CoronaRuntime runtime) {
				LuaState L = runtime.getLuaState();
				CoronaLua.newEvent(L, EVENT_NAME);
				L.pushString("subscribed");
				L.setField(-2, "name");
				L.pushString(topic);
				L.setField(-2, "topic");
				L.pushInteger(grantedQos);
				L.setField(-2, "grantedQos");
				try {
					CoronaLua.dispatchEvent(L, fListener, 0);
				} catch (Exception e) {
					Log.e(TAG, "dispatchSubscribedEvent failed", e);
				}
			}
		});
	}

	private void dispatchErrorEvent(final String errorMessage) {
		CoronaActivity activity = CoronaEnvironment.getCoronaActivity();
		if (activity == null) return;
		activity.getRuntimeTaskDispatcher().send(new CoronaRuntimeTask() {
			@Override
			public void executeUsing(CoronaRuntime runtime) {
				LuaState L = runtime.getLuaState();
				CoronaLua.newEvent(L, EVENT_NAME);
				L.pushString("error");
				L.setField(-2, "name");
				L.pushString(errorMessage != null ? errorMessage : "Unknown error");
				L.setField(-2, "errorMessage");
				try {
					CoronaLua.dispatchEvent(L, fListener, 0);
				} catch (Exception e) {
					Log.e(TAG, "dispatchErrorEvent failed", e);
				}
			}
		});
	}

	// ========================================================================
	// NamedJavaFunction wrappers
	// ========================================================================

	private class InitWrapper implements NamedJavaFunction {
		@Override public String getName() { return "init"; }
		@Override public int invoke(LuaState L) { return init(L); }
	}

	private class ConnectWrapper implements NamedJavaFunction {
		@Override public String getName() { return "connect"; }
		@Override public int invoke(LuaState L) { return connect(L); }
	}

	private class DisconnectWrapper implements NamedJavaFunction {
		@Override public String getName() { return "disconnect"; }
		@Override public int invoke(LuaState L) { return disconnect(L); }
	}

	private class SubscribeWrapper implements NamedJavaFunction {
		@Override public String getName() { return "subscribe"; }
		@Override public int invoke(LuaState L) { return subscribe(L); }
	}

	private class UnsubscribeWrapper implements NamedJavaFunction {
		@Override public String getName() { return "unsubscribe"; }
		@Override public int invoke(LuaState L) { return unsubscribe(L); }
	}

	private class PublishWrapper implements NamedJavaFunction {
		@Override public String getName() { return "publish"; }
		@Override public int invoke(LuaState L) { return publish(L); }
	}
}
