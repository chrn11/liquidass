#pragma once
/* Instance-owned optical observation state. This never dispatches actions,
 * changes hit-testing, or supplies unverified cross-process renderer identity.
 * UI adapters must mirror ORIGINAL UIControl tracking/visibility decisions.
 */
#include <stdbool.h>
#include <stdint.h>
#include <math.h>

typedef enum {
    LGOpticalIdle=0, LGOpticalTrackingInside, LGOpticalTrackingOutside,
    LGOpticalReleasing, LGOpticalCancelled, LGOpticalSuspended
} LGOpticalPhase;

typedef struct {
    double lastTime;
    float pressure, target, touchX, touchY;
    uint64_t geometryGeneration;
    LGOpticalPhase phase;
    bool hasTime, tracking, touchValid, eligible, wantsFrames;
} LGButtonOpticalState;

static inline void LGOpticalReset(LGButtonOpticalState *s,
                                    uint64_t generation) {
    if (!s) return;
    *s=(LGButtonOpticalState){0};
    s->geometryGeneration=generation;
    s->touchX=s->touchY=0.5f;
    s->phase=LGOpticalIdle;
}

static inline bool LGOpticalSetEligibility(LGButtonOpticalState *s,
    bool candidateOn, bool enabled, bool attached, bool visible,
    bool appActive, uint64_t generation) {
    if (!s) return false;
    bool eligible=candidateOn && enabled && attached && visible && appActive;
    if (!eligible || (!s->eligible && eligible) ||
        s->geometryGeneration!=generation) {
        LGOpticalReset(s,generation);
        s->phase=eligible ? LGOpticalIdle : LGOpticalSuspended;
    }
    s->eligible=eligible;
    return eligible;
}

static inline bool LGOpticalTick(LGButtonOpticalState *s,double now) {
    if (!s) return false;
    if (!s->eligible || !isfinite(now) || now<0 ||
        (s->hasTime && now<s->lastTime)) {
        uint64_t g=s->geometryGeneration;
        bool eligible=s->eligible;
        LGOpticalReset(s,g);
        s->eligible=eligible;
        s->phase=eligible ? LGOpticalIdle : LGOpticalSuspended;
        return false;
    }
    if (!s->hasTime) {s->lastTime=now;s->hasTime=true;}
    double dt=now-s->lastTime;s->lastTime=now;
    // Exact exponential update is stable for arbitrarily large positive dt.
    // Attack/release have fixed meanings independent of frame rate.
    double tau=s->target>s->pressure ? 0.065 : 0.115;
    double alpha=-expm1(-dt/tau);
    s->pressure=(float)(s->pressure+(s->target-s->pressure)*alpha);
    if (!isfinite(s->pressure)) s->pressure=0;
    s->pressure=fminf(1.0f,fmaxf(0.0f,s->pressure));
    if (fabsf(s->pressure-s->target)<0.0005f) s->pressure=s->target;
    if (!s->tracking && s->pressure==0 && s->target==0) {
        s->phase=LGOpticalIdle;
        s->touchValid=false;
    }
    s->wantsFrames=fabsf(s->pressure-s->target)>0.0f;
    return s->wantsFrames;
}

static inline bool LGOpticalObservePoint(LGButtonOpticalState *s,
                                          float x, float y,
                                          float width,float height) {
    if (!s || !s->eligible || !isfinite(x) || !isfinite(y) || !isfinite(width) ||
        !isfinite(height) || width<=0 || height<=0) return false;
    s->touchX=fminf(1.0f,fmaxf(0.0f,x/width));
    s->touchY=fminf(1.0f,fmaxf(0.0f,y/height));
    s->touchValid=true;
    return true;
}

static inline bool LGOpticalBegin(LGButtonOpticalState *s,
 double now, bool originalTrackingAccepted, bool originalInside,
 float x,float y,float width,float height) {
    if (!s || !s->eligible || s->tracking || !originalTrackingAccepted ||
        !isfinite(now) || now<0 || (s->hasTime && now<s->lastTime)) return false;
    LGOpticalTick(s,now);
    if (!s->eligible || !isfinite(now) || now<0 ||
        !LGOpticalObservePoint(s,x,y,width,height)) return false;
    s->tracking=true;s->target=originalInside ? 1.0f : 0.0f;
    s->phase=originalInside ? LGOpticalTrackingInside : LGOpticalTrackingOutside;
    s->wantsFrames=s->pressure!=s->target;
    return true;
}

static inline void LGOpticalContinue(LGButtonOpticalState *s,double now,
 bool originalTrackingContinues,bool originalInside,
 float x,float y,float width,float height) {
    if (!s || !s->eligible || !s->tracking) return;
    LGOpticalTick(s,now);
    if (!s->tracking || !originalTrackingContinues ||
        !LGOpticalObservePoint(s,x,y,width,height)) {
        s->tracking=false;s->target=0;s->phase=LGOpticalCancelled;
    } else {
        s->target=originalInside ? 1.0f : 0.0f;
        s->phase=originalInside ? LGOpticalTrackingInside : LGOpticalTrackingOutside;
    }
    s->wantsFrames=s->pressure!=s->target;
    if (!s->tracking && s->pressure==0.0f && s->target==0.0f)
        s->touchValid=false;
}

static inline void LGOpticalEnd(LGButtonOpticalState *s,double now,
                                bool cancelled) {
    if (!s) return;
    LGOpticalTick(s,now);
    s->tracking=false;s->target=0;
    s->phase=s->eligible ? (cancelled ? LGOpticalCancelled : LGOpticalReleasing)
                        : LGOpticalSuspended;
    s->wantsFrames=s->eligible && s->pressure!=0;
    if (s->pressure==0.0f) s->touchValid=false;
}

/* Quantization is a bounded observation value, not a CA transport guarantee. */
static inline unsigned LGOpticalPressureIndex(const LGButtonOpticalState *s,
                                               unsigned levels) {
    if (!s || !s->eligible || levels<2 || levels>65) return 0;
    float pressure=fminf(1.0f,fmaxf(0.0f,s->pressure));
    return (unsigned)lroundf(pressure*(float)(levels-1));
}
