(*
* Copyright (c) 2014 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

open Utils
module L = Logging

(** Module for the checks called by Eradicate. *)

(* activate the condition redundant warnings *)
let activate_condition_redundant = Config.from_env_variable "ERADICATE_CONDITION_REDUNDANT"

(* activate check for @Present annotations *)
let activate_optional_present = Config.from_env_variable "ERADICATE_OPTIONAL_PRESENT"

(* activate the field not mutable warnings *)
let activate_field_not_mutable = Config.from_env_variable "ERADICATE_FIELD_NOT_MUTABLE"

(* activate the field over annotated warnings *)
let activate_field_over_annotated = Config.from_env_variable "ERADICATE_FIELD_OVER_ANNOTATED"

(* activate the return over annotated warning *)
let activate_return_over_annotated = Config.from_env_variable "ERADICATE_RETURN_OVER_ANNOTATED"

(* do not report RETURN_NOT_NULLABLE if the return is annotated @Nonnull *)
let return_nonnull_silent = true

(* if true, check calls to libraries (i.e. not modelled and source not available) *)
let check_library_calls = false


let get_field_annotation fn typ =
  match Annotations.get_field_type_and_annotation fn typ with
  | None -> None
  | Some (t, ia) ->
      let ia' =
        (* TODO (t4968422) eliminate not !Config.eradicate check by marking fields as nullified *)
        (* outside of Eradicate in some other way *)
        if (Models.Inference.enabled || not !Config.eradicate)
        && Models.Inference.field_is_marked fn
        then Annotations.mk_ia Annotations.Nullable ia
        else ia in
      Some (t, ia')

let report_error = TypeErr.report_error Checkers.ST.report_error

let explain_expr node e =
  match Errdesc.exp_rv_dexp node e with
  | Some de -> Some (Sil.dexp_to_string de)
  | None -> None

(** Classify a procedure. *)
let classify_procedure pn pd =
  let unique_id = Procname.to_unique_id pn in
  let classification =
    if Models.is_modelled_nullable pn then "M" (* modelled *)
    else if Models.is_ret_library pn then "R" (* return library *)
    else if Specs.proc_is_library pn pd then "L" (* library *)
    else if not (Cfg.Procdesc.is_defined pd) then "S" (* skip *)
    else if string_is_prefix "com.facebook" unique_id then "F" (* FB *)
    else "?" in
  classification

let pp_inferred_return_annotation is_nullable proc_name =
  L.stdout "(*InferredLibraryReturnAnnotation*) %5b, \"%s\";@."
    is_nullable
    (Procname.to_unique_id proc_name)


let is_virtual = function
  | ("this", _, _):: _ -> true
  | _ -> false


(** Check an access (read or write) to a field. *)
let check_field_access
    find_canonical_duplicate curr_pname node instr_ref exp fname ta loc : unit =
  if TypeAnnotation.get_value Annotations.Nullable ta = true then
    let origin_descr = TypeAnnotation.descr_origin ta in
    report_error
      find_canonical_duplicate
      node
      (TypeErr.Null_field_access (explain_expr node exp, fname, origin_descr, false))
      (Some instr_ref)
      loc curr_pname

(** Check an access to an array *)
let check_array_access
    find_canonical_duplicate
    curr_pname
    node
    instr_ref
    array_exp
    fname
    ta
    loc
    indexed =
  if TypeAnnotation.get_value Annotations.Nullable ta = true then
    let origin_descr = TypeAnnotation.descr_origin ta in
    report_error
      find_canonical_duplicate
      node
      (TypeErr.Null_field_access (explain_expr node array_exp, fname, origin_descr, indexed))
      (Some instr_ref)
      loc
      curr_pname

(** Where the condition is coming from *)
type from_call =
  | From_condition (** Direct condition *)
  | From_instanceof (** x instanceof C *)
  | From_optional_isPresent (** x.isPresent *)
  | From_containsKey (** x.containsKey *)

(** Check the normalized "is zero" or "is not zero" condition of a prune instruction. *)
let check_condition case_zero find_canonical_duplicate get_proc_desc curr_pname
    node e typ ta true_branch from_call idenv linereader loc instr_ref : unit =
  let is_fun_nonnull ta = match TypeAnnotation.get_origin ta with
    | TypeOrigin.Proc (_, _, signature, _) ->
        let (ia, _) = signature.Annotations.ret in
        Annotations.ia_is_nonnull ia
    | _ -> false in

  let contains_instanceof_throwable node =
    (* Check if the current procedure has a catch Throwable. *)
    (* That always happens in the bytecode generated by try-with-resources. *)
    let loc = Cfg.Node.get_loc node in
    let throwable_found = ref false in
    let throwable_class = Mangled.from_string "java.lang.Throwable" in
    let typ_is_throwable = function
      | Sil.Tstruct (_, _, Sil.Class, Some c, _, _, _) ->
          Mangled.equal c throwable_class
      | _ -> false in
    let do_instr = function
      | Sil.Call (_, Sil.Const (Sil.Cfun pn), [_; (Sil.Sizeof(t, _), _)], _, _) when
      Procname.equal pn SymExec.ModelBuiltins.__instanceof && typ_is_throwable t ->
          throwable_found := true
      | _ -> () in
    let do_node n =
      if Sil.loc_equal loc (Cfg.Node.get_loc n)
      then list_iter do_instr (Cfg.Node.get_instrs n) in
    Cfg.Procdesc.iter_nodes do_node (Cfg.Node.get_proc_desc node);
    !throwable_found in

  let from_try_with_resources () : bool =
    (* heuristic to check if the condition is the translation of try-with-resources *)
    match Printer.LineReader.from_loc linereader loc with
    | Some line ->
        not (string_contains "==" line || string_contains "!=" line)
        && (string_contains "}" line)
        && contains_instanceof_throwable node
    | None -> false in

  let is_temp = Idenv.exp_is_temp idenv e in
  let nonnull = is_fun_nonnull ta in
  let should_report =
    TypeAnnotation.get_value Annotations.Nullable ta = false &&
    (activate_condition_redundant || nonnull) &&
    true_branch &&
    (not is_temp || nonnull) &&
    PatternMatch.type_is_class typ &&
    not (from_try_with_resources ()) &&
    from_call = From_condition &&
    not (TypeAnnotation.origin_is_fun_library ta) in
  let is_always_true = not case_zero in
  let nonnull = is_fun_nonnull ta in
  if should_report then
    report_error
      find_canonical_duplicate
      node
      (TypeErr.Condition_redundant (is_always_true, explain_expr node e, nonnull))
      (Some instr_ref)
      loc curr_pname

(** Check an "is zero" condition. *)
let check_zero find_canonical_duplicate = check_condition true find_canonical_duplicate

(** Check an "is not zero" condition. *)
let check_nonzero find_canonical_duplicate = check_condition false find_canonical_duplicate

(** Check an assignment to a field. *)
let check_field_assignment
    find_canonical_duplicate curr_pname node instr_ref typestate exp_lhs
    exp_rhs typ loc fname t_ia_opt typecheck_expr print_current_state : unit =
  let (t_lhs, ta_lhs, _) =
    typecheck_expr node instr_ref curr_pname typestate exp_lhs
      (typ, TypeAnnotation.const Annotations.Nullable false TypeOrigin.ONone, [loc]) loc in
  let (_, ta_rhs, _) =
    typecheck_expr node instr_ref curr_pname typestate exp_rhs
      (typ, TypeAnnotation.const Annotations.Nullable false TypeOrigin.ONone, [loc]) loc in
  let should_report_nullable =
    TypeAnnotation.get_value Annotations.Nullable ta_lhs = false &&
    TypeAnnotation.get_value Annotations.Nullable ta_rhs = true &&
    PatternMatch.type_is_class t_lhs &&
    not (Ident.java_fieldname_is_outer_instance fname) in
  let should_report_absent =
    activate_optional_present &&
    TypeAnnotation.get_value Annotations.Present ta_lhs = true &&
    TypeAnnotation.get_value Annotations.Present ta_rhs = false &&
    not (Ident.java_fieldname_is_outer_instance fname) in
  let should_report_mutable =
    let field_is_mutable () = match t_ia_opt with
      | Some (_, ia) -> Annotations.ia_is_mutable ia
      | _ -> true in
    activate_field_not_mutable &&
    not (Procname.is_constructor curr_pname) &&
    not (Procname.is_class_initializer curr_pname) &&
    not (field_is_mutable ()) in
  if should_report_nullable || should_report_absent then
    begin
      let ann = if should_report_nullable then Annotations.Nullable else Annotations.Present in
      if Models.Inference.enabled then Models.Inference.field_add_nullable_annotation fname;
      let origin_descr = TypeAnnotation.descr_origin ta_rhs in
      report_error
        find_canonical_duplicate
        node
        (TypeErr.Field_annotation_inconsistent (ann, fname, origin_descr))
        (Some instr_ref)
        loc curr_pname
    end;
  if should_report_mutable then
    begin
      let origin_descr = TypeAnnotation.descr_origin ta_rhs in
      report_error
        find_canonical_duplicate
        node
        (TypeErr.Field_not_mutable (fname, origin_descr))
        (Some instr_ref)
        loc curr_pname
    end


(** Check that nonnullable fields are initialized in constructors. *)
let check_constructor_initialization
    find_canonical_duplicate
    curr_pname
    curr_pdesc
    start_node
    final_typestate
    final_initializer_typestates
    final_constructor_typestates
    loc: unit =
  State.set_node start_node;
  if Procname.is_constructor curr_pname
  then begin
    match PatternMatch.get_this_type curr_pdesc with
    | Some (Sil.Tptr (Sil.Tstruct (ftal, _, _, nameo, _, _, _) as ts, _)) ->
        let do_fta (fn, ft, ia) =
          let annotated_with f = match get_field_annotation fn ts with
            | None -> false
            | Some (_, ia) -> f ia in
          let nullable_annotated = annotated_with Annotations.ia_is_nullable in
          let nonnull_annotated = annotated_with Annotations.ia_is_nonnull in
          let inject_annotated = annotated_with Annotations.ia_is_inject in

          let final_type_annotation_with unknown list f =
            let filter_range_opt = function
              | Some (_, ta, _) -> f ta
              | None -> unknown in
            list_exists
              (function pname, typestate ->
                    let pvar = Sil.mk_pvar
                        (Mangled.from_string (Ident.fieldname_to_string fn))
                        pname in
                    filter_range_opt (TypeState.lookup_pvar pvar typestate))
              list in

          let may_be_assigned_in_final_typestate =
            final_type_annotation_with
              false
              (Lazy.force final_initializer_typestates)
              (fun ta -> TypeAnnotation.get_origin ta <> TypeOrigin.Undef) in

          let may_be_nullable_in_final_typestate () =
            final_type_annotation_with
              true
              (Lazy.force final_constructor_typestates)
              (fun ta -> TypeAnnotation.get_value Annotations.Nullable ta = true) in

          let should_check_field =
            let in_current_class =
              let fld_cname = Ident.java_fieldname_get_class fn in
              match nameo with
              | None -> false
              | Some name -> Mangled.equal name (Mangled.from_string fld_cname) in
            not inject_annotated &&
            PatternMatch.type_is_class ft &&
            in_current_class &&
            not (Ident.java_fieldname_is_outer_instance fn) in

          if should_check_field then
            begin
              if Models.Inference.enabled then Models.Inference.field_add_nullable_annotation fn;

              (* Check if field is missing annotation. *)
              if not (nullable_annotated || nonnull_annotated) &&
              not may_be_assigned_in_final_typestate then
                report_error
                  find_canonical_duplicate
                  start_node
                  (TypeErr.Field_not_initialized (fn, curr_pname))
                  None
                  loc
                  curr_pname;

              (* Check if field is over-annotated. *)
              if activate_field_over_annotated &&
              nullable_annotated &&
              not (may_be_nullable_in_final_typestate ()) then
                report_error
                  find_canonical_duplicate
                  start_node
                  (TypeErr.Field_over_annotated (fn, curr_pname))
                  None
                  loc
                  curr_pname;
            end in

        list_iter do_fta ftal
    | _ -> ()
  end

(** Check the annotations when returning from a method. *)
let check_return_annotation
    find_canonical_duplicate curr_pname curr_pdesc exit_node ret_range
    ret_ia ret_implicitly_nullable loc : unit =
  let ret_annotated_nullable = Annotations.ia_is_nullable ret_ia in
  let ret_annotated_present = Annotations.ia_is_present ret_ia in
  let ret_annotated_nonnull = Annotations.ia_is_nonnull ret_ia in
  let return_not_nullable =
    match ret_range with
    | Some (_, final_ta, _) ->
        let final_nullable = TypeAnnotation.get_value Annotations.Nullable final_ta in
        let final_present = TypeAnnotation.get_value Annotations.Present final_ta in
        let origin_descr = TypeAnnotation.descr_origin final_ta in
        let return_not_nullable =
          final_nullable &&
          not ret_annotated_nullable &&
          not ret_implicitly_nullable &&
          not (return_nonnull_silent && ret_annotated_nonnull) in
        let return_value_not_present =
          activate_optional_present &&
          not final_present &&
          ret_annotated_present in
        let return_over_annotated =
          not final_nullable &&
          ret_annotated_nullable &&
          activate_return_over_annotated in
        if return_not_nullable || return_value_not_present then
          begin
            let ann =
              if return_not_nullable then Annotations.Nullable else Annotations.Present in
            if Models.Inference.enabled then Models.Inference.proc_add_return_nullable curr_pname;
            report_error
              find_canonical_duplicate
              exit_node
              (TypeErr.Return_annotation_inconsistent (ann, curr_pname, origin_descr))
              None
              loc curr_pname
          end;
        if return_over_annotated then
          begin
            report_error
              find_canonical_duplicate
              exit_node
              (TypeErr.Return_over_annotated curr_pname)
              None
              loc curr_pname
          end;
        return_not_nullable
    | _ ->
        false in
  if Models.infer_library_return && classify_procedure curr_pname curr_pdesc = "L"
  then pp_inferred_return_annotation return_not_nullable curr_pname

(** Check the receiver of a virtual call. *)
let check_call_receiver
    find_canonical_duplicate
    curr_pname
    node
    typestate
    call_params
    callee_pname
    callee_loc
    (instr_ref : TypeErr.InstrRef.t)
    loc
    typecheck_expr
    print_current_state : unit =
  match call_params with
  | ((original_this_e, this_e), typ) :: _ ->
      let (_, this_ta, _) =
        typecheck_expr node instr_ref curr_pname typestate this_e
          (typ, TypeAnnotation.const Annotations.Nullable false TypeOrigin.ONone, []) loc in
      let null_method_call = TypeAnnotation.get_value Annotations.Nullable this_ta in
      let optional_get_on_absent =
        activate_optional_present &&
        Models.is_optional_get callee_pname &&
        not (TypeAnnotation.get_value Annotations.Present this_ta) in
      if null_method_call || optional_get_on_absent then
        begin
          let ann = if null_method_call then Annotations.Nullable else Annotations.Present in
          let descr = explain_expr node original_this_e in
          let origin_descr = TypeAnnotation.descr_origin this_ta in
          report_error
            find_canonical_duplicate
            node
            (TypeErr.Call_receiver_annotation_inconsistent
              (ann, descr, callee_pname, origin_descr))
            (Some instr_ref)
            loc curr_pname
        end
  | [] -> ()

(** Check the parameters of a call. *)
let check_call_parameters
    find_canonical_duplicate curr_pname node typestate callee_pname
    callee_pdesc sig_params call_params loc annotated_signature
    instr_ref typecheck_expr print_current_state : unit =
  let has_this = is_virtual sig_params in
  let tot_param_num = list_length sig_params - (if has_this then 1 else 0) in
  let rec check sparams cparams = match sparams, cparams with
    | (s1, ia1, t1) :: sparams', ((orig_e2, e2), t2) :: cparams' ->
        let param_is_this = s1 = "this" in
        let formal_is_nullable = Annotations.ia_is_nullable ia1 in
        let formal_is_present = Annotations.ia_is_present ia1 in
        let (_, ta2, _) =
          typecheck_expr node instr_ref curr_pname typestate e2
            (t2, TypeAnnotation.const Annotations.Nullable false TypeOrigin.ONone, []) loc in
        let parameter_not_nullable =
          not param_is_this &&
          PatternMatch.type_is_class t1 &&
          not formal_is_nullable &&
          TypeAnnotation.get_value Annotations.Nullable ta2 in
        let parameter_absent =
          activate_optional_present &&
          not param_is_this &&
          PatternMatch.type_is_class t1 &&
          formal_is_present &&
          not (TypeAnnotation.get_value Annotations.Present ta2) in
        if parameter_not_nullable || parameter_absent then
          begin
            let ann =
              if parameter_not_nullable
              then Annotations.Nullable
              else Annotations.Present in
            let description =
              match explain_expr node orig_e2 with
              | Some descr -> descr
              | None -> "formal parameter " ^ s1 in
            let origin_descr = TypeAnnotation.descr_origin ta2 in

            let param_num = list_length sparams' + (if has_this then 0 else 1) in
            let callee_loc = Cfg.Procdesc.get_loc callee_pdesc in
            report_error
              find_canonical_duplicate
              node
              (TypeErr.Parameter_annotation_inconsistent (
                  ann,
                  description,
                  param_num,
                  callee_pname,
                  callee_loc,
                  origin_descr))
              (Some instr_ref)
              loc curr_pname;
            if Models.Inference.enabled then
              Models.Inference.proc_add_parameter_nullable callee_pname param_num tot_param_num
          end;
        check sparams' cparams'
    | _ -> () in
  let should_check_parameters =
    if check_library_calls then true
    else
      Models.is_modelled_nullable callee_pname ||
      Cfg.Procdesc.is_defined callee_pdesc ||
      Specs.get_summary callee_pname <> None in
  if should_check_parameters then
    (* left to right to avoid guessing the different lengths *)
    check (list_rev sig_params) (list_rev call_params)

(** Checks if the annotations are consistent with the inherited class or with the
implemented interfaces *)
let check_overridden_annotations
    find_canonical_duplicate get_proc_desc tenv proc_name proc_desc annotated_signature =

  let start_node = Cfg.Procdesc.get_start_node proc_desc in
  let loc = Cfg.Node.get_loc start_node in

  let check_return overriden_proc_name overriden_signature =
    let ret_is_nullable =
      let ia, _ = annotated_signature.Annotations.ret in
      Annotations.ia_is_nullable ia
    and ret_overridden_nullable =
      let overriden_ia, _ = overriden_signature.Annotations.ret in
      Annotations.ia_is_nullable overriden_ia in
    if ret_is_nullable && not ret_overridden_nullable then
      report_error
        find_canonical_duplicate
        start_node
        (TypeErr.Inconsistent_subclass_return_annotation (proc_name, overriden_proc_name))
        None
        loc proc_name

  and check_params overriden_proc_name overriden_signature =
    let compare pos current_param overriden_param : int =
      let current_name, current_ia, current_type = current_param in
      let _, overriden_ia, overriden_type = overriden_param in
      let () =
        if not (Annotations.ia_is_nullable current_ia)
        && Annotations.ia_is_nullable overriden_ia then
          report_error
            find_canonical_duplicate
            start_node
            (TypeErr.Inconsistent_subclass_parameter_annotation
              (current_name, pos, proc_name, overriden_proc_name))
            None
            loc proc_name in
      (pos + 1) in

    (* TODO (#5280249): investigate why argument lists can be of different length *)
    let current_params = annotated_signature.Annotations.params
    and overridden_params = overriden_signature.Annotations.params in
    let initial_pos = if is_virtual current_params then 0 else 1 in
    if (list_length current_params) = (list_length overridden_params) then
      ignore (list_fold_left2 compare initial_pos current_params overridden_params) in

  let check overriden_proc_name =
    (* TODO (#5280260): investigate why proc_desc may not be found *)
    match get_proc_desc overriden_proc_name with
    | Some overriden_proc_desc ->
        let overriden_signature =
          Models.get_annotated_signature overriden_proc_desc overriden_proc_name in
        check_return overriden_proc_name overriden_signature;
        check_params overriden_proc_name overriden_signature
    | None -> () in

  let check_overridden_methods super_class_name =
    let super_proc_name = Procname.java_replace_class proc_name super_class_name in
    let type_name = Sil.TN_csu (Sil.Class, Mangled.from_string super_class_name) in
    match Sil.tenv_lookup tenv type_name with
    | Some (Sil.Tstruct (_, _, _, _, _, methods, _)) ->
        let is_override pname =
          Procname.equal pname super_proc_name &&
          not (Procname.is_constructor pname) in
        list_iter
          (fun pname ->
                if is_override pname
                then check pname)
          methods
    | _ -> () in

  let super_types =
    let type_name =
      let class_name = Procname.java_get_class proc_name in
      Sil.TN_csu (Sil.Class, Mangled.from_string class_name) in
    match Sil.tenv_lookup tenv type_name with
    | Some curr_type ->
        list_map Mangled.to_string (PatternMatch.type_get_direct_supertypes curr_type)
    | None -> [] in

  list_iter check_overridden_methods super_types
