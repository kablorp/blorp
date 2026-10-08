/* Blorp final Core C artifact */
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct brp_ty0 brp_ty0;
typedef struct Option Option;
typedef struct brp_ty1 brp_ty1;
typedef struct brp_ty2 brp_ty2;

#define brp_c_28 0L
#define brp_c_29 1L
static blorp_String* __blorp_enum_to_string_Bool(long v) {
    switch (v) {
    case brp_c_28: return blorp_string_create("True");
    case brp_c_29: return blorp_string_create("False");
    default: return blorp_to_string(v);
    }
}
blorp_String* blorp_vector_to_string_Bool(blorp_Vector* v) {
    return blorp_vector_to_string_packed_enum(v, __blorp_enum_to_string_Bool);
}

typedef struct { int tag; __int128 value; } blorp_StackOption_Int128;
typedef struct { int tag; unsigned __int128 value; } blorp_StackOption_UInt128;
typedef struct { int tag; long value; } blorp_StackOption_Range;

typedef struct Option {
  blorp_Object header;
  int tag;
  unsigned long release_mask;
  union {
    struct { void* field0; } Some;
    char None;
  } data;
} Option;

#define brp_t_el 0
#define brp_t_em 1

static void Option_destroy(void* obj) {
  Option* self = (Option*)obj;
  switch (self->tag) {
    case brp_t_el:
        if ((self->release_mask & 1UL) && self->data.Some.field0) blorp_release(self->data.Some.field0);
      break;
    default:
      break;
  }
}

Option* brp_c_el(void* field0, unsigned long release_mask) {
  Option* __vc = (Option*)blorp_alloc(sizeof(Option));
  BLORP_INSTALL_TYPE(__vc, Option_destroy, "Option");
  __vc->tag = brp_t_el;
  __vc->release_mask = release_mask;
  __vc->data.Some.field0 = field0;
  return __vc;
}

static Option __instance_brp_c_em;
__attribute__((constructor)) static void __init_brp_c_em(void) {
  atomic_store_explicit(&__instance_brp_c_em.header.refcount, BLORP_IMMORTAL_REFCOUNT, memory_order_relaxed);
  __instance_brp_c_em.tag = brp_t_em;
}
#define brp_c_em ((Option*)&__instance_brp_c_em)

static inline Option* __blorp_reuse_Option_brp_c_el(Option* __old, void* field0, unsigned long release_mask) {
  if (__old && blorp_is_unique(__old)) {
    Option_destroy(__old);
    __old->tag = brp_t_el;
    __old->release_mask = release_mask;
    __old->data.Some.field0 = field0;
    return __old;
  }
  Option* __fresh = brp_c_el(field0, release_mask);
  if (__old) blorp_release(__old);
  return __fresh;
}

typedef struct brp_ty2 {
  blorp_Object header;
  int tag;
  unsigned long release_mask;
  union {
    struct { void* field0; void* field1; } Circle;
    struct { void* field0; void* field1; } Rect;
    char Empty;
  } data;
} brp_ty2;

#define brp_t_1Y 0
#define brp_t_1Z 1
#define brp_t_20 2

static void brp_ty2_destroy(void* obj) {
  brp_ty2* self = (brp_ty2*)obj;
  switch (self->tag) {
    case brp_t_1Y:
        if ((self->release_mask & 1UL) && self->data.Circle.field0) blorp_release(self->data.Circle.field0);
      break;
    case brp_t_1Z:
        if ((self->release_mask & 1UL) && self->data.Rect.field0) blorp_release(self->data.Rect.field0);
        if ((self->release_mask & 2UL) && self->data.Rect.field1) blorp_release(self->data.Rect.field1);
      break;
    default:
      break;
  }
}

brp_ty2* brp_c_1Y(void* field0, void* field1, unsigned long release_mask) {
  brp_ty2* __vc = (brp_ty2*)blorp_alloc(sizeof(brp_ty2));
  BLORP_INSTALL_TYPE(__vc, brp_ty2_destroy, "Shape");
  __vc->tag = brp_t_1Y;
  __vc->release_mask = release_mask;
  __vc->data.Circle.field0 = field0;
  __vc->data.Circle.field1 = field1;
  return __vc;
}

brp_ty2* brp_c_1Z(void* field0, void* field1, unsigned long release_mask) {
  brp_ty2* __vc = (brp_ty2*)blorp_alloc(sizeof(brp_ty2));
  BLORP_INSTALL_TYPE(__vc, brp_ty2_destroy, "Shape");
  __vc->tag = brp_t_1Z;
  __vc->release_mask = release_mask;
  __vc->data.Rect.field0 = field0;
  __vc->data.Rect.field1 = field1;
  return __vc;
}

static brp_ty2 __instance_brp_c_20;
__attribute__((constructor)) static void __init_brp_c_20(void) {
  atomic_store_explicit(&__instance_brp_c_20.header.refcount, BLORP_IMMORTAL_REFCOUNT, memory_order_relaxed);
  __instance_brp_c_20.tag = brp_t_20;
}
#define brp_c_20 ((brp_ty2*)&__instance_brp_c_20)

static inline brp_ty2* __blorp_reuse_Shape_brp_c_1Y(brp_ty2* __old, void* field0, void* field1, unsigned long release_mask) {
  if (__old && blorp_is_unique(__old)) {
    brp_ty2_destroy(__old);
    __old->tag = brp_t_1Y;
    __old->release_mask = release_mask;
    __old->data.Circle.field0 = field0;
    __old->data.Circle.field1 = field1;
    return __old;
  }
  brp_ty2* __fresh = brp_c_1Y(field0, field1, release_mask);
  if (__old) blorp_release(__old);
  return __fresh;
}

static inline brp_ty2* __blorp_reuse_Shape_brp_c_1Z(brp_ty2* __old, void* field0, void* field1, unsigned long release_mask) {
  if (__old && blorp_is_unique(__old)) {
    brp_ty2_destroy(__old);
    __old->tag = brp_t_1Z;
    __old->release_mask = release_mask;
    __old->data.Rect.field0 = field0;
    __old->data.Rect.field1 = field1;
    return __old;
  }
  brp_ty2* __fresh = brp_c_1Z(field0, field1, release_mask);
  if (__old) blorp_release(__old);
  return __fresh;
}

typedef struct brp_ty0 {
  blorp_Object header;
  long f0;
  void* f1;
} brp_ty0;

static void brp_ty0_destroy(void* obj) {
  brp_ty0* __rec = (brp_ty0*)obj;
  if (__rec->f1) blorp_release_arc_only(__rec->f1);
}

