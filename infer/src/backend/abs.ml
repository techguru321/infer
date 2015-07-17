(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(** Implementation of Abstraction Functions *)

module L = Logging
module F = Format
open Utils

(** {2 Abstraction} *)

type rule =
  { r_vars: Ident.t list;
    r_root: Match.hpred_pat;
    r_sigma: Match.hpred_pat list; (* sigma should be in a specific order *)
    r_new_sigma: Sil.hpred list;
    r_new_pi: Prop.normal Prop.t -> Prop.normal Prop.t -> Sil.subst -> Sil.atom list;
    r_condition: Prop.normal Prop.t -> Sil.subst -> bool }

let sigma_rewrite p r : Prop.normal Prop.t option =
  match (Match.prop_match_with_impl p r.r_condition r.r_vars r.r_root r.r_sigma) with
  | None -> None
  | Some(sub, p_leftover) ->
      if not (r.r_condition p_leftover sub) then None
      else
        let res_pi = r.r_new_pi p p_leftover sub in
        let res_sigma = Prop.sigma_sub sub r.r_new_sigma in
        let p_with_res_pi = list_fold_left Prop.prop_atom_and p_leftover res_pi in
        let p_new = Prop.prop_sigma_star p_with_res_pi res_sigma in
        Some (Prop.normalize p_new)

let sigma_fav_list sigma =
  Sil.fav_to_list (Prop.sigma_fav sigma)

let sigma_fav_in_pvars =
  Sil.fav_imperative_to_functional Prop.sigma_fav_in_pvars_add

let sigma_fav_in_pvars_list sigma =
  Sil.fav_to_list (sigma_fav_in_pvars sigma)

(******************** Start of SLL abstraction rules  *****************)
let create_fresh_primeds_ls para =
  let id_base = Ident.create_fresh Ident.kprimed in
  let id_next = Ident.create_fresh Ident.kprimed in
  let id_end = Ident.create_fresh Ident.kprimed in
  let ids_shared =
    let svars = para.Sil.svars in
    let f id = Ident.create_fresh Ident.kprimed in
    list_map f svars in
  let ids_tuple = (id_base, id_next, id_end, ids_shared) in
  let exp_base = Sil.Var id_base in
  let exp_next = Sil.Var id_next in
  let exp_end = Sil.Var id_end in
  let exps_shared = list_map (fun id -> Sil.Var id) ids_shared in
  let exps_tuple = (exp_base, exp_next, exp_end, exps_shared) in
  (ids_tuple, exps_tuple)

let create_condition_ls ids_private id_base p_leftover (inst: Sil.subst) =
  let (insts_of_private_ids, insts_of_public_ids, inst_of_base) =
    let f id' = list_exists (fun id'' -> Ident.equal id' id'') ids_private in
    let (inst_private, inst_public) = Sil.sub_domain_partition f inst in
    let insts_of_public_ids = Sil.sub_range inst_public in
    let inst_of_base = try Sil.sub_find (Ident.equal id_base) inst_public with Not_found -> assert false in
    let insts_of_private_ids = Sil.sub_range inst_private in
    (insts_of_private_ids, insts_of_public_ids, inst_of_base) in
  let fav_insts_of_public_ids = list_flatten (list_map Sil.exp_fav_list insts_of_public_ids) in
  let fav_insts_of_private_ids = list_flatten (list_map Sil.exp_fav_list insts_of_private_ids) in
  let (fav_p_leftover, fav_in_pvars) =
    let sigma = Prop.get_sigma p_leftover in
    (sigma_fav_list sigma, sigma_fav_in_pvars_list sigma) in
  let fpv_inst_of_base = Sil.exp_fpv inst_of_base in
  let fpv_insts_of_private_ids = list_flatten (list_map Sil.exp_fpv insts_of_private_ids) in
  (*
  let fav_inst_of_base = Sil.exp_fav_list inst_of_base in
  L.out "@[.... application of condition ....@\n@.";
  L.out "@[<4>  private ids : %a@\n@." pp_exp_list insts_of_private_ids;
  L.out "@[<4>  public ids : %a@\n@." pp_exp_list insts_of_public_ids;
  *)
  (* (not (list_intersect compare fav_inst_of_base fav_in_pvars)) && *)
  (fpv_inst_of_base = []) &&
  (fpv_insts_of_private_ids = []) &&
  (not (list_exists Ident.is_normal fav_insts_of_private_ids)) &&
  (not (Utils.list_intersect Ident.compare fav_insts_of_private_ids fav_p_leftover)) &&
  (not (Utils.list_intersect Ident.compare fav_insts_of_private_ids fav_insts_of_public_ids))

let mk_rule_ptspts_ls impl_ok1 impl_ok2 (para: Sil.hpara) =
  let (ids_tuple, exps_tuple) = create_fresh_primeds_ls para in
  let (id_base, id_next, id_end, ids_shared) = ids_tuple in
  let (exp_base, exp_next, exp_end, exps_shared) = exps_tuple in
  let (ids_exist_fst, para_fst) = Sil.hpara_instantiate para exp_base exp_next exps_shared in
  let (para_fst_start, para_fst_rest) =
    let mark_impl_flag hpred = { Match.hpred = hpred; Match.flag = impl_ok1 } in
    match para_fst with
    | [] -> L.out "@.@.ERROR (Empty Para): %a @.@." (Sil.pp_hpara pe_text) para; assert false
    | hpred :: hpreds ->
        let hpat = mark_impl_flag hpred in
        let hpats = list_map mark_impl_flag hpreds in
        (hpat, hpats) in
  let (ids_exist_snd, para_snd) =
    let mark_impl_flag hpred = { Match.hpred = hpred; Match.flag = impl_ok2 } in
    let (ids, para_body) = Sil.hpara_instantiate para exp_next exp_end exps_shared in
    let para_body_hpats = list_map mark_impl_flag para_body in
    (ids, para_body_hpats) in
  let lseg_res = Prop.mk_lseg Sil.Lseg_NE para exp_base exp_end exps_shared in
  let gen_pi_res p_start p_leftover (inst: Sil.subst) = [] in
  let condition =
    let ids_private = id_next :: (ids_exist_fst @ ids_exist_snd) in
    create_condition_ls ids_private id_base in
  { r_vars = id_base :: id_next :: id_end :: ids_shared @ ids_exist_fst @ ids_exist_snd;
    r_root = para_fst_start;
    r_sigma = para_fst_rest @ para_snd;
    r_new_sigma = [lseg_res];
    r_new_pi = gen_pi_res;
    r_condition = condition }

let mk_rule_ptsls_ls k2 impl_ok1 impl_ok2 para =
  let (ids_tuple, exps_tuple) = create_fresh_primeds_ls para in
  let (id_base, id_next, id_end, ids_shared) = ids_tuple in
  let (exp_base, exp_next, exp_end, exps_shared) = exps_tuple in
  let (ids_exist, para_inst) = Sil.hpara_instantiate para exp_base exp_next exps_shared in
  let (para_inst_start, para_inst_rest) =
    match para_inst with
    | [] -> L.out "@.@.ERROR (Empty Para): %a @.@." (Sil.pp_hpara pe_text) para; assert false
    | hpred :: hpreds ->
        let allow_impl hpred = { Match.hpred = hpred; Match.flag = impl_ok1 } in
        (allow_impl hpred, list_map allow_impl hpreds) in
  let lseg_pat = { Match.hpred = Prop.mk_lseg k2 para exp_next exp_end exps_shared; Match.flag = impl_ok2 } in
  let lseg_res = Prop.mk_lseg Sil.Lseg_NE para exp_base exp_end exps_shared in
  let gen_pi_res p_start p_leftover (inst: Sil.subst) = [] in
  let condition =
    let ids_private = id_next :: ids_exist in
    create_condition_ls ids_private id_base in
  { r_vars = id_base :: id_next :: id_end :: ids_shared @ ids_exist;
    r_root = para_inst_start;
    r_sigma = para_inst_rest @ [lseg_pat];
    r_new_pi = gen_pi_res;
    r_new_sigma = [lseg_res];
    r_condition = condition }

let mk_rule_lspts_ls k1 impl_ok1 impl_ok2 para =
  let (ids_tuple, exps_tuple) = create_fresh_primeds_ls para in
  let (id_base, id_next, id_end, ids_shared) = ids_tuple in
  let (exp_base, exp_next, exp_end, exps_shared) = exps_tuple in
  let lseg_pat = { Match.hpred = Prop.mk_lseg k1 para exp_base exp_next exps_shared; Match.flag = impl_ok1 } in
  let (ids_exist, para_inst_pat) =
    let (ids, para_body) = Sil.hpara_instantiate para exp_next exp_end exps_shared in
    let allow_impl hpred = { Match.hpred = hpred; Match.flag = impl_ok2 } in
    let para_body_pat = list_map allow_impl para_body in
    (ids, para_body_pat) in
  let lseg_res = Prop.mk_lseg Sil.Lseg_NE para exp_base exp_end exps_shared in
  let gen_pi_res p_start p_leftover (inst: Sil.subst) = [] in
  let condition =
    let ids_private = id_next :: ids_exist in
    create_condition_ls ids_private id_base in
  { r_vars = id_base :: id_next :: id_end :: ids_shared @ ids_exist;
    r_root = lseg_pat;
    r_sigma = para_inst_pat;
    r_new_sigma = [lseg_res];
    r_new_pi = gen_pi_res;
    r_condition = condition }

let lseg_kind_add k1 k2 = match k1, k2 with
  | Sil.Lseg_NE, Sil.Lseg_NE | Sil.Lseg_NE, Sil.Lseg_PE | Sil.Lseg_PE, Sil.Lseg_NE -> Sil.Lseg_NE
  | Sil.Lseg_PE, Sil.Lseg_PE -> Sil.Lseg_PE

