#pragma once
#include "LGSurfaceDescriptor.h"
#include "LGHostRegistry.h"
#include <stddef.h>
#include <string.h>
#include <time.h>

/* Diagnostic transport ONLY. These identities are scoped to the producer's
 * epoch; neither surfaceIdentifier nor host atom identifies a CA render layer.
 * There is deliberately no render-lookup API and no readiness/presentation ACK. */
#define LG_SURFACE_DIAGNOSTICS_PATH "/var/mobile/Library/Accessibility/liquidglass-surface-diagnostics-v1.bin"
#define LG_SURFACE_DIAGNOSTICS_NOTE "dylv.liquidglass/SurfaceDiagnostics"
#define LG_SURFACE_DIAGNOSTICS_MAGIC 0x4c475344u
#define LG_SURFACE_DIAGNOSTICS_VERSION 1u
#define LG_SURFACE_DIAGNOSTICS_CAPACITY 128u
#define LG_SURFACE_DIAGNOSTICS_MAX_AGE_MS 5000u
#define LG_SURFACE_DIAGNOSTICS_ONLY 1u
#define LG_SURFACE_DIAGNOSTICS_TRUNCATED 2u
#ifdef __OBJC__
#define LG_SURFACE_DIAGNOSTICS_PREF @"Surface.Diagnostics.Enabled"
static inline int LGSurfaceDiagnosticsPreferenceEnabled(id value) {
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}
#endif

typedef struct LGSurfaceDiagnosticEntryV1 {
    uint64_t surfaceIdentifier;
    LGSurfaceDescriptorV1 surface;
} LGSurfaceDiagnosticEntryV1;

typedef struct LGSurfaceDiagnosticPacketV1 {
    uint32_t magic, version, byteSize, capacity;
    uint32_t count, producerPID, flags, reserved;
    uint64_t producerEpoch, serial, monotonicMilliseconds;
    LGSurfaceDiagnosticEntryV1 entries[LG_SURFACE_DIAGNOSTICS_CAPACITY];
} LGSurfaceDiagnosticPacketV1;

typedef struct LGSurfaceDiagnosticCursor {
    uint64_t epoch, serial, monotonicMilliseconds;
    uint32_t producerPID;
} LGSurfaceDiagnosticCursor;

static inline uint64_t LGSurfaceDiagnosticMonotonicMilliseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000u + (uint64_t)now.tv_nsec / 1000000u;
}

static inline int LGSurfaceDiagnosticPacketIsValid(
    const LGSurfaceDiagnosticPacketV1 *packet, size_t byteCount, uint64_t now) {
    if (!packet || byteCount != sizeof(*packet) ||
        packet->magic != LG_SURFACE_DIAGNOSTICS_MAGIC ||
        packet->version != LG_SURFACE_DIAGNOSTICS_VERSION ||
        packet->byteSize != sizeof(*packet) ||
        packet->capacity != LG_SURFACE_DIAGNOSTICS_CAPACITY ||
        packet->count > LG_SURFACE_DIAGNOSTICS_CAPACITY || packet->reserved ||
        !packet->producerPID || packet->producerPID > INT32_MAX ||
        !packet->producerEpoch || !packet->serial || !packet->monotonicMilliseconds ||
        !(packet->flags & LG_SURFACE_DIAGNOSTICS_ONLY) ||
        (packet->flags & ~(LG_SURFACE_DIAGNOSTICS_ONLY | LG_SURFACE_DIAGNOSTICS_TRUNCATED)) ||
        now < packet->monotonicMilliseconds ||
        now - packet->monotonicMilliseconds > LG_SURFACE_DIAGNOSTICS_MAX_AGE_MS) return 0;
    uint64_t previousID = 0;
    for (uint32_t i = 0; i < packet->count; i++) {
        const LGSurfaceDiagnosticEntryV1 *entry = &packet->entries[i];
        const LGSurfaceDescriptorV1 *surface = &entry->surface;
        if (entry->surfaceIdentifier <= previousID ||
            !LGSurfaceDescriptorV1IsValid(surface) || !surface->hostGeneration ||
            surface->captureOwnerGeneration != surface->hostGeneration ||
            surface->captureGroup >= LGHostIdentifierCount ||
            surface->captureOwnerGroup != surface->captureGroup) return 0;
        previousID = entry->surfaceIdentifier;
    }
    return 1;
}

/* Validate first; advance the cursor only after accepting a complete packet.
 * This is replay detection for diagnostics, NOT producer authentication. */
static inline int LGSurfaceDiagnosticAccept(
    const LGSurfaceDiagnosticPacketV1 *packet, size_t byteCount, uint64_t now,
    LGSurfaceDiagnosticCursor *cursor) {
    if (!cursor || !LGSurfaceDiagnosticPacketIsValid(packet, byteCount, now)) return 0;
    if (cursor->epoch) {
        if (packet->monotonicMilliseconds < cursor->monotonicMilliseconds) return 0;
        if (packet->producerEpoch == cursor->epoch) {
            if (packet->producerPID != cursor->producerPID || packet->serial <= cursor->serial)
                return 0;
        } else if (packet->monotonicMilliseconds <= cursor->monotonicMilliseconds) return 0;
    }
    cursor->epoch = packet->producerEpoch;
    cursor->serial = packet->serial;
    cursor->producerPID = packet->producerPID;
    cursor->monotonicMilliseconds = packet->monotonicMilliseconds;
    return 1;
}

#ifdef __cplusplus
static_assert(sizeof(LGSurfaceDiagnosticEntryV1) == 160, "diagnostic entry ABI changed");
static_assert(sizeof(LGSurfaceDiagnosticPacketV1) == 20536, "diagnostic packet ABI changed");
#else
_Static_assert(sizeof(LGSurfaceDiagnosticEntryV1) == 160, "diagnostic entry ABI changed");
_Static_assert(sizeof(LGSurfaceDiagnosticPacketV1) == 20536, "diagnostic packet ABI changed");
#endif
