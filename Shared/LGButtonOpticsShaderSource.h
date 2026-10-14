#pragma once

/* Stringify exactly the same formula statements compiled by the C regression. */
#define LGBO_STRUCT_BEGIN(name) "struct " #name " {\n"
#define LGBO_FIELD(type, name) #type " " #name ";\n"
#define LGBO_STRUCT_END(name) "};\n"
#define LGBO_FUNCTION_BEGIN(ret, name, args) #ret " " #name #args " {\n"
#define LGBO_STMT(line) #line "\n"
#define LGBO_FUNCTION_END "}\n"
static const char kLGButtonOpticsFormulaMSL[] =
#include "LGButtonOpticsFormula.inc"
;
#undef LGBO_FUNCTION_END
#undef LGBO_STMT
#undef LGBO_FUNCTION_BEGIN
#undef LGBO_STRUCT_END
#undef LGBO_FIELD
#undef LGBO_STRUCT_BEGIN
