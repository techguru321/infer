(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
module F = Format
module L = Logging

(** Forward analysis to compute uninitialized variables at each program point *)
module D =
UninitDomain.Domain
module UninitVars = AbstractDomain.FiniteSet (AccessExpression)
module AliasedVars = AbstractDomain.FiniteSet (UninitDomain.VarPair)
module RecordDomain = UninitDomain.Record (UninitVars) (AliasedVars) (D)

module Payload = SummaryPayload.Make (struct
  type t = UninitDomain.summary

  let update_payloads sum (payloads: Payloads.t) = {payloads with uninit= Some sum}

  let of_payloads (payloads: Payloads.t) = payloads.uninit
end)

let blacklisted_functions = [BuiltinDecl.__set_array_length]

let rec is_basic_type t =
  match t.Typ.desc with
  | Tint _ | Tfloat _ | Tvoid ->
      true
  | Tptr (t', _) ->
      is_basic_type t'
  | _ ->
      false


let is_blacklisted_function pname =
  List.exists ~f:(fun fname -> Typ.Procname.equal pname fname) blacklisted_functions


module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = RecordDomain

  let report_intra access_expr loc summary =
    let message =
      F.asprintf "The value read from %a was never initialized" AccessExpression.pp access_expr
    in
    let ltr = [Errlog.make_trace_element 0 loc "" []] in
    let exn =
      Exceptions.Checkers (IssueType.uninitialized_value, Localise.verbatim_desc message)
    in
    Reporting.log_error summary ~loc ~ltr exn


  type extras = FormalMap.t * Summary.t

  let is_struct t = match t.Typ.desc with Typ.Tstruct _ -> true | _ -> false

  let is_array t = match t.Typ.desc with Typ.Tarray _ -> true | _ -> false

  let get_formals call =
    match Ondemand.get_proc_desc call with
    | Some proc_desc ->
        Procdesc.get_formals proc_desc
    | _ ->
        []


  let should_report_var pdesc tenv uninit_vars access_expr =
    let base = AccessExpression.get_base access_expr in
    match (AccessExpression.get_typ access_expr tenv, base) with
    | Some typ, (Var.ProgramVar pv, _) ->
        not (Pvar.is_frontend_tmp pv) && not (Procdesc.is_captured_var pdesc pv)
        && D.mem access_expr uninit_vars && is_basic_type typ
    | _, _ ->
        false


  let nth_formal_param callee_pname idx =
    let formals = get_formals callee_pname in
    List.nth formals idx


  let function_expects_a_pointer_as_nth_param callee_pname idx =
    match nth_formal_param callee_pname idx with Some (_, typ) -> Typ.is_pointer typ | _ -> false


  let is_struct_field_passed_by_ref call t access_expr idx =
    is_struct t && not (AccessExpression.is_base access_expr)
    && function_expects_a_pointer_as_nth_param call idx


  let is_array_element_passed_by_ref call t access_expr idx =
    is_array t && not (AccessExpression.is_base access_expr)
    && function_expects_a_pointer_as_nth_param call idx


  let report_on_function_params call pdesc tenv uninit_vars actuals loc extras =
    List.iteri
      ~f:(fun idx e ->
        match e with
        | HilExp.AccessExpression access_expr ->
            let _, t = AccessExpression.get_base access_expr in
            if
              should_report_var pdesc tenv uninit_vars access_expr && not (Typ.is_pointer t)
              && not (is_struct_field_passed_by_ref call t access_expr idx)
            then report_intra access_expr loc (snd extras)
            else ()
        | _ ->
            () )
      actuals


  let remove_all_fields tenv base uninit_vars =
    match base with
    | _, {Typ.desc= Tptr ({Typ.desc= Tstruct name_struct}, _)} | _, {Typ.desc= Tstruct name_struct}
          -> (
      match Tenv.lookup tenv name_struct with
      | Some {fields} ->
          List.fold
            ~f:(fun acc (fn, _, _) -> D.remove (AccessExpression.FieldOffset (Base base, fn)) acc)
            fields ~init:uninit_vars
      | _ ->
          uninit_vars )
    | _ ->
        uninit_vars


  let remove_dereference_access base uninit_vars =
    match base with
    | _, {Typ.desc= Tptr _} ->
        D.remove (AccessExpression.Dereference (Base base)) uninit_vars
    | _ ->
        uninit_vars


  let remove_all_array_elements base uninit_vars =
    match base with
    | _, {Typ.desc= Tptr (elt, _)} ->
        D.remove (AccessExpression.ArrayOffset (Base base, elt, [])) uninit_vars
    | _ ->
        uninit_vars


  let remove_init_fields base formal_var uninit_vars init_fields =
    let subst_formal_actual_fields initialized_fields =
      D.map
        (fun access_expr ->
          let v, t = AccessExpression.get_base access_expr in
          let v' = if Var.equal v formal_var then fst base else v in
          let t' =
            match t.desc with
            | Typ.Tptr ({Typ.desc= Tstruct n}, _) ->
                (* a pointer to struct needs to be changed into struct
                       as the actual is just type struct and it would make it
                       equality fail. Not sure why the actual are type struct when
                      passed by reference *)
                {t with Typ.desc= Tstruct n}
            | _ ->
                t
          in
          AccessExpression.replace_base ~remove_deref_after_base:true (v', t') access_expr )
        initialized_fields
    in
    match base with
    | _, {Typ.desc= Tptr ({Typ.desc= Tstruct _}, _)} | _, {Typ.desc= Tstruct _} ->
        D.diff uninit_vars (subst_formal_actual_fields init_fields)
    | _ ->
        uninit_vars


  let is_dummy_constructor_of_a_struct call =
    let is_dummy_constructor_of_struct =
      match get_formals call with
      | [(_, {Typ.desc= Typ.Tptr ({Typ.desc= Tstruct _}, _)})] ->
          true
      | _ ->
          false
    in
    Typ.Procname.is_constructor call && is_dummy_constructor_of_struct


  let is_pointer_assignment tenv lhs rhs =
    let _, base_typ = AccessExpression.get_base lhs in
    HilExp.is_null_literal rhs
    (* the rhs has type int when assigning the lhs to null *)
    || Option.equal Typ.equal (AccessExpression.get_typ lhs tenv) (HilExp.get_typ tenv rhs)
       && Typ.is_pointer base_typ


  (* checks that the set of initialized formal parameters defined in the precondition of
   the function (init_formal_params) contains the (base of) nth formal parameter of the function  *)
  let init_nth_actual_param callee_pname idx init_formal_params =
    match nth_formal_param callee_pname idx with
    | None ->
        None
    | Some (fparam, t) ->
        let var_fparam = Var.of_pvar (Pvar.mk fparam callee_pname) in
        if
          D.exists
            (fun access_expr ->
              let base = AccessExpression.get_base access_expr in
              AccessPath.equal_base base (var_fparam, t) )
            init_formal_params
        then Some var_fparam
        else None


  let remove_initialized_params pdesc call acc idx access_expr remove_fields =
    match Payload.read pdesc call with
    | Some {pre= initialized_formal_params; post= _} -> (
      match init_nth_actual_param call idx initialized_formal_params with
      | Some nth_formal ->
          let acc' = D.remove access_expr acc in
          let base = AccessExpression.get_base access_expr in
          if remove_fields then remove_init_fields base nth_formal acc' initialized_formal_params
          else acc'
      | _ ->
          acc )
    | _ ->
        acc


  (* true if a function initializes at least a param or a field of a struct param *)
  let function_initializes_some_formal_params pdesc call =
    match Payload.read pdesc call with
    | Some {pre= initialized_formal_params; post= _} ->
        not (D.is_empty initialized_formal_params)
    | _ ->
        false


  let exec_instr (astate: Domain.astate) {ProcData.pdesc; ProcData.extras; ProcData.tenv} _
      (instr: HilInstr.t) =
    let update_prepost access_expr rhs =
      let lhs_base = AccessExpression.get_base access_expr in
      if
        FormalMap.is_formal lhs_base (fst extras) && Typ.is_pointer (snd lhs_base)
        && ( not (is_pointer_assignment tenv access_expr rhs)
           || not (AccessExpression.is_base access_expr) )
      then
        let pre' = D.add access_expr (fst astate.prepost) in
        let post = snd astate.prepost in
        (pre', post)
      else astate.prepost
    in
    match instr with
    | Assign (lhs_access_expr, rhs_expr, loc) ->
        let uninit_vars' = D.remove lhs_access_expr astate.uninit_vars in
        let uninit_vars =
          if AccessExpression.is_base lhs_access_expr then
            (* if we assign to the root of a struct then we need to remove all the fields *)
            let lhs_base = AccessExpression.get_base lhs_access_expr in
            remove_all_fields tenv lhs_base uninit_vars' |> remove_dereference_access lhs_base
          else uninit_vars'
        in
        let prepost = update_prepost lhs_access_expr rhs_expr in
        (* check on lhs_typ to avoid false positive when assigning a pointer to another *)
        let is_lhs_not_a_pointer =
          match AccessExpression.get_typ lhs_access_expr tenv with
          | None ->
              false
          | Some lhs_ap_typ ->
              not (Typ.is_pointer lhs_ap_typ)
        in
        ( match rhs_expr with
        | AccessExpression rhs_access_expr ->
            if should_report_var pdesc tenv uninit_vars rhs_access_expr && is_lhs_not_a_pointer
            then report_intra rhs_access_expr loc (snd extras)
        | _ ->
            () ) ;
        {astate with uninit_vars; prepost}
    | Call (_, Direct callee_pname, _, _, _)
      when Typ.Procname.equal callee_pname BuiltinDecl.objc_cpp_throw ->
        {astate with uninit_vars= D.empty}
    | Call (_, HilInstr.Direct call, [HilExp.AccessExpression (AddressOf (Base base))], _, _)
      when is_dummy_constructor_of_a_struct call ->
        (* if it's a default constructor, we use the following heuristic: we assume that it initializes
    correctly all fields when there is an implementation of the constructor that initilizes at least one
    field. If there is no explicit implementation we cannot assume fields are initialized *)
        if function_initializes_some_formal_params pdesc call then
          let uninit_vars' =
            (* in HIL/SIL the default constructor has only one param: the struct *)
            remove_all_fields tenv base astate.uninit_vars
          in
          {astate with uninit_vars= uninit_vars'}
        else astate
    | Call (_, HilInstr.Direct call, actuals, _, loc) ->
        (* in case of intraprocedural only analysis we assume that parameters passed by reference
           to a function will be initialized inside that function *)
        let uninit_vars =
          List.foldi ~init:astate.uninit_vars actuals ~f:(fun idx acc actual_exp ->
              match actual_exp with
              | HilExp.AccessExpression access_expr
                -> (
                  let access_expr_to_remove =
                    match access_expr with AddressOf ae -> ae | _ -> access_expr
                  in
                  match AccessExpression.get_base access_expr with
                  | _, {Typ.desc= Tarray _} when is_blacklisted_function call ->
                      D.remove access_expr acc
                  | _, t
                    when is_struct_field_passed_by_ref call t access_expr idx
                         || is_array_element_passed_by_ref call t access_expr idx ->
                      (* Access to a field of a struct by reference *)
                      if Config.uninit_interproc then
                        remove_initialized_params pdesc call acc idx access_expr_to_remove false
                      else D.remove access_expr_to_remove acc
                  | base when Typ.Procname.is_constructor call ->
                      remove_all_fields tenv base (D.remove access_expr_to_remove acc)
                  | (_, {Typ.desc= Tptr _}) as base ->
                      if Config.uninit_interproc then
                        remove_initialized_params pdesc call acc idx access_expr_to_remove true
                      else
                        D.remove access_expr_to_remove acc |> remove_all_fields tenv base
                        |> remove_all_array_elements base |> remove_dereference_access base
                  | _ ->
                      acc )
              | HilExp.Closure (_, apl) ->
                  (* remove the captured variables of a block/lambda *)
                  List.fold
                    ~f:(fun acc' (base, _) -> D.remove (AccessExpression.Base base) acc')
                    ~init:acc apl
              | _ ->
                  acc )
        in
        report_on_function_params call pdesc tenv uninit_vars actuals loc extras ;
        {astate with uninit_vars}
    | Call _ | Assume _ ->
        astate


  let pp_session_name node fmt = F.fprintf fmt "uninit %a" CFG.pp_id (CFG.id node)
end

module CFG = ProcCfg.NormalOneInstrPerNode
module Analyzer =
  AbstractInterpreter.Make (CFG) (LowerHil.Make (TransferFunctions) (LowerHil.DefaultConfig))

let get_locals cfg tenv pdesc =
  List.fold
    ~f:(fun acc (var_data: ProcAttributes.var_data) ->
      let pvar = Pvar.mk var_data.name (Procdesc.get_proc_name pdesc) in
      let base_access_expr = AccessExpression.Base (Var.of_pvar pvar, var_data.typ) in
      match var_data.typ.Typ.desc with
      | Typ.Tstruct qual_name -> (
        match Tenv.lookup tenv qual_name with
        | Some {fields} ->
            let flist =
              List.fold
                ~f:(fun acc' (fn, _, _) ->
                  AccessExpression.FieldOffset (base_access_expr, fn) :: acc' )
                ~init:acc fields
            in
            base_access_expr :: flist
            (* for struct we take the struct address, and the access_path
                                    to the fields one level down *)
        | _ ->
            acc )
      | Typ.Tarray {elt} ->
          AccessExpression.ArrayOffset (base_access_expr, elt, []) :: acc
      | Typ.Tptr _ ->
          AccessExpression.Dereference base_access_expr :: acc
      | _ ->
          base_access_expr :: acc )
    ~init:[] (Procdesc.get_locals cfg)


let checker {Callbacks.tenv; summary; proc_desc} : Summary.t =
  let cfg = CFG.from_pdesc proc_desc in
  (* start with empty set of uninit local vars and  empty set of init formal params *)
  let formal_map = FormalMap.make proc_desc in
  let uninit_vars = get_locals cfg tenv proc_desc in
  let init =
    ( { RecordDomain.uninit_vars= UninitVars.of_list uninit_vars
      ; RecordDomain.aliased_vars= AliasedVars.empty
      ; RecordDomain.prepost= (D.empty, D.empty) }
    , IdAccessPathMapDomain.empty )
  in
  let invariant_map =
    Analyzer.exec_cfg cfg
      (ProcData.make proc_desc tenv (formal_map, summary))
      ~initial:init ~debug:false
  in
  match Analyzer.extract_post (CFG.id (CFG.exit_node cfg)) invariant_map with
  | Some
      ( {RecordDomain.uninit_vars= _; RecordDomain.aliased_vars= _; RecordDomain.prepost= pre, post}
      , _ ) ->
      Payload.update_summary {pre; post} summary
  | None ->
      if Procdesc.Node.get_succs (Procdesc.get_start_node proc_desc) <> [] then (
        L.internal_error "Uninit analyzer failed to compute post for %a" Typ.Procname.pp
          (Procdesc.get_proc_name proc_desc) ;
        summary )
      else summary
