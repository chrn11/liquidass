#pragma once
/* Finite category routing only: it is NOT an instance identifier or an IPC slot.
 * Attachments on independent CA filter objects choose independent categories.
 * Actual CA -> Backboard atom delivery remains a separate runtime gate.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#ifndef LG_BUTTON_PRESSURE_EXPERIMENTAL
#define LG_BUTTON_PRESSURE_EXPERIMENTAL 0
#endif
#define LG_BUTTON_PRESSURE_PREF "PrefsButton.MaterialCandidate.OpticalPress.Enabled"
#define LG_BUTTON_PRESSURE_LEVELS 9u
#define LG_BUTTON_PRESSURE_ROUTE_STEM "dylv.liquidglass.prefsbuttonmaterial.pressure"
#define LG_BUTTON_PRESSURE_ROUTE_MAX_NAMES ((LG_BUTTON_PRESSURE_LEVELS-1u)*4u)

typedef struct {unsigned bucket;bool dark,refresh;} LGButtonPressureCategory;

static inline bool LGButtonPressureTypeName(char *out,size_t capacity,
                                             LGButtonPressureCategory c) {
 if(!out||capacity<1||c.bucket<1||c.bucket>=LG_BUTTON_PRESSURE_LEVELS)return false;
 int n=snprintf(out,capacity,LG_BUTTON_PRESSURE_ROUTE_STEM "%u%s%s",c.bucket,c.dark?".dark":"",c.refresh?".refresh":"");
 if(n<0||(size_t)n>=capacity){out[0]=0;return false;}return true;
}

static inline bool LGButtonPressureParseName(const char *name,
                                               LGButtonPressureCategory *out) {
 if(!name||!out)return false;
 size_t n=sizeof(LG_BUTTON_PRESSURE_ROUTE_STEM)-1;
 if(strncmp(name,LG_BUTTON_PRESSURE_ROUTE_STEM,n)!=0)return false;
 const char *p=name+n;
 if(*p<'1'||*p>'8')return false;
 LGButtonPressureCategory c={(unsigned)(*p-'0'),false,false};p++;
 if(strncmp(p,".dark",5)==0){c.dark=true;p+=5;}
 if(strcmp(p,".refresh")==0){c.refresh=true;p+=8;}
 if(*p)return false;
 char canonical[96];if(!LGButtonPressureTypeName(canonical,sizeof canonical,c)||strcmp(canonical,name)!=0)return false;
 *out=c;return true;
}

static inline float LGButtonPressureValue(unsigned bucket) {
 return bucket<LG_BUTTON_PRESSURE_LEVELS ? (float)bucket/(LG_BUTTON_PRESSURE_LEVELS-1u) : 0.0f;
}

/* Scalar press deforms the complete optical field, not UIView alpha/scale.
 * Unit convention is the existing renderer's source-texel thickness. These
 * reductions operate on its actual height amplitude, so a >radius configured
 * thickness cannot accidentally make pressing optically inert.
 */
static inline bool LGButtonPressureMaterial(float shortest,float configuredThickness,
 unsigned bucket,float *thicknessFactorApplied,float *refractionFactor) {
 if(!thicknessFactorApplied||!refractionFactor||!isfinite(shortest)||!isfinite(configuredThickness)||shortest<1||shortest>16384||configuredThickness<0||bucket>=LG_BUTTON_PRESSURE_LEVELS)return false;
 float pressure=LGButtonPressureValue(bucket);
 *thicknessFactorApplied=bucket==0?configuredThickness:fminf(configuredThickness,shortest*.5f)*(1.0f-.20f*pressure);
 *refractionFactor=1.0f-.10f*pressure;
 return isfinite(*thicknessFactorApplied)&&isfinite(*refractionFactor);
}
