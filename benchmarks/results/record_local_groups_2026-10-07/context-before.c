static brp_tyfJ* brp_50Y(brp_tyj3* brp_v_eso, blorp_List* brp_v_esZ, brp_tyfJ* brp_v_etl) {
void* const __blorp_task = __blorp_current_task;
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_etl;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_etl, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_etl, &brp_v_etl, (void*)brp_v_etl, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfJ* __to_0 = brp_v_etl;
brp_tyfJ* __tn_1;
if (((brp_tyfJ*)__to_0)->tag == brp_t_3OI) {
brp_tyfJ* brp_vd_petl_d0 = brp_50t(brp_v_eso, brp_v_esZ, brp_v_etl);
blorp_task_cleanup_pop_slot_with_task(&brp_v_etl, __blorp_task);
blorp_release(brp_v_etl);
__tn_1 = brp_vd_petl_d0;
} else if (((brp_tyfJ*)__to_0)->tag == brp_t_3NV) {
brp_tyfq* brp_v_evs = ((brp_tyfq*)((brp_tyfJ*)__to_0)->data.CallExpr.field0);
brp_tyfJ* brp_v_evy = ((brp_tyfJ*)((brp_tyfJ*)__to_0)->data.CallExpr.field1);
blorp_List* brp_v_evG = ((blorp_List*)((brp_tyfJ*)__to_0)->data.CallExpr.field2);
brp_tyeZ* brp_v_evM = ((brp_tyeZ*)((brp_tyfJ*)__to_0)->data.CallExpr.field3);
long brp_v_evR = ((long)(long)((brp_tyfJ*)__to_0)->data.CallExpr.field4);
blorp_retain(brp_v_evM);
blorp_retain(brp_v_evG);
brp_tyfJ* brp_vd_pevG_d0 = ({
blorp_retain(brp_v_evy);
blorp_retain(brp_v_evs);
brp_tyfJ* brp_vd_pevs_d0 = ({
blorp_task_cleanup_pop_slot_with_task(&brp_v_etl, __blorp_task);
blorp_release(brp_v_etl);
blorp_List* brp_v_ew4 = (blorp_List*)&__blorp_canonical_empty_list_pointer_managed;
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_ew4;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_ew4, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_ew4, &brp_v_ew4, (void*)brp_v_ew4, blorp_cleanup_release_arc_value, __blorp_task);
{
blorp_List* __t1c_2;
{
blorp_retain(brp_v_evG);
  __t1c_2 = brp_v_evG;
}
blorp_List* __tc_3 = __t1c_2;
blorp_CancelCleanupFrame __blorp_owned_cleanup___tc_3;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_owned_cleanup___tc_3, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_owned_cleanup___tc_3, &__tc_3, (void*)__tc_3, blorp_cleanup_release_arc_value, __blorp_task);
long __tf_3 = __tc_3->len; for (long __ta_3 = 0; __ta_3 < __tf_3; __ta_3++) {
brp_tyfJ* brp_v_ewL = ((brp_tyfJ*)__tc_3->data[__ta_3]);
{
blorp_cooperative_checkpoint();
}
brp_tyfJ* brp_vn_1 = ({
brp_tyj4* brp_vt_OTWdap3GZN_b0 = ({
brp_tyj3* brp_vn_1xF = ({ blorp_retain(brp_v_eso);
 brp_v_eso; });
blorp_List* brp_vn_1xG = ({ blorp_retain(brp_v_esZ);
 brp_v_esZ; });
brp_tyj4_make(brp_vn_1xF, brp_vn_1xG);
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_vt_OTWdap3GZN_b0;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_vt_OTWdap3GZN_b0, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_vt_OTWdap3GZN_b0, &brp_vt_OTWdap3GZN_b0, (void*)brp_vt_OTWdap3GZN_b0, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfJ* brp_vd_tOTWdap3GZN_b0_d0 = ({
brp_tyj4* __t0_4 = brp_vt_OTWdap3GZN_b0;
brp_tyfJ* __t0_5;
{
blorp_retain(brp_v_ewL);
  __t0_5 = brp_v_ewL;
}
brp_50r(__t0_4, __t0_5);
});
blorp_task_cleanup_pop_slot_with_task(&brp_vt_OTWdap3GZN_b0, __blorp_task);
blorp_release(brp_vt_OTWdap3GZN_b0);
brp_vd_tOTWdap3GZN_b0_d0;
});
blorp_List* brp_vd_n1_d0 = ({
long brp_vn_2 = ((blorp_List*)brp_v_ew4)->len;
blorp_List* brp_vn_3 = ({
blorp_List* __t0_6 = brp_v_ew4;
long __t0_7 = (brp_vn_2 + 1);
blorp_task_cleanup_pop_slot_with_task(&brp_v_ew4, __blorp_task);
blorp_list_ensure_capacity_checked((blorp_List*)__t0_6, __t0_7);
});
{
  (void)(blorp_list_retain_for((blorp_List*)brp_vn_3, (void*)brp_vn_1));
}
{
  (void)(({ blorp_list_set_raw((blorp_List*)brp_vn_3, brp_vn_2, (void*)brp_vn_1); }));
}
{
blorp_List* __t0_8 = brp_vn_3;
long __t0_9 = (brp_vn_2 + 1);
  (void)((((blorp_List*)__t0_8)->len = __t0_9));
}
brp_vn_3;
});
blorp_release(brp_vn_1);
brp_v_ew4 = brp_vd_n1_d0;
blorp_task_cleanup_rearm_with_task(&__blorp_cleanup_brp_v_ew4, &brp_v_ew4, (void*)brp_v_ew4, blorp_cleanup_release_arc_value, __blorp_task);
}
blorp_task_cleanup_pop_slot_with_task(&__tc_3, __blorp_task);
blorp_release(__tc_3);
}
brp_tyfJ* brp_v_ezO = ({
brp_tyj4* brp_vt_OTWewYo3Hp_b0 = ({
brp_tyj3* brp_vn_1xH = ({ blorp_retain(brp_v_eso);
 brp_v_eso; });
blorp_List* brp_vn_1xI = ({ blorp_retain(brp_v_esZ);
 brp_v_esZ; });
brp_tyj4_make(brp_vn_1xH, brp_vn_1xI);
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_vt_OTWewYo3Hp_b0;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_vt_OTWewYo3Hp_b0, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_vt_OTWewYo3Hp_b0, &brp_vt_OTWewYo3Hp_b0, (void*)brp_vt_OTWewYo3Hp_b0, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfJ* brp_vd_tOTWewYo3Hp_b0_d0 = ({
brp_tyj4* __t0_10 = brp_vt_OTWewYo3Hp_b0;
brp_tyfJ* __t0_11;
{
blorp_retain(brp_v_evy);
  __t0_11 = brp_v_evy;
}
brp_50r(__t0_10, __t0_11);
});
blorp_task_cleanup_pop_slot_with_task(&brp_vt_OTWewYo3Hp_b0, __blorp_task);
blorp_release(brp_vt_OTWewYo3Hp_b0);
brp_vd_tOTWewYo3Hp_b0_d0;
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_ezO;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_ezO, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_ezO, &brp_v_ezO, (void*)brp_v_ezO, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfq* brp_v_eC5 = ({
blorp_retain(brp_v_evM);
blorp_retain(brp_v_ezO);
blorp_task_cleanup_duplicate_slot_with_task(&brp_v_ezO, __blorp_task);
void* __blorp_internal_match_scrut_19280_2030_43_2053_13_5 = ({
void* brp_vt_OTWfK3zxjg_j0 = brp_v_eso->f1;
blorp_retain(brp_vt_OTWfK3zxjg_j0);
brp_vt_OTWfK3zxjg_j0;
});
blorp_CancelCleanupFrame __blorp_owned_cleanup___blorp_internal_match_scrut_19280_2030_43_2053_13_5;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_owned_cleanup___blorp_internal_match_scrut_19280_2030_43_2053_13_5, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_owned_cleanup___blorp_internal_match_scrut_19280_2030_43_2053_13_5, &__blorp_internal_match_scrut_19280_2030_43_2053_13_5, (void*)__blorp_internal_match_scrut_19280_2030_43_2053_13_5, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfq* __tn_13;
if (__blorp_internal_match_scrut_19280_2030_43_2053_13_5 != NULL) {
brp_tyj0* brp_v_eDa = __blorp_internal_match_scrut_19280_2030_43_2053_13_5;
brp_tyfq* brp_vd_pevM_d0 = ({
brp_tyfJ* brp_v_eDl = ({
brp_tyfq* __to_14 = brp_v_evs;
brp_tyfJ* __tn_15;
if (((brp_tyfq*)__to_14)->tag == brp_t_3Mn) {
brp_tyfJ* brp_vd_pevy_d0 = ({
blorp_task_cleanup_pop_slot_with_task(&brp_v_ezO, __blorp_task);
blorp_release(brp_v_ezO);
brp_tyfJ* brp_vt_OTWgNvx0P2_j0 = brp_v_evy;
blorp_retain(brp_vt_OTWgNvx0P2_j0);
brp_vt_OTWgNvx0P2_j0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_evy, __blorp_task);
blorp_release(brp_v_evy);
__tn_15 = brp_vd_pevy_d0;
} else {
blorp_task_cleanup_pop_slot_with_task(&brp_v_evy, __blorp_task);
blorp_release(brp_v_evy);
brp_tyfJ* brp_vd_pezO_d0 = ({
brp_tyfJ* brp_vt_OTWh6gbZBr_j0 = brp_v_ezO;
blorp_retain(brp_vt_OTWh6gbZBr_j0);
brp_vt_OTWh6gbZBr_j0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_ezO, __blorp_task);
blorp_release(brp_v_ezO);
__tn_15 = brp_vd_pezO_d0;
}
__tn_15;
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_eDl;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_eDl, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_eDl, &brp_v_eDl, (void*)brp_v_eDl, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfq* brp_vd_peDl_d0 = brp_50V(brp_v_eDa, brp_v_eso->f2, brp_v_esZ, brp_v_evs, brp_v_eDl, brp_v_ew4, brp_v_evM);
blorp_task_cleanup_pop_slot_with_task(&brp_v_eDl, __blorp_task);
blorp_release(brp_v_eDl);
brp_vd_peDl_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_evM, __blorp_task);
blorp_release(brp_v_evM);
__tn_13 = brp_vd_pevM_d0;
} else if (__blorp_internal_match_scrut_19280_2030_43_2053_13_5 == NULL) {
blorp_task_cleanup_pop_slot_with_task(&brp_v_evM, __blorp_task);
blorp_release(brp_v_evM);
blorp_task_cleanup_pop_slot_with_task(&brp_v_evy, __blorp_task);
blorp_release(brp_v_evy);
blorp_task_cleanup_pop_slot_with_task(&brp_v_ezO, __blorp_task);
blorp_release(brp_v_ezO);
brp_tyfq* brp_vt_OTWiUHCibE_j0 = brp_v_evs;
blorp_retain(brp_vt_OTWiUHCibE_j0);
__tn_13 = brp_vt_OTWiUHCibE_j0;
} else {
fprintf(stderr, "blorp: non-exhaustive match\n");
abort();
}
blorp_task_cleanup_pop_slot_with_task(&__blorp_internal_match_scrut_19280_2030_43_2053_13_5, __blorp_task);
blorp_release(__blorp_internal_match_scrut_19280_2030_43_2053_13_5);
__tn_13;
});
brp_tyfJ* brp_vd_pevM_d0 = ({
brp_tyfJ* brp_vd_pezO_d0 = ({ brp_tyfJ* __moved_construct = brp_c_3NV((void*)brp_v_eC5, (void*)brp_50M(brp_v_ezO, brp_v_eC5), (void*)brp_v_ew4, (void*)({ blorp_retain(brp_v_evM);
 brp_v_evM; }), (void*)(long)(brp_v_evR), 15UL);
blorp_task_cleanup_pop_slot_with_task(&brp_v_ew4, __blorp_task);
blorp_task_cleanup_pop_slot_with_task(&brp_v_evM, __blorp_task);
__moved_construct; });
blorp_task_cleanup_pop_slot_with_task(&brp_v_ezO, __blorp_task);
blorp_release(brp_v_ezO);
brp_vd_pezO_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_evM, __blorp_task);
blorp_release(brp_v_evM);
brp_vd_pevM_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_evs, __blorp_task);
blorp_release(brp_v_evs);
brp_vd_pevs_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_evG, __blorp_task);
blorp_release(brp_v_evG);
__tn_1 = brp_vd_pevG_d0;
} else if (((brp_tyfJ*)__to_0)->tag == brp_t_3Pd) {
brp_tyfJ* brp_v_eMS = ((brp_tyfJ*)((brp_tyfJ*)__to_0)->data.IfExpr.field0);
brp_tyfJ* brp_v_eMY = ((brp_tyfJ*)((brp_tyfJ*)__to_0)->data.IfExpr.field1);
brp_tyfJ* brp_v_eN9 = ((brp_tyfJ*)((brp_tyfJ*)__to_0)->data.IfExpr.field2);
brp_tyeZ* brp_v_eNk = ((brp_tyeZ*)((brp_tyfJ*)__to_0)->data.IfExpr.field3);
long brp_v_eNp = ((long)(long)((brp_tyfJ*)__to_0)->data.IfExpr.field4);
blorp_retain(brp_v_eNk);
brp_tyfJ* brp_vd_peNk_d0 = ({
blorp_retain(brp_v_eN9);
brp_tyfJ* brp_vd_peN9_d0 = ({
blorp_retain(brp_v_eMY);
brp_tyfJ* brp_vd_peMY_d0 = ({
blorp_retain(brp_v_eMS);
brp_tyfJ* brp_vd_peMS_d0 = ({
blorp_task_cleanup_pop_slot_with_task(&brp_v_etl, __blorp_task);
blorp_release(brp_v_etl);
brp_tyfJ* brp_v_eNy = ({
brp_tyj4* brp_vt_OTWkqD8Mmb_b0 = ({
brp_tyj3* brp_vn_1xJ = ({ blorp_retain(brp_v_eso);
 brp_v_eso; });
blorp_List* brp_vn_1xK = ({ blorp_retain(brp_v_esZ);
 brp_v_esZ; });
brp_tyj4_make(brp_vn_1xJ, brp_vn_1xK);
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_vt_OTWkqD8Mmb_b0;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_vt_OTWkqD8Mmb_b0, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_vt_OTWkqD8Mmb_b0, &brp_vt_OTWkqD8Mmb_b0, (void*)brp_vt_OTWkqD8Mmb_b0, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfJ* brp_vd_tOTWkqD8Mmb_b0_d0 = ({
brp_tyj4* __t0_16 = brp_vt_OTWkqD8Mmb_b0;
brp_tyfJ* __t0_17;
{
blorp_retain(brp_v_eMS);
  __t0_17 = brp_v_eMS;
}
brp_50r(__t0_16, __t0_17);
});
blorp_task_cleanup_pop_slot_with_task(&brp_vt_OTWkqD8Mmb_b0, __blorp_task);
blorp_release(brp_vt_OTWkqD8Mmb_b0);
brp_vd_tOTWkqD8Mmb_b0_d0;
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_eNy;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_eNy, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_eNy, &brp_v_eNy, (void*)brp_v_eNy, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfJ* brp_v_ePK = ({
brp_tyj4* brp_vt_OTWlugsd55_b0 = ({
brp_tyj3* brp_vn_1xL = ({ blorp_retain(brp_v_eso);
 brp_v_eso; });
blorp_List* brp_vn_1xM = ({ blorp_retain(brp_v_esZ);
 brp_v_esZ; });
brp_tyj4_make(brp_vn_1xL, brp_vn_1xM);
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_vt_OTWlugsd55_b0;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_vt_OTWlugsd55_b0, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_vt_OTWlugsd55_b0, &brp_vt_OTWlugsd55_b0, (void*)brp_vt_OTWlugsd55_b0, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfJ* brp_vd_tOTWlugsd55_b0_d0 = ({
brp_tyj4* __t0_18 = brp_vt_OTWlugsd55_b0;
brp_tyfJ* __t0_19;
{
blorp_retain(brp_v_eMY);
  __t0_19 = brp_v_eMY;
}
brp_50r(__t0_18, __t0_19);
});
blorp_task_cleanup_pop_slot_with_task(&brp_vt_OTWlugsd55_b0, __blorp_task);
blorp_release(brp_vt_OTWlugsd55_b0);
brp_vd_tOTWlugsd55_b0_d0;
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_ePK;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_ePK, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_ePK, &brp_v_ePK, (void*)brp_v_ePK, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfJ* brp_v_eS1 = ({
brp_tyj4* brp_vt_OTWmxTLDNZ_b0 = ({
brp_tyj3* brp_vn_1xN = ({ blorp_retain(brp_v_eso);
 brp_v_eso; });
blorp_List* brp_vn_1xO = ({ blorp_retain(brp_v_esZ);
 brp_v_esZ; });
brp_tyj4_make(brp_vn_1xN, brp_vn_1xO);
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_vt_OTWmxTLDNZ_b0;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_vt_OTWmxTLDNZ_b0, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_vt_OTWmxTLDNZ_b0, &brp_vt_OTWmxTLDNZ_b0, (void*)brp_vt_OTWmxTLDNZ_b0, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfJ* brp_vd_tOTWmxTLDNZ_b0_d0 = ({
brp_tyj4* __t0_20 = brp_vt_OTWmxTLDNZ_b0;
brp_tyfJ* __t0_21;
{
blorp_retain(brp_v_eN9);
  __t0_21 = brp_v_eN9;
}
brp_50r(__t0_20, __t0_21);
});
blorp_task_cleanup_pop_slot_with_task(&brp_vt_OTWmxTLDNZ_b0, __blorp_task);
blorp_release(brp_vt_OTWmxTLDNZ_b0);
brp_vd_tOTWmxTLDNZ_b0_d0;
});
void* __t14_22 = (void*)brp_v_eNy;
void* __t14_23 = (void*)brp_v_ePK;
void* __t14_24 = (void*)brp_v_eS1;
void* __t14_25 = (void*)({ blorp_retain(brp_v_eNk);
 brp_v_eNk; });
void* __t14_26 = (void*)(long)(brp_v_eNp);
brp_tyfJ* __t15_27 = brp_c_3Pd(__t14_22, __t14_23, __t14_24, __t14_25, __t14_26, 15UL);
brp_tyfJ* __moved_construct_28 = __t15_27;
blorp_task_cleanup_pop_slot_with_task(&brp_v_eNy, __blorp_task);
blorp_task_cleanup_pop_slot_with_task(&brp_v_ePK, __blorp_task);
blorp_task_cleanup_pop_slot_with_task(&brp_v_eNk, __blorp_task);
__moved_construct_28;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_eMS, __blorp_task);
blorp_release(brp_v_eMS);
brp_vd_peMS_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_eMY, __blorp_task);
blorp_release(brp_v_eMY);
brp_vd_peMY_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_eN9, __blorp_task);
blorp_release(brp_v_eN9);
brp_vd_peN9_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_eNk, __blorp_task);
blorp_release(brp_v_eNk);
__tn_1 = brp_vd_peNk_d0;
} else if (((brp_tyfJ*)__to_0)->tag == brp_t_3O0) {
brp_tyfJ* brp_vd_petl_d0 = brp_50W(brp_v_eso, brp_v_esZ, brp_v_etl);
blorp_task_cleanup_pop_slot_with_task(&brp_v_etl, __blorp_task);
blorp_release(brp_v_etl);
__tn_1 = brp_vd_petl_d0;
} else if (((brp_tyfJ*)__to_0)->tag == brp_t_3NY) {
blorp_task_cleanup_pop_slot_with_task(&brp_v_etl, __blorp_task);
__tn_1 = brp_50X(brp_v_eso, brp_v_esZ, brp_v_etl);
} else {
brp_tyfJ* brp_vd_petl_d0 = ({
brp_tyj4* brp_v_eYe = ({
brp_tyj3* brp_vn_1xP = ({ blorp_retain(brp_v_eso);
 brp_v_eso; });
blorp_List* brp_vn_1xQ = ({ blorp_retain(brp_v_esZ);
 brp_v_esZ; });
brp_tyj4_make(brp_vn_1xP, brp_vn_1xQ);
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_v_eYe;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_v_eYe, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_v_eYe, &brp_v_eYe, (void*)brp_v_eYe, blorp_cleanup_release_arc_value, __blorp_task);
brp_tyfJ* brp_vd_peYe_d0 = ({
blorp_List* brp_vt_OTWp73CO4T_e1 = ({
blorp_List* brp_vt_OTWp7xIhRC_j0 = brp_v_eYe->f1;
blorp_retain(brp_vt_OTWp7xIhRC_j0);
brp_vt_OTWp7xIhRC_j0;
});
blorp_CancelCleanupFrame __blorp_cleanup_brp_vt_OTWp73CO4T_e1;
BLORP_TASK_CLEANUP_SCOPE_WITH_TASK(__blorp_cleanup_brp_vt_OTWp73CO4T_e1, __blorp_task);
blorp_task_cleanup_push_with_task(&__blorp_cleanup_brp_vt_OTWp73CO4T_e1, &brp_vt_OTWp73CO4T_e1, (void*)brp_vt_OTWp73CO4T_e1, blorp_cleanup_release_arc_value, __blorp_task);
blorp_task_cleanup_pop_slot_with_task(&brp_vt_OTWp73CO4T_e1, __blorp_task);
brp_50Z(brp_v_eYe->f0, brp_vt_OTWp73CO4T_e1, brp_v_etl);
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_eYe, __blorp_task);
blorp_release(brp_v_eYe);
brp_vd_peYe_d0;
});
blorp_task_cleanup_pop_slot_with_task(&brp_v_etl, __blorp_task);
blorp_release(brp_v_etl);
__tn_1 = brp_vd_petl_d0;
}
  return __tn_1;
}
