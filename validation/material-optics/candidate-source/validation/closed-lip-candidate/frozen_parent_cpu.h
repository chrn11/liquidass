/* Frozen independently named parent for exact inner-core/pressure comparisons. */
#pragma once
#define LGButtonOpticsResult Frozen_LGButtonOpticsResult
#define LGBOAbs Frozen_LGBOAbs
#define LGBOMin Frozen_LGBOMin
#define LGBOMax Frozen_LGBOMax
#define LGBOClamp Frozen_LGBOClamp
#define LGBOHypot Frozen_LGBOHypot
#define LGBOSmoothCappedLength Frozen_LGBOSmoothCappedLength
#define LGBOButtonRoundedBoxSDF Frozen_LGBOButtonRoundedBoxSDF
#define LGButtonOpticsEvaluateWithContact Frozen_LGButtonOpticsEvaluateWithContact
#define LGButtonOpticsEvaluate Frozen_LGButtonOpticsEvaluate
#define LGBOImageEdgeRadianceWeight Frozen_LGBOImageEdgeRadianceWeight
#define LGBOImageEdgeRadianceRadius Frozen_LGBOImageEdgeRadianceRadius
#define LGBOAverageFourRadianceSamples Frozen_LGBOAverageFourRadianceSamples
#define LGBOEnvironmentMixPremultipliedChannel Frozen_LGBOEnvironmentMixPremultipliedChannel
#define LGBO_STRUCT_BEGIN(name) typedef struct name {
#define LGBO_FIELD(type, name) type name;
#define LGBO_STRUCT_END(name) } name;
#define LGBO_FUNCTION_BEGIN(ret, name, args) static inline ret name args {
#define LGBO_STMT(line) line
#define LGBO_FUNCTION_END }
#include "frozen_parent_formula.inc"
#undef LGBO_FUNCTION_END
#undef LGBO_STMT
#undef LGBO_FUNCTION_BEGIN
#undef LGBO_STRUCT_END
#undef LGBO_FIELD
#undef LGBO_STRUCT_BEGIN
#undef LGButtonOpticsResult
#undef LGBOAbs
#undef LGBOMin
#undef LGBOMax
#undef LGBOClamp
#undef LGBOHypot
#undef LGBOSmoothCappedLength
#undef LGBOButtonRoundedBoxSDF
#undef LGButtonOpticsEvaluateWithContact
#undef LGButtonOpticsEvaluate
#undef LGBOImageEdgeRadianceWeight
#undef LGBOImageEdgeRadianceRadius
#undef LGBOAverageFourRadianceSamples
#undef LGBOEnvironmentMixPremultipliedChannel
