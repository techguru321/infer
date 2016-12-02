(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

module F = Format
module L = Logging

(** Create a taint analysis from a trace domain *)

module Summary = Summary.Make(struct
    type summary = QuandarySummary.t

    let update_payload summary payload =
      { payload with Specs.quandary = Some summary; }

    let read_from_payload payload =
      match payload.Specs.quandary with
      | None ->
          (* abstract/native/interface methods will have None as a summary. treat them as skip *)
          Some []
      | summary_opt ->
          summary_opt
  end)

module Make (TaintSpecification : TaintSpec.S) = struct

  module TraceDomain = TaintSpecification.Trace
  module TaintDomain = AccessTree.Make (TraceDomain)
  module IdMapDomain = IdAccessPathMapDomain

  module Domain = struct
    type astate =
      {
        access_tree : TaintDomain.astate; (* mapping of access paths to trace sets *)
        id_map : IdMapDomain.astate; (* mapping of id's to access paths for normalization *)
      }

    let initial =
      let access_tree = TaintDomain.initial in
      let id_map = IdMapDomain.initial in
      { access_tree; id_map; }

    let (<=) ~lhs ~rhs =
      if lhs == rhs
      then true
      else
        TaintDomain.(<=) ~lhs:lhs.access_tree ~rhs:rhs.access_tree &&
        IdMapDomain.(<=) ~lhs:lhs.id_map ~rhs:rhs.id_map

    let join astate1 astate2 =
      if astate1 == astate2
      then astate1
      else
        let access_tree = TaintDomain.join astate1.access_tree astate2.access_tree in
        let id_map = IdMapDomain.join astate1.id_map astate2.id_map in
        { access_tree; id_map; }

    let widen ~prev ~next ~num_iters =
      if prev == next
      then prev
      else
        let access_tree =
          TaintDomain.widen ~prev:prev.access_tree ~next:next.access_tree ~num_iters in
        let id_map = IdMapDomain.widen ~prev:prev.id_map ~next:next.id_map ~num_iters in
        { access_tree; id_map; }

    let pp fmt { access_tree; id_map; } =
      F.fprintf fmt "(%a, %a)" TaintDomain.pp access_tree IdMapDomain.pp id_map
  end

  let is_global (var, _) = match var with
    | Var.ProgramVar pvar -> Pvar.is_global pvar
    | Var.LogicalVar _ -> false

  module TransferFunctions (CFG : ProcCfg.S) = struct
    module CFG = CFG
    module Domain = Domain

    (** map from formals to their position *)
    type formal_map = int AccessPath.BaseMap.t
    type extras = formal_map

    let is_formal base formal_map =
      AccessPath.BaseMap.mem base formal_map

    let is_rooted_in_environment ap formal_map =
      let root, _ = AccessPath.extract ap in
      is_formal root formal_map || is_global root

    let resolve_id id_map id =
      try Some (IdMapDomain.find id id_map)
      with Not_found -> None

    (* get the node associated with [access_path] in [access_tree] *)
    let access_path_get_node access_path access_tree (proc_data : formal_map ProcData.t) loc =
      match TaintDomain.get_node access_path access_tree with
      | Some _ as node_opt ->
          node_opt
      | None when is_rooted_in_environment access_path proc_data.extras ->
          let call_site = CallSite.make (Procdesc.get_proc_name proc_data.ProcData.pdesc) loc in
          let trace =
            TraceDomain.of_source (TraceDomain.Source.make_footprint access_path call_site) in
          Some (TaintDomain.make_normal_leaf trace)
      | None ->
          None

    (* get the trace associated with [access_path] in [access_tree]. *)
    let access_path_get_trace access_path access_tree proc_data loc =
      match access_path_get_node access_path access_tree proc_data loc with
      | Some (trace, _) -> trace
      | None -> TraceDomain.initial

    (* get the node associated with [exp] in [access_tree] *)
    let exp_get_node ?(abstracted=false) exp typ { Domain.access_tree; id_map; } proc_data loc =
      let f_resolve_id = resolve_id id_map in
      match AccessPath.of_lhs_exp exp typ ~f_resolve_id with
      | Some raw_access_path ->
          let access_path =
            if abstracted
            then AccessPath.Abstracted raw_access_path
            else AccessPath.Exact raw_access_path in
          access_path_get_node access_path access_tree proc_data loc
      | None ->
          (* can't make an access path from [exp] *)
          None

    let analyze_assignment lhs_access_path rhs_exp rhs_typ astate proc_data loc =
      let rhs_node =
        match exp_get_node rhs_exp rhs_typ astate proc_data loc with
        | Some node -> node
        | None -> TaintDomain.empty_node in
      let access_tree = TaintDomain.add_node lhs_access_path rhs_node astate.Domain.access_tree in
      { astate with Domain.access_tree; }

    let analyze_id_assignment lhs_id rhs_exp rhs_typ ({ Domain.id_map; } as astate) =
      let f_resolve_id = resolve_id id_map in
      match AccessPath.of_lhs_exp rhs_exp rhs_typ ~f_resolve_id with
      | Some rhs_access_path ->
          let id_map' = IdMapDomain.add lhs_id rhs_access_path id_map in
          { astate with Domain.id_map = id_map'; }
      | None ->
          astate

    let add_source source ret_id ret_typ access_tree =
      let trace = TraceDomain.of_source source in
      let id_ap = AccessPath.Exact (AccessPath.of_id ret_id ret_typ) in
      TaintDomain.add_trace id_ap trace access_tree

    (** log any new reportable source-sink flows in [trace] *)
    let report_trace trace cur_site (proc_data : formal_map ProcData.t) =
      let trace_of_pname pname =
        match Summary.read_summary proc_data.pdesc pname with
        | Some summary ->
            let join_output_trace acc { QuandarySummary.output_trace; } =
              TraceDomain.join (TaintSpecification.of_summary_trace output_trace) acc in
            IList.fold_left join_output_trace TraceDomain.initial summary
        | None ->
            TraceDomain.initial in

      let pp_path_short fmt (_, sources_passthroughs, sinks_passthroughs) =
        let original_source = fst (IList.hd sources_passthroughs) in
        let final_sink = fst (IList.hd sinks_passthroughs) in
        F.fprintf
          fmt
          "%a -> %a"
          TraceDomain.Source.pp original_source
          TraceDomain.Sink.pp final_sink in

      let report_error path =
        let caller_pname = Procdesc.get_proc_name proc_data.pdesc in
        let msg = Localise.to_string Localise.quandary_taint_error in
        let trace_str = F.asprintf "%a" pp_path_short path in
        let ltr = TraceDomain.to_loc_trace path in
        let exn = Exceptions.Checkers (msg, Localise.verbatim_desc trace_str) in
        Reporting.log_error caller_pname ~loc:(CallSite.loc cur_site) ~ltr exn in

      IList.iter report_error (TraceDomain.get_reportable_paths ~cur_site trace ~trace_of_pname)

    let add_sinks sinks actuals ({ Domain.access_tree; id_map; } as astate) proc_data callee_site =
      let f_resolve_id = resolve_id id_map in
      (* add [sink] to the trace associated with the [formal_num]th actual *)
      let add_sink_to_actual access_tree_acc (sink_param : TraceDomain.Sink.t Sink.parameter) =
        let actual_exp, actual_typ = IList.nth actuals sink_param.index in
        match AccessPath.of_lhs_exp actual_exp actual_typ ~f_resolve_id with
        | Some actual_ap_raw ->
            let actual_ap =
              let is_array_typ = match actual_typ with
                | Typ.Tptr (Tarray _, _) (* T* [] (Java-style) *)
                | Tptr (Tptr _, _) (* T** (C/C++ style 1) *)
                | Tarray _ (* T[] C/C++ style 2 *) ->
                    true
                | _ ->
                    false in
              (* conisder any sources that are reachable from an array *)
              if sink_param.report_reachable || is_array_typ
              then AccessPath.Abstracted actual_ap_raw
              else AccessPath.Exact actual_ap_raw in
            begin
              match access_path_get_node
                      actual_ap access_tree_acc proc_data (CallSite.loc callee_site) with
              | Some (actual_trace, _) ->
                  let actual_trace' = TraceDomain.add_sink sink_param.sink actual_trace in
                  report_trace actual_trace' callee_site proc_data;
                  TaintDomain.add_trace actual_ap actual_trace' access_tree_acc
              | None ->
                  access_tree_acc
            end
        | None ->
            access_tree_acc in
      let access_tree' = IList.fold_left add_sink_to_actual access_tree sinks in
      { astate with Domain.access_tree = access_tree'; }

    let apply_summary
        ret_id
        actuals
        summary
        (astate_in : Domain.astate)
        proc_data
        callee_site =
      let callee_loc = CallSite.loc callee_site in

      let apply_return ret_ap = function
        | Some (ret_id, _) -> AccessPath.with_base_var (Var.of_id ret_id) ret_ap
        | None -> failwith "Have summary for retval, but no ret id to bind it to!" in

      let get_actual_ap_trace formal_num formal_ap access_tree =
        let get_actual_ap formal_num =
          let f_resolve_id = resolve_id astate_in.id_map in
          let actual_exp, actual_typ =
            try IList.nth actuals formal_num
            with Failure _ -> failwithf "Bad formal number %d" formal_num in
          AccessPath.of_lhs_exp actual_exp actual_typ ~f_resolve_id in
        let project ~formal_ap ~actual_ap =
          let projected_ap = AccessPath.append actual_ap (snd (AccessPath.extract formal_ap)) in
          if AccessPath.is_exact formal_ap
          then AccessPath.Exact projected_ap
          else AccessPath.Abstracted projected_ap in
        match get_actual_ap formal_num with
        | Some actual_ap ->
            let projected_ap = project ~formal_ap ~actual_ap in
            let projected_trace =
              access_path_get_trace projected_ap access_tree proc_data callee_loc in
            Some (projected_ap, projected_trace)
        | None ->
            None in

      let apply_one access_tree (in_out_summary : QuandarySummary.in_out_summary) =
        let in_trace = match in_out_summary.input with
          | In_empty ->
              TraceDomain.initial
          | In_formal (formal_num, formal_ap) ->
              begin
                match get_actual_ap_trace formal_num formal_ap access_tree with
                | Some (_, actual_trace) -> actual_trace
                | None -> TraceDomain.initial
              end
          | In_global global_ap ->
              access_path_get_trace global_ap access_tree proc_data callee_loc in

        let caller_ap_trace_opt =
          match in_out_summary.output with
          | Out_return ret_ap ->
              let caller_ret_ap = apply_return ret_ap ret_id in
              let ret_trace =
                access_path_get_trace caller_ret_ap access_tree proc_data callee_loc in
              Some (caller_ret_ap, ret_trace)
          | Out_formal (formal_num, formal_ap) ->
              get_actual_ap_trace formal_num formal_ap access_tree
          | Out_global global_ap ->
              let global_trace = access_path_get_trace global_ap access_tree proc_data callee_loc in
              Some (global_ap, global_trace) in
        match caller_ap_trace_opt with
        | Some (caller_ap, caller_trace) ->
            let output_trace = TaintSpecification.of_summary_trace in_out_summary.output_trace in
            let appended_trace = TraceDomain.append in_trace output_trace callee_site in
            let joined_trace = TraceDomain.join caller_trace appended_trace in
            if appended_trace == joined_trace
            then
              access_tree
            else
              begin
                report_trace joined_trace callee_site proc_data;
                TaintDomain.add_trace caller_ap joined_trace access_tree
              end
        | None ->
            access_tree in

      let access_tree = IList.fold_left apply_one astate_in.access_tree summary in
      { astate_in with access_tree; }

    let exec_instr (astate : Domain.astate) (proc_data : formal_map ProcData.t) _ instr =
      let f_resolve_id = resolve_id astate.id_map in
      match instr with
      | Sil.Load (lhs_id, rhs_exp, rhs_typ, _) ->
          analyze_id_assignment (Var.of_id lhs_id) rhs_exp rhs_typ astate
      | Sil.Store (Exp.Lvar lhs_pvar, lhs_typ, rhs_exp, _) when Pvar.is_frontend_tmp lhs_pvar ->
          analyze_id_assignment (Var.of_pvar lhs_pvar) rhs_exp lhs_typ astate
      | Sil.Store (Exp.Lvar lhs_pvar, _, Exp.Exn _, _) when Pvar.is_return lhs_pvar ->
          (* the Java frontend translates `throw Exception` as `return Exception`, which is a bit
             wonky. this tranlsation causes problems for us in computing a summary when an
             exception is "returned" from a void function. skip code like this for now
             (fix via t14159157 later *)
          astate
      | Sil.Store (lhs_exp, lhs_typ, rhs_exp, loc) ->
          let lhs_access_path =
            match AccessPath.of_lhs_exp lhs_exp lhs_typ ~f_resolve_id with
            | Some access_path ->
                access_path
            | None ->
                failwithf
                  "Assignment to unexpected lhs expression %a in proc %a at loc %a"
                  Exp.pp lhs_exp
                  Procname.pp (Procdesc.get_proc_name (proc_data.pdesc))
                  Location.pp loc in
          let astate' =
            analyze_assignment
              (AccessPath.Exact lhs_access_path) rhs_exp lhs_typ astate proc_data loc in
          begin
            (* direct `exp = id` assignments are treated specially; we update the id map too. this
               is so future reads of `exp` will get the subtree associated with `id` (needed to
               handle the `id = foo(); exp = id case` and similar). *)
            match rhs_exp with
            | Exp.Var rhs_id ->
                let existing_accesses =
                  try snd (IdMapDomain.find (Var.of_id rhs_id) astate'.Domain.id_map)
                  with Not_found -> [] in
                let lhs_ap' = AccessPath.append lhs_access_path existing_accesses in
                let id_map' = IdMapDomain.add (Var.of_id rhs_id) lhs_ap' astate'.Domain.id_map in
                { astate' with Domain.id_map = id_map'; }
            | _ ->
                astate'
          end
      | Sil.Call (Some (ret_id, _), Const (Cfun callee_pname), args, loc, _)
        when BuiltinDecl.is_declared callee_pname ->
          if Procname.equal callee_pname BuiltinDecl.__cast
          then
            match args with
            | (cast_target, cast_typ) :: _ ->
                analyze_id_assignment (Var.of_id ret_id) cast_target cast_typ astate
            | _ ->
                failwithf
                  "Unexpected cast %a in procedure %a at line %a"
                  (Sil.pp_instr pe_text) instr
                  Procname.pp (Procdesc.get_proc_name (proc_data.pdesc))
                  Location.pp loc
          else
            astate

      | Sil.Call (ret, Const (Cfun called_pname), actuals, callee_loc, call_flags) ->

          let handle_unknown_call callee_pname astate =
            let exp_join_traces trace_acc (exp, typ) =
              match exp_get_node ~abstracted:true exp typ astate proc_data callee_loc with
              | Some (trace, _) -> TraceDomain.join trace trace_acc
              | None -> trace_acc in
            let propagate_to_access_path access_path actuals (astate : Domain.astate) =
              let trace_with_propagation =
                IList.fold_left exp_join_traces TraceDomain.initial actuals in
              let access_tree =
                TaintDomain.add_trace access_path trace_with_propagation astate.access_tree in
              { astate with access_tree; } in
            let handle_unknown_call_ astate_acc propagation =
              match propagation, actuals, ret with
              | _, [], _ ->
                  astate_acc
              | TaintSpec.Propagate_to_return, actuals, Some (ret_id, ret_typ) ->
                  let ret_ap = AccessPath.Exact (AccessPath.of_id ret_id ret_typ) in
                  propagate_to_access_path ret_ap actuals astate_acc
              | TaintSpec.Propagate_to_receiver,
                (receiver_exp, receiver_typ) :: (_ :: _ as other_actuals),
                _ ->
                  let receiver_ap =
                    match AccessPath.of_lhs_exp receiver_exp receiver_typ ~f_resolve_id with
                    | Some ap ->
                        AccessPath.Exact ap
                    | None ->
                        failwithf
                          "Receiver for called procedure %a does not have an access path"
                          Procname.pp
                          callee_pname in
                  propagate_to_access_path receiver_ap other_actuals astate_acc
              | _ ->
                  astate_acc in

            let propagations =
              TaintSpecification.handle_unknown_call callee_pname (Option.map snd ret) in
            IList.fold_left handle_unknown_call_ astate propagations in

          let analyze_call astate_acc callee_pname =
            let call_site = CallSite.make callee_pname callee_loc in

            let sinks = TraceDomain.Sink.get call_site actuals in
            let astate_with_sink = match sinks with
              | [] -> astate
              | sinks -> add_sinks sinks actuals astate proc_data call_site in

            let source = TraceDomain.Source.get call_site in
            let astate_with_source =
              match source, ret with
              | Some source, Some (ret_id, ret_typ) ->
                  let access_tree = add_source source ret_id ret_typ astate_with_sink.access_tree in
                  { astate_with_sink with access_tree; }
              | Some _, None ->
                  failwithf
                    "%a is marked as a source, but has no return value" Procname.pp callee_pname
              | None, _ ->
                  astate_with_sink in

            let astate_with_summary =
              if sinks <> [] || Option.is_some source
              then
                (* don't use a summary for a procedure that is a direct source or sink *)
                astate_with_source
              else
                match Summary.read_summary proc_data.pdesc callee_pname with
                | Some summary ->
                    apply_summary ret actuals summary astate_with_source proc_data call_site
                | None ->
                    handle_unknown_call callee_pname astate_with_source in

            Domain.join astate_acc astate_with_summary in

          (* highly polymorphic call sites stress reactive mode too much by using too much memory.
             here, we choose an arbitrary call limit that allows us to finish the analysis in
             practice. this is obviously unsound; will try to remove in the future. *)
          let max_calls = 10 in
          let targets =
            if IList.length call_flags.cf_targets <= max_calls
            then
              called_pname :: call_flags.cf_targets
            else
              begin
                L.out "Skipping highly polymorphic call site for %a@." Procname.pp called_pname;
                [called_pname]
              end in
          (* for each possible target of the call, apply the summary. join all results together *)
          IList.fold_left analyze_call Domain.initial targets
      | Sil.Call _ ->
          failwith "Unimp: non-pname call expressions"
      | Sil.Nullify (pvar, _) ->
          let id_map = IdMapDomain.remove (Var.of_pvar pvar) astate.id_map in
          { astate with id_map; }
      | Sil.Remove_temps (ids, _) ->
          let id_map =
            IList.fold_left
              (fun acc id -> IdMapDomain.remove (Var.of_id id) acc)
              astate.id_map
              ids in
          { astate with id_map; }
      | Sil.Prune _ | Abstract _ | Declare_locals _ ->
          astate
  end

  module Analyzer = AbstractInterpreter.Make
      (ProcCfg.Exceptional)
      (Scheduler.ReversePostorder)
      (TransferFunctions)

  (** grab footprint traces in [access_tree] and make them into inputs for the summary. for each
      trace Footprint(T_out, a.b.c) associated with access path x.z.y, we will produce a summary of
      the form (x.z.y, T_in) => (T_in + T_out, a.b.c) *)
  let make_summary formal_map access_tree =
    let is_return (var, _) = match var with
      | Var.ProgramVar pvar -> Pvar.is_return pvar
      | Var.LogicalVar _ -> false in
    let add_summaries_for_trace summary_acc access_path trace =
      let summary_trace = TaintSpecification.to_summary_trace trace in
      let output_opt =
        let base, accesses = AccessPath.extract access_path in
        match AccessPath.BaseMap.find base formal_map with
        | index ->
            (* Java is pass-by-value. thus, summaries should not include assignments to the formal
               parameters (first part of the check) . however, they should reflect when a formal
               passes through a sink (second part of the check) *)
            if accesses = [] && TraceDomain.Sinks.is_empty (TraceDomain.sinks trace)
            (* TODO: and if [base] is not passed by reference, for C/C++/Obj-C *)
            then None
            else Some (QuandarySummary.make_formal_output index access_path)
        | exception Not_found ->
            if is_return base
            then Some (QuandarySummary.make_return_output access_path)
            else if is_global base
            then Some (QuandarySummary.make_global_output access_path)
            else None in

      let add_summary_for_source source acc =
        match TraceDomain.Source.get_footprint_access_path source with
        | Some footprint_ap ->
            let footprint_ap_base = fst (AccessPath.extract footprint_ap) in
            begin
              match AccessPath.BaseMap.find footprint_ap_base formal_map with
              | formal_index ->
                  let input = QuandarySummary.make_formal_input formal_index footprint_ap in
                  begin
                    match output_opt with
                    | Some output ->
                        (QuandarySummary.make_in_out_summary input output summary_trace) :: acc
                    | None ->
                        if not (TraceDomain.Sinks.is_empty (TraceDomain.sinks trace))
                        then
                          let output =
                            QuandarySummary.make_formal_output formal_index footprint_ap in
                          (QuandarySummary.make_in_out_summary input output summary_trace) :: acc
                        else
                          (* output access path is same as input access path and there were no sinks
                             in this function. summary would be the identity function *)
                          acc
                  end
              | exception Not_found ->
                  if is_global footprint_ap_base
                  then
                    let input = QuandarySummary.make_global_input footprint_ap in
                    let output =
                      match output_opt with
                      | Some output -> output
                      | None -> QuandarySummary.make_global_output footprint_ap in
                    (QuandarySummary.make_in_out_summary input output summary_trace) :: acc
                  else
                    failwithf
                      "Couldn't find formal number for %a@." AccessPath.pp_base footprint_ap_base
            end
        | None ->
            begin
              match output_opt with
              | Some output ->
                  let summary =
                    QuandarySummary.make_in_out_summary
                      QuandarySummary.empty_input output summary_trace in
                  summary :: acc
              | None ->
                  acc
            end in

      TraceDomain.Source.Set.fold add_summary_for_source (TraceDomain.sources trace) summary_acc in
    TaintDomain.fold add_summaries_for_trace access_tree []

  let dummy_cg = Cg.create None

  let checker { Callbacks.get_proc_desc; proc_name; proc_desc; tenv; } =
    let analyze_ondemand _ pdesc =
      let make_formal_access_paths pdesc =
        let pname = Procdesc.get_proc_name pdesc in
        let attrs = Procdesc.get_attributes pdesc in
        let formals_with_nums =
          IList.mapi
            (fun index (name, typ) ->
               let pvar = Pvar.mk name pname in
               AccessPath.base_of_pvar pvar typ, index)
            attrs.ProcAttributes.formals in
        IList.fold_left
          (fun formal_map (base, index) -> AccessPath.BaseMap.add base index formal_map)
          AccessPath.BaseMap.empty
          formals_with_nums in

      Preanal.doit ~handle_dynamic_dispatch:true pdesc dummy_cg tenv;
      let formals = make_formal_access_paths pdesc in
      let proc_data = ProcData.make pdesc tenv formals in
      match Analyzer.compute_post proc_data with
      | Some { access_tree; } ->
          let summary = make_summary formals access_tree in
          Summary.write_summary (Procdesc.get_proc_name pdesc) summary;
      | None ->
          if Procdesc.Node.get_succs (Procdesc.get_start_node pdesc) <> []
          then failwith "Couldn't compute post" in

    let callbacks =
      {
        Ondemand.analyze_ondemand;
        get_proc_desc;
      } in
    if Ondemand.procedure_should_be_analyzed proc_name
    then
      begin
        Ondemand.set_callbacks callbacks;
        analyze_ondemand DB.source_file_empty proc_desc;
        Ondemand.unset_callbacks ();
      end

end
