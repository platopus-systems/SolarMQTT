//
//  PluginSolarMQTT.h
//  SolarMQTT Plugin for Solar2D
//
//  Copyright (c) 2026 Platopus Systems. All rights reserved.
//

#ifndef _PluginSolarMQTT_H__
#define _PluginSolarMQTT_H__

#include <CoronaLua.h>
#include <CoronaMacros.h>

// This corresponds to the name of the library, e.g. [Lua] require "plugin.solarmqtt"
CORONA_EXPORT int luaopen_plugin_solarmqtt( lua_State *L );

#endif // _PluginSolarMQTT_H__
