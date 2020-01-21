(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module L = Logging
module BasicCost = CostDomain.BasicCost

(* CFG modules used in several other modules  *)
module InstrCFG = ProcCfg.NormalOneInstrPerNode
module NodeCFG = ProcCfg.Normal
module Node = ProcCfg.DefaultNode

let attrs_of_pname = Summary.OnDisk.proc_resolve_attributes

module Payload = SummaryPayload.Make (struct
  type t = CostDomain.summary

  let field = Payloads.Fields.cost
end)

type callee_summary_and_formals = CostDomain.summary * (Pvar.t * Typ.t) list

type extras_WorstCaseCost =
  { inferbo_invariant_map: BufferOverrunAnalysis.invariant_map
  ; integer_type_widths: Typ.IntegerWidths.t
  ; get_node_nb_exec: Node.id -> BasicCost.t
  ; get_callee_summary_and_formals: Procname.t -> callee_summary_and_formals option }

let instantiate_cost integer_type_widths ~inferbo_caller_mem ~callee_pname ~callee_formals ~params
    ~callee_cost ~loc =
  let eval_sym =
    BufferOverrunSemantics.mk_eval_sym_cost integer_type_widths callee_formals params
      inferbo_caller_mem
  in
  BasicCost.subst callee_pname loc callee_cost eval_sym


module InstrBasicCost = struct
  (*
    Compute the cost for an instruction.
    For example for basic operation we set it to 1 and for function call we take it from the spec of the function.
  *)

  let allocation_functions =
    [ BuiltinDecl.__new
    ; BuiltinDecl.__new_array
    ; BuiltinDecl.__objc_alloc_no_fail
    ; BuiltinDecl.malloc
    ; BuiltinDecl.malloc_no_fail ]


  let is_allocation_function callee_pname =
    List.exists allocation_functions ~f:(fun f -> Procname.equal callee_pname f)


  let get_instr_cost_record tenv extras instr_node instr =
    match instr with
    | Sil.Call (ret, Exp.Const (Const.Cfun callee_pname), params, _, _) ->
        let {inferbo_invariant_map; integer_type_widths; get_callee_summary_and_formals} = extras in
        let operation_cost =
          match
            BufferOverrunAnalysis.extract_pre (InstrCFG.Node.id instr_node) inferbo_invariant_map
          with
          | None ->
              CostDomain.unit_cost_atomic_operation
          | Some inferbo_mem -> (
              let loc = InstrCFG.Node.loc instr_node in
              let fun_arg_list =
                List.map params ~f:(fun (exp, typ) ->
                    ProcnameDispatcher.Call.FuncArg.{exp; typ; arg_payload= ()} )
              in
              match CostModels.Call.dispatch tenv callee_pname fun_arg_list with
              | Some model ->
                  let node_hash = InstrCFG.Node.hash instr_node in
                  let model_env =
                    BufferOverrunUtils.ModelEnv.mk_model_env callee_pname ~node_hash loc tenv
                      integer_type_widths
                  in
                  CostDomain.of_operation_cost (model model_env ~ret inferbo_mem)
              | None -> (
                match get_callee_summary_and_formals callee_pname with
                | Some ({CostDomain.post= callee_cost_record}, callee_formals) ->
                    CostDomain.map callee_cost_record ~f:(fun callee_cost ->
                        instantiate_cost integer_type_widths ~inferbo_caller_mem:inferbo_mem
                          ~callee_pname ~callee_formals ~params ~callee_cost ~loc )
                | None ->
                    CostDomain.unit_cost_atomic_operation ) )
        in
        if is_allocation_function callee_pname then
          CostDomain.plus CostDomain.unit_cost_allocation operation_cost
        else operation_cost
    | Sil.Load {id= lhs_id} when Ident.is_none lhs_id ->
        (* dummy deref inserted by frontend--don't count as a step. In
           JDK 11, dummy deref disappears and causes cost differences
           otherwise. *)
        CostDomain.zero_record
    | Sil.Load _ | Sil.Store _ | Sil.Call _ | Sil.Prune _ ->
        CostDomain.unit_cost_atomic_operation
    | Sil.Metadata Skip -> (
      match InstrCFG.Node.kind instr_node with
      | Procdesc.Node.Start_node ->
          CostDomain.unit_cost_atomic_operation
      | _ ->
          CostDomain.zero_record )
    | Sil.Metadata (Abstract _ | ExitScope _ | Nullify _ | VariableLifetimeBegins _) ->
        CostDomain.zero_record


  let get_instr_node_cost_record tenv extras instr_node =
    let instrs = InstrCFG.instrs instr_node in
    let instr =
      match IContainer.singleton_or_more instrs ~fold:Instrs.fold with
      | Empty ->
          Sil.skip_instr
      | Singleton instr ->
          instr
      | More ->
          assert false
    in
    let cost = get_instr_cost_record tenv extras instr_node instr in
    if BasicCost.is_top (CostDomain.get_operation_cost cost) then
      Logging.d_printfln_escaped "Statement cost became top at %a (%a)." InstrCFG.Node.pp_id
        (InstrCFG.Node.id instr_node)
        (Sil.pp_instr ~print_types:false Pp.text)
        instr ;
    cost
end

let compute_errlog_extras cost =
  { Jsonbug_t.cost_polynomial= Some (Format.asprintf "%a" BasicCost.pp_hum cost)
  ; cost_degree= BasicCost.degree cost |> Option.map ~f:Polynomials.Degree.encode_to_int }


module ThresholdReports = struct
  type threshold_or_report =
    | Threshold of BasicCost.t
    | ReportOn of {location: Location.t; cost: BasicCost.t}

  type t = threshold_or_report CostIssues.CostKindMap.t

  let none : t = CostIssues.CostKindMap.empty

  let config =
    CostIssues.CostKindMap.fold
      (fun kind kind_spec acc ->
        match kind_spec with
        | CostIssues.{threshold= Some threshold} ->
            CostIssues.CostKindMap.add kind (Threshold (BasicCost.of_int_exn threshold)) acc
        | _ ->
            acc )
      CostIssues.enabled_cost_map none
end

(** Calculate the final Worst Case Cost predicted for each cost field and each WTO component. It is
    the dot product of the symbolic cost of the node and how many times it is executed. *)
module WorstCaseCost = struct
  type astate = {costs: CostDomain.t; reports: ThresholdReports.t}

  (** We don't report when the cost is Top as it corresponds to subsequent 'don't know's. Instead,
      we report Top cost only at the top level per function. *)
  let should_report_cost cost ~threshold =
    (not (BasicCost.is_top cost)) && not (BasicCost.leq ~lhs:cost ~rhs:threshold)


  let exec_node tenv {costs; reports} extras instr_node =
    let {get_node_nb_exec} = extras in
    let node_cost =
      let instr_cost_record = InstrBasicCost.get_instr_node_cost_record tenv extras instr_node in
      let node_id = InstrCFG.Node.underlying_node instr_node |> Node.id in
      let nb_exec = get_node_nb_exec node_id in
      if BasicCost.is_top nb_exec then
        Logging.d_printfln_escaped "Node %a is analyzed to visit infinite (top) times." Node.pp_id
          node_id ;
      CostDomain.mult_by_scalar instr_cost_record nb_exec
    in
    let costs = CostDomain.plus costs node_cost in
    let reports =
      CostIssues.CostKindMap.merge
        (fun _kind threshold_or_report_opt cost_opt ->
          match (threshold_or_report_opt, cost_opt) with
          | None, _ ->
              None
          | Some (ThresholdReports.Threshold threshold), Some cost
            when should_report_cost cost ~threshold ->
              Some (ThresholdReports.ReportOn {location= InstrCFG.Node.loc instr_node; cost})
          | _ ->
              threshold_or_report_opt )
        reports costs
    in
    {costs; reports}


  let rec exec_partition tenv astate extras
      (partition : InstrCFG.Node.t WeakTopologicalOrder.Partition.t) =
    match partition with
    | Empty ->
        astate
    | Node {node; next} ->
        let astate = exec_node tenv astate extras node in
        exec_partition tenv astate extras next
    | Component {head; rest; next} ->
        let {costs; reports} = astate in
        let {costs} = exec_partition tenv {costs; reports= ThresholdReports.none} extras rest in
        (* Execute head after the loop body to always report at loop head *)
        let astate = exec_node tenv {costs; reports} extras head in
        exec_partition tenv astate extras next


  let compute tenv extras instr_cfg_wto =
    let initial = {costs= CostDomain.zero_record; reports= ThresholdReports.config} in
    exec_partition tenv initial extras instr_cfg_wto
end

module Check = struct
  let report_threshold proc_desc summary ~name ~location ~cost CostIssues.{expensive_issue}
      ~threshold ~is_on_ui_thread =
    let pname = Procdesc.get_proc_name proc_desc in
    let report_issue_type =
      L.(debug Analysis Medium) "@\n\n++++++ Checking error type for %a **** @\n" Procname.pp pname ;
      let is_on_cold_start =
        ExternalPerfData.in_profiler_data_map (Procdesc.get_proc_name proc_desc)
      in
      expensive_issue ~is_on_cold_start ~is_on_ui_thread
    in
    let bigO_str =
      Format.asprintf ", %a"
        (BasicCost.pp_degree ~only_bigO:true)
        (BasicCost.get_degree_with_term cost)
    in
    let degree_str = BasicCost.degree_str cost in
    let message =
      F.asprintf
        "%s from the beginning of the function up to this program point is likely above the \
         acceptable threshold of %d (estimated cost %a%s)"
        name threshold BasicCost.pp_hum cost degree_str
    in
    let cost_trace_elem =
      let cost_desc =
        F.asprintf "with estimated cost %a%s%s" BasicCost.pp_hum cost bigO_str degree_str
      in
      Errlog.make_trace_element 0 location cost_desc []
    in
    Reporting.log_error summary ~loc:location
      ~ltr:(cost_trace_elem :: BasicCost.polynomial_traces cost)
      ~extras:(compute_errlog_extras cost) report_issue_type message


  let report_top_and_bottom proc_desc summary ~name ~cost CostIssues.{zero_issue; infinite_issue} =
    let report issue suffix =
      let message =
        F.asprintf "%s of the function %a %s" name Procname.pp
          (Procdesc.get_proc_name proc_desc)
          suffix
      in
      let loc = Procdesc.get_start_node proc_desc |> Procdesc.Node.get_loc in
      Reporting.log_error ~loc
        ~ltr:(BasicCost.polynomial_traces cost)
        ~extras:(compute_errlog_extras cost) summary issue message
    in
    if BasicCost.is_top cost then report infinite_issue "cannot be computed"
    else if BasicCost.is_zero cost then report zero_issue "is zero"


  let check_and_report ~is_on_ui_thread WorstCaseCost.{costs; reports} proc_desc summary =
    let pname = Procdesc.get_proc_name proc_desc in
    if not (Procname.is_java_access_method pname) then (
      CostIssues.CostKindMap.iter2 CostIssues.enabled_cost_map reports
        ~f:(fun _kind (CostIssues.{name; threshold} as kind_spec) -> function
        | ThresholdReports.Threshold _ ->
            ()
        | ThresholdReports.ReportOn {location; cost} ->
            report_threshold proc_desc summary ~name ~location ~cost kind_spec
              ~threshold:(Option.value_exn threshold) ~is_on_ui_thread ) ;
      CostIssues.CostKindMap.iter2 CostIssues.enabled_cost_map costs
        ~f:(fun _kind (CostIssues.{name; top_and_bottom} as issue_spec) cost ->
          if top_and_bottom then report_top_and_bottom proc_desc summary ~name ~cost issue_spec ) )
end

type bound_map = BasicCost.t Node.IdMap.t

type get_node_nb_exec = Node.id -> BasicCost.t

let compute_bound_map node_cfg inferbo_invariant_map control_dep_invariant_map loop_invmap :
    bound_map =
  BoundMap.compute_upperbound_map node_cfg inferbo_invariant_map control_dep_invariant_map
    loop_invmap


let compute_get_node_nb_exec node_cfg bound_map : get_node_nb_exec =
  let debug =
    if Config.write_html then
      let f fmt = L.d_printfln fmt in
      {ConstraintSolver.f}
    else
      let f fmt = L.(debug Analysis Verbose) fmt in
      {ConstraintSolver.f}
  in
  let start_node = NodeCFG.start_node node_cfg in
  NodePrinter.with_session start_node
    ~pp_name:(fun fmt -> F.pp_print_string fmt "cost(constraints)")
    ~f:(fun () -> ConstraintSolver.get_node_nb_exec ~debug node_cfg bound_map)


let compute_worst_case_cost tenv integer_type_widths get_callee_summary_and_formals instr_cfg_wto
    inferbo_invariant_map get_node_nb_exec =
  let extras =
    {inferbo_invariant_map; integer_type_widths; get_node_nb_exec; get_callee_summary_and_formals}
  in
  WorstCaseCost.compute tenv extras instr_cfg_wto


let get_cost_summary ~is_on_ui_thread astate =
  CostDomain.{post= astate.WorstCaseCost.costs; is_on_ui_thread}


let report_errors ~is_on_ui_thread proc_desc astate summary =
  Check.check_and_report ~is_on_ui_thread astate proc_desc summary


let checker {Callbacks.exe_env; summary} : Summary.t =
  let proc_name = Summary.get_proc_name summary in
  let tenv = Exe_env.get_tenv exe_env proc_name in
  let integer_type_widths = Exe_env.get_integer_type_widths exe_env proc_name in
  let proc_desc = Summary.get_proc_desc summary in
  let inferbo_invariant_map =
    BufferOverrunAnalysis.cached_compute_invariant_map summary tenv integer_type_widths
  in
  let node_cfg = NodeCFG.from_pdesc proc_desc in
  (* computes reaching defs: node -> (var -> node set) *)
  let reaching_defs_invariant_map = ReachingDefs.compute_invariant_map summary tenv in
  (* collect all prune nodes that occur in loop guards, needed for ControlDepAnalyzer *)
  let control_maps, loop_head_to_loop_nodes = Loop_control.get_loop_control_maps node_cfg in
  (* computes the control dependencies: node -> var set *)
  let control_dep_invariant_map = Control.compute_invariant_map summary tenv control_maps in
  (* compute loop invariant map for control var analysis *)
  let loop_inv_map =
    let get_callee_purity callee_pname =
      match Ondemand.analyze_proc_name ~caller_summary:summary callee_pname with
      | Some {Summary.payloads= {Payloads.purity}} ->
          purity
      | _ ->
          None
    in
    LoopInvariant.get_loop_inv_var_map tenv get_callee_purity reaching_defs_invariant_map
      loop_head_to_loop_nodes
  in
  (* given the semantics computes the upper bound on the number of times a node could be executed *)
  let bound_map =
    compute_bound_map node_cfg inferbo_invariant_map control_dep_invariant_map loop_inv_map
  in
  let is_on_ui_thread = ConcurrencyModels.runs_on_ui_thread ~attrs_of_pname tenv proc_name in
  let get_node_nb_exec = compute_get_node_nb_exec node_cfg bound_map in
  let astate =
    let get_callee_summary_and_formals callee_pname =
      Payload.read_full ~caller_summary:summary ~callee_pname
      |> Option.map ~f:(fun (callee_pdesc, callee_summary) ->
             (callee_summary, Procdesc.get_pvar_formals callee_pdesc) )
    in
    let instr_cfg = InstrCFG.from_pdesc proc_desc in
    let instr_cfg_wto = InstrCFG.wto instr_cfg in
    compute_worst_case_cost tenv integer_type_widths get_callee_summary_and_formals instr_cfg_wto
      inferbo_invariant_map get_node_nb_exec
  in
  let () =
    let exit_cost_record = astate.WorstCaseCost.costs in
    L.(debug Analysis Verbose)
      "@\n[COST ANALYSIS] PROCEDURE '%a' |CFG| = %i FINAL COST = %a @\n" Procname.pp proc_name
      (Container.length ~fold:NodeCFG.fold_nodes node_cfg)
      CostDomain.VariantCostMap.pp exit_cost_record
  in
  report_errors ~is_on_ui_thread proc_desc astate summary ;
  Payload.update_summary (get_cost_summary ~is_on_ui_thread astate) summary
