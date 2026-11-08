// src/kernels/cpu/iq_avx2_bmi2.cpp - iq_avx2_rows.inc built for AVX2 with hardware BMI2: the same rows, the sign
// masks of IQ2_XXS, IQ2_XS and IQ3_XXS built by pdep/pext and a byte parity instead of the sign tables, and the IQ3_S
// and IQ2_S grid indices by pdep.  Only called behind cpu_pdep_ok(), which keeps the CPUs whose BMI2 runs in
// microcode on the base build.  No IQ4_NL rows: they hold no BMI2 path.

#include "basalt/kernels/cpu/iq_avx2.hpp"

#define GGML_COMMON_DECL_CPP
#define GGML_COMMON_IMPL_CPP
#include "basalt/ggml/ggml_common.h"
#include "basalt/log.hpp"
#include "basalt/platform/compiler.hpp"

#include <immintrin.h>

#include <cmath>
#include <cstdlib>
#include <cstring>

#define BASALT_IQ_VNNI 0
#define BASALT_IQ_BMI2 1
#define BASALT_IQ_IQ4NL 0
#define BASALT_IQ_EXPORT(name) name##_bmi2
#include "iq_avx2_rows.inc"