let mk_rule_lsls_ls k1 k2 impl_ok1 impl_ok2 para =
  let (ids_tuple, exps_tuple) = create_fresh_primeds_ls para in
  let (id_base, id_next, id_end, ids_shared) = ids_tuple in
  let (exp_base, exp_next, exp_end, exps_shared) = exps_tuple in
  let lseg_fst_pat =
    { Match.hpred = Prop.mk_lseg k1 para exp_base exp_next exps_shared; Match.flag = impl_ok1 } in
  let lseg_snd_pat =
    { Match.hpred = Prop.mk_lseg k2 para exp_next exp_end exps_shared; Match.flag = impl_ok2 } in
  let k_res = lseg_kind_add k1 k2 in
  let lseg_res = Prop.mk_lseg k_res para exp_base exp_end exps_shared in
  let gen_pi_res p_start p_leftover (inst: Sil.subst) = []
  (*
  let inst_base, inst_next, inst_end =
  let find x = sub_find (equal x) inst in
  try
  (find id_base, find id_next, find id_end)
  with Not_found -> assert false in
  let spooky_case _ =
  (lseg_kind_equal Sil.Lseg_PE k_res)
  && (check_allocatedness p_leftover inst_end)
  && ((check_disequal p_start inst_base inst_next)
  || (check_disequal p_start inst_next inst_end)) in
  let obvious_case _ =
  check_disequal p_start inst_base inst_end &&
  not (check_disequal p_leftover inst_base inst_end) in
  if not (spooky_case () || obvious_case ()) then []
  else [Aneq(inst_base, inst_end)]
  *)
  in
  let condition =
    let ids_private = [id_next] in
    create_condition_ls ids_private id_base in
  { r_vars = id_base :: id_next :: id_end :: ids_shared ;
    r_root = lseg_fst_pat;
    r_sigma = [lseg_snd_pat];
    r_new_sigma = [lseg_res];
    r_new_pi = gen_pi_res;
    r_condition = condition }

let mk_rules_for_sll (para : Sil.hpara) : rule list =
  if not !Config.nelseg then
    begin
      let pts_pts = mk_rule_ptspts_ls true true para in
      let pts_pels = mk_rule_ptsls_ls Sil.Lseg_PE true false para in
      let pels_pts = mk_rule_lspts_ls Sil.Lseg_PE false true para in
      let pels_nels = mk_rule_lsls_ls Sil.Lseg_PE Sil.Lseg_NE false false para in
      let nels_pels = mk_rule_lsls_ls Sil.Lseg_NE Sil.Lseg_PE false false para in
      let pels_pels = mk_rule_lsls_ls Sil.Lseg_PE Sil.Lseg_PE false false para in
      [pts_pts; pts_pels; pels_pts; pels_nels; nels_pels; pels_pels]
    end
  else
    begin
      let pts_pts = mk_rule_ptspts_ls true true para in
      let pts_nels = mk_rule_ptsls_ls Sil.Lseg_NE true false para in
      let nels_pts = mk_rule_lspts_ls Sil.Lseg_NE false true para in
      let nels_nels = mk_rule_lsls_ls Sil.Lseg_NE Sil.Lseg_NE false false para in
      [pts_pts; pts_nels; nels_pts; nels_nels]
    end
(******************  End of SLL abstraction rules ******************)

(******************  Start of DLL abstraction rules  ******************)
let create_condition_dll = create_condition_ls

let mk_rule_ptspts_dll impl_ok1 impl_ok2 para =
  let id_iF = Ident.create_fresh Ident.kprimed in
  let id_iF' = Ident.create_fresh Ident.kprimed in
  let id_oB = Ident.create_fresh Ident.kprimed in
  let id_oF = Ident.create_fresh Ident.kprimed in
  let ids_shared =
    let svars = para.Sil.svars_dll in
    let f id = Ident.create_fresh Ident.kprimed in
    list_map f svars in
  let exp_iF = Sil.Var id_iF in
  let exp_iF' = Sil.Var id_iF' in
  let exp_oB = Sil.Var id_oB in
  let exp_oF = Sil.Var id_oF in
  let exps_shared = list_map (fun id -> Sil.Var id) ids_shared in
  let (ids_exist_fst, para_fst) = Sil.hpara_dll_instantiate para exp_iF exp_oB exp_iF' exps_shared in
  let (para_fst_start, para_fst_rest) =
    let mark_impl_flag hpred = { Match.hpred = hpred; Match.flag = impl_ok1 } in
    match para_fst with
    | [] -> L.out "@.@.ERROR (Empty DLL para): %a@.@." (Sil.pp_hpara_dll pe_text) para; assert false
    | hpred :: hpreds ->
        let hpat = mark_impl_flag hpred in
        let hpats = list_map mark_impl_flag hpreds in
        (hpat, hpats) in
  let (ids_exist_snd, para_snd) =
    let mark_impl_flag hpred = { Match.hpred = hpred; Match.flag = impl_ok2 } in
    let (ids, para_body) = Sil.hpara_dll_instantiate para exp_iF' exp_iF exp_oF exps_shared in
    let para_body_hpats = list_map mark_impl_flag para_body in
    (ids, para_body_hpats) in
  let dllseg_res = Prop.mk_dllseg Sil.Lseg_NE para exp_iF exp_oB exp_oF exp_iF' exps_shared in
  let gen_pi_res p_start p_leftover (inst: Sil.subst) = [] in
  let condition =
    (* for the case of ptspts since iF'=iB therefore iF' cannot be private*)
    let ids_private = ids_exist_fst @ ids_exist_snd in
    create_condition_dll ids_private id_iF in
  (*
  L.out "r_root/para_fst_start=%a @.@." pp_hpat para_fst_start;
  L.out "para_fst_rest=%a @.@." pp_hpat_list para_fst_rest;
  L.out "para_snd=%a @.@." pp_hpat_list para_snd;
  L.out "dllseg_res=%a @.@." pp_hpred dllseg_res;
  *)
  { r_vars = id_iF :: id_oB :: id_iF':: id_oF :: ids_shared @ ids_exist_fst @ ids_exist_snd;
    r_root = para_fst_start;
    r_sigma = para_fst_rest @ para_snd;
    r_new_sigma = [dllseg_res];
    r_new_pi = gen_pi_res;
    r_condition = condition }