brp_ty0* brp_ty0_make(long f0, void* f1) {
  brp_ty0* __rec = (brp_ty0*)blorp_alloc(sizeof(brp_ty0));
  BLORP_INSTALL_TYPE(__rec, brp_ty0_destroy, "exit__ExitStatus");
  __rec->f0 = f0;
  __rec->f1 = f1;
  return (brp_ty0*)__rec;
}

static inline brp_ty0* __blorp_reuse_record_brp_ty0(brp_ty0* __old, long f0, void* f1) {
  if (__old && blorp_is_unique(__old)) {
    brp_ty0_destroy(__old);
    __old->f0 = f0;
    __old->f1 = f1;
    return __old;
  }
  brp_ty0* __fresh = brp_ty0_make(f0, f1);
  if (__old) blorp_release(__old);
  return __fresh;
}

typedef struct brp_ty1 {
  blorp_Object header;
  long f0;
  long f1;
} brp_ty1;

brp_ty1* brp_ty1_make(long f0, long f1) {
  brp_ty1* __rec = (brp_ty1*)blorp_alloc(sizeof(brp_ty1));
  BLORP_INSTALL_TAG(__rec, "Point");
  __rec->f0 = f0;
  __rec->f1 = f1;
  return (brp_ty1*)__rec;
}

static inline brp_ty1* __blorp_reuse_record_brp_ty1(brp_ty1* __old, long f0, long f1) {
  if (__old && blorp_is_unique(__old)) {
    __old->f0 = f0;
    __old->f1 = f1;
    return __old;
  }
  brp_ty1* __fresh = brp_ty1_make(f0, f1);
  if (__old) blorp_release(__old);
  return __fresh;
}

