(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

module F = Format
module L = Logging
module MF = MarkupFormatter

module CallSiteSet = AbstractDomain.FiniteSet (CallSite.Set)
module CallsDomain = AbstractDomain.Map (Annot.Map) (CallSiteSet)

let dummy_constructor_annot = "__infer_is_constructor"

let annotation_of_str annot_str =
  { Annot.class_name = annot_str; parameters = []; }

let src_snk_pairs () =
  (* parse user-defined specs from .inferconfig *)
  let parse_user_defined_specs = function
    | `List user_specs ->
        let parse_user_spec json =
          let open Yojson.Basic in
          let sources = Util.member "sources" json |> Util.to_list |> List.map ~f:Util.to_string in
          let sinks = Util.member "sink" json |> Util.to_string in
          sources, sinks in
        List.map ~f:parse_user_spec user_specs
    | _ ->
        [] in
  let specs =
    ([Annotations.performance_critical], Annotations.expensive) ::
    ([Annotations.no_allocation], dummy_constructor_annot) ::
    ([Annotations.any_thread; Annotations.for_non_ui_thread], Annotations.ui_thread) ::
    ([Annotations.ui_thread; Annotations.for_ui_thread], Annotations.for_non_ui_thread) ::
    (parse_user_defined_specs Config.annotation_reachability) in
  List.map
    ~f:(fun (src_annot_str_list, snk_annot_str) ->
        List.map ~f:annotation_of_str src_annot_str_list, annotation_of_str snk_annot_str)
    specs

module Domain = struct
  module TrackingVar = AbstractDomain.FiniteSet (Var.Set)
  module TrackingDomain = AbstractDomain.Pair (CallsDomain) (TrackingVar)
  include TrackingDomain

  let add_call key call ((call_map, vars) as astate) =
    let call_set =
      try CallsDomain.find key call_map
      with Not_found -> CallSiteSet.empty in
    let call_set' = CallSiteSet.add call call_set in
    if phys_equal call_set' call_set
    then astate
    else (CallsDomain.add key call_set' call_map, vars)

  let stop_tracking (_ : astate) =
    (* The empty call map here prevents any subsequent calls to be added *)
    (CallsDomain.empty, TrackingVar.empty)

  let add_tracking_var var (calls, previous_vars) =
    (calls, TrackingVar.add var previous_vars)

  let remove_tracking_var var (calls, previous_vars) =
    (calls, TrackingVar.remove var previous_vars)

  let is_tracked_var var (_, vars) =
    TrackingVar.mem var vars
end

module Summary = Summary.Make (struct
    type payload = CallsDomain.astate

    let update_payload call_map (summary : Specs.summary) =
      { summary with payload = { summary.payload with calls = Some call_map }}

    let read_payload (summary : Specs.summary) =
      summary.payload.calls
  end)

(* Warning name when a performance critical method directly or indirectly
   calls a method annotatd as expensive *)
let calls_expensive_method =
  "CHECKERS_CALLS_EXPENSIVE_METHOD"

(* Warning name when a performance critical method directly or indirectly
   calls a method allocating memory *)
let allocates_memory =
  "CHECKERS_ALLOCATES_MEMORY"

(* Warning name for the subtyping rule: method not annotated as expensive cannot be overridden
   by a method annotated as expensive *)
let expensive_overrides_unexpensive =
  "CHECKERS_EXPENSIVE_OVERRIDES_UNANNOTATED"

let annotation_reachability_error = "CHECKERS_ANNOTATION_REACHABILITY_ERROR"

let is_modeled_expensive tenv = function
  | Typ.Procname.Java proc_name_java as proc_name ->
      not (BuiltinDecl.is_declared proc_name) &&
      let is_subclass =
        let classname = Typ.Name.Java.from_string (Typ.Procname.java_get_class_name proc_name_java) in
        PatternMatch.is_subtype_of_str tenv classname in
      Inferconfig.modeled_expensive_matcher is_subclass proc_name
  | _ ->
      false

let is_allocator tenv pname =
  match pname with
  | Typ.Procname.Java pname_java ->
      let is_throwable () =
        let class_name =
          Typ.Name.Java.from_string (Typ.Procname.java_get_class_name pname_java) in
        PatternMatch.is_throwable tenv class_name in
      Typ.Procname.is_constructor pname
      && not (BuiltinDecl.is_declared pname)
      && not (is_throwable ())
  | _ ->
      false

let check_attributes check tenv pname =
  PatternMatch.check_class_attributes check tenv pname ||
  Annotations.pname_has_return_annot pname ~attrs_of_pname:Specs.proc_resolve_attributes check

let method_overrides is_annotated tenv pname =
  PatternMatch.override_exists (fun pn -> is_annotated tenv pn) tenv pname

let method_has_annot annot tenv pname =
  let has_annot ia = Annotations.ia_ends_with ia annot.Annot.class_name in
  if Annotations.annot_ends_with annot dummy_constructor_annot
  then is_allocator tenv pname
  else if Annotations.annot_ends_with annot Annotations.expensive
  then check_attributes has_annot tenv pname || is_modeled_expensive tenv pname
  else check_attributes has_annot tenv pname

let method_overrides_annot annot tenv pname =
  method_overrides (method_has_annot annot) tenv pname

let lookup_annotation_calls caller_pdesc annot pname : CallSite.t list =
  match Ondemand.analyze_proc_name ~propagate_exceptions:false caller_pdesc pname with
  | Some { Specs.payload = { Specs.calls = Some call_map; }; } ->
      begin
        try
          Annot.Map.find annot call_map
          |> CallSiteSet.elements
        with Not_found ->
          []
      end
  | _ -> []

let update_trace loc trace =
  if Location.equal loc Location.dummy then trace
  else
    Errlog.make_trace_element 0 loc "" [] :: trace

let string_of_pname =
  Typ.Procname.to_simplified_string ~withclass:true

let report_allocation_stack
    src_annot summary fst_call_loc trace stack_str constructor_pname call_loc =
  let pname = Specs.get_proc_name summary in
  let final_trace = List.rev (update_trace call_loc trace) in
  let constr_str = string_of_pname constructor_pname in
  let description =
    Format.asprintf
      "Method %a annotated with %a allocates %a via %a"
      MF.pp_monospaced (Typ.Procname.to_simplified_string pname)
      MF.pp_monospaced ("@" ^ src_annot)
      MF.pp_monospaced constr_str
      MF.pp_monospaced (stack_str ^ ("new "^constr_str)) in
  let exn =
    Exceptions.Checkers (allocates_memory, Localise.verbatim_desc description) in
  Reporting.log_error_from_summary summary ~loc:fst_call_loc ~ltr:final_trace exn

let report_annotation_stack src_annot snk_annot src_summary loc trace stack_str snk_pname call_loc =
  let src_pname = Specs.get_proc_name src_summary in
  if String.equal snk_annot dummy_constructor_annot
  then report_allocation_stack src_annot src_summary loc trace stack_str snk_pname call_loc
  else
    let final_trace = List.rev (update_trace call_loc trace) in
    let exp_pname_str = string_of_pname snk_pname in
    let description =
      Format.asprintf
        "Method %a annotated with %a calls %a where %a is annotated with %a"
        MF.pp_monospaced (Typ.Procname.to_simplified_string src_pname)
        MF.pp_monospaced ("@" ^ src_annot)
        MF.pp_monospaced (stack_str ^ exp_pname_str)
        MF.pp_monospaced exp_pname_str
        MF.pp_monospaced ("@" ^ snk_annot) in
    let msg =
      if String.equal src_annot Annotations.performance_critical
      then calls_expensive_method
      else annotation_reachability_error in
    let exn =
      Exceptions.Checkers (msg, Localise.verbatim_desc description) in
    Reporting.log_error_from_summary src_summary ~loc ~ltr:final_trace exn

let report_call_stack summary end_of_stack lookup_next_calls report call_site calls =
  (* TODO: stop using this; we can use the call site instead *)
  let lookup_location pname =
    match Specs.get_summary pname with
    | None -> Location.dummy
    | Some summary -> summary.Specs.attributes.ProcAttributes.loc in
  let rec loop fst_call_loc visited_pnames (trace, stack_str) (callee_pname, call_loc) =
    if end_of_stack callee_pname then
      report summary fst_call_loc trace stack_str callee_pname call_loc
    else
      let callee_def_loc = lookup_location callee_pname in
      let next_calls = lookup_next_calls callee_pname in
      let callee_pname_str = string_of_pname callee_pname in
      let new_stack_str = stack_str ^ callee_pname_str ^ " -> " in
      let new_trace = update_trace call_loc trace |> update_trace callee_def_loc in
      let unseen_pnames, updated_visited =
        List.fold
          ~f:(fun (accu, set) call_site ->
              let p = CallSite.pname call_site in
              let loc = CallSite.loc call_site in
              if Typ.Procname.Set.mem p set then (accu, set)
              else ((p, loc) :: accu, Typ.Procname.Set.add p set))
          ~init:([], visited_pnames)
          next_calls in
      List.iter ~f:(loop fst_call_loc updated_visited (new_trace, new_stack_str)) unseen_pnames in
  List.iter
    ~f:(fun fst_call_site ->
        let fst_callee_pname = CallSite.pname fst_call_site in
        let fst_call_loc = CallSite.loc fst_call_site in
        let start_trace = update_trace (CallSite.loc call_site) [] in
        loop fst_call_loc Typ.Procname.Set.empty (start_trace, "") (fst_callee_pname, fst_call_loc))
    calls

module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = Domain
  type extras = ProcData.no_extras

  (* This is specific to the @NoAllocation and @PerformanceCritical checker
     and the "unlikely" method is used to guard branches that are expected to run sufficiently
     rarely to not affect the performances *)
  let is_unlikely pname =
    match pname with
    | Typ.Procname.Java java_pname ->
        String.equal (Typ.Procname.java_get_method java_pname) "unlikely"
    | _ -> false

  let is_tracking_exp astate = function
    | Exp.Var id -> Domain.is_tracked_var (Var.of_id id) astate
    | Exp.Lvar pvar -> Domain.is_tracked_var (Var.of_pvar pvar) astate
    | _ -> false

  let prunes_tracking_var astate = function
    | Exp.BinOp (Binop.Eq, lhs, rhs)
      when is_tracking_exp astate lhs ->
        Exp.equal rhs Exp.one
    | Exp.UnOp (Unop.LNot, Exp.BinOp (Binop.Eq, lhs, rhs), _)
      when is_tracking_exp astate lhs ->
        Exp.equal rhs Exp.zero
    | _ ->
        false

  let method_has_ignore_allocation_annot tenv pname =
    check_attributes Annotations.ia_is_ignore_allocations tenv pname

  (* TODO: generalize this to allow sanitizers for other annotation types, store it in [extras] so
     we can compute it just once *)
  let method_is_sanitizer annot tenv pname =
    if String.equal annot.Annot.class_name dummy_constructor_annot
    then method_has_ignore_allocation_annot tenv pname
    else false

  let merge_call_map
      callee_call_map tenv callee_pname caller_pname call_site ((call_map, _) as astate) =
    let add_call_for_annot annot _ astate =
      let calls =
        try Annot.Map.find annot callee_call_map
        with Not_found -> CallSiteSet.empty in
      if (not (CallSiteSet.is_empty calls) || method_has_annot annot tenv callee_pname) &&
         (not (method_is_sanitizer annot tenv caller_pname))
      then
        Domain.add_call annot call_site astate
      else
        astate in
    (* for each annotation type T in domain(astate), check if method calls
       something annotated with T *)
    Annot.Map.fold add_call_for_annot call_map astate

  let exec_instr astate { ProcData.pdesc; tenv; } _ = function
    | Sil.Call (Some (id, _), Const (Cfun callee_pname), _, _, _)
      when is_unlikely callee_pname ->
        Domain.add_tracking_var (Var.of_id id) astate
    | Sil.Call (_, Const (Cfun callee_pname), _, call_loc, _) ->
        let caller_pname = Procdesc.get_proc_name pdesc in
        let call_site = CallSite.make callee_pname call_loc in
        begin
          (* Runs the analysis of callee_pname if not already analyzed *)
          match Summary.read_summary pdesc callee_pname with
          | Some call_map ->
              merge_call_map call_map tenv callee_pname caller_pname call_site astate
          | None ->
              merge_call_map Annot.Map.empty tenv callee_pname caller_pname call_site astate
        end
    | Sil.Load (id, exp, _, _)
      when is_tracking_exp astate exp ->
        Domain.add_tracking_var (Var.of_id id) astate
    | Sil.Store (Exp.Lvar pvar, _, exp, _)
      when is_tracking_exp astate exp ->
        Domain.add_tracking_var (Var.of_pvar pvar) astate
    | Sil.Store (Exp.Lvar pvar, _, _, _) ->
        Domain.remove_tracking_var (Var.of_pvar pvar) astate
    | Sil.Prune (exp, _, _, _)
      when prunes_tracking_var astate exp ->
        Domain.stop_tracking astate
    | Sil.Call (None, _, _, _, _) ->
        failwith "Expecting a return identifier"
    | _ ->
        astate
end

module Analyzer = AbstractInterpreter.Make (ProcCfg.Exceptional) (TransferFunctions)

module Interprocedural = struct
  include AbstractInterpreter.Interprocedural(Summary)

  let is_expensive tenv pname =
    check_attributes Annotations.ia_is_expensive tenv pname

  let method_is_expensive tenv pname =
    is_modeled_expensive tenv pname || is_expensive tenv pname

  let check_and_report ({ Callbacks.proc_desc; tenv; summary } as proc_data) : Specs.summary =
    let proc_name = Procdesc.get_proc_name proc_desc in
    let loc = Procdesc.get_loc proc_desc in
    let expensive = is_expensive tenv proc_name in
    (* TODO: generalize so we can check subtyping on arbitrary annotations *)
    let check_expensive_subtyping_rules overridden_pname =
      if not (method_is_expensive tenv overridden_pname) then
        let description =
          Format.asprintf
            "Method %a overrides unannotated method %a and cannot be annotated with %a"
            MF.pp_monospaced (Typ.Procname.to_string proc_name)
            MF.pp_monospaced (Typ.Procname.to_string overridden_pname)
            MF.pp_monospaced ("@" ^ Annotations.expensive) in
        let exn =
          Exceptions.Checkers
            (expensive_overrides_unexpensive, Localise.verbatim_desc description) in
        Reporting.log_error_from_summary summary ~loc exn in

    if expensive then
      PatternMatch.override_iter check_expensive_subtyping_rules tenv proc_name;

    let report_src_snk_paths call_map (src_annot_list, (snk_annot: Annot.t)) =
      let extract_calls_with_annot annot call_map =
        try
          Annot.Map.find annot call_map
          |> CallSiteSet.elements
        with Not_found -> [] in
      let report_src_snk_path (calls : CallSite.t list) (src_annot: Annot.t) =
        if method_overrides_annot src_annot tenv proc_name
        then
          let f_report =
            report_annotation_stack src_annot.class_name snk_annot.class_name in
          report_call_stack
            summary
            (method_has_annot snk_annot tenv)
            (lookup_annotation_calls proc_desc snk_annot)
            f_report
            (CallSite.make proc_name loc)
            calls in
      let calls = extract_calls_with_annot snk_annot call_map in
      if not (Int.equal (List.length calls) 0)
      then List.iter ~f:(report_src_snk_path calls) src_annot_list in

    let initial =
      let init_map =
        List.fold
          ~f:(fun astate_acc (_, snk_annot) ->
              CallsDomain.add snk_annot CallSiteSet.empty astate_acc)
          ~init:CallsDomain.empty
          (src_snk_pairs ()) in
      (init_map, Domain.TrackingVar.empty) in
    let compute_post proc_data =
      Option.map ~f:fst (Analyzer.compute_post ~initial proc_data) in
    let updated_summary : Specs.summary =
      compute_and_store_post
        ~compute_post:compute_post
        ~make_extras:ProcData.make_empty_extras
        proc_data in
    begin
      match updated_summary.payload.calls with
      | Some call_map ->
          List.iter ~f:(report_src_snk_paths call_map) (src_snk_pairs ())
      | None ->
          ()
    end;
    updated_summary

end

let checker = Interprocedural.check_and_report
