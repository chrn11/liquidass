/* Test-only frozen previous formula under distinct names, never production. */
#pragma once
#define LGButtonOpticsResult LGFrozenButtonOpticsResult
#define LGBOAbs LGFrozenAbs
#define LGBOMin LGFrozenMin
#define LGBOMax LGFrozenMax
#define LGBOClamp LGFrozenClamp
#define LGBOHypot LGFrozenHypot
#define LGBOButtonRoundedBoxSDF LGFrozenRoundedBoxSDF
#define LGButtonOpticsEvaluate LGFrozenOpticsEvaluate
#define LGBOEnvironmentMixPremultipliedChannel LGFrozenEnvironmentMix
#define LGBO_STRUCT_BEGIN(name) typedef struct name {
#define LGBO_FIELD(type, name) type name;
#define LGBO_STRUCT_END(name) } name;
#define LGBO_FUNCTION_BEGIN(ret, name, args) static inline ret name args {
#define LGBO_STMT(line) line
#define LGBO_FUNCTION_END }
#include "legacy_button_optics_formula_fixture.inc"
#undef LGBO_FUNCTION_END
#undef LGBO_STMT
#undef LGBO_FUNCTION_BEGIN
#undef LGBO_STRUCT_END
#undef LGBO_FIELD
#undef LGBO_STRUCT_BEGIN
#undef LGBOEnvironmentMixPremultipliedChannel
#undef LGButtonOpticsEvaluate
#undef LGBOButtonRoundedBoxSDF
#undef LGBOHypot
#undef LGBOClamp
#undef LGBOMax
#undef LGBOMin
#undef LGBOAbs
#undef LGButtonOpticsResult
