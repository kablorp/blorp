long brp_vn_8 = ({ blorp_List* __lg_list = (blorp_List*)brp_vn_5; long __lg_idx = brp_vn_6; long __lg_value = 0; memcpy(&__lg_value, (char*)__lg_list->data + __lg_idx * 8, 8); __lg_value; });
{
  (void)((void)0);
}
__tb_9 = brp_vn_8;
} else {
__tb_9 = brp_vn_7;
}
  __t0_10 = __tb_9;
}
long __t0_11 = (brp_v_1II + 1);
long __t0_12 = brp_v_1G2;
brp_7fc(__t0_8, __t0_10, __t0_11, __t0_12);
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_1Ft, __blorp_task);
blorp_release(brp_v_1Ft);
__tn_3 = brp_vd_p1Ft_d0;
} else if (__blorp_internal_match_scrut_27839_221_5_239_1_2 == NULL) {
brp_ty4o* brp_vd_p1Ft_d0 = brp_7fe(brp_v_1Ft, brp_v_1G2);
blorp_task_cleanup_pop_slot_with_task(&brp_v_1Ft, __blorp_task);
blorp_release(brp_v_1Ft);
__tn_3 = brp_vd_p1Ft_d0;
} else {
fprintf(stderr, "blorp: non-exhaustive match\n");
abort();
}
blorp_task_cleanup_pop_slot_with_task(&__blorp_internal_match_scrut_27839_221_5_239_1_2, __blorp_task);
blorp_release(__blorp_internal_match_scrut_27839_221_5_239_1_2);
brp_ty4o* __tg_13 = __tn_3;
blorp_task_cleanup_pop_slot_with_task(&brp_v_1Ft, __blorp_task);
  return __tg_13;
}
static brp_ty4p* brp_7f2(brp_ty4r* brp_v_1OU, long brp_v_1Pe) {
void* const __blorp_task = __blorp_current_task;
static brp_ty4o* brp_7fc(blorp_String* brp_v_2z9, long brp_v_2zo, long brp_v_2zI, long brp_v_2A0) {
long brp_v_2Av = brp_v_2zo;
long brp_v_2B1 = brp_v_2zI;
long brp_v_2Bt = 1;
{
while ((brp_v_2Av < brp_v_2A0)) {
{
blorp_cooperative_checkpoint();
}
{
int32_t __blorp_internal_match_scrut_27850_327_9_335_9_6 = ({
blorp_StackOption_Char __blorp_option_fusion_27850_0_opt = blorp_string_get_opt(brp_v_2z9, brp_v_2Av);
int32_t __blorp_option_fusion_27850_0_default = 0;
blorp_StackOption_Char __to_0 = __blorp_option_fusion_27850_0_opt;
int32_t __tn_1;
if (__to_0.tag == BLORP_TAG_SOME) {
int32_t __blorp_option_fusion_27850_0_value = __to_0.value;
__tn_1 = __blorp_option_fusion_27850_0_value;
} else if (__to_0.tag == BLORP_TAG_NONE) {
__tn_1 = __blorp_option_fusion_27850_0_default;
} else {
fprintf(stderr, "blorp: non-exhaustive match\n");
abort();
}
__tn_1;
});
int32_t __to_2 = __blorp_internal_match_scrut_27850_327_9_335_9_6;
if (__to_2 == 10) {
{
brp_v_2B1 = (brp_v_2B1 + 1);
}
brp_v_2Bt = 1;
} else if (__to_2 == 9) {
brp_v_2Bt = brp_7fb(brp_v_2Bt);
} else {
brp_v_2Bt = (brp_v_2Bt + 1);
}
}
brp_v_2Av = (brp_v_2Av + 1);
}
}
  return brp_ty4o_make(brp_v_2Av, brp_v_2B1, brp_v_2Bt);
}
static brp_ty4o* brp_7fd(brp_ty4n* brp_v_2Gd, brp_ty4o* brp_v_2Gu) {
blorp_StackOption_Char __blorp_internal_match_scrut_27851_345_5_368_1_0 = brp_7fa(brp_v_2Gd, brp_v_2Gu);
}
static brp_ty4p* brp_7ff(brp_ty4n* brp_v_2Rb, brp_ty4o* brp_v_2Rs, brp_ty4o* brp_v_2RO) {
blorp_String* __t10_0;
{
blorp_String* brp_vt_nCuVO0xOqd_k10985_2Rb = brp_v_2Rb->path;
