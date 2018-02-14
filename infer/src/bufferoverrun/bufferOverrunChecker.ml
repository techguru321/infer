(*
 * Copyright (c) 2016 - present
 *
 * Programming Research Laboratory (ROPAS)
 * Seoul National University, Korea
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
open AbsLoc
open! AbstractDomain.Types
module L = Logging
module Dom = BufferOverrunDomain
module PO = BufferOverrunProofObligations
module Trace = BufferOverrunTrace
module TraceSet = Trace.Set

module Summary = Summary.Make (struct
  type payload = Dom.Summary.t

  let update_payload astate (summary: Specs.summary) =
    {summary with payload= {summary.payload with buffer_overrun= Some astate}}


  let read_payload (summary: Specs.summary) = summary.payload.buffer_overrun
end)

module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = Dom.Mem
  module BoUtils = BufferOverrunUtils.Make (CFG)
  module Sem = BoUtils.Sem
  module Models = BufferOverrunModels.Make (BoUtils)

  type extras = Typ.Procname.t -> Procdesc.t option

  let declare_symbolic_val
      : Typ.Procname.t -> Tenv.t -> CFG.node -> Location.t -> Loc.t -> Typ.typ -> inst_num:int
        -> new_sym_num:(unit -> int) -> Domain.t -> Domain.t =
    fun pname tenv node location loc typ ~inst_num ~new_sym_num mem ->
      let max_depth = 2 in
      let new_alloc_num = BoUtils.counter_gen 1 in
      let rec decl_sym_val pname tenv node location ~depth loc typ mem =
        if depth > max_depth then mem
        else
          let depth = depth + 1 in
          match typ.Typ.desc with
          | Typ.Tint ikind ->
              let unsigned = Typ.ikind_is_unsigned ikind in
              let v =
                Dom.Val.make_sym ~unsigned pname new_sym_num
                |> Dom.Val.add_trace_elem (Trace.SymAssign location)
              in
              Dom.Mem.add_heap loc v mem
          | Typ.Tfloat _ ->
              let v =
                Dom.Val.make_sym pname new_sym_num
                |> Dom.Val.add_trace_elem (Trace.SymAssign location)
              in
              Dom.Mem.add_heap loc v mem
          | Typ.Tptr (typ, _) ->
              BoUtils.Exec.decl_sym_arr ~decl_sym_val pname tenv node location ~depth loc typ
                ~inst_num ~new_sym_num ~new_alloc_num mem
          | Typ.Tarray (typ, opt_int_lit, _) ->
              let size = Option.map ~f:Itv.of_int_lit opt_int_lit in
              let offset = Itv.zero in
              BoUtils.Exec.decl_sym_arr ~decl_sym_val pname tenv node location ~depth loc typ
                ~offset ?size ~inst_num ~new_sym_num ~new_alloc_num mem
          | Typ.Tstruct typename -> (
            match Models.TypName.dispatch typename with
            | Some {Models.declare_symbolic} ->
                declare_symbolic ~decl_sym_val pname tenv node location ~depth loc ~inst_num
                  ~new_sym_num ~new_alloc_num mem
            | None ->
                let decl_fld mem (fn, typ, _) =
                  let loc_fld = Loc.append_field loc ~fn in
                  decl_sym_val pname tenv node location ~depth loc_fld typ mem
                in
                let decl_flds str = List.fold ~f:decl_fld ~init:mem str.Typ.Struct.fields in
                let opt_struct = Tenv.lookup tenv typename in
                Option.value_map opt_struct ~default:mem ~f:decl_flds )
          | _ ->
              if Config.bo_debug >= 3 then
                L.(debug BufferOverrun Verbose)
                  "/!\\ decl_fld of unhandled type: %a at %a@." (Typ.pp Pp.text) typ Location.pp
                  (CFG.loc node) ;
              mem
      in
      decl_sym_val pname tenv node location ~depth:0 loc typ mem


  let declare_symbolic_parameters
      : Typ.Procname.t -> Tenv.t -> CFG.node -> Location.t -> inst_num:int -> (Pvar.t * Typ.t) list
        -> Dom.Mem.astate -> Dom.Mem.astate =
    fun pname tenv node location ~inst_num formals mem ->
      let new_sym_num = BoUtils.counter_gen 0 in
      let add_formal (mem, inst_num) (pvar, typ) =
        let loc = Loc.of_pvar pvar in
        let mem =
          declare_symbolic_val pname tenv node location loc typ ~inst_num ~new_sym_num mem
        in
        (mem, inst_num + 1)
      in
      List.fold ~f:add_formal ~init:(mem, inst_num) formals |> fst


  let instantiate_ret ret callee_pname callee_exit_mem subst_map mem ret_alias location =
    match ret with
    | Some (id, _) ->
        let ret_loc = Loc.of_pvar (Pvar.get_ret_pvar callee_pname) in
        let ret_val = Dom.Mem.find_heap ret_loc callee_exit_mem in
        let ret_var = Loc.of_var (Var.of_id id) in
        let add_ret_alias l = Dom.Mem.load_alias id l mem in
        let mem = Option.value_map ret_alias ~default:mem ~f:add_ret_alias in
        Dom.Val.subst ret_val subst_map location |> Dom.Val.add_trace_elem (Trace.Return location)
        |> Fn.flip (Dom.Mem.add_stack ret_var) mem
    | None ->
        mem


  let instantiate_param tenv pdesc params callee_entry_mem callee_exit_mem subst_map location mem =
    let formals = Sem.get_formals pdesc in
    let actuals = List.map ~f:(fun (a, _) -> Sem.eval a mem) params in
    let f mem formal actual =
      match (snd formal).Typ.desc with
      | Typ.Tptr (typ, _) -> (
        match typ.Typ.desc with
        | Typ.Tstruct typename -> (
          match Tenv.lookup tenv typename with
          | Some str ->
              let formal_locs =
                Dom.Mem.find_heap (Loc.of_pvar (fst formal)) callee_entry_mem
                |> Dom.Val.get_array_blk |> ArrayBlk.get_pow_loc
              in
              let instantiate_fld mem (fn, _, _) =
                let formal_fields = PowLoc.append_field formal_locs ~fn in
                let v = Dom.Mem.find_heap_set formal_fields callee_exit_mem in
                let actual_fields = PowLoc.append_field (Dom.Val.get_all_locs actual) ~fn in
                Dom.Val.subst v subst_map location
                |> Fn.flip (Dom.Mem.strong_update_heap actual_fields) mem
              in
              List.fold ~f:instantiate_fld ~init:mem str.Typ.Struct.fields
          | _ ->
              mem )
        | _ ->
            let formal_locs =
              Dom.Mem.find_heap (Loc.of_pvar (fst formal)) callee_entry_mem
              |> Dom.Val.get_array_blk |> ArrayBlk.get_pow_loc
            in
            let v = Dom.Mem.find_heap_set formal_locs callee_exit_mem in
            let actual_locs = Dom.Val.get_all_locs actual in
            Dom.Val.subst v subst_map location
            |> Fn.flip (Dom.Mem.strong_update_heap actual_locs) mem )
      | _ ->
          mem
    in
    try List.fold2_exn formals actuals ~init:mem ~f with Invalid_argument _ -> mem


  let instantiate_mem
      : Tenv.t -> (Ident.t * Typ.t) option -> Procdesc.t option -> Typ.Procname.t
        -> (Exp.t * Typ.t) list -> Dom.Mem.astate -> Dom.Summary.t -> Location.t -> Dom.Mem.astate =
    fun tenv ret callee_pdesc callee_pname params caller_mem summary location ->
      let callee_entry_mem = Dom.Summary.get_input summary in
      let callee_exit_mem = Dom.Summary.get_output summary in
      let callee_ret_alias = Dom.Mem.find_ret_alias callee_exit_mem in
      match callee_pdesc with
      | Some pdesc ->
          let subst_map, ret_alias =
            Sem.get_subst_map tenv pdesc params caller_mem callee_entry_mem ~callee_ret_alias
          in
          instantiate_ret ret callee_pname callee_exit_mem subst_map caller_mem ret_alias location
          |> instantiate_param tenv pdesc params callee_entry_mem callee_exit_mem subst_map
               location
      | None ->
          caller_mem


  let print_debug_info : Sil.instr -> Dom.Mem.astate -> Dom.Mem.astate -> unit =
    fun instr pre post ->
      L.(debug BufferOverrun Verbose) "@\n@\n================================@\n" ;
      L.(debug BufferOverrun Verbose) "@[<v 2>Pre-state : @,%a" Dom.Mem.pp pre ;
      L.(debug BufferOverrun Verbose) "@]@\n@\n%a" (Sil.pp_instr Pp.text) instr ;
      L.(debug BufferOverrun Verbose) "@\n@\n" ;
      L.(debug BufferOverrun Verbose) "@[<v 2>Post-state : @,%a" Dom.Mem.pp post ;
      L.(debug BufferOverrun Verbose) "@]@\n" ;
      L.(debug BufferOverrun Verbose) "================================@\n@."


  let exec_instr : Dom.Mem.astate -> extras ProcData.t -> CFG.node -> Sil.instr -> Dom.Mem.astate =
    fun mem {pdesc; tenv; extras} node instr ->
      let pname = Procdesc.get_proc_name pdesc in
      let output_mem =
        match instr with
        | Load (id, _, _, _) when Ident.is_none id ->
            mem
        | Load (id, exp, _, _) ->
            BoUtils.Exec.load_val id (Sem.eval exp mem) mem
        | Store (exp1, _, exp2, location) ->
            let locs = Sem.eval exp1 mem |> Dom.Val.get_all_locs in
            let v = Sem.eval exp2 mem |> Dom.Val.add_trace_elem (Trace.Assign location) in
            let mem = Dom.Mem.update_mem locs v mem in
            let mem =
              if PowLoc.is_singleton locs then
                let loc_v = PowLoc.min_elt locs in
                match Typ.Procname.get_method pname with
                | "__inferbo_empty" when Loc.is_return loc_v -> (
                  match Sem.get_formals pdesc with
                  | [(formal, _)] ->
                      let formal_v = Dom.Mem.find_heap (Loc.of_pvar formal) mem in
                      Dom.Mem.store_empty_alias formal_v loc_v exp2 mem
                  | _ ->
                      assert false )
                | _ ->
                    Dom.Mem.store_simple_alias loc_v exp2 mem
              else mem
            in
            let mem = Dom.Mem.update_latest_prune exp1 exp2 mem in
            mem
        | Prune (exp, _, _, _) ->
            Sem.prune exp mem
        | Call (ret, Const Cfun callee_pname, params, location, _) -> (
          match Models.Procname.dispatch callee_pname params with
          | Some {Models.exec} ->
              exec callee_pname ret node location mem
          | None ->
            match Summary.read_summary pdesc callee_pname with
            | Some summary ->
                let callee = extras callee_pname in
                instantiate_mem tenv ret callee callee_pname params mem summary location
            | None ->
                L.(debug BufferOverrun Verbose)
                  "/!\\ Unknown call to %a at %a@\n" Typ.Procname.pp callee_pname Location.pp
                  location ;
                Models.model_by_value Dom.Val.unknown callee_pname ret node location mem
                |> Dom.Mem.add_heap Loc.unknown Dom.Val.unknown )
        | Declare_locals (locals, location) ->
            (* array allocation in stack e.g., int arr[10] *)
            let rec decl_local pname node location loc typ ~inst_num ~dimension mem =
              match typ.Typ.desc with
              | Typ.Tarray (typ, length, stride0) ->
                  let stride = Option.map ~f:IntLit.to_int stride0 in
                  BoUtils.Exec.decl_local_array ~decl_local pname node location loc typ ~length
                    ?stride ~inst_num ~dimension mem
              | Typ.Tstruct typname -> (
                match Models.TypName.dispatch typname with
                | Some {Models.declare_local} ->
                    declare_local ~decl_local pname node location loc ~inst_num ~dimension mem
                | None ->
                    (mem, inst_num) )
              | _ ->
                  (mem, inst_num)
            in
            let try_decl_local (mem, inst_num) (pvar, typ) =
              let loc = Loc.of_pvar pvar in
              decl_local pname node location loc typ ~inst_num ~dimension:1 mem
            in
            let mem, inst_num = List.fold ~f:try_decl_local ~init:(mem, 1) locals in
            let formals = Sem.get_formals pdesc in
            declare_symbolic_parameters pname tenv node location ~inst_num formals mem
        | Call (_, fun_exp, _, location, _) ->
            let () =
              L.(debug BufferOverrun Verbose)
                "/!\\ Call to non-const function %a at %a" Exp.pp fun_exp Location.pp location
            in
            mem
        | Remove_temps (temps, _) ->
            Dom.Mem.remove_temps temps mem
        | Abstract _ | Nullify _ ->
            mem
      in
      print_debug_info instr mem output_mem ;
      output_mem
end

module Analyzer = AbstractInterpreter.Make (ProcCfg.Normal) (TransferFunctions)
module CFG = Analyzer.TransferFunctions.CFG

module Report = struct
  (* I'd like to avoid rebuilding this :(
    Everything depend on CFG only because of `get_allocsite` *)
  module BoUtils = BufferOverrunUtils.Make (CFG)
  module Sem = BoUtils.Sem
  module Models = BufferOverrunModels.Make (BoUtils)

  type extras = Typ.Procname.t -> Procdesc.t option

  let add_condition
      : Typ.Procname.t -> Exp.t -> Location.t -> Dom.Mem.astate -> PO.ConditionSet.t
        -> PO.ConditionSet.t =
    fun pname exp location mem cond_set ->
      match exp with
      | Exp.Var _ ->
          let v = Sem.eval exp mem in
          let arr = Dom.Val.get_array_blk v in
          let arr_traces = Dom.Val.get_traces v in
          BoUtils.Check.array_access ~arr ~arr_traces ~idx:Itv.zero ~idx_traces:TraceSet.empty
            ~is_plus:true pname location cond_set
      | Exp.Lindex (array_exp, index_exp) ->
          BoUtils.Check.lindex ~array_exp ~index_exp mem pname location cond_set
      | Exp.BinOp ((Binop.PlusA as bop), e1, e2) | Exp.BinOp ((Binop.MinusA as bop), e1, e2) ->
          let v_arr = Sem.eval e1 mem in
          let arr = Dom.Val.get_array_blk v_arr in
          let arr_traces = Dom.Val.get_traces v_arr in
          let v_idx = Sem.eval e2 mem in
          let idx = Dom.Val.get_itv v_idx in
          let idx_traces = Dom.Val.get_traces v_idx in
          let is_plus = Binop.equal bop Binop.PlusA in
          BoUtils.Check.array_access ~arr ~arr_traces ~idx ~idx_traces ~is_plus pname location
            cond_set
      | _ ->
          cond_set


  let instantiate_cond
      : Tenv.t -> Typ.Procname.t -> Procdesc.t option -> (Exp.t * Typ.t) list -> Dom.Mem.astate
        -> Summary.payload -> Location.t -> PO.ConditionSet.t =
    fun tenv caller_pname callee_pdesc params caller_mem summary location ->
      let callee_entry_mem = Dom.Summary.get_input summary in
      let callee_cond = Dom.Summary.get_cond_set summary in
      match callee_pdesc with
      | Some pdesc ->
          let subst_map, _ =
            Sem.get_subst_map tenv pdesc params caller_mem callee_entry_mem ~callee_ret_alias:None
          in
          let pname = Procdesc.get_proc_name pdesc in
          PO.ConditionSet.subst callee_cond subst_map caller_pname pname location
      | _ ->
          callee_cond


  let print_debug_info : Sil.instr -> Dom.Mem.astate -> PO.ConditionSet.t -> unit =
    fun instr pre cond_set ->
      L.(debug BufferOverrun Verbose) "@\n@\n================================@\n" ;
      L.(debug BufferOverrun Verbose) "@[<v 2>Pre-state : @,%a" Dom.Mem.pp pre ;
      L.(debug BufferOverrun Verbose) "@]@\n@\n%a" (Sil.pp_instr Pp.text) instr ;
      L.(debug BufferOverrun Verbose) "@[<v 2>@\n@\n%a" PO.ConditionSet.pp cond_set ;
      L.(debug BufferOverrun Verbose) "@]@\n" ;
      L.(debug BufferOverrun Verbose) "================================@\n@."


  module ExitStatement = struct
    let non_significant_instr = function
      | Sil.(Abstract _ | Nullify _ | Remove_temps _) ->
          true
      | _ ->
          false


    (* check that we are the last significant instruction
     * of a procedure (no more significant instruction)
     * or of a block (goes directly to a node with multiple predecessors)
     *)
    let rec is_end_of_block_or_procedure node rem_instrs =
      List.for_all rem_instrs ~f:non_significant_instr
      &&
      match Procdesc.Node.get_succs node with
      | [] ->
          true
      | [succ]
        -> (
          is_end_of_block_or_procedure succ (CFG.instrs succ)
          ||
          match Procdesc.Node.get_preds succ with
          | _ :: _ :: _ ->
              true (* [succ] is a join, i.e. [node] is the end of a block *)
          | _ ->
              false )
      | _ :: _ :: _ ->
          false
  end

  let rec collect_instrs
      : Specs.summary -> extras ProcData.t -> CFG.node -> Sil.instr list -> Dom.Mem.astate
        -> PO.ConditionSet.t -> PO.ConditionSet.t =
    fun summary ({pdesc; tenv; extras} as pdata) node instrs mem cond_set ->
      match instrs with
      | [] ->
          cond_set
      | instr :: rem_instrs ->
          let pname = Procdesc.get_proc_name pdesc in
          let cond_set =
            match instr with
            | Sil.Load (_, exp, _, location) | Sil.Store (exp, _, _, location) ->
                add_condition pname exp location mem cond_set
            | Sil.Call (_, Const Cfun callee_pname, params, location, _) -> (
              match Models.Procname.dispatch callee_pname params with
              | Some {Models.check} ->
                  check pname node location mem cond_set
              | None ->
                match Summary.read_summary pdesc callee_pname with
                | Some callee_summary ->
                    let callee = extras callee_pname in
                    instantiate_cond tenv pname callee params mem callee_summary location
                    |> PO.ConditionSet.join cond_set
                | _ ->
                    cond_set )
            | _ ->
                cond_set
          in
          let mem' = Analyzer.TransferFunctions.exec_instr mem pdata node instr in
          let () =
            match (mem, mem') with
            | NonBottom _, Bottom -> (
              match instr with
              | Sil.Prune (_, _, _, (Ik_land_lor | Ik_bexp)) ->
                  ()
              | Sil.Prune (cond, location, true_branch, _) ->
                  let i = match cond with Exp.Const Const.Cint i -> i | _ -> IntLit.zero in
                  let desc =
                    Errdesc.explain_condition_always_true_false tenv i cond node location
                  in
                  let exn =
                    Exceptions.Condition_always_true_false (desc, not true_branch, __POS__)
                  in
                  Reporting.log_warning summary ~loc:location exn
              (* special case for `exit` when we're at the end of a block / procedure *)
              | Sil.Call (_, Const Cfun pname, _, _, _)
                when String.equal (Typ.Procname.get_method pname) "exit"
                     && ExitStatement.is_end_of_block_or_procedure node rem_instrs ->
                  ()
              | _ ->
                  let location = Sil.instr_get_loc instr in
                  let desc = Errdesc.explain_unreachable_code_after location in
                  let exn = Exceptions.Unreachable_code_after (desc, __POS__) in
                  Reporting.log_error summary ~loc:location exn )
            | _ ->
                ()
          in
          print_debug_info instr mem' cond_set ;
          collect_instrs summary pdata node rem_instrs mem' cond_set


  let collect_node
      : Specs.summary -> extras ProcData.t -> Analyzer.invariant_map -> PO.ConditionSet.t
        -> CFG.node -> PO.ConditionSet.t =
    fun summary pdata inv_map cond_set node ->
      match Analyzer.extract_pre (CFG.id node) inv_map with
      | Some mem ->
          let instrs = CFG.instrs node in
          collect_instrs summary pdata node instrs mem cond_set
      | _ ->
          cond_set


  let collect : Specs.summary -> extras ProcData.t -> Analyzer.invariant_map -> PO.ConditionSet.t =
    fun summary ({pdesc} as pdata) inv_map ->
      let add_node1 acc node = collect_node summary pdata inv_map acc node in
      Procdesc.fold_nodes add_node1 PO.ConditionSet.empty pdesc


  let make_err_trace : Trace.t -> string -> Errlog.loc_trace =
    fun trace desc ->
      let f elem (trace, depth) =
        match elem with
        | Trace.Assign location ->
            (Errlog.make_trace_element depth location "Assignment" [] :: trace, depth)
        | Trace.ArrDecl location ->
            (Errlog.make_trace_element depth location "ArrayDeclaration" [] :: trace, depth)
        | Trace.Call location ->
            (Errlog.make_trace_element depth location "Call" [] :: trace, depth + 1)
        | Trace.Return location ->
            (Errlog.make_trace_element (depth - 1) location "Return" [] :: trace, depth - 1)
        | Trace.SymAssign _ ->
            (trace, depth)
        | Trace.ArrAccess location ->
            (Errlog.make_trace_element depth location ("ArrayAccess: " ^ desc) [] :: trace, depth)
      in
      List.fold_right ~f ~init:([], 0) trace.trace |> fst |> List.rev


  let report_errors : Specs.summary -> Procdesc.t -> PO.ConditionSet.t -> unit =
    fun summary pdesc cond_set ->
      let pname = Procdesc.get_proc_name pdesc in
      let report cond trace issue_type =
        let caller_pname, location =
          match PO.ConditionTrace.get_cond_trace trace with
          | PO.ConditionTrace.Inter (caller_pname, _, location) ->
              (caller_pname, location)
          | PO.ConditionTrace.Intra pname ->
              (pname, PO.ConditionTrace.get_location trace)
        in
        if Typ.Procname.equal pname caller_pname then
          let description = PO.description cond trace in
          let error_desc = Localise.desc_buffer_overrun description in
          let exn = Exceptions.Checkers (issue_type, error_desc) in
          let trace =
            match TraceSet.choose_shortest trace.PO.ConditionTrace.val_traces with
            | trace ->
                make_err_trace trace description
            | exception _ ->
                [Errlog.make_trace_element 0 location description []]
          in
          Reporting.log_error summary ~loc:location ~ltr:trace exn
      in
      PO.ConditionSet.check_all ~report cond_set
end

let compute_post
    : Specs.summary -> Analyzer.TransferFunctions.extras ProcData.t -> Summary.payload option =
  fun summary {pdesc; tenv; extras= get_pdesc} ->
    let cfg = CFG.from_pdesc pdesc in
    let pdata = ProcData.make pdesc tenv get_pdesc in
    let inv_map = Analyzer.exec_pdesc ~initial:Dom.Mem.init pdata in
    let entry_mem =
      let entry_id = CFG.id (CFG.start_node cfg) in
      Analyzer.extract_post entry_id inv_map
    in
    let exit_mem =
      let exit_id = CFG.id (CFG.exit_node cfg) in
      Analyzer.extract_post exit_id inv_map
    in
    let cond_set = Report.collect summary pdata inv_map in
    Report.report_errors summary pdesc cond_set ;
    match (entry_mem, exit_mem) with
    | Some entry_mem, Some exit_mem ->
        Some (entry_mem, exit_mem, cond_set)
    | _ ->
        None


let print_summary : Typ.Procname.t -> Dom.Summary.t -> unit =
  fun proc_name s ->
    L.(debug BufferOverrun Medium)
      "@\n@[<v 2>Summary of %a :@,%a@]@." Typ.Procname.pp proc_name Dom.Summary.pp_summary s


let checker : Callbacks.proc_callback_args -> Specs.summary =
  fun {proc_desc; tenv; summary; get_proc_desc} ->
    let proc_data = ProcData.make proc_desc tenv get_proc_desc in
    Preanal.do_preanalysis proc_desc tenv ;
    match compute_post summary proc_data with
    | Some post ->
        ( if Config.bo_debug >= 1 then
            let proc_name = Specs.get_proc_name summary in
            print_summary proc_name post ) ;
        Summary.update_summary post summary
    | None ->
        summary
