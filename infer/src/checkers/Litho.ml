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
module Domain = LithoDomain

module Summary = Summary.Make (struct
  type payload = Domain.astate

  let update_payload astate (summary: Specs.summary) =
    {summary with payload= {summary.payload with litho= Some astate}}


  let read_payload (summary: Specs.summary) = summary.payload.litho
end)

module LithoFramework = struct
  let is_component_builder procname tenv =
    match procname with
    | Typ.Procname.Java java_procname ->
        PatternMatch.is_subtype_of_str tenv
          (Typ.Procname.Java.get_class_type_name java_procname)
          "com.facebook.litho.Component$Builder"
    | _ ->
        false


  let is_component_build_method procname tenv =
    match Typ.Procname.get_method procname with
    | "build" ->
        is_component_builder procname tenv
    | _ ->
        false


  let is_on_create_layout = function
    | Typ.Procname.Java java_pname -> (
      match Typ.Procname.Java.get_method java_pname with "onCreateLayout" -> true | _ -> false )
    | _ ->
        false
end

module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = Domain

  type extras = Specs.summary

  let is_graphql_getter procname summary =
    Option.is_none summary
    (* we skip analysis of all GraphQL procs *)
    &&
    match procname with
    | Typ.Procname.Java java_procname
      -> (
        PatternMatch.is_getter java_procname
        &&
        match Typ.Procname.Java.get_package java_procname with
        | Some package ->
            String.is_prefix ~prefix:"com.facebook.graphql.model" package
        | None ->
            false )
    | _ ->
        false


  let apply_callee_summary summary_opt caller_pname ret_opt actuals astate =
    match summary_opt with
    | Some summary ->
        (* TODO: append paths if the footprint access path is an actual path instead of a var *)
        let f_sub {Domain.LocalAccessPath.access_path= (var, _), _} =
          match Var.get_footprint_index var with
          | Some footprint_index -> (
            match List.nth actuals footprint_index with
            | Some HilExp.AccessPath actual_access_path ->
                Some (Domain.LocalAccessPath.make actual_access_path caller_pname)
            | _ ->
                None )
          | None ->
              if Var.is_return var then
                match ret_opt with
                | Some ret ->
                    Some (Domain.LocalAccessPath.make (ret, []) caller_pname)
                | None ->
                    assert false
              else None
        in
        Domain.substitute ~f_sub summary |> Domain.join astate
    | None ->
        astate


  let get_required_props typename tenv =
    let is_required_prop annotations =
      List.exists
        ~f:(fun ({Annot.class_name; parameters}, _) ->
          String.is_suffix class_name ~suffix:Annotations.prop
          && (* Don't count as required if it's @Prop(optional = true). Note: this is a hack. We
                only translate boolean parameters at the moment, and we only translate the value of
                the parameter (as a string, lol), not its name. In this case, the only boolean
                parameter of @Prop is optional, and its default value is false. So it suffices to
                do the "one parameter true" check *)
             not (List.exists ~f:(fun annot_string -> String.equal annot_string "true") parameters)
          )
        annotations
    in
    match Tenv.lookup tenv typename with
    | Some {fields} ->
        List.filter_map
          ~f:(fun (fieldname, _, annotation) ->
            if is_required_prop annotation then Some (Typ.Fieldname.Java.get_field fieldname)
            else None )
          fields
    | None ->
        []


  let report_missing_required_prop summary prop_string loc =
    let message =
      F.asprintf "@Prop %s is required, but not set before the call to build()" prop_string
    in
    let exn =
      Exceptions.Checkers (IssueType.missing_required_prop, Localise.verbatim_desc message)
    in
    let ltr = [Errlog.make_trace_element 0 loc message []] in
    Reporting.log_error summary ~loc ~ltr exn


  let check_required_props receiver_ap astate callee_procname caller_procname tenv summary loc =
    match callee_procname with
    | Typ.Procname.Java java_pname
      -> (
        (* Here, we'll have a type name like MyComponent$Builder in hand. Truncate the $Builder
             part from the typename, then look at the fields of MyComponent to figure out which
             ones are annotated with @Prop *)
        let typename = Typ.Procname.Java.get_class_type_name java_pname in
        match Typ.Name.Java.get_outer_class typename with
        | Some outer_class_typename ->
            let required_props = get_required_props outer_class_typename tenv in
            let receiver = Domain.LocalAccessPath.make receiver_ap caller_procname in
            let method_call = Domain.MethodCall.make receiver callee_procname in
            let f _ prop_setter_calls =
              (* See if there's a required prop whose setter wasn't called *)
              let prop_set =
                List.fold prop_setter_calls
                  ~f:(fun acc pname -> String.Set.add acc (Typ.Procname.get_method pname))
                  ~init:String.Set.empty
              in
              List.iter
                ~f:(fun required_prop ->
                  if not (String.Set.mem prop_set required_prop) then
                    report_missing_required_prop summary required_prop loc )
                required_props
            in
            (* check every chain ending in [build()] to make sure that required props are passed
                 on all of them *)
            Domain.iter_call_chains_with_suffix ~f method_call astate
        | None ->
            () )
    | _ ->
        ()


  let exec_instr astate (proc_data: extras ProcData.t) _ (instr: HilInstr.t) : Domain.astate =
    let caller_pname = Procdesc.get_proc_name proc_data.pdesc in
    match instr with
    | Call
        ( (Some return_base as ret_opt)
        , Direct (Typ.Procname.Java java_callee_procname as callee_procname)
        , ((HilExp.AccessPath receiver_ap) :: _ as actuals)
        , _
        , loc ) ->
        if LithoFramework.is_component_build_method callee_procname proc_data.tenv then
          (* call to Component$Builder.build(); check that all required props are passed *)
          (* TODO: only check when the root of the call chain is <: Component? otherwise,
             methods that call build() but implicitly have a precondition of "add a required prop"
             will be wrongly flagged *)
          check_required_props receiver_ap astate callee_procname caller_pname proc_data.tenv
            proc_data.extras loc ;
        let summary = Summary.read_summary proc_data.pdesc callee_procname in
        (* TODO: we should probably track all calls rooted in formals as well *)
        let receiver = Domain.LocalAccessPath.make receiver_ap caller_pname in
        if ( LithoFramework.is_component_builder callee_procname proc_data.tenv
           (* track Builder's in order to check required prop's *)
           || is_graphql_getter callee_procname summary
           || (* track GraphQL getters in order to report graphql field accesses *)
              Domain.mem receiver astate
              (* track anything called on a receiver we're already tracking *) )
           && not (Typ.Procname.Java.is_static java_callee_procname)
        then
          let return_access_path = Domain.LocalAccessPath.make (return_base, []) caller_pname in
          let return_calls =
            (try Domain.find return_access_path astate with Not_found -> Domain.CallSet.empty)
            |> Domain.CallSet.add (Domain.MethodCall.make receiver callee_procname)
          in
          Domain.add return_access_path return_calls astate
        else
          (* treat it like a normal call *)
          apply_callee_summary summary caller_pname ret_opt actuals astate
    | Call (ret_opt, Direct callee_procname, actuals, _, _) ->
        let summary = Summary.read_summary proc_data.pdesc callee_procname in
        apply_callee_summary summary caller_pname ret_opt actuals astate
    | Assign (lhs_ap, HilExp.AccessPath rhs_ap, _)
      -> (
        (* creating an alias for the rhs binding; assume all reads will now occur through the
           alias. this helps us keep track of chains in cases like tmp = getFoo(); x = tmp;
           tmp.getBar() *)
        let lhs_access_path = Domain.LocalAccessPath.make lhs_ap caller_pname in
        let rhs_access_path = Domain.LocalAccessPath.make rhs_ap caller_pname in
        try
          let call_set = Domain.find rhs_access_path astate in
          Domain.remove rhs_access_path astate |> Domain.add lhs_access_path call_set
        with Not_found -> astate )
    | _ ->
        astate
end

module Analyzer = LowerHil.MakeAbstractInterpreter (ProcCfg.Exceptional) (TransferFunctions)

let should_report proc_desc = LithoFramework.is_on_create_layout (Procdesc.get_proc_name proc_desc)

let report_graphql_getters summary access_path call_chain =
  let call_strings = List.map ~f:(Typ.Procname.to_simplified_string ~withclass:false) call_chain in
  let call_string = String.concat ~sep:"." call_strings in
  let message = F.asprintf "%a.%s" AccessPath.pp access_path call_string in
  let exn = Exceptions.Checkers (IssueType.graphql_field_access, Localise.verbatim_desc message) in
  let loc = Specs.get_loc summary in
  let ltr = [Errlog.make_trace_element 0 loc message []] in
  Reporting.log_error summary ~loc ~ltr exn


let postprocess astate proc_desc : Domain.astate =
  let formal_map = FormalMap.make proc_desc in
  let f_sub access_path = Domain.LocalAccessPath.to_formal_option access_path formal_map in
  Domain.substitute ~f_sub astate


let checker {Callbacks.summary; proc_desc; tenv} =
  let proc_data = ProcData.make proc_desc tenv summary in
  match Analyzer.compute_post proc_data ~initial:Domain.empty with
  | Some post ->
      ( if should_report proc_desc then
          let f = report_graphql_getters summary in
          Domain.iter_call_chains ~f post ) ;
      let payload = postprocess post proc_desc in
      Summary.update_summary payload summary
  | None ->
      summary