#define BLORP_STATIC_STRING(name, length, bytes) \
  _Static_assert(sizeof(bytes) == (length) + 1, "string literal byte length"); \
  static blorp_String name = { \
    .header = { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, \
    .len = (length), \
    .capacity = (length), \
    .data = bytes \
  }

BLORP_STATIC_STRING(__blorp_string_literal_0, 5L, "empty");
BLORP_STATIC_STRING(__blorp_string_literal_1, 10L, "circle at ");
BLORP_STATIC_STRING(__blorp_string_literal_2, 1L, ",");
BLORP_STATIC_STRING(__blorp_string_literal_3, 3L, " r=");
BLORP_STATIC_STRING(__blorp_string_literal_4, 5L, "rect ");
BLORP_STATIC_STRING(__blorp_string_literal_5, 1L, "-");
BLORP_STATIC_STRING(__blorp_string_literal_6, 12L, "total area: ");
BLORP_STATIC_STRING(__blorp_string_literal_7, 14L, "empty shapes: ");

static blorp_Closure __sc_brp_q4;
static blorp_Closure __sc_brp_q5;
static blorp_Closure __sc_brp_q6;
static blorp_Closure __sc_brp_q7;
static blorp_Closure __sc_brp_q8;

static blorp_List* brp_dd(long brp_v_7sd, long brp_v_7sp);
static brp_ty0* brp_40(long brp_v_oE);
static long brp_3Z(long brp_v_gf);
static void brp_bE(blorp_String* brp_v_5k);
static void brp_bI(blorp_String* brp_v_dS);
static blorp_String* brp_hx(blorp_String* brp_v_5Vp);
static long brp_21(brp_ty2* brp_v_6E);
static blorp_String* brp_22(brp_ty2* brp_v_8X);
static brp_ty2* brp_23(long brp_v_cc);
static long brp_24(long brp_v_g8, long brp_v_gi);
static blorp_Dict* brp_25(blorp_Dict* brp_v_h7, blorp_String* brp_v_hv);
static long brp_26(blorp_List* brp_v_iV);
static void brp_pV(blorp_String* brp_v_ck);
static blorp_Dict* brp_pW(blorp_Dict* brp_v_DH, blorp_String* brp_v_DZ, long brp_v_E7);
static long brp_pX(blorp_Dict* brp_v_1lg, blorp_String* brp_v_1ly, long brp_v_1lG);
static blorp_List* brp_pY(blorp_List* brp_v_294, blorp_Closure* brp_v_29k);
static long brp_pZ(blorp_List* brp_v_2Wf, long brp_v_2Wv, blorp_Closure* brp_v_2WH);
static blorp_List* brp_q0(blorp_List* brp_v_294, blorp_Closure* brp_v_29k);
static blorp_List* brp_q1(blorp_List* brp_v_294, blorp_Closure* brp_v_29k);
static blorp_Dict* brp_q2(blorp_List* brp_v_2Wf, blorp_Dict* brp_v_2Wv, blorp_Closure* brp_v_2WH);
static void brp_q3(blorp_String* brp_v_3Y);
static void* brp_q4(void* __env, void* __arg0);
static void* brp_q5(void* __env, void* __arg0);
static void* brp_q6(void* __env, void* __arg0, void* __arg1);
static void* brp_q7(void* __env, void* __arg0);
static void* brp_q8(void* __env, void* __arg0, void* __arg1);

static double float__INFINITY = INFINITY;

static double float__NEG_INFINITY = -INFINITY;

static double float__NAN = NAN;

static long int__INT_MAX = 9223372036854775807L;

static long int__INT_MIN = (-9223372036854775807L - 1L);

static long units__MICROSECONDS_PER_MILLISECOND = 1000L;

static long units__MICROSECONDS_PER_SECOND = 1000000L;

static long units__MICROSECONDS_PER_MINUTE = 60000000L;

static long units__MICROSECONDS_PER_HOUR = 3600000000L;

static long units__MICROSECONDS_PER_DAY = 86400000000L;

static long units__MICROSECONDS_PER_WEEK = 604800000000L;

static double units__MILLISECONDS_PER_SECOND = 1000.0;

static long units__BYTES_PER_KILOBYTE_SI = 1000L;

static long units__BYTES_PER_MEGABYTE_SI = 1000000L;

static long units__BYTES_PER_GIGABYTE_SI = 1000000000L;

static long units__BYTES_PER_KIBIBYTE_IEC = 1024L;

static long units__BYTES_PER_MEBIBYTE_IEC = 1048576L;

static long units__BYTES_PER_GIBIBYTE_IEC = 1073741824L;

static double units__A4_FREQUENCY_HZ = 440.0;

static long units__A4_MIDI_NOTE = 69L;

static double units__SEMITONES_PER_OCTAVE = 12.0;

static double units__AMPLITUDE_DB_FACTOR = 20.0;

static double units__SILENCE_DB_FLOOR = -120.0;

static double units__PERCENT_SCALE = 100.0;

static double math__PI = 3.141592653589793;

static double math__E = 2.718281828459045;

static double math__TAU = 6.283185307179586;

static double math__PHI = 1.618033988749895;

void __blorp_init_globals(void) {
}

static blorp_List* brp_dd(long brp_v_7sd, long brp_v_7sp) {
void* const __blorp_task = __blorp_current_task;
long __start = brp_v_7sd;
long __stop = brp_v_7sp;
long __out_n = ((__stop <= __start) ? 0 : (__stop - __start));
blorp_List* __result = blorp_list_new_inline(__out_n, 8);
blorp_CancelCleanupFrame __blorp_cleanup___result;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___result, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___result, &__result, (void*)__result, blorp_cleanup_release_arc_value, __blorp_task);
{
long __tq_0 = 0;
long __tp_0 = __out_n;
for (long __i = __tq_0; __i < __tp_0; __i++) {
{
blorp_cooperative_checkpoint();
}
(void)(({ blorp_List* __list_store_inline_set = (blorp_List*)__result; long __list_store_idx_inline_set = __i; long __list_store_value_inline_set = (__start + __i); if (__list_store_inline_set && __list_store_idx_inline_set >= 0 && __list_store_idx_inline_set < __list_store_inline_set->capacity) { memcpy((char*)__list_store_inline_set->data + __list_store_idx_inline_set * 8, &__list_store_value_inline_set, 8); } }));
}
}
{
  (void)((((blorp_List*)__result)->len = __out_n));
}
blorp_List* __tg_1 = __result;
blorp_task_cleanup_pop_slot_with_task(&__result, __blorp_task);
  return __tg_1;
}
/* function bytes__from_hex kind=builtin def_id=168 */
/* function bytes__encode_utf8 kind=builtin def_id=169 */
/* function bytes__decode_utf8 kind=builtin def_id=170 */
static brp_ty0* brp_40(long brp_v_oE) {
long __t10_0 = brp_v_oE;
void* __t10_1 = NULL;
brp_ty0* __t11_2 = brp_ty0_make(__t10_0, __t10_1);
  return __t11_2;
}
static long brp_3Z(long brp_v_gf) {
brp_ty0* brp_v_gC = brp_40(brp_v_gf);
{
blorp_retain(brp_v_gC);
if ((brp_v_gC->f0 != 0)) {
void* __blorp_internal_match_scrut_247_39_13_45_9_3 = ({
void* brp_vt_2F0R4KvIIy_j0 = brp_v_gC->f1;
blorp_retain(brp_vt_2F0R4KvIIy_j0);
brp_vt_2F0R4KvIIy_j0;
});
if (__blorp_internal_match_scrut_247_39_13_45_9_3 != NULL) {
blorp_String* brp_v_i4 = __blorp_internal_match_scrut_247_39_13_45_9_3;
blorp_release(brp_v_gC);
(void)(brp_pV(brp_v_i4));
} else if (__blorp_internal_match_scrut_247_39_13_45_9_3 == NULL) {
blorp_release(brp_v_gC);
(void)((void)0);
} else {
fprintf(stderr, "blorp: non-exhaustive match\n");
abort();
}
blorp_release_arc_only(__blorp_internal_match_scrut_247_39_13_45_9_3);
} else {
blorp_release(brp_v_gC);
(void)((void)0);
}
}
long brp_vd_pgC_d0 = brp_v_gC->f0;
blorp_release(brp_v_gC);
  return brp_vd_pgC_d0;
}
static void brp_bE(blorp_String* brp_v_5k) {
  (void)(blorp_print(brp_v_5k));
}
static void brp_bI(blorp_String* brp_v_dS) {
  (void)(blorp_print_error(brp_v_dS));
}
static blorp_String* brp_hx(blorp_String* brp_v_5Vp) {
blorp_retain(brp_v_5Vp);
  return brp_v_5Vp;
}
/* function vector__cross kind=unresolved_builtin def_id=1586 */
/* function stream__from_range kind=builtin def_id=1007 */
static long brp_21(brp_ty2* brp_v_6E) {
brp_ty2* __to_0 = brp_v_6E;
long __tn_1;
if (((brp_ty2*)__to_0)->tag == brp_t_1Y) {
long brp_v_7q = ((long)(long)((brp_ty2*)__to_0)->data.Circle.field1);
__tn_1 = ((3 * brp_v_7q) * brp_v_7q);
} else if (((brp_ty2*)__to_0)->tag == brp_t_1Z) {
brp_ty1* brp_v_7O = ((brp_ty1*)((brp_ty2*)__to_0)->data.Rect.field0);
brp_ty1* brp_v_7R = ((brp_ty1*)((brp_ty2*)__to_0)->data.Rect.field1);
__tn_1 = ((brp_v_7R->f0 - brp_v_7O->f0) * (brp_v_7R->f1 - brp_v_7O->f1));
} else if (((brp_ty2*)__to_0)->tag == brp_t_20) {
__tn_1 = 0;
} else {
fprintf(stderr, "blorp: non-exhaustive match\n");
abort();
}
  return __tn_1;
}
static blorp_String* brp_22(brp_ty2* brp_v_8X) {
brp_ty2* __to_0 = brp_v_8X;
blorp_String* __tn_1;
if (((brp_ty2*)__to_0)->tag == brp_t_1Y) {
brp_ty1* brp_v_9J = ((brp_ty1*)((brp_ty2*)__to_0)->data.Circle.field0);
long brp_v_9R = ((long)(long)((brp_ty2*)__to_0)->data.Circle.field1);
long __t0_2 = 6;
blorp_String* __t0_3 = (blorp_String*)&__blorp_string_literal_1;
blorp_String* __t0_4 = blorp_to_string(brp_v_9J->f0);
blorp_String* __t0_5 = (blorp_String*)&__blorp_string_literal_2;
blorp_String* __t0_6 = blorp_to_string(brp_v_9J->f1);
blorp_String* __t0_7 = (blorp_String*)&__blorp_string_literal_3;
blorp_String* __t0_8 = blorp_to_string(brp_v_9R);
__tn_1 = blorp_string_concat_many(__t0_2, __t0_3, __t0_4, __t0_5, __t0_6, __t0_7, __t0_8);
} else if (((brp_ty2*)__to_0)->tag == brp_t_1Z) {
brp_ty1* brp_v_aM = ((brp_ty1*)((brp_ty2*)__to_0)->data.Rect.field0);
brp_ty1* brp_v_aP = ((brp_ty1*)((brp_ty2*)__to_0)->data.Rect.field1);
long __t0_9 = 8;
blorp_String* __t0_10 = (blorp_String*)&__blorp_string_literal_4;
blorp_String* __t0_11 = blorp_to_string(brp_v_aM->f0);
blorp_String* __t0_12 = (blorp_String*)&__blorp_string_literal_2;
blorp_String* __t0_13 = blorp_to_string(brp_v_aM->f1);
blorp_String* __t0_14 = (blorp_String*)&__blorp_string_literal_5;
blorp_String* __t0_15 = blorp_to_string(brp_v_aP->f0);
blorp_String* __t0_16 = (blorp_String*)&__blorp_string_literal_2;
blorp_String* __t0_17 = blorp_to_string(brp_v_aP->f1);
__tn_1 = blorp_string_concat_many(__t0_9, __t0_10, __t0_11, __t0_12, __t0_13, __t0_14, __t0_15, __t0_16, __t0_17);
} else if (((brp_ty2*)__to_0)->tag == brp_t_20) {
__tn_1 = (blorp_String*)&__blorp_string_literal_0;
} else {
fprintf(stderr, "blorp: non-exhaustive match\n");
abort();
}
  return __tn_1;
}
static brp_ty2* brp_23(long brp_v_cc) {
brp_ty1* brp_v_cv = ({
long __t10_0 = brp_v_cc;
long __t10_1 = (brp_v_cc + 1);
brp_ty1* __t11_2 = brp_ty1_make(__t10_0, __t10_1);
__t11_2;
});
brp_ty1* brp_v_d7 = brp_ty1_make(0, 0);
brp_ty1* brp_v_dF = ({
long __t10_3 = brp_v_cc;
long __t10_4 = (brp_v_cc * 2);
brp_ty1* __t11_5 = brp_ty1_make(__t10_3, __t10_4);
__t11_5;
});
  return ((({ long __blorp_internal_arithmetic_left = brp_v_cc; long __blorp_internal_arithmetic_right = 3; (__blorp_internal_arithmetic_right == 0 ? 0 : (__blorp_internal_arithmetic_right == -1 && __blorp_internal_arithmetic_left == LONG_MIN ? 0 : (__blorp_internal_arithmetic_left % __blorp_internal_arithmetic_right))); }) == 0) ? ({ blorp_release(brp_v_d7);
 ({ blorp_release(brp_v_dF);
 brp_c_1Y((void*)brp_v_cv, (void*)(long)((brp_v_cc + 2)), 1UL); }); }) : ({ blorp_release(brp_v_cv);
 ((({ long __blorp_internal_arithmetic_left = brp_v_cc; long __blorp_internal_arithmetic_right = 3; (__blorp_internal_arithmetic_right == 0 ? 0 : (__blorp_internal_arithmetic_right == -1 && __blorp_internal_arithmetic_left == LONG_MIN ? 0 : (__blorp_internal_arithmetic_left % __blorp_internal_arithmetic_right))); }) == 1) ? brp_c_1Z((void*)brp_v_d7, (void*)brp_v_dF, 3UL) : ({ blorp_release(brp_v_d7);
 ({ blorp_release(brp_v_dF);
 brp_c_20; }); })); }));
}
static long brp_24(long brp_v_g8, long brp_v_gi) {
  return (brp_v_g8 + brp_v_gi);
}
static blorp_Dict* brp_25(blorp_Dict* brp_v_h7, blorp_String* brp_v_hv) {
void* const __blorp_task = __blorp_current_task;
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_h7;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_h7, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_h7, &brp_v_h7, (void*)brp_v_h7, blorp_cleanup_release_arc_value, __blorp_task);
blorp_Dict* __t0_0 = brp_v_h7;
blorp_String* __t0_1 = brp_v_hv;
long __t0_2 = (brp_pX(brp_v_h7, brp_v_hv, 0) + 1);
blorp_task_cleanup_pop_slot_with_task(&brp_v_h7, __blorp_task);
  return brp_pW(__t0_0, __t0_1, __t0_2);
}
static long brp_26(blorp_List* brp_v_iV) {
void* const __blorp_task = __blorp_current_task;
blorp_List* brp_v_jo = ({
blorp_List* brp_vt_9nC5wcY_b0 = brp_dd(0, 30);
blorp_CancelCleanupFrame __blorp_cleanup_brp_vt_9nC5wcY_b0;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_vt_9nC5wcY_b0, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_vt_9nC5wcY_b0, &brp_vt_9nC5wcY_b0, (void*)brp_vt_9nC5wcY_b0, blorp_cleanup_release_arc_value, __blorp_task);
blorp_List* brp_vd_t9nC5wcY_b0_d0 = ({
blorp_List* __t0_0 = brp_vt_9nC5wcY_b0;
blorp_Closure* __t0_1 = ((void*)&__sc_brp_q4);
brp_pY(__t0_0, __t0_1);
});
blorp_task_cleanup_pop_slot_with_task(&brp_vt_9nC5wcY_b0, __blorp_task);
blorp_release(brp_vt_9nC5wcY_b0);
brp_vd_t9nC5wcY_b0_d0;
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_jo;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_jo, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_jo, &brp_v_jo, (void*)brp_v_jo, blorp_cleanup_release_arc_value, __blorp_task);
long brp_vd_pjo_d0 = ({
long brp_v_ki = ({
blorp_List* brp_vt_9wS2rdn_b0 = ({
blorp_List* __t0_2 = brp_v_jo;
blorp_Closure* __t0_3 = ((void*)&__sc_brp_q5);
brp_q0(__t0_2, __t0_3);
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_vt_9wS2rdn_b0;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_vt_9wS2rdn_b0, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_vt_9wS2rdn_b0, &brp_vt_9wS2rdn_b0, (void*)brp_vt_9wS2rdn_b0, blorp_cleanup_release_arc_value, __blorp_task);
long brp_vd_t9wS2rdn_b0_d0 = ({
blorp_List* __t0_4 = brp_vt_9wS2rdn_b0;
long __t0_5 = 0;
blorp_Closure* __t0_6 = ((void*)&__sc_brp_q6);
brp_pZ(__t0_4, __t0_5, __t0_6);
});
blorp_task_cleanup_pop_slot_with_task(&brp_vt_9wS2rdn_b0, __blorp_task);
blorp_release(brp_vt_9wS2rdn_b0);
brp_vd_t9wS2rdn_b0_d0;
});
blorp_List* brp_v_l9 = ({
blorp_List* __t0_7 = brp_v_jo;
blorp_Closure* __t0_8 = ((void*)&__sc_brp_q7);
brp_q1(__t0_7, __t0_8);
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_l9;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_l9, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_l9, &brp_v_l9, (void*)brp_v_l9, blorp_cleanup_release_arc_value, __blorp_task);
long brp_vd_pl9_d0 = ({
blorp_Dict* brp_v_lV = blorp_dict_new_string();
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_lV;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_lV, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_lV, &brp_v_lV, (void*)brp_v_lV, blorp_cleanup_release_arc_value, __blorp_task);
long brp_vd_plV_d0 = ({
blorp_Dict* brp_v_mu = ({
blorp_List* __t0_9 = brp_v_l9;
blorp_Dict* __t0_10 = brp_v_lV;
blorp_Closure* __t0_11 = ((void*)&__sc_brp_q8);
brp_q2(__t0_9, __t0_10, __t0_11);
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_mu;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_mu, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_mu, &brp_v_mu, (void*)brp_v_mu, blorp_cleanup_release_arc_value, __blorp_task);
long brp_vd_pmu_d0 = ({
{
blorp_String* brp_vt_a8fYPo3_b0 = ({
blorp_String* brp_vt_a8jo0WO_b1 = blorp_to_string(brp_v_ki);
blorp_String* brp_vd_ta8jo0WO_b1_d0 = blorp_string_concat((blorp_String*)&__blorp_string_literal_6, brp_vt_a8jo0WO_b1);
blorp_release(brp_vt_a8jo0WO_b1);
brp_vd_ta8jo0WO_b1_d0;
});
{
  (void)(brp_q3(brp_vt_a8fYPo3_b0));
}
blorp_release(brp_vt_a8fYPo3_b0);
  (void)((void)0);
}
{
blorp_String* brp_vt_ahDjjMx_b0 = ({
blorp_String* brp_vt_ahGIvli_b1 = blorp_to_string(brp_pX(brp_v_mu, (blorp_String*)&__blorp_string_literal_0, 0));
blorp_String* brp_vd_tahGIvli_b1_d0 = blorp_string_concat((blorp_String*)&__blorp_string_literal_7, brp_vt_ahGIvli_b1);
blorp_release(brp_vt_ahGIvli_b1);
brp_vd_tahGIvli_b1_d0;
});
{
  (void)(brp_q3(brp_vt_ahDjjMx_b0));
}
blorp_release(brp_vt_ahDjjMx_b0);
  (void)((void)0);
}
0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_mu, __blorp_task);
blorp_release(brp_v_mu);
brp_vd_pmu_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_lV, __blorp_task);
blorp_release(brp_v_lV);
brp_vd_plV_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_l9, __blorp_task);
blorp_release(brp_v_l9);
brp_vd_pl9_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_jo, __blorp_task);
blorp_release(brp_v_jo);
  return brp_vd_pjo_d0;
}
int main(int argc, char** argv) {
  __blorp_init_globals();
  blorp_List* brp_v_iV = blorp_list_new(argc);
  blorp_list_init_elem_release(brp_v_iV, blorp_elem_release_fn);
  for (int __i = 0; __i < argc; __i++) brp_v_iV = blorp_list_append_owned(brp_v_iV, (void*)blorp_string_create(argv[__i]));
  int __blorp_main_result = (int)brp_3Z(brp_26(brp_v_iV));
  blorp_release(brp_v_iV);
  return (int)__blorp_main_result;
}
static void brp_pV(blorp_String* brp_v_ck) {
blorp_String* brp_vt_4ZoKNh6DCt_b0 = brp_hx(brp_v_ck);
{
  (void)(brp_bI(brp_vt_4ZoKNh6DCt_b0));
}
blorp_release(brp_vt_4ZoKNh6DCt_b0);
  (void)((void)0);
}
static blorp_Dict* brp_pW(blorp_Dict* brp_v_DH, blorp_String* brp_v_DZ, long brp_v_E7) {
void* const __blorp_task = __blorp_current_task;
blorp_Dict* __result = blorp_dict_cow((blorp_Dict*)brp_v_DH);
blorp_CancelCleanupFrame __blorp_cleanup___result;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___result, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___result, &__result, (void*)__result, blorp_cleanup_release_arc_value, __blorp_task);
{
if ((((blorp_Dict*)__result)->order_len >= ((blorp_Dict*)__result)->capacity)) {
blorp_Dict* __t0_0 = __result;
long __t0_1 = ((blorp_Dict*)__result)->capacity;
(void)(blorp_dict_resize_to((blorp_Dict*)__t0_0, __t0_1));
}
}
{
void* __set_key = ((void*)brp_v_DZ);
{
void* __dict_insert_key = __set_key;
void* __dict_insert_value = (void*)(long)(brp_v_E7);
long __dict_insert_hash = ((long)((blorp_Dict*)__result)->hash_fn(__dict_insert_key));
long __dict_insert_h2 = ({
long __t0_2 = (((long)(__dict_insert_hash)) >> (57 & 63));
long __t0_3 = 127;
(__t0_2 & __t0_3);
});
long __dict_insert_idx = ({
long __t0_4 = __dict_insert_hash;
long __t0_5 = ((blorp_Dict*)__result)->mask;
(__t0_4 & __t0_5);
});
long __dict_insert_first_available = -1;
long __dict_insert_insert_slot = -1;
long __dict_insert_found_slot = -1;
long __dict_insert_probes = 0;
{
while ((__dict_insert_probes <= ((blorp_Dict*)__result)->capacity)) {
{
blorp_cooperative_checkpoint();
}
long __dict_insert_meta = ((long)((blorp_Dict*)__result)->meta[__dict_insert_idx]);
int __th_6;
if ((__dict_insert_meta == __dict_insert_h2)) {
blorp_Dict* __t0_7 = __result;
void* __t0_8 = ((blorp_Dict*)__result)->keys[__dict_insert_idx];
void* __t0_9 = __dict_insert_key;
bool __t4_10 = ((long)((blorp_Dict*)__t0_7)->eq_fn(__t0_8, __t0_9));
__th_6 = __t4_10;
} else {
__th_6 = 0;
}
bool __t4_11 = __th_6;
if (__t4_11) {
{
__dict_insert_found_slot = __dict_insert_idx;
}
break;
} else {
if ((__dict_insert_meta == 255)) {
{
__dict_insert_insert_slot = ((__dict_insert_first_available >= 0) ? __dict_insert_first_available : __dict_insert_idx);
}
break;
} else {
{
if (((__dict_insert_meta == 128) && (__dict_insert_first_available < 0))) {
__dict_insert_first_available = __dict_insert_idx;
}
}
{
long __t0_12 = (__dict_insert_idx + 1);
long __t0_13 = ((blorp_Dict*)__result)->mask;
__dict_insert_idx = (__t0_12 & __t0_13);
}
__dict_insert_probes = (__dict_insert_probes + 1);
}
}
}
}
{
if (((__dict_insert_insert_slot < 0) && (__dict_insert_first_available >= 0))) {
__dict_insert_insert_slot = __dict_insert_first_available;
}
}
{
if ((__dict_insert_found_slot >= 0)) {
void* __dict_insert_old_value = ((blorp_Dict*)__result)->values[__dict_insert_found_slot];
if ((__dict_insert_old_value != __dict_insert_value)) {
{
  (void)(({ blorp_Dict* __rtd = (blorp_Dict*)__result; void* __rv = (void*)__dict_insert_old_value; if (__rtd->value_release && __rv) __rtd->value_release(__rv); (void)0; }));
}
{
  (void)(({ blorp_Dict* __rtd = (blorp_Dict*)__result; void* __rtv = (void*)__dict_insert_value; if (__rtd->value_release && __rtv) blorp_retain(__rtv); (void)0; }));
}
(void)((((blorp_Dict*)__result)->values[__dict_insert_found_slot] = __dict_insert_value));
}
} else {
long __dict_insert_order_len = ((blorp_Dict*)__result)->order_len;
long __dict_insert_new_len = (((blorp_Dict*)__result)->size + 1);
long __dict_insert_new_order_len = (__dict_insert_order_len + 1);
{
  (void)((((blorp_Dict*)__result)->meta[__dict_insert_insert_slot] = (uint8_t)__dict_insert_h2));
}
{
  (void)(({ blorp_Dict* __rtd = (blorp_Dict*)__result; void* __rtk = (void*)__dict_insert_key; if (__rtd->key_release && __rtk) blorp_retain(__rtk); (void)0; }));
}
{
  (void)(({ blorp_Dict* __rtd = (blorp_Dict*)__result; void* __rtv = (void*)__dict_insert_value; if (__rtd->value_release && __rtv) blorp_retain(__rtv); (void)0; }));
}
{
  (void)((((blorp_Dict*)__result)->keys[__dict_insert_insert_slot] = __dict_insert_key));
}
{
  (void)((((blorp_Dict*)__result)->values[__dict_insert_insert_slot] = __dict_insert_value));
}
{
  (void)((((blorp_Dict*)__result)->order_index[__dict_insert_insert_slot] = __dict_insert_order_len));
}
{
  (void)((((blorp_Dict*)__result)->order[__dict_insert_order_len] = __dict_insert_insert_slot));
}
{
  (void)((((blorp_Dict*)__result)->order_len = __dict_insert_new_order_len));
}
{
  (void)((((blorp_Dict*)__result)->size = __dict_insert_new_len));
}
if ((__dict_insert_new_len >= ((blorp_Dict*)__result)->grow_at)) {
blorp_Dict* __t0_14 = __result;
long __t0_15 = (((blorp_Dict*)__result)->capacity * 2);
(void)(blorp_dict_resize_to((blorp_Dict*)__t0_14, __t0_15));
}
}
}
  (void)((void)0);
}
  (void)((void)0);
}
blorp_Dict* __tg_16 = __result;
blorp_task_cleanup_pop_slot_with_task(&__result, __blorp_task);
  return __tg_16;
}
static long brp_pX(blorp_Dict* brp_v_1lg, blorp_String* brp_v_1ly, long brp_v_1lG) {
long __dict_get_or_slot = ({
void* __get_or_key = ((void*)brp_v_1ly);
long __get_or_key_result = ({
void* __dict_lookup_key = __get_or_key;
long __dict_lookup_hash = ((long)((blorp_Dict*)brp_v_1lg)->hash_fn(__dict_lookup_key));
long __dict_lookup_h2 = ({
long __t0_0 = (((long)(__dict_lookup_hash)) >> (57 & 63));
long __t0_1 = 127;
(__t0_0 & __t0_1);
});
long __dict_lookup_idx = ({
long __t0_2 = __dict_lookup_hash;
long __t0_3 = ((blorp_Dict*)brp_v_1lg)->mask;
(__t0_2 & __t0_3);
});
long __dict_lookup_found_slot = -1;
long __dict_lookup_probes = 0;
{
while ((__dict_lookup_probes <= ((blorp_Dict*)brp_v_1lg)->capacity)) {
{
blorp_cooperative_checkpoint();
}
long __dict_lookup_meta = ((long)((blorp_Dict*)brp_v_1lg)->meta[__dict_lookup_idx]);
int __th_4;
if ((__dict_lookup_meta == __dict_lookup_h2)) {
blorp_Dict* __t0_5 = brp_v_1lg;
void* __t0_6 = ((blorp_Dict*)brp_v_1lg)->keys[__dict_lookup_idx];
void* __t0_7 = __dict_lookup_key;
bool __t4_8 = ((long)((blorp_Dict*)__t0_5)->eq_fn(__t0_6, __t0_7));
__th_4 = __t4_8;
} else {
__th_4 = 0;
}
bool __t4_9 = __th_4;
if (__t4_9) {
{
__dict_lookup_found_slot = __dict_lookup_idx;
}
break;
} else {
if ((__dict_lookup_meta == 255)) {
break;
} else {
{
long __t0_10 = (__dict_lookup_idx + 1);
long __t0_11 = ((blorp_Dict*)brp_v_1lg)->mask;
__dict_lookup_idx = (__t0_10 & __t0_11);
}
__dict_lookup_probes = (__dict_lookup_probes + 1);
}
}
}
}
__dict_lookup_found_slot;
});
{
  (void)((void)0);
}
__get_or_key_result;
});
long __tb_12;
if ((__dict_get_or_slot >= 0)) {
void* __dict_get_or_value = ((blorp_Dict*)brp_v_1lg)->values[__dict_get_or_slot];
{
  (void)(({ blorp_Dict* __rtd = (blorp_Dict*)brp_v_1lg; void* __rtv = (void*)__dict_get_or_value; if (__rtd->value_release && __rtv) blorp_retain(__rtv); (void)0; }));
}
__tb_12 = ((long)(long)__dict_get_or_value);
} else {
__tb_12 = brp_v_1lG;
}
  return __tb_12;
}
static blorp_List* brp_pY(blorp_List* brp_v_294, blorp_Closure* brp_v_29k) {
void* const __blorp_task = __blorp_current_task;
blorp_List* __self = brp_v_294;
blorp_Closure* __callback = ({ blorp_retain(brp_v_29k);
 brp_v_29k; });
blorp_CancelCleanupFrame __blorp_cleanup___callback;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___callback, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___callback, &__callback, (void*)__callback, blorp_cleanup_release_arc_value, __blorp_task);
blorp_List* brp_vd_z__callback_d0 = ({
long __n = ((blorp_List*)__self)->len;
blorp_List* __result = ({ blorp_List* __list_alloc = blorp_list_new(__n); blorp_list_init_elem_release(__list_alloc, blorp_elem_release_fn); __list_alloc; });
blorp_CancelCleanupFrame __blorp_cleanup___result;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___result, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___result, &__result, (void*)__result, blorp_cleanup_release_arc_value, __blorp_task);
{
long __tq_0 = 0;
long __tp_0 = __n;
for (long __i = __tq_0; __i < __tp_0; __i++) {
{
blorp_cooperative_checkpoint();
}
brp_ty2* __mapped = ({ blorp_Closure* __cl = (blorp_Closure*)__callback; void* __cl_arg_0 = (void*)(long)(({ blorp_List* __lg_list = (blorp_List*)__self; long __lg_idx = __i; long __lg_value = 0; if (__builtin_expect(!__lg_list || __lg_idx < 0 || __lg_idx >= __lg_list->len, 0)) { } else { memcpy(&__lg_value, (char*)__lg_list->data + __lg_idx * 8, 8); } __lg_value; })); void* __cl_r = ((void* (*)(void*, void*))(__cl->func))(__cl->env, __cl_arg_0); ((brp_ty2*)__cl_r); });
(void)(({ blorp_list_set_raw((blorp_List*)__result, __i, (void*)__mapped); }));
}
}
{
  (void)((((blorp_List*)__result)->len = __n));
}
blorp_List* __tg_1 = __result;
blorp_task_cleanup_pop_slot_with_task(&__result, __blorp_task);
__tg_1;
});
blorp_task_cleanup_pop_slot_with_task(&__callback, __blorp_task);
blorp_release(__callback);
  return brp_vd_z__callback_d0;
}
static long brp_pZ(blorp_List* brp_v_2Wf, long brp_v_2Wv, blorp_Closure* brp_v_2WH) {
void* const __blorp_task = __blorp_current_task;
blorp_List* __self = brp_v_2Wf;
blorp_Closure* __callback = ({ blorp_retain(brp_v_2WH);
 brp_v_2WH; });
blorp_CancelCleanupFrame __blorp_cleanup___callback;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___callback, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___callback, &__callback, (void*)__callback, blorp_cleanup_release_arc_value, __blorp_task);
long brp_vd_z__callback_d0 = ({
long __n = ((blorp_List*)__self)->len;
long __acc = brp_v_2Wv;
{
long __tq_0 = 0;
long __tp_0 = __n;
for (long __offset = __tq_0; __offset < __tp_0; __offset++) {
{
blorp_cooperative_checkpoint();
}
long __next = ({
blorp_Closure* __t18_1 = __callback;
long __t0_2 = __acc;
long __t0_3 = ({ blorp_List* __lg_list = (blorp_List*)__self; long __lg_idx = __offset; long __lg_value = 0; if (__builtin_expect(!__lg_list || __lg_idx < 0 || __lg_idx >= __lg_list->len, 0)) { } else { memcpy(&__lg_value, (char*)__lg_list->data + __lg_idx * 8, 8); } __lg_value; });
({ blorp_Closure* __cl = (blorp_Closure*)__t18_1; void* __cl_arg_0 = (void*)(long)(__t0_2); void* __cl_arg_1 = (void*)(long)(__t0_3); void* __cl_r = ((void* (*)(void*, void*, void*))(__cl->func))(__cl->env, __cl_arg_0, __cl_arg_1); ((long)(long)__cl_r); });
});
__acc = __next;
}
}
__acc;
});
blorp_task_cleanup_pop_slot_with_task(&__callback, __blorp_task);
blorp_release(__callback);
  return brp_vd_z__callback_d0;
}
static blorp_List* brp_q0(blorp_List* brp_v_294, blorp_Closure* brp_v_29k) {
void* const __blorp_task = __blorp_current_task;
blorp_List* __self = brp_v_294;
blorp_Closure* __callback = ({ blorp_retain(brp_v_29k);
 brp_v_29k; });
blorp_CancelCleanupFrame __blorp_cleanup___callback;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___callback, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___callback, &__callback, (void*)__callback, blorp_cleanup_release_arc_value, __blorp_task);
blorp_List* brp_vd_z__callback_d0 = ({
long __n = ((blorp_List*)__self)->len;
blorp_List* __result = blorp_list_new_inline(__n, 8);
blorp_CancelCleanupFrame __blorp_cleanup___result;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___result, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___result, &__result, (void*)__result, blorp_cleanup_release_arc_value, __blorp_task);
{
long __tq_0 = 0;
long __tp_0 = __n;
for (long __i = __tq_0; __i < __tp_0; __i++) {
{
blorp_cooperative_checkpoint();
}
long __mapped = ({ blorp_Closure* __cl = (blorp_Closure*)__callback; void* __cl_arg_0 = (void*)((brp_ty2*)blorp_list_get((blorp_List*)__self, __i)); void* __cl_r = ((void* (*)(void*, void*))(__cl->func))(__cl->env, __cl_arg_0); ((long)(long)__cl_r); });
(void)(({ blorp_List* __list_store_inline_set = (blorp_List*)__result; long __list_store_idx_inline_set = __i; long __list_store_value_inline_set = __mapped; if (__list_store_inline_set && __list_store_idx_inline_set >= 0 && __list_store_idx_inline_set < __list_store_inline_set->capacity) { memcpy((char*)__list_store_inline_set->data + __list_store_idx_inline_set * 8, &__list_store_value_inline_set, 8); } }));
}
}
{
  (void)((((blorp_List*)__result)->len = __n));
}
blorp_List* __tg_1 = __result;
blorp_task_cleanup_pop_slot_with_task(&__result, __blorp_task);
__tg_1;
});
blorp_task_cleanup_pop_slot_with_task(&__callback, __blorp_task);
blorp_release(__callback);
  return brp_vd_z__callback_d0;
}
static blorp_List* brp_q1(blorp_List* brp_v_294, blorp_Closure* brp_v_29k) {
void* const __blorp_task = __blorp_current_task;
blorp_List* __self = brp_v_294;
blorp_Closure* __callback = ({ blorp_retain(brp_v_29k);
 brp_v_29k; });
blorp_CancelCleanupFrame __blorp_cleanup___callback;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___callback, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___callback, &__callback, (void*)__callback, blorp_cleanup_release_arc_value, __blorp_task);
blorp_List* brp_vd_z__callback_d0 = ({
long __n = ((blorp_List*)__self)->len;
blorp_List* __result = ({ blorp_List* __list_alloc = blorp_list_new(__n); blorp_list_init_elem_release(__list_alloc, blorp_elem_release_fn); __list_alloc; });
blorp_CancelCleanupFrame __blorp_cleanup___result;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___result, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___result, &__result, (void*)__result, blorp_cleanup_release_arc_value, __blorp_task);
{
long __tq_0 = 0;
long __tp_0 = __n;
for (long __i = __tq_0; __i < __tp_0; __i++) {
{
blorp_cooperative_checkpoint();
}
blorp_String* __mapped = ({ blorp_Closure* __cl = (blorp_Closure*)__callback; void* __cl_arg_0 = (void*)((brp_ty2*)blorp_list_get((blorp_List*)__self, __i)); void* __cl_r = ((void* (*)(void*, void*))(__cl->func))(__cl->env, __cl_arg_0); ((blorp_String*)__cl_r); });
(void)(({ blorp_list_set_raw((blorp_List*)__result, __i, (void*)__mapped); }));
}
}
{
  (void)((((blorp_List*)__result)->len = __n));
}
blorp_List* __tg_1 = __result;
blorp_task_cleanup_pop_slot_with_task(&__result, __blorp_task);
__tg_1;
});
blorp_task_cleanup_pop_slot_with_task(&__callback, __blorp_task);
blorp_release(__callback);
  return brp_vd_z__callback_d0;
}
static blorp_Dict* brp_q2(blorp_List* brp_v_2Wf, blorp_Dict* brp_v_2Wv, blorp_Closure* brp_v_2WH) {
void* const __blorp_task = __blorp_current_task;
blorp_List* __self = brp_v_2Wf;
blorp_Closure* __callback = ({ blorp_retain(brp_v_2WH);
 brp_v_2WH; });
blorp_CancelCleanupFrame __blorp_cleanup___callback;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___callback, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___callback, &__callback, (void*)__callback, blorp_cleanup_release_arc_value, __blorp_task);
blorp_Dict* brp_vd_z__callback_d0 = ({
long __n = ((blorp_List*)__self)->len;
blorp_Dict* __acc = ({ blorp_retain(brp_v_2Wv);
 brp_v_2Wv; });
blorp_CancelCleanupFrame __blorp_cleanup___acc;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup___acc, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup___acc, &__acc, (void*)__acc, blorp_cleanup_release_arc_value, __blorp_task);
{
long __tq_0 = 0;
long __tp_0 = __n;
for (long __offset = __tq_0; __offset < __tp_0; __offset++) {
{
blorp_cooperative_checkpoint();
}
blorp_Dict* __next = ({
blorp_Closure* __t18_1 = __callback;
blorp_Dict* __t0_2 = __acc;
blorp_String* __t0_3 = ((blorp_String*)blorp_list_get((blorp_List*)__self, __offset));
({ blorp_Closure* __cl = (blorp_Closure*)__t18_1; void* __cl_arg_0 = (void*)__t0_2; void* __cl_arg_1 = (void*)__t0_3; void* __cl_r = ((void* (*)(void*, void*, void*))(__cl->func))(__cl->env, __cl_arg_0, __cl_arg_1); ((blorp_Dict*)__cl_r); });
});
{
blorp_Dict* brp_vd_z__acc_a0 = ({
blorp_Dict* brp_vt_5uFzovh2zo4_j0 = __next;
blorp_retain(brp_vt_5uFzovh2zo4_j0);
brp_vt_5uFzovh2zo4_j0;
});
{
blorp_task_cleanup_pop_slot_with_task(&__acc, __blorp_task);
blorp_release(__acc);
  (void)((void)0);
}
__acc = brp_vd_z__acc_a0;
blorp_task_cleanup_rearm_with_task(&__blorp_cleanup___acc, &__acc, (void*)__acc, blorp_cleanup_release_arc_value, __blorp_task);
}
blorp_release(__next);
(void)((void)0);
}
}
blorp_Dict* __tg_4 = __acc;
blorp_task_cleanup_pop_slot_with_task(&__acc, __blorp_task);
__tg_4;
});
blorp_task_cleanup_pop_slot_with_task(&__callback, __blorp_task);
blorp_release(__callback);
  return brp_vd_z__callback_d0;
}
static void brp_q3(blorp_String* brp_v_3Y) {
blorp_String* brp_vt_4ZoHjCvmFp_b0 = brp_hx(brp_v_3Y);
{
  (void)(brp_bE(brp_vt_4ZoHjCvmFp_b0));
}
blorp_release(brp_vt_4ZoHjCvmFp_b0);
  (void)((void)0);
}
static void* brp_q4(void* __env, void* __arg0) {
  (void)__env;
  long __eta_arg_0 = (long)(long)__arg0;
  return (void*)brp_23(__eta_arg_0);
}
static blorp_Closure __sc_brp_q4 = { { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, (void*)brp_q4, NULL, 0, 0 };
static void* brp_q5(void* __env, void* __arg0) {
  (void)__env;
  brp_ty2* __eta_arg_0 = (brp_ty2*)__arg0;
  return (void*)(long)(brp_21(__eta_arg_0));
}
static blorp_Closure __sc_brp_q5 = { { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, (void*)brp_q5, NULL, 0, 0 };
static void* brp_q6(void* __env, void* __arg0, void* __arg1) {
  (void)__env;
  long __eta_arg_0 = (long)(long)__arg0;
  long __eta_arg_1 = (long)(long)__arg1;
  return (void*)(long)(brp_24(__eta_arg_0, __eta_arg_1));
}
static blorp_Closure __sc_brp_q6 = { { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, (void*)brp_q6, NULL, 0, 0 };
static void* brp_q7(void* __env, void* __arg0) {
  (void)__env;
  brp_ty2* __eta_arg_0 = (brp_ty2*)__arg0;
  return (void*)brp_22(__eta_arg_0);
}
static blorp_Closure __sc_brp_q7 = { { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, (void*)brp_q7, NULL, 0, 0 };
static void* brp_q8(void* __env, void* __arg0, void* __arg1) {
  (void)__env;
  blorp_Dict* __eta_arg_0 = (blorp_Dict*)__arg0;
  blorp_String* __eta_arg_1 = (blorp_String*)__arg1;
blorp_Dict* __t0_0;
{
blorp_retain(__eta_arg_0);
  __t0_0 = __eta_arg_0;
}
blorp_String* __t0_1 = __eta_arg_1;
  return (void*)brp_25(__t0_0, __t0_1);
}
static blorp_Closure __sc_brp_q8 = { { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, (void*)brp_q8, NULL, 0, 0 };
