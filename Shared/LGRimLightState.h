#ifndef LG_RIM_LIGHT_STATE_H
#define LG_RIM_LIGHT_STATE_H

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define LG_RIM_LIGHT_STATE_MAGIC 0x4c47524du

static inline const char *LGRimLightStatePath(void) {
    return "/var/mobile/Library/Accessibility/liquidglass-rim-light.bin";
}

typedef struct {
    uint32_t magic;
    uint32_t sequence;
    float angle;
    float dirX;
    float dirY;
} LGRimLightSharedState;

static inline LGRimLightSharedState *LGRimLightMapSharedState(bool writable) {
    static LGRimLightSharedState *readOnlyState;
    static LGRimLightSharedState *writableState;
    LGRimLightSharedState **slot = writable ? &writableState : &readOnlyState;
    if (*slot) return *slot;

    int flags = writable ? (O_RDWR | O_CREAT) : O_RDONLY;
    int fd = open(LGRimLightStatePath(), flags, 0666);
    if (fd < 0) return NULL;
    if (writable && ftruncate(fd, (off_t)sizeof(LGRimLightSharedState)) != 0) {
        close(fd);
        return NULL;
    }

    struct stat info = {};
    if (fstat(fd, &info) != 0 ||
        info.st_size < (off_t)sizeof(LGRimLightSharedState)) {
        close(fd);
        return NULL;
    }

    int protection = PROT_READ | (writable ? PROT_WRITE : 0);
    void *mapping = mmap(NULL, sizeof(LGRimLightSharedState), protection,
                         MAP_SHARED, fd, 0);
    close(fd);
    if (mapping == MAP_FAILED) return NULL;

    *slot = (LGRimLightSharedState *)mapping;
    if (writable && (*slot)->magic != LG_RIM_LIGHT_STATE_MAGIC) {
        memset(*slot, 0, sizeof(**slot));
        (*slot)->magic = LG_RIM_LIGHT_STATE_MAGIC;
        (*slot)->angle = -0.78539816339f;
        (*slot)->dirX = 0.70710678f;
        (*slot)->dirY = -0.70710678f;
    }
    return *slot;
}

static inline void LGRimLightWriteSharedState(float angle) {
    LGRimLightSharedState *state = LGRimLightMapSharedState(true);
    if (!state) return;
    uint32_t sequence = __atomic_load_n(&state->sequence, __ATOMIC_RELAXED);
    uint32_t writing = (sequence + 1u) | 1u;
    __atomic_store_n(&state->sequence, writing, __ATOMIC_RELEASE);
    state->angle = angle;
    state->dirX = cosf(angle);
    state->dirY = sinf(angle);
    __atomic_store_n(&state->sequence, writing + 1u, __ATOMIC_RELEASE);
}

static inline bool LGRimLightReadSharedState(LGRimLightSharedState *snapshot) {
    if (!snapshot) return false;
    LGRimLightSharedState *state = LGRimLightMapSharedState(false);
    if (!state || state->magic != LG_RIM_LIGHT_STATE_MAGIC) return false;
    for (int attempt = 0; attempt < 4; attempt++) {
        uint32_t before = __atomic_load_n(&state->sequence, __ATOMIC_ACQUIRE);
        if (before & 1u) continue;
        memcpy(snapshot, state, sizeof(*snapshot));
        uint32_t after = __atomic_load_n(&state->sequence, __ATOMIC_ACQUIRE);
        if (before == after && !(after & 1u) &&
            snapshot->magic == LG_RIM_LIGHT_STATE_MAGIC) {
            return true;
        }
    }
    return false;
}

#endif
