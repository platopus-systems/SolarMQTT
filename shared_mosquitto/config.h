/*
 * SolarMQTT config.h — minimal configuration for libmosquitto embedded build.
 * Based on mosquitto/config.h with TLS, broker, SRV, websockets, etc. disabled.
 */

#ifndef CONFIG_H
#define CONFIG_H

/* ============================================================
 * Platform options
 * ============================================================ */

#ifdef __APPLE__
#  define __DARWIN_C_SOURCE
#elif defined(__FreeBSD__) || defined(__NetBSD__)
#  define HAVE_NETINET_IN_H
#endif

/* ============================================================
 * Feature flags — all optional features disabled for minimal build
 * ============================================================ */

#define WITH_TLS             /* OpenSSL via xcframeworks */
/* #undef WITH_TLS_PSK       -- no pre-shared key TLS */
/* #undef WITH_SRV           -- no DNS SRV lookup */
/* #undef WITH_BROKER        -- client library only */
/* #undef WITH_WEBSOCKETS    -- no WebSocket transport */
/* #undef WITH_SOCKS         -- no SOCKS5 proxy */
/* #undef WITH_ADNS          -- no async DNS */

/* Threading MUST be enabled for mosquitto_loop_start() background thread */
#define WITH_THREADING

/* ============================================================
 * Compatibility defines
 * ============================================================ */

#if defined(_MSC_VER) && _MSC_VER < 1900
#  define snprintf sprintf_s
#  define EPROTO ECONNABORTED
#  ifndef ECONNABORTED
#    define ECONNABORTED WSAECONNABORTED
#  endif
#  ifndef ENOTCONN
#    define ENOTCONN WSAENOTCONN
#  endif
#  ifndef ECONNREFUSED
#    define ECONNREFUSED WSAECONNREFUSED
#  endif
#endif

#ifdef WIN32
#  define strcasecmp _stricmp
#  define strncasecmp _strnicmp
#  define strtok_r strtok_s
#  define strerror_r(e, b, l) strerror_s(b, l, e)
#  ifdef _MSC_VER
#    include <basetsd.h>
typedef SSIZE_T ssize_t;
#  endif
#endif

/* ============================================================
 * uthash memory allocation overrides
 * ============================================================ */

#define uthash_malloc(sz) mosquitto_malloc(sz)
#define uthash_free(ptr, sz) mosquitto_free(ptr)

/* ============================================================
 * Misc
 * ============================================================ */

#define UNUSED(A) (void)(A)

/* Android Bionic libpthread implementation doesn't have pthread_cancel */
#if !defined(ANDROID) && !defined(WIN32)
#  define HAVE_PTHREAD_CANCEL
#endif

#define WS_IS_LWS 1
#define WS_IS_BUILTIN 2

#define BROKER_EXPORT

#define TOPIC_HIERARCHY_LIMIT 200

#endif /* CONFIG_H */