let mk_rule_ptsdll_dll k2 impl_ok1 impl_ok2 para =
  let id_iF = Ident.create_fresh Ident.kprimed in
  let id_iF' = Ident.create_fresh Ident.kprimed in
  let id_oB = Ident.create_fresh Ident.kprimed in
  let id_oF = Ident.create_fresh Ident.kprimed in
  let id_iB = Ident.create_fresh Ident.kprimed in
  let ids_shared =
    let svars = para.Sil.svars_dll in
    let f id = Ident.create_fresh Ident.kprimed in
    list_map f svars in
  let exp_iF = Sil.Var id_iF in
  let exp_iF' = Sil.Var id_iF' in
  let exp_oB = Sil.Var id_oB in
  let exp_oF = Sil.Var id_oF in
  let exp_iB = Sil.Var id_iB in
  let exps_shared = list_map (fun id -> Sil.Var id) ids_shared in
  let (ids_exist, para_inst) = Sil.hpara_dll_instantiate para exp_iF exp_oB exp_iF' exps_shared in
  let (para_inst_start, para_inst_rest) =
    match para_inst with
    | [] -> assert false
    | hpred :: hpreds ->
        let allow_impl hpred = { Match.hpred = hpred; Match.flag = impl_ok1 } in
        (allow_impl hpred, list_map allow_impl hpreds) in
  let dllseg_pat = { Match.hpred = Prop.mk_dllseg k2 para exp_iF' exp_iF exp_oF exp_iB exps_shared; Match.flag = impl_ok2 } in
  let dllseg_res = Prop.mk_dllseg Sil.Lseg_NE para exp_iF exp_oB exp_oF exp_iB exps_shared in
  let gen_pi_res p_start p_leftover (inst: Sil.subst) = [] in
  let condition =
    let ids_private = id_iF':: ids_exist in
    create_condition_dll ids_private id_iF in
  { r_vars = id_iF :: id_oB :: id_iF':: id_oF:: id_iB:: ids_shared @ ids_exist;
    r_root = para_inst_start;
    r_sigma = para_inst_rest @ [dllseg_pat];
    r_new_pi = gen_pi_res;
    r_new_sigma = [dllseg_res];
    r_condition = condition }

let mk_rule_dllpts_dll k1 impl_ok1 impl_ok2 para =
  let id_iF = Ident.create_fresh Ident.kprimed in
  let id_iF' = Ident.create_fresh Ident.kprimed in
  let id_oB = Ident.create_fresh Ident.kprimed in
  let id_oB' = Ident.create_fresh Ident.kprimed in
  let id_oF = Ident.create_fresh Ident.kprimed in
  let ids_shared =
    let svars = para.Sil.svars_dll in
    let f id = Ident.create_fresh Ident.kprimed in
    list_map f svars in
  let exp_iF = Sil.Var id_iF in
  let exp_iF' = Sil.Var id_iF' in
  let exp_oB = Sil.Var id_oB in
  let exp_oB' = Sil.Var id_oB' in
  let exp_oF = Sil.Var id_oF in
  let exps_shared = list_map (fun id -> Sil.Var id) ids_shared in
  let (ids_exist, para_inst) = Sil.hpara_dll_instantiate para exp_iF' exp_oB' exp_oF exps_shared in
  let para_inst_pat =
    let allow_impl hpred = { Match.hpred = hpred; Match.flag = impl_ok2 } in
    list_map allow_impl para_inst in
  let dllseg_pat = { Match.hpred = Prop.mk_dllseg k1 para exp_iF exp_oB exp_iF' exp_oB' exps_shared; Match.flag = impl_ok1 } in
  let dllseg_res = Prop.mk_dllseg Sil.Lseg_NE para exp_iF exp_oB exp_oF exp_iF' exps_shared in
  let gen_pi_res p_start p_leftover (inst: Sil.subst) = [] in
  let condition =
    let ids_private = id_oB':: ids_exist in
    create_condition_dll ids_private id_iF in
  { r_vars = id_iF :: id_oB :: id_iF':: id_oB':: id_oF:: ids_shared @ ids_exist;
    r_root = dllseg_pat;
    r_sigma = para_inst_pat;
    r_new_pi = gen_pi_res;
    r_new_sigma = [dllseg_res];
    r_condition = condition }

let mk_rule_dlldll_dll k1 k2 impl_ok1 impl_ok2 para =
  let id_iF = Ident.create_fresh Ident.kprimed in
  let id_iF' = Ident.create_fresh Ident.kprimed in
  let id_oB = Ident.create_fresh Ident.kprimed in
  let id_oB' = Ident.create_fresh Ident.kprimed in
  let id_oF = Ident.create_fresh Ident.kprimed in
  let id_iB = Ident.create_fresh Ident.kprimed in
  let ids_shared =
    let svars = para.Sil.svars_dll in
    let f id = Ident.create_fresh Ident.kprimed in
    list_map f svars in
  let exp_iF = Sil.Var id_iF in
  let exp_iF' = Sil.Var id_iF' in
  let exp_oB = Sil.Var id_oB in
  let exp_oB' = Sil.Var id_oB' in
  let exp_oF = Sil.Var id_oF in
  let exp_iB = Sil.Var id_iB in
  let exps_shared = list_map (fun id -> Sil.Var id) ids_shared in
  let lseg_fst_pat = { Match.hpred = Prop.mk_dllseg k1 para exp_iF exp_oB exp_iF' exp_oB' exps_shared; Match.flag = impl_ok1 } in
  let lseg_snd_pat = { Match.hpred = Prop.mk_dllseg k2 para exp_iF' exp_oB' exp_oF exp_iB exps_shared; Match.flag = impl_ok2 } in
  let k_res = lseg_kind_add k1 k2 in
  let lseg_res = Prop.mk_dllseg k_res para exp_iF exp_oB exp_oF exp_iB exps_shared in
  let gen_pi_res p_start p_leftover (inst: Sil.subst) = [] in
  let condition =
    let ids_private = [id_iF'; id_oB'] in
    create_condition_dll ids_private id_iF in
  { r_vars = id_iF :: id_iF' :: id_oB:: id_oB' :: id_oF:: id_iB:: ids_shared ;
    r_root = lseg_fst_pat;
    r_sigma = [lseg_snd_pat];
    r_new_sigma = [lseg_res];
    r_new_pi = gen_pi_res;
    r_condition = condition }

let mk_rules_for_dll (para : Sil.hpara_dll) : rule list =
  if not !Config.nelseg then
    begin
      let pts_pts = mk_rule_ptspts_dll true true para in
      let pts_pedll = mk_rule_ptsdll_dll Sil.Lseg_PE true false para in
      let pedll_pts = mk_rule_dllpts_dll Sil.Lseg_PE false true para in
      let pedll_nedll = mk_rule_dlldll_dll Sil.Lseg_PE Sil.Lseg_NE false false para in
      let nedll_pedll = mk_rule_dlldll_dll Sil.Lseg_NE Sil.Lseg_PE false false para in
      let pedll_pedll = mk_rule_dlldll_dll Sil.Lseg_PE Sil.Lseg_PE false false para in
      [pts_pts; pts_pedll; pedll_pts; pedll_nedll; nedll_pedll; pedll_pedll]
    end
  else
    begin
      let ptspts_dll = mk_rule_ptspts_dll true true para in
      let ptsdll_dll = mk_rule_ptsdll_dll Sil.Lseg_NE true false para in
      let dllpts_dll = mk_rule_dllpts_dll Sil.Lseg_NE false true para in
      let dlldll_dll = mk_rule_dlldll_dll Sil.Lseg_NE Sil.Lseg_NE false false para in
      [ptspts_dll; ptsdll_dll; dllpts_dll; dlldll_dll]
    end
(******************  End of DLL abstraction rules  ******************)

(******************  Start of Predicate Discovery  ******************)
let typ_get_recursive_flds tenv te =
  let filter (_, t, _) =
    match t with
    | Sil.Tvar _ | Sil.Tint _ | Sil.Tfloat _ | Sil.Tvoid | Sil.Tfun _ -> false
    | Sil.Tptr (Sil.Tvar tname', _) ->
        let typ' = match Sil.tenv_lookup tenv tname' with
          | None ->
              L.err "@.typ_get_recursive: Undefined type %s@." (Sil.typename_to_string tname');
              t
          | Some typ' -> typ' in
        Sil.exp_equal te (Sil.Sizeof (typ', Sil.Subtype.exact))
    | Sil.Tptr _ | Sil.Tstruct _ | Sil.Tarray _ | Sil.Tenum _ ->
        false
  in
  match te with
  | Sil.Sizeof (typ, _) ->
      (match typ with
        | Sil.Tvar _ -> assert false (* there should be no indirection *)
        | Sil.Tint _ | Sil.Tvoid | Sil.Tfun _ | Sil.Tptr _ | Sil.Tfloat _ | Sil.Tenum _ -> []
        | Sil.Tstruct (fld_typ_ann_list, _, _, _, _, _, _) -> list_map (fun (x, y, z) -> x) (list_filter filter fld_typ_ann_list)
        | Sil.Tarray _ -> [])
  | Sil.Var _ -> [] (* type of |-> not known yet *)
  | Sil.Const _ -> []
  | _ ->
      L.err "@.typ_get_recursive: unexpected type expr: %a@." (Sil.pp_exp pe_text) te;
      assert false

let discover_para_roots p root1 next1 root2 next2 : Sil.hpara option =
  let eq_arg1 = Sil.exp_equal root1 next1 in
  let eq_arg2 = Sil.exp_equal root2 next2 in
  let precondition_check = (not eq_arg1 && not eq_arg2) in
  if not precondition_check then None
  else
    let corres = [(next1, next2)] in
    let todos = [(root1, root2)] in
    let sigma = Prop.get_sigma p in
    match Match.find_partial_iso (Prover.check_equal p) corres todos sigma with
    | None -> None
    | Some (new_corres, new_sigma1, _, _) ->
        let hpara, _ = Match.hpara_create new_corres new_sigma1 root1 next1 in
        Some hpara

let discover_para_dll_roots p root1 blink1 flink1 root2 blink2 flink2 : Sil.hpara_dll option =
  let eq_arg1 = Sil.exp_equal root1 blink1 in
  let eq_arg1' = Sil.exp_equal root1 flink1 in
  let eq_arg2 = Sil.exp_equal root2 blink2 in
  let eq_arg2' = Sil.exp_equal root2 flink2 in
  let precondition_check = not (eq_arg1 || eq_arg1' || eq_arg2 || eq_arg2') in
  if not precondition_check then None
  else
    let corres = [(blink1, blink2); (flink1, flink2)] in
    let todos = [(root1, root2)] in
    let sigma = Prop.get_sigma p in
    match Match.find_partial_iso (Prover.check_equal p) corres todos sigma with
    | None -> None
    | Some (new_corres, new_sigma1, _, _) ->
        let hpara_dll, _ = Match.hpara_dll_create new_corres new_sigma1 root1 blink1 flink1 in
        Some hpara_dll

let discover_para_candidates tenv p =
  let edges = ref [] in
  let add_edge edg = edges := edg :: !edges in
  let get_edges_strexp rec_flds root se =
    let is_rec_fld fld = list_exists (Sil.fld_equal fld) rec_flds in
    match se with
    | Sil.Eexp _ | Sil.Earray _ -> ()
    | Sil.Estruct (fsel, _) ->
        let fsel' = list_filter (fun (fld, _) -> is_rec_fld fld) fsel in
        let process (_, nextse) =
          match nextse with
          | Sil.Eexp (next, inst) -> add_edge (root, next)
          | _ -> assert false in
        list_iter process fsel' in
  let rec get_edges_sigma = function
    | [] -> ()
    | Sil.Hlseg _ :: sigma_rest | Sil.Hdllseg _ :: sigma_rest ->
        get_edges_sigma sigma_rest
    | Sil.Hpointsto (root, se, te) :: sigma_rest ->
        let rec_flds = typ_get_recursive_flds tenv te in
        get_edges_strexp rec_flds root se;
        get_edges_sigma sigma_rest in
  let rec find_all_consecutive_edges found edges_seen = function
    | [] -> list_rev found
    | (e1, e2) :: edges_notseen ->
        let edges_others = (list_rev edges_seen) @ edges_notseen in
        let edges_matched = list_filter (fun (e1', _) -> Sil.exp_equal e2 e1') edges_others in
        let new_found =
          let f found_acc (_, e3) = (e1, e2, e3) :: found_acc in
          list_fold_left f found edges_matched in
        let new_edges_seen = (e1, e2) :: edges_seen in
        find_all_consecutive_edges new_found new_edges_seen edges_notseen in
  let sigma = Prop.get_sigma p in
  get_edges_sigma sigma;
  find_all_consecutive_edges [] [] !edges

let discover_para_dll_candidates tenv p =
  let edges = ref [] in
  let add_edge edg = (edges := edg :: !edges) in
  let get_edges_strexp rec_flds root se =
    let is_rec_fld fld = list_exists (Sil.fld_equal fld) rec_flds in
    match se with
    | Sil.Eexp _ | Sil.Earray _ -> ()
    | Sil.Estruct (fsel, _) ->
        let fsel' = list_filter (fun (fld, _) -> is_rec_fld fld) fsel in
        let convert_to_exp acc (_, se) =
          match se with
          | Sil.Eexp (e, inst) -> e:: acc
          | _ -> assert false in
        let links = list_rev (list_fold_left convert_to_exp [] fsel') in
        let rec iter_pairs = function
          | [] -> ()
          | x:: l -> (list_iter (fun y -> add_edge (root, x, y)) l; iter_pairs l) in
        iter_pairs links in
  let rec get_edges_sigma = function
    | [] -> ()
    | Sil.Hlseg _ :: sigma_rest | Sil.Hdllseg _ :: sigma_rest ->
        get_edges_sigma sigma_rest
    | Sil.Hpointsto (root, se, te) :: sigma_rest ->
        let rec_flds = typ_get_recursive_flds tenv te in
        get_edges_strexp rec_flds root se;
        get_edges_sigma sigma_rest in
  let rec find_all_consecutive_edges found edges_seen = function
    | [] -> list_rev found
    | (iF, blink, flink) :: edges_notseen ->
        let edges_others = (list_rev edges_seen) @ edges_notseen in
        let edges_matched = list_filter (fun (e1', _, _) -> Sil.exp_equal flink e1') edges_others in
        let new_found =
          let f found_acc (_, _, flink2) = (iF, blink, flink, flink2) :: found_acc in
          list_fold_left f found edges_matched in
        let new_edges_seen = (iF, blink, flink) :: edges_seen in
        find_all_consecutive_edges new_found new_edges_seen edges_notseen in
  let sigma = Prop.get_sigma p in
  get_edges_sigma sigma;
  find_all_consecutive_edges [] [] !edges

let discover_para tenv p =
  let candidates = discover_para_candidates tenv p in
  let already_defined para paras =
    list_exists (fun para' -> Match.hpara_iso para para') paras in
  let f paras (root, next, out) =
    match (discover_para_roots p root next next out) with
    | None -> paras
    | Some para -> if already_defined para paras then paras else para :: paras in
  list_fold_left f [] candidates

let discover_para_dll tenv p =
  (*
  L.out "@[.... Called discover_dll para ...@.";
  L.out "@[<4>  PROP : %a@\n@." pp_prop p;
  *)
  let candidates = discover_para_dll_candidates tenv p in
  let already_defined para paras =
    list_exists (fun para' -> Match.hpara_dll_iso para para') paras in
  let f paras (iF, oB, iF', oF) =
    match (discover_para_dll_roots p iF oB iF' iF' iF oF) with
    | None -> paras
    | Some para -> if already_defined para paras then paras else para :: paras in
  list_fold_left f [] candidates
(******************  Start of Predicate Discovery  ******************)

(****************** Start of the ADT abs_rules ******************)
type para_ty = SLL of Sil.hpara | DLL of Sil.hpara_dll

type rule_set = para_ty * rule list

type abs_rules = { mutable ar_default : rule_set list }

let eqs_sub subst eqs =
  list_map (fun (e1, e2) -> (Sil.exp_sub subst e1, Sil.exp_sub subst e2)) eqs

let eqs_solve ids_in eqs_in =
  let rec solve (sub: Sil.subst) (eqs: (Sil.exp * Sil.exp) list) : Sil.subst option =
    let do_default id e eqs_rest =
      if not (list_exists (fun id' -> Ident.equal id id') ids_in) then None
      else
        let sub' = match Sil.extend_sub sub id e with
          | None -> L.out "@.@.ERROR : Buggy Implementation.@.@."; assert false
          | Some sub' -> sub' in
        let eqs_rest' = eqs_sub sub' eqs_rest in
        solve sub' eqs_rest' in
    match eqs with
    | [] -> Some sub
    | (e1, e2) :: eqs_rest when Sil.exp_equal e1 e2 ->
        solve sub eqs_rest
    | (Sil.Var id1, (Sil.Const _ as e2)) :: eqs_rest ->
        do_default id1 e2 eqs_rest
    | ((Sil.Const _ as e1), (Sil.Var _ as e2)) :: eqs_rest ->
        solve sub ((e2, e1):: eqs_rest)
    | ((Sil.Var id1 as e1), (Sil.Var id2 as e2)) :: eqs_rest ->
        let n = Ident.compare id1 id2 in
        begin
          if n = 0 then solve sub eqs_rest
          else if n > 0 then solve sub ((e2, e1):: eqs_rest)
          else do_default id1 e2 eqs_rest
        end
    | _ :: _ -> None in
  let compute_ids sub =
    let sub_list = Sil.sub_to_list sub in
    let sub_dom = list_map fst sub_list in
    let filter id =
      not (list_exists (fun id' -> Ident.equal id id') sub_dom) in
    list_filter filter ids_in in
  match solve Sil.sub_empty eqs_in with
  | None -> None
  | Some sub -> Some (compute_ids sub, sub)

let sigma_special_cases_eqs sigma =
  let rec f ids_acc eqs_acc sigma_acc = function
    | [] ->
        [(list_rev ids_acc, list_rev eqs_acc, list_rev sigma_acc)]
    | Sil.Hpointsto _ as hpred :: sigma_rest ->
        f ids_acc eqs_acc (hpred:: sigma_acc) sigma_rest
    | Sil.Hlseg(k, para, e1, e2, es) as hpred :: sigma_rest ->
        let empty_case =
          f ids_acc ((e1, e2):: eqs_acc) sigma_acc sigma_rest in
        let pointsto_case =
          let (eids, para_inst) = Sil.hpara_instantiate para e1 e2 es in
          f (eids@ids_acc) eqs_acc sigma_acc (para_inst@sigma_rest) in
        let general_case =
          f ids_acc eqs_acc (hpred:: sigma_acc) sigma_rest in
        empty_case @ pointsto_case @ general_case
    | Sil.Hdllseg(k, para, e1, e2, e3, e4, es) as hpred :: sigma_rest ->
        let empty_case =
          f ids_acc ((e1, e3):: (e2, e4):: eqs_acc) sigma_acc sigma_rest in
        let pointsto_case =
          let (eids, para_inst) = Sil.hpara_dll_instantiate para e1 e2 e3 es in
          f (eids@ids_acc) eqs_acc sigma_acc (para_inst@sigma_rest) in
        let general_case =
          f ids_acc eqs_acc (hpred:: sigma_acc) sigma_rest in
        empty_case @ pointsto_case @ general_case in
  f [] [] [] sigma

let sigma_special_cases ids sigma : (Ident.t list * Sil.hpred list) list =
  let special_cases_eqs = sigma_special_cases_eqs sigma in
  let special_cases_rev =
    let f acc (eids_cur, eqs_cur, sigma_cur) =
      let ids_all = ids @ eids_cur in
      match (eqs_solve ids_all eqs_cur) with
      | None -> acc
      | Some (ids_res, sub) ->
          (ids_res, list_map (Sil.hpred_sub sub) sigma_cur) :: acc in
    list_fold_left f [] special_cases_eqs in
  list_rev special_cases_rev

let rec hpara_special_cases hpara : Sil.hpara list =
  let update_para (evars', body') = { hpara with Sil.evars = evars'; Sil.body = body'} in
  let special_cases = sigma_special_cases hpara.Sil.evars hpara.Sil.body in
  list_map update_para special_cases

let rec hpara_special_cases_dll hpara : Sil.hpara_dll list =
  let update_para (evars', body') = { hpara with Sil.evars_dll = evars'; Sil.body_dll = body'} in
  let special_cases = sigma_special_cases hpara.Sil.evars_dll hpara.Sil.body_dll in
  list_map update_para special_cases

let abs_rules : abs_rules = { ar_default = [] }

let abs_rules_reset () =
  abs_rules.ar_default <- []

let abs_rules_add rule_set : unit =
  (*
  let _ = match (fst rule_set) with
  | SLL hpara -> L.out "@.@....Added Para: %a@.@." pp_hpara hpara
  | DLL _ -> ()
  in
  *)
  abs_rules.ar_default <- abs_rules.ar_default@[rule_set]

let abs_rules_add_sll (para: Sil.hpara) : unit =
  let rules = mk_rules_for_sll para in
  let rule_set = (SLL para, rules) in
  abs_rules_add rule_set

let abs_rules_add_dll (para: Sil.hpara_dll) : unit =
  let rules = mk_rules_for_dll para in
  let rule_set = (DLL para, rules) in
  abs_rules_add rule_set

let abs_rules_apply_rsets (rsets: rule_set list) (p_in: Prop.normal Prop.t) : Prop.normal Prop.t =
  let apply_rule (changed, p) r =
    match (sigma_rewrite p r) with
    | None -> (changed, p)
    | Some p' ->
    (*
    L.out "@[.... abstraction (rewritten in abs_rules) ....@.";
    L.out "@[<4>  PROP:%a@\n@." pp_prop p';
    *)
        (true, p') in
  let rec apply_rule_set p rset =
    let (_, rules) = rset in
    let (changed, p') = list_fold_left apply_rule (false, p) rules in
    if changed then apply_rule_set p' rset else p' in
  list_fold_left apply_rule_set p_in rsets

let abs_rules_apply_lists tenv (p_in: Prop.normal Prop.t) : Prop.normal Prop.t =
  let new_rsets = ref [] in
  let def_rsets = abs_rules.ar_default in
  let rec discover_then_abstract p =
    let (closed_paras_sll, closed_paras_dll) =
      let paras_sll = discover_para tenv p in
      let paras_dll = discover_para_dll tenv p in
      let closed_paras_sll = list_flatten (list_map hpara_special_cases paras_sll) in
      let closed_paras_dll = list_flatten (list_map hpara_special_cases_dll paras_dll) in
      begin
        (*
        if list_length closed_paras_sll >= 1 then
        begin
        L.out "@.... discovered predicates ....@.";
        L.out "@[<4>  pred : %a@\n@." pp_hpara_list closed_paras_sll;
        end
        if list_length closed_paras_dll >= 1 then
        begin
        L.out "@.... discovered predicates ....@.";
        L.out "@[<4>  pred : %a@\n@." pp_hpara_dll_list closed_paras_dll;
        end
        *)
        (closed_paras_sll, closed_paras_dll)
      end in
    let (todo_paras_sll, todo_paras_dll) =
      let eq_sll para = function (SLL para', _) -> Match.hpara_iso para para' | _ -> false in
      let eq_dll para = function (DLL para', _) -> Match.hpara_dll_iso para para' | _ -> false in
      let filter_sll para =
        not (list_exists (eq_sll para) def_rsets) && not (list_exists (eq_sll para) !new_rsets) in
      let filter_dll para =
        not (list_exists (eq_dll para) def_rsets) && not (list_exists (eq_dll para) !new_rsets) in
      let todo_paras_sll = list_filter filter_sll closed_paras_sll in
      let todo_paras_dll = list_filter filter_dll closed_paras_dll in
      (todo_paras_sll, todo_paras_dll) in
    let f_recurse () =
      let todo_rsets_sll = list_map (fun para -> (SLL para, mk_rules_for_sll para)) todo_paras_sll in
      let todo_rsets_dll = list_map (fun para -> (DLL para, mk_rules_for_dll para)) todo_paras_dll in
      new_rsets := !new_rsets @ todo_rsets_sll @ todo_rsets_dll;
      let p' = abs_rules_apply_rsets todo_rsets_sll p in
      let p'' = abs_rules_apply_rsets todo_rsets_dll p' in
      discover_then_abstract p'' in
    match todo_paras_sll, todo_paras_dll with
    | [], [] -> p
    | _ -> f_recurse () in
  let p1 = abs_rules_apply_rsets def_rsets p_in in
  let p2 = if !Config.on_the_fly then discover_then_abstract p1 else p1
  in
  abs_rules.ar_default <- (def_rsets@(!new_rsets));
  p2

let abs_rules_apply tenv (p_in: Prop.normal Prop.t) : Prop.normal Prop.t =
  abs_rules_apply_lists tenv p_in
(****************** End of the ADT abs_rules ******************)

(****************** Start of fns that add rules during preprocessing ******************)
let is_simply_recursive tenv tname =
  let typ = match Sil.tenv_lookup tenv tname with
    | None -> assert false
    | Some typ -> typ in
  let filter (_, t, _) = match t with
    | Sil.Tvar _ | Sil.Tint _ | Sil.Tfloat _ | Sil.Tvoid | Sil.Tfun _ | Sil.Tenum _ ->
        false
    | Sil.Tptr (Sil.Tvar tname', _) ->
        Sil.typename_equal tname tname'
    | Sil.Tptr _ | Sil.Tstruct _ | Sil.Tarray _ ->
        false in
  match typ with
  | Sil.Tvar _ ->
      assert false (* there should be no indirection *)
  | Sil.Tint _ | Sil.Tfloat _ | Sil.Tvoid | Sil.Tfun _ | Sil.Tptr _ | Sil.Tenum _ ->
      None
  | Sil.Tstruct (fld_typ_ann_list, _, _, _, _, _, _) ->
      begin
        match (list_filter filter fld_typ_ann_list) with
        | [(fld, _, _)] -> Some fld
        | _ -> None
      end
  | Sil.Tarray _ ->
      None

let create_hpara_from_tname_flds tenv tname nfld sflds eflds inst =
  let typ = match Sil.tenv_lookup tenv tname with
    | Some typ -> typ
    | None -> assert false in
  let id_base = Ident.create_fresh Ident.kprimed in
  let id_next = Ident.create_fresh Ident.kprimed in
  let ids_shared = list_map (fun _ -> Ident.create_fresh Ident.kprimed) sflds in
  let ids_exist = list_map (fun _ -> Ident.create_fresh Ident.kprimed) eflds in
  let exp_base = Sil.Var id_base in
  let fld_sexps =
    let ids = id_next :: (ids_shared @ ids_exist) in
    let flds = nfld :: (sflds @ eflds) in
    let f fld id = (fld, Sil.Eexp (Sil.Var id, inst)) in
    try list_map2 f flds ids with Invalid_argument _ -> assert false in
  let strexp_para = Sil.Estruct (fld_sexps, inst) in
  let ptsto_para = Prop.mk_ptsto exp_base strexp_para (Sil.Sizeof (typ, Sil.Subtype.exact)) in
  Prop.mk_hpara id_base id_next ids_shared ids_exist [ptsto_para]

let create_dll_hpara_from_tname_flds tenv tname flink blink sflds eflds inst =
  let typ = match Sil.tenv_lookup tenv tname with
    | Some typ -> typ
    | None -> assert false in
  let id_iF = Ident.create_fresh Ident.kprimed in
  let id_oB = Ident.create_fresh Ident.kprimed in
  let id_oF = Ident.create_fresh Ident.kprimed in
  let ids_shared = list_map (fun _ -> Ident.create_fresh Ident.kprimed) sflds in
  let ids_exist = list_map (fun _ -> Ident.create_fresh Ident.kprimed) eflds in
  let exp_iF = Sil.Var id_iF in
  let fld_sexps =
    let ids = id_oF:: id_oB :: (ids_shared @ ids_exist) in
    let flds = flink:: blink:: (sflds @ eflds) in
    let f fld id = (fld, Sil.Eexp (Sil.Var id, inst)) in
    try list_map2 f flds ids with Invalid_argument _ -> assert false in
  let strexp_para = Sil.Estruct (fld_sexps, inst) in
  let ptsto_para = Prop.mk_ptsto exp_iF strexp_para (Sil.Sizeof (typ, Sil.Subtype.exact)) in
  Prop.mk_dll_hpara id_iF id_oB id_oF ids_shared ids_exist [ptsto_para]

let create_hpara_two_ptsto tname1 tenv nfld1 dfld tname2 nfld2 inst =
  let typ1 = match Sil.tenv_lookup tenv tname1 with
    | Some typ -> typ
    | None -> assert false in
  let typ2 = match Sil.tenv_lookup tenv tname2 with
    | Some typ -> typ
    | None -> assert false in
  let id_base = Ident.create_fresh Ident.kprimed in
  let id_next = Ident.create_fresh Ident.kprimed in
  let id_exist = Ident.create_fresh Ident.kprimed in
  let exp_base = Sil.Var id_base in
  let exp_exist = Sil.Var id_exist in
  let fld_sexps1 =
    let ids = [id_next; id_exist] in
    let flds = [nfld1; dfld] in
    let f fld id = (fld, Sil.Eexp (Sil.Var id, inst)) in
    try list_map2 f flds ids with Invalid_argument _ -> assert false in
  let fld_sexps2 =
    [(nfld2, Sil.Eexp (Sil.exp_zero, inst))] in
  let strexp_para1 = Sil.Estruct (fld_sexps1, inst) in
  let strexp_para2 = Sil.Estruct (fld_sexps2, inst) in
  let ptsto_para1 = Prop.mk_ptsto exp_base strexp_para1 (Sil.Sizeof (typ1, Sil.Subtype.exact)) in
  let ptsto_para2 = Prop.mk_ptsto exp_exist strexp_para2 (Sil.Sizeof (typ2, Sil.Subtype.exact)) in
  Prop.mk_hpara id_base id_next [] [id_exist] [ptsto_para1; ptsto_para2]

let create_hpara_dll_two_ptsto tenv tname1 flink_fld1 blink_fld1 dfld tname2 nfld2 inst =
  let typ1 = match Sil.tenv_lookup tenv tname1 with
    | Some typ -> typ
    | None -> assert false in
  let typ2 = match Sil.tenv_lookup tenv tname2 with
    | Some typ -> typ
    | None -> assert false in
  let id_cell = Ident.create_fresh Ident.kprimed in
  let id_blink = Ident.create_fresh Ident.kprimed in
  let id_flink = Ident.create_fresh Ident.kprimed in
  let id_exist = Ident.create_fresh Ident.kprimed in
  let exp_cell = Sil.Var id_cell in
  let exp_exist = Sil.Var id_exist in
  let fld_sexps1 =
    let ids = [ id_blink; id_flink; id_exist] in
    let flds = [ blink_fld1; flink_fld1; dfld] in
    let f fld id = (fld, Sil.Eexp (Sil.Var id, inst)) in
    try list_map2 f flds ids with Invalid_argument _ -> assert false in
  let fld_sexps2 =
    [(nfld2, Sil.Eexp (Sil.exp_zero, inst))] in
  let strexp_para1 = Sil.Estruct (fld_sexps1, inst) in
  let strexp_para2 = Sil.Estruct (fld_sexps2, inst) in
  let ptsto_para1 = Prop.mk_ptsto exp_cell strexp_para1 (Sil.Sizeof (typ1, Sil.Subtype.exact)) in
  let ptsto_para2 = Prop.mk_ptsto exp_exist strexp_para2 (Sil.Sizeof (typ2, Sil.Subtype.exact)) in
  Prop.mk_dll_hpara id_cell id_blink id_flink [] [id_exist] [ptsto_para1; ptsto_para2]

let create_hpara_from_tname_twoflds_hpara tenv tname fld_next fld_down para inst =
  let typ = match Sil.tenv_lookup tenv tname with
    | Some typ -> typ
    | None -> assert false in
  let id_base = Ident.create_fresh Ident.kprimed in
  let id_next = Ident.create_fresh Ident.kprimed in
  let id_down = Ident.create_fresh Ident.kprimed in
  let exp_base = Sil.Var id_base in
  let exp_next = Sil.Var id_next in
  let exp_down = Sil.Var id_down in
  let strexp = Sil.Estruct ([(fld_next, Sil.Eexp (exp_next, inst)); (fld_down, Sil.Eexp (exp_down, inst))], inst) in
  let ptsto = Prop.mk_ptsto exp_base strexp (Sil.Sizeof (typ, Sil.Subtype.exact)) in
  let lseg = Prop.mk_lseg Sil.Lseg_PE para exp_down Sil.exp_zero [] in
  let body = [ptsto; lseg] in
  Prop.mk_hpara id_base id_next [] [id_down] body

let create_hpara_dll_from_tname_twoflds_hpara tenv tname fld_flink fld_blink fld_down para inst =
  let typ = match Sil.tenv_lookup tenv tname with
    | Some typ -> typ
    | None -> assert false in
  let id_cell = Ident.create_fresh Ident.kprimed in
  let id_blink = Ident.create_fresh Ident.kprimed in
  let id_flink = Ident.create_fresh Ident.kprimed in
  let id_down = Ident.create_fresh Ident.kprimed in
  let exp_cell = Sil.Var id_cell in
  let exp_blink = Sil.Var id_blink in
  let exp_flink = Sil.Var id_flink in
  let exp_down = Sil.Var id_down in
  let strexp = Sil.Estruct ([(fld_blink, Sil.Eexp (exp_blink, inst)); (fld_flink, Sil.Eexp (exp_flink, inst)); (fld_down, Sil.Eexp (exp_down, inst))], inst) in
  let ptsto = Prop.mk_ptsto exp_cell strexp (Sil.Sizeof (typ, Sil.Subtype.exact)) in
  let lseg = Prop.mk_lseg Sil.Lseg_PE para exp_down Sil.exp_zero [] in
  let body = [ptsto; lseg] in
  Prop.mk_dll_hpara id_cell id_blink id_flink [] [id_down] body

let tname_list = Sil.TN_typedef (Mangled.from_string "list")
let name_down = Ident.create_fieldname (Mangled.from_string "down") 0
let tname_HSlist2 = Sil.TN_typedef (Mangled.from_string "HSlist2")
let name_next = Ident.create_fieldname (Mangled.from_string "next") 0

let tname_dllist = Sil.TN_typedef (Mangled.from_string "dllist")
let name_Flink = Ident.create_fieldname (Mangled.from_string "Flink") 0
let name_Blink = Ident.create_fieldname (Mangled.from_string "Blink") 0
let tname_HOdllist = Sil.TN_typedef (Mangled.from_string "HOdllist")

let create_absrules_from_tdecl tenv tname =
  if (not (!Config.on_the_fly)) && Sil.typename_equal tname tname_HSlist2 then
    (* L.out "@[.... Adding Abstraction Rules for Nested Lists ....@\n@."; *)
    let para1 = create_hpara_from_tname_flds tenv tname_list name_down [] [] Sil.inst_abstraction in
    let para2 = create_hpara_from_tname_flds tenv tname_HSlist2 name_next [name_down] [] Sil.inst_abstraction in
    let para_nested = create_hpara_from_tname_twoflds_hpara tenv tname_HSlist2 name_next name_down para1 Sil.inst_abstraction in
    let para_nested_base = create_hpara_two_ptsto tname_HSlist2 tenv name_next name_down tname_list name_down Sil.inst_abstraction in
    list_iter abs_rules_add_sll [para_nested_base; para2; para_nested]
  else if (not (!Config.on_the_fly)) && Sil.typename_equal tname tname_dllist then
    (* L.out "@[.... Adding Abstraction Rules for Doubly-linked Lists ....@\n@."; *)
    let para = create_dll_hpara_from_tname_flds tenv tname_dllist name_Flink name_Blink [] [] Sil.inst_abstraction in
    abs_rules_add_dll para
  else if (not (!Config.on_the_fly)) && Sil.typename_equal tname tname_HOdllist then
    (* L.out "@[.... Adding Abstraction Rules for High-Order Doubly-linked Lists ....@\n@."; *)
    let para1 = create_hpara_from_tname_flds tenv tname_list name_down [] [] Sil.inst_abstraction in
    let para2 = create_dll_hpara_from_tname_flds tenv tname_HOdllist name_Flink name_Blink [name_down] [] Sil.inst_abstraction in
    let para_nested = create_hpara_dll_from_tname_twoflds_hpara tenv tname_HOdllist name_Flink name_Blink name_down para1 Sil.inst_abstraction in
    let para_nested_base = create_hpara_dll_two_ptsto tenv tname_HOdllist name_Flink name_Blink name_down tname_list name_down Sil.inst_abstraction in
    list_iter abs_rules_add_dll [para_nested_base; para2; para_nested]
  else if (not (!Config.on_the_fly)) then
    match is_simply_recursive tenv tname with
    | None -> ()
    | Some (fld) ->
    (* L.out "@[.... Adding Abstraction Rules ....@\n@."; *)
        let para = create_hpara_from_tname_flds tenv tname fld [] [] Sil.inst_abstraction in
        abs_rules_add_sll para
  else ()
(****************** End of fns that add rules during preprocessing ******************)

(****************** Start of Main Abstraction Functions ******************)
let abstract_pure_part p ~(from_abstract_footprint: bool) =
  let do_pure pure =
    let pi_filtered =
      let sigma = Prop.get_sigma p in
      let fav_sigma = Prop.sigma_fav sigma in
      let fav_nonpure = Prop.prop_fav_nonpure p in (** vars in current and footprint sigma *)
      let filter atom =
        let fav' = Sil.atom_fav atom in
        Sil.fav_for_all fav' (fun id ->
                if Ident.is_primed id then Sil.fav_mem fav_sigma id
                else if Ident.is_footprint id then Sil.fav_mem fav_nonpure id
                else true) in
      list_filter filter pure in
    let new_pure =
      list_fold_left
        (fun pi a ->
              match a with
              | Sil.Aneq (Sil.Var name, _) -> a:: pi
              (* we only use Lt and Le because Gt and Ge are inserted in terms of Lt and Le. *)
              | Sil.Aeq (Sil.Const (Sil.Cint i), Sil.BinOp (Sil.Lt, _, _))
              | Sil.Aeq (Sil.BinOp (Sil.Lt, _, _), Sil.Const (Sil.Cint i))
              | Sil.Aeq (Sil.Const (Sil.Cint i), Sil.BinOp (Sil.Le, _, _))
              | Sil.Aeq (Sil.BinOp (Sil.Le, _, _), Sil.Const (Sil.Cint i)) when Sil.Int.isone i ->
                  a :: pi
              | Sil.Aeq (Sil.Var name, e) when not (Ident.is_primed name) ->
                  (match e with
                    | Sil.Var _
                    | Sil.Const _ -> a :: pi
                    | _ -> pi)
              | _ -> pi)
        [] pi_filtered in
    list_rev new_pure in

  let new_pure = do_pure (Prop.get_pure p) in
  let eprop' = Prop.replace_pi new_pure (Prop.replace_sub Sil.sub_empty p) in
  let eprop'' =
    if !Config.footprint && not from_abstract_footprint then
      let new_pi_footprint = do_pure (Prop.get_pi_footprint p) in
      Prop.replace_pi_footprint new_pi_footprint eprop'
    else eprop' in
  Prop.normalize eprop''

(* Collect symbolic garbage from pi and sigma *)
let abstract_gc p =
  let pi = Prop.get_pi p in
  let p_without_pi = Prop.normalize (Prop.replace_pi [] p) in
  let fav_p_without_pi = Prop.prop_fav p_without_pi in
  (* let weak_filter atom =
  let fav_atom = atom_fav atom in
  list_intersect compare fav_p_without_pi fav_atom in *)
  let strong_filter = function
    | Sil.Aeq(e1, e2) | Sil.Aneq(e1, e2) ->
        let fav_e1 = Sil.exp_fav e1 in
        let fav_e2 = Sil.exp_fav e2 in
        let intersect_e1 _ = list_intersect Ident.compare (Sil.fav_to_list fav_e1) (Sil.fav_to_list fav_p_without_pi) in
        let intersect_e2 _ = list_intersect Ident.compare (Sil.fav_to_list fav_e2) (Sil.fav_to_list fav_p_without_pi) in
        let no_fav_e1 = Sil.fav_is_empty fav_e1 in
        let no_fav_e2 = Sil.fav_is_empty fav_e2 in
        (no_fav_e1 || intersect_e1 ()) && (no_fav_e2 || intersect_e2 ()) in
  let new_pi = list_filter strong_filter pi in
  let prop = Prop.normalize (Prop.replace_pi new_pi p) in
  match Prop.prop_iter_create prop with
  | None -> prop
  | Some iter -> Prop.prop_iter_to_prop (Prop.prop_iter_gc_fields iter)

module IdMap = Map.Make (Ident) (** maps from identifiers *)
module HpredSet =
  Set.Make(struct
    type t = Sil.hpred
    let compare = Sil.hpred_compare
  end)

let hpred_entries hpred = match hpred with
  | Sil.Hpointsto (e, _, _) -> [e]
  | Sil.Hlseg (_, _, e, _, _) -> [e]
  | Sil.Hdllseg (_, _, e1, _, _, e2, _) -> [e1; e2]

(** find the id's in sigma reachable from the given roots *)
let sigma_reachable root_fav sigma =
  let fav_to_set fav = Ident.idlist_to_idset (Sil.fav_to_list fav) in
  let reach_set = ref (fav_to_set root_fav) in
  let edges = ref [] in
  let do_hpred hpred =
    let hp_fav_set = fav_to_set (Sil.hpred_fav hpred) in
    let add_entry e = edges := (e, hp_fav_set) :: !edges in
    list_iter add_entry (hpred_entries hpred) in
  list_iter do_hpred sigma;
  let edge_fires (e, _) = match e with
    | Sil.Var id ->
        if (Ident.is_primed id || Ident.is_footprint id) then Ident.IdentSet.mem id !reach_set
        else true
    | _ -> true in
  let rec apply_once edges_to_revisit edges_todo modified = match edges_todo with
    | [] -> (edges_to_revisit, modified)
    | edge:: edges_todo' ->
        if edge_fires edge then
          begin
            reach_set := Ident.IdentSet.union (snd edge) !reach_set;
            apply_once edges_to_revisit edges_todo' true
          end
        else apply_once (edge :: edges_to_revisit) edges_todo' modified in
  let rec find_fixpoint edges_todo =
    let edges_to_revisit, modified = apply_once [] edges_todo false in
    if modified then find_fixpoint edges_to_revisit in
  find_fixpoint !edges;
  (* L.d_str "reachable: ";
  Ident.IdentSet.iter (fun id -> Sil.d_exp (Sil.Var id); L.d_str " ") !reach_set;
  L.d_ln (); *)
  !reach_set

let get_cycle root prop =
  let sigma = Prop.get_sigma prop in
  let get_points_to e =
    match e with
    | Sil.Eexp(e', _) ->
        (try
          Some(list_find (fun hpred -> match hpred with
                    | Sil.Hpointsto(e'', _, _) -> Sil.exp_equal e'' e'
                    | _ -> false) sigma)
        with _ -> None)
    | _ -> None in
  let print_cycle cyc =
    (L.d_str "Cycle= ";
      list_iter (fun ((e, t), f, e') ->
              match e, e' with
              | Sil.Eexp (e, _), Sil.Eexp (e', _) ->
                  L.d_str ("("^(Sil.exp_to_string e)^": "^(Sil.typ_to_string t)^", "^(Ident.fieldname_to_string f)^", "^(Sil.exp_to_string e')^")")
              | _ -> ()) cyc;
      L.d_strln "") in
  (* perform a dfs of a graph stopping when e_root is reached. *)
  (* Returns a pair (path, bool) where path is a list of edges ((e1,type_e1),f,e2) *)
  (* describing the path to e_root and bool is true if e_root is reached. *)
  let rec dfs e_root et_src path el visited =
    match el with
    | [] -> path, false
    | (f, e):: el' ->
        if Sil.strexp_equal e e_root then
          (et_src, f, e):: path, true
        else if list_mem Sil.strexp_equal e visited then
          path, false
        else (
          let visited' = (fst et_src):: visited in
          let res = (match get_points_to e with
              | None -> path, false
              | Some (Sil.Hpointsto(_, Sil.Estruct(fl, _), Sil.Sizeof(te, _))) ->
                  dfs e_root (e, te) ((et_src, f, e):: path) fl visited'
              | _ -> path, false (* check for lists *)) in
          if snd res then res
          else dfs e_root et_src path el' visited') in
  L.d_strln "Looking for cycle with root expression: "; Sil.d_hpred root; L.d_strln "";
  match root with
  | Sil.Hpointsto(e_root, Sil.Estruct(fl, _), Sil.Sizeof(te, _)) ->
      let se_root = Sil.Eexp(e_root, Sil.Inone) in
      (* start dfs with empty path and expr pointing to root *)
      let (pot_cycle, res) = dfs se_root (se_root, te) [] fl [] in
      if res then (
        print_cycle pot_cycle;
        pot_cycle
      ) else (
        L.d_strln "NO cycle found from root";
        [])
  | _ -> L.d_strln "Root exp is not an allocated object. No cycle found"; []

(** return a reachability function based on whether an id appears in several hpreds *)
let reachable_when_in_several_hpreds sigma : Ident.t -> bool =
  let (id_hpred_map : HpredSet.t IdMap.t ref) = ref IdMap.empty (* map id to hpreds in which it occurs *) in
  let add_id_hpred id hpred =
    try
      let hpred_set = IdMap.find id !id_hpred_map in
      id_hpred_map := IdMap.add id (HpredSet.add hpred hpred_set) !id_hpred_map
    with
    | Not_found -> id_hpred_map := IdMap.add id (HpredSet.singleton hpred) !id_hpred_map in
  let add_hpred hpred =
    let fav = Sil.fav_new () in
    Sil.hpred_fav_add fav hpred;
    list_iter (fun id -> add_id_hpred id hpred) (Sil.fav_to_list fav) in
  let id_in_several_hpreds id =
    HpredSet.cardinal (IdMap.find id !id_hpred_map) > 1 in
  list_iter add_hpred sigma;
  id_in_several_hpreds

let full_reachability_algorithm = true

(* Check whether the hidden counter field of a struct representing an *)
(* objective-c object is positive, and whether the leak is part of the *)
(* specified buckets. In the positive case, it returns the bucket *)
let should_raise_objc_leak prop hpred =
  match hpred with
  | Sil.Hpointsto(e, Sil.Estruct((fn, Sil.Eexp( (Sil.Const (Sil.Cint i)), _)):: _, _), Sil.Sizeof (typ, _))
  when Ident.fieldname_is_hidden fn && Sil.Int.gt i Sil.Int.zero (* counter > 0 *) ->
      Mleak_buckets.should_raise_leak typ
  | _ -> None

let print_retain_cycle _prop =
  match _prop with
  | None -> ()
  | Some (Some _prop) ->
      let loc = State.get_loc () in
      let source_file = DB.source_file_to_string loc.Sil.file in
      let source_file'= Str.global_replace (Str.regexp_string "/") "_" source_file in
      let dest_file_str = (DB.filename_to_string (DB.Results_dir.specs_dir ()))^"/"^source_file'^"_RETAIN_CYCLE_"^(Sil.loc_to_string loc)^".dot" in
      L.d_strln ("Printing dotty proposition for retain cycle in :"^dest_file_str);
      Prop.d_prop _prop; L.d_strln "";
      Dotty.dotty_prop_to_dotty_file dest_file_str _prop
  | _ -> ()

let get_var_retain_cycle _prop =
  let sigma = Prop.get_sigma _prop in
  let is_pvar v h =
    match h with
    | Sil.Hpointsto (Sil.Lvar pv, v', _) when Sil.strexp_equal v v' -> true
    | _ -> false in
  let is_hpred_block v h =
    match h, v with
    | Sil.Hpointsto (e, _, Sil.Sizeof(typ, _)), Sil.Eexp (e', _)
    when Sil.exp_equal e e' && Sil.is_block_type typ -> true
    | _, _ -> false in
  let find_pvar v =
    try
      let hp = list_find (is_pvar v) sigma in
      Some (Sil.hpred_get_lhs hp)
    with Not_found -> None in
  let find_block v =
    if (list_exists (is_hpred_block v) sigma) then
      Some (Sil.Lvar Sil.block_pvar)
    else None in
  let sexp e = Sil.Eexp (e, Sil.Inone) in
  let find_pvar_or_block ((e, t), f, e') =
    match find_pvar e with
    | Some pvar -> [((sexp pvar, t), f, e')]
    | _ -> (match find_block e with
          | Some blk -> [((sexp blk, t), f, e')]
          | _ -> [((sexp (Sil.Sizeof(t, Sil.Subtype.exact)), t), f, e')]) in
  (* returns the pvars of the first cycle we find in sigma. *)
  (* This is an heuristic that works if there is one cycle. *)
  (* In case there are more than one cycle we may return not necessarily*)
  (* the one we are looking for. *)
  let rec do_sigma sigma_todo =
    match sigma_todo with
    | [] -> []
    | hp:: sigma' ->
        let cycle = get_cycle hp _prop in
        L.d_strln "Filtering pvar in cycle ";
        let cycle' = list_flatten (list_map find_pvar_or_block cycle) in
        if cycle' = [] then do_sigma sigma'
        else cycle' in
  do_sigma sigma

let remove_opt _prop =
  match _prop with
  | Some (Some p) -> p
  | _ -> Prop.prop_emp

(* Checks if cycle has fields (derived from a property or directly defined as ivar) *)
(* with attributes weak/unsafe_unretained/assing *)
let cycle_has_weak_or_unretained_or_assign_field cycle =
  (* returns items annotation for field fn in struct t *)
  let get_item_annotation t fn =
    match t with
    | Sil.Tstruct(nsf, sf, _, _, _, _, _) ->
        let ia = ref [] in
        list_iter (fun (fn', t', ia') ->
                if Ident.fieldname_equal fn fn' then ia := ia') (nsf@sf);
        !ia
    | _ -> [] in
  let rec has_weak_or_unretained_or_assign params =
    match params with
    | [] -> false
    | att:: _ when Config.unsafe_unret = att || Config.weak = att || Config.assign = att -> true
    | _:: params' -> has_weak_or_unretained_or_assign params' in
  let do_annotation (a, _) =
    ((a.Sil.class_name = Config.property_attributes) ||
      (a.Sil.class_name = Config.ivar_attributes)) && has_weak_or_unretained_or_assign a.Sil.parameters in
  let rec do_cycle c =
    match c with
    | [] -> false
    | ((e, t), fn, _):: c' ->
        let ia = get_item_annotation t fn in
        if (list_exists do_annotation ia) then true
        else do_cycle c' in
  do_cycle cycle

let check_junk ?original_prop pname tenv prop =
  let fav_sub_sigmafp = Sil.fav_new () in
  Sil.sub_fav_add fav_sub_sigmafp (Prop.get_sub prop);
  Prop.sigma_fav_add fav_sub_sigmafp (Prop.get_sigma_footprint prop);
  let leaks_reported = ref [] in

  let remove_junk_once fp_part fav_root sigma =
    let id_considered_reachable = (* reachability function *)
      if full_reachability_algorithm then
        let reach_set = sigma_reachable fav_root sigma in
        fun id -> Ident.IdentSet.mem id reach_set
      else
        reachable_when_in_several_hpreds sigma in
    let should_remove_hpred entries =
      let predicate = function
        | Sil.Var id ->
            (Ident.is_primed id || Ident.is_footprint id)
            && not (Sil.fav_mem fav_root id) && not (id_considered_reachable id)
        | _ -> false in
      list_for_all predicate entries in
    let hpred_in_cycle hpred = (* check if the predicate belongs to a cycle in the heap *)
      let id_in_cycle id =
        let set1 = sigma_reachable (Sil.fav_from_list [id]) sigma in
        let set2 = Ident.IdentSet.remove id set1 in
        let fav2 = Sil.fav_from_list (Ident.IdentSet.elements set2) in
        let set3 = sigma_reachable fav2 sigma in
        Ident.IdentSet.mem id set3 in
      let entries = hpred_entries hpred in
      let predicate = function
        | Sil.Var id -> id_in_cycle id
        | _ -> false in
      let hpred_is_loop = match hpred with (* true if hpred has a self loop, ie one field points to id *)
        | Sil.Hpointsto (Sil.Var id, se, _) ->
            let fav = Sil.fav_new () in
            Sil.strexp_fav_add fav se;
            Sil.fav_mem fav id
        | _ -> false in
      hpred_is_loop
      ||
      list_exists predicate entries in
    let rec remove_junk_recursive sigma_done sigma_todo =
      match sigma_todo with
      | [] -> list_rev sigma_done
      | hpred :: sigma_todo' ->
          let entries = hpred_entries hpred in
          if should_remove_hpred entries
          then begin
            let part = if fp_part then "footprint" else "normal" in
            L.d_strln (".... Prop with garbage in " ^ part ^ " part ....");
            L.d_increase_indent 1;
            L.d_strln "PROP:";
            Prop.d_prop prop; L.d_ln ();
            L.d_strln "PREDICATE:";
            Prop.d_sigma [hpred];
            L.d_ln ();
            let alloc_attribute = (* find the alloc attribute of one of the roots of hpred, if it exists *)
              let res = ref None in
              let do_entry e =
                match Prop.get_resource_undef_attribute prop e with
                | Some (Sil.Aresource ({ Sil.ra_kind = Sil.Racquire }) as a) ->
                    L.d_str "ATTRIBUTE: "; Sil.d_exp (Sil.Const (Sil.Cattribute a)); L.d_ln ();
                    res := Some a
                | Some (Sil.Aundef _ as a) ->
                    res := Some a
                | _ -> () in
              list_iter do_entry entries;
              !res in
            L.d_decrease_indent 1;
            let is_undefined = match alloc_attribute with
              | Some (Sil.Aundef _) -> true
              | _ -> false in
            let resource = match Errdesc.hpred_is_open_resource prop hpred with
              | Some res -> res
              | None -> Sil.Rmemory Sil.Mmalloc in
            let objc_ml_bucket_opt =
              match resource with
              | Sil.Rmemory Sil.Mobjc -> should_raise_objc_leak prop hpred
              | _ -> None in
            let exn_retain_cycle cycle =
              print_retain_cycle original_prop;
              let desc = Errdesc.explain_retain_cycle (remove_opt original_prop) cycle (State.get_loc ()) in
              Exceptions.Retain_cycle(remove_opt original_prop, hpred, desc, try assert false with Assert_failure x -> x) in
            let exn_leak =
              Exceptions.Leak (fp_part, prop, hpred, Errdesc.explain_leak tenv hpred prop alloc_attribute objc_ml_bucket_opt, !Absarray.array_abstraction_performed, resource, try assert false with Assert_failure x -> x) in
            let ignore_resource, exn =
              (match alloc_attribute, resource with
                | Some _, Sil.Rmemory Sil.Mobjc when (hpred_in_cycle hpred) ->
                (* When there is a cycle in objc we ignore it only if it has weak or unsafe_unretained fields *)
                (* Otherwise we report a retain cycle*)
                    let cycle = get_var_retain_cycle (remove_opt original_prop) in
                    if cycle_has_weak_or_unretained_or_assign_field cycle then
                      true, exn_retain_cycle cycle
                    else false, exn_retain_cycle cycle
                | Some _, Sil.Rmemory Sil.Mobjc ->
                    objc_ml_bucket_opt = None, exn_leak
                | Some _, Sil.Rmemory _ -> !Sil.curr_language = Sil.Java, exn_leak
                | Some _, Sil.Rignore -> true, exn_leak
                | Some _, Sil.Rfile -> false, exn_leak
                | Some _, Sil.Rlock -> false, exn_leak
                | _ when hpred_in_cycle hpred && Sil.has_objc_ref_counter hpred ->
                (* When its a cycle and the object has a ref counter then *)
                (* we have a retain cycle. Objc object may not have the *)
                (* Sil.Mobjc qualifier when added in footprint doing abduction *)
                    let cycle = get_var_retain_cycle (remove_opt original_prop) in
                    false, exn_retain_cycle cycle
                | _ -> !Sil.curr_language = Sil.Java, exn_leak) in
            let ignore_leak = !Config.allowleak || ignore_resource || is_undefined in
            let report_and_continue = !Config.footprint in (* in footprint mode, report leak and continue *)
            let already_reported () =
              let attr_opt_equal ao1 ao2 = match ao1, ao2 with
                | None, None -> true
                | Some a1, Some a2 -> Sil.attribute_equal a1 a2
                | Some _, None
                | None, Some _ -> false in
              (alloc_attribute = None && !leaks_reported <> []) || (* None attribute only reported if it's the first one *)
              list_mem attr_opt_equal alloc_attribute !leaks_reported in
            let report_leak () =
              if report_and_continue then
                begin
                  if not (already_reported ()) (* report each leak only once *)
                  then begin
                    Reporting.log_error pname exn;
                    Exceptions.print_exception_html "Error: " exn;
                  end;
                  leaks_reported := alloc_attribute :: !leaks_reported;
                  remove_junk_recursive sigma_done sigma_todo'
                end
              else raise exn in
            if ignore_leak then remove_junk_recursive sigma_done sigma_todo'
            else report_leak ()
          end
          else
            remove_junk_recursive (hpred :: sigma_done) sigma_todo' in
    remove_junk_recursive [] sigma in
  let rec remove_junk fp_part fav_root sigma = (* call remove_junk_once until sigma stops shrinking *)
    let sigma' = remove_junk_once fp_part fav_root sigma in
    if list_length sigma' = list_length sigma then sigma'
    else remove_junk fp_part fav_root sigma' in
  let sigma_new = remove_junk false fav_sub_sigmafp (Prop.get_sigma prop) in
  let sigma_fp_new = remove_junk true (Sil.fav_new ()) (Prop.get_sigma_footprint prop) in
  if Prop.sigma_equal (Prop.get_sigma prop) sigma_new && Prop.sigma_equal (Prop.get_sigma_footprint prop) sigma_fp_new
  then prop
  else Prop.normalize (Prop.replace_sigma sigma_new (Prop.replace_sigma_footprint sigma_fp_new prop))

(** Check whether the prop contains junk.
If it does, and [Config.allowleak] is true, remove the junk, otherwise raise a Leak exception. *)
let abstract_junk ?original_prop pname tenv prop =
  Absarray.array_abstraction_performed := false;
  check_junk ~original_prop: original_prop pname tenv prop

(** Remove redundant elements in an array, and check for junk afterwards *)
let remove_redundant_array_elements pname tenv prop =
  Absarray.array_abstraction_performed := false;
  let prop' = Absarray.remove_redundant_elements prop in
  check_junk ~original_prop: (Some(prop)) pname tenv prop'

let abstract_prop pname tenv ~(rename_primed: bool) ~(from_abstract_footprint: bool) p =
  Absarray.array_abstraction_performed := false;
  let pure_abs_p = abstract_pure_part ~from_abstract_footprint: true p in
  let array_abs_p =
    if from_abstract_footprint
    then pure_abs_p
    else abstract_pure_part ~from_abstract_footprint: from_abstract_footprint (Absarray.abstract_array_check pure_abs_p) in
  let abs_p = abs_rules_apply tenv array_abs_p in
  let abs_p = abstract_gc abs_p in (** abstraction might enable more gc *)
  let abs_p = check_junk ~original_prop: (Some(p)) pname tenv abs_p in
  let ren_abs_p =
    if rename_primed
    then Prop.prop_rename_primed_footprint_vars abs_p
    else abs_p in
  ren_abs_p

let get_local_stack cur_sigma init_sigma =
  let filter_stack = function
    | Sil.Hpointsto (Sil.Lvar _, _, _) -> true
    | Sil.Hpointsto _ | Sil.Hlseg _ | Sil.Hdllseg _ -> false in
  let get_stack_var = function
    | Sil.Hpointsto (Sil.Lvar pvar, _, _) -> pvar
    | Sil.Hpointsto _ | Sil.Hlseg _ | Sil.Hdllseg _ -> assert false in
  let filter_local_stack old_pvars = function
    | Sil.Hpointsto (Sil.Lvar pvar, _, _) -> not (list_exists (Sil.pvar_equal pvar) old_pvars)
    | Sil.Hpointsto _ | Sil.Hlseg _ | Sil.Hdllseg _ -> false in
  let init_stack = list_filter filter_stack init_sigma in
  let init_stack_pvars = list_map get_stack_var init_stack in
  let cur_local_stack = list_filter (filter_local_stack init_stack_pvars) cur_sigma in
  let cur_local_stack_pvars = list_map get_stack_var cur_local_stack in
  (cur_local_stack, cur_local_stack_pvars)

(** Extract the footprint, add a local stack and return it as a prop *)
let extract_footprint_for_abs (p : 'a Prop.t) : Prop.exposed Prop.t * Sil.pvar list =
  let sigma = Prop.get_sigma p in
  let foot_pi = Prop.get_pi_footprint p in
  let foot_sigma = Prop.get_sigma_footprint p in
  let (local_stack, local_stack_pvars) = get_local_stack sigma foot_sigma in
  let p0 = Prop.from_sigma (local_stack @ foot_sigma) in
  let p1 = Prop.replace_pi foot_pi p0 in
  (p1, local_stack_pvars)

let remove_local_stack sigma pvars =
  let filter_non_stack = function
    | Sil.Hpointsto (Sil.Lvar pvar, _, _) -> not (list_exists (Sil.pvar_equal pvar) pvars)
    | Sil.Hpointsto _ | Sil.Hlseg _ | Sil.Hdllseg _ -> true in
  list_filter filter_non_stack sigma

(** [prop_set_fooprint p p_foot] removes a local stack from [p_foot],
and sets proposition [p_foot] as footprint of [p]. *)
let set_footprint_for_abs (p : 'a Prop.t) (p_foot : 'a Prop.t) local_stack_pvars : Prop.exposed Prop.t =
  let p_foot_pure = Prop.get_pure p_foot in
  let p_foot_sigma = Prop.get_sigma p_foot in
  let pi = p_foot_pure in
  let sigma = remove_local_stack p_foot_sigma local_stack_pvars in
  Prop.replace_sigma_footprint sigma (Prop.replace_pi_footprint pi p)

(** Abstract the footprint of prop *)
let abstract_footprint pname (tenv : Sil.tenv) (prop : Prop.normal Prop.t) : Prop.normal Prop.t =
  let (p, added_local_vars) = extract_footprint_for_abs prop in
  let p_abs =
    abstract_prop
      pname tenv ~rename_primed: false
      ~from_abstract_footprint: true (Prop.normalize p) in
  let prop' = set_footprint_for_abs prop p_abs added_local_vars in
  Prop.normalize prop'

let _abstract pname pay tenv p =
  if pay then SymOp.pay(); (* pay one symop *)
  let p' = if !Config.footprint then abstract_footprint pname tenv p else p in
  abstract_prop pname tenv ~rename_primed: true ~from_abstract_footprint: false p'

let abstract pname tenv p =
  _abstract pname true tenv p

let abstract_no_symop pname tenv p =
  _abstract pname false tenv p

let lifted_abstract pname tenv pset =
  let f p =
    if Prover.check_inconsistency p then None
    else Some (abstract pname tenv p) in
  let abstracted_pset = Propset.map_option f pset in
  abstracted_pset

(***************** End of Main Abstraction Functions *****************)
