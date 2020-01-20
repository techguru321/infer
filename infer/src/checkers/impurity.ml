(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format
module L = Logging
open PulseBasicInterface
open PulseDomainInterface

let debug fmt = L.(debug Analysis Verbose fmt)

(* An impurity analysis that relies on pulse to determine how the state
   changes *)

let get_matching_dest_addr_opt ~edges_pre ~edges_post : AbstractValue.t list option =
  match
    List.fold2 ~init:(Some [])
      ~f:(fun acc (_, (addr_dest_pre, _)) (_, (addr_dest_post, _)) ->
        if AbstractValue.equal addr_dest_pre addr_dest_post then
          Option.map acc ~f:(fun acc -> addr_dest_pre :: acc)
        else None )
      (BaseMemory.Edges.bindings edges_pre)
      (BaseMemory.Edges.bindings edges_post)
  with
  | Unequal_lengths ->
      debug "Mismatch in pre and post.\n" ;
      None
  | Ok x ->
      x


let add_invalid_and_modified ~check_empty attrs acc =
  let modified =
    Attributes.get_written_to attrs
    |> Option.value_map ~default:[] ~f:(fun modified -> [ImpurityDomain.WrittenTo modified])
  in
  let res =
    Attributes.get_invalid attrs
    |> Option.value_map ~default:modified ~f:(fun invalid ->
           ImpurityDomain.Invalid invalid :: modified )
  in
  if check_empty && List.is_empty res then
    L.(die InternalError) "Address is modified without being written to or invalidated."
  else res @ acc


(** Given Pulse summary, extract impurity info, i.e. parameters and global variables that are
    modified by the function and skipped functions. *)
let extract_impurity tenv pdesc pre_post : ImpurityDomain.t =
  let pre_heap = (AbductiveDomain.extract_pre pre_post).BaseDomain.heap in
  let post = AbductiveDomain.extract_post pre_post in
  let post_heap = post.BaseDomain.heap in
  let post_stack = post.BaseDomain.stack in
  let add_to_modified var addr acc =
    let rec aux acc ~addr_to_explore ~visited : ImpurityDomain.trace list =
      match addr_to_explore with
      | [] ->
          acc
      | addr :: addr_to_explore -> (
          if AbstractValue.Set.mem addr visited then aux acc ~addr_to_explore ~visited
          else
            let cell_pre_opt = BaseMemory.find_opt addr pre_heap in
            let cell_post_opt = BaseMemory.find_opt addr post_heap in
            let visited = AbstractValue.Set.add addr visited in
            match (cell_pre_opt, cell_post_opt) with
            | None, None ->
                aux acc ~addr_to_explore ~visited
            | Some (_, _pre_attrs), None ->
                L.(die InternalError)
                  "It is unexpected to have an address which has a binding in pre but not in post!"
            | None, Some (_edges_post, attrs_post) ->
                aux
                  (add_invalid_and_modified ~check_empty:false attrs_post acc)
                  ~addr_to_explore ~visited
            | Some (edges_pre, _), Some (edges_post, attrs_post) -> (
              match get_matching_dest_addr_opt ~edges_pre ~edges_post with
              | Some addr_list ->
                  aux
                    (add_invalid_and_modified attrs_post ~check_empty:false acc)
                    ~addr_to_explore:(addr_list @ addr_to_explore) ~visited
              | None ->
                  aux
                    (add_invalid_and_modified ~check_empty:true attrs_post acc)
                    ~addr_to_explore ~visited ) )
    in
    match aux [] ~addr_to_explore:[addr] ~visited:AbstractValue.Set.empty with
    | [] ->
        acc
    | hd :: tl ->
        ImpurityDomain.ModifiedVarSet.add {var; trace_list= (hd, tl)} acc
  in
  let pname = Procdesc.get_proc_name pdesc in
  let modified_params =
    Procdesc.get_formals pdesc
    |> List.fold_left ~init:ImpurityDomain.ModifiedVarSet.empty ~f:(fun acc (name, typ) ->
           let var = Var.of_pvar (Pvar.mk name pname) in
           match BaseStack.find_opt var post_stack with
           | Some (addr, _) when Typ.is_pointer typ -> (
             match BaseMemory.find_opt addr pre_heap with
             | Some (edges_pre, _) ->
                 BaseMemory.Edges.fold
                   (fun _ (addr, _) acc -> add_to_modified var addr acc)
                   edges_pre acc
             | None ->
                 debug "The address is not materialized in pre-heap." ;
                 acc )
           | _ ->
               acc )
  in
  let modified_globals =
    BaseStack.fold
      (fun var (addr, _) acc -> if Var.is_global var then add_to_modified var addr acc else acc)
      post_stack ImpurityDomain.ModifiedVarSet.empty
  in
  let is_modeled_pure pname =
    match PurityModels.ProcName.dispatch tenv pname with
    | Some callee_summary ->
        PurityDomain.is_pure callee_summary
    | None ->
        false
  in
  let skipped_calls_map =
    post.BaseDomain.skipped_calls_map
    |> BaseDomain.SkippedCallsMap.filter (fun proc_name _ ->
           Purity.should_report proc_name && not (is_modeled_pure proc_name) )
  in
  {modified_globals; modified_params; skipped_calls_map}


let report_errors summary proc_name pname_loc modified_opt =
  let impure_fun_desc = F.asprintf "Impure function %a" Procname.pp proc_name in
  let impure_fun_ltr = Errlog.make_trace_element 0 pname_loc impure_fun_desc [] in
  ( match modified_opt with
  | None ->
      Reporting.log_error summary ~loc:pname_loc ~ltr:[impure_fun_ltr] IssueType.impure_function
        impure_fun_desc
  | Some (ImpurityDomain.{modified_globals; modified_params; skipped_calls_map} as astate) ->
      if Purity.should_report proc_name && not (ImpurityDomain.is_pure astate) then
        let modified_ltr param_source set acc =
          ImpurityDomain.ModifiedVarSet.fold
            (ImpurityDomain.add_to_errlog ~nesting:1 param_source)
            set acc
        in
        let skipped_functions =
          PulseBaseDomain.SkippedCallsMap.fold
            (fun proc_name trace acc ->
              PulseTrace.add_to_errlog ~nesting:1
                ~pp_immediate:(fun fmt ->
                  F.fprintf fmt "call to skipped function %a occurs here" Procname.pp proc_name )
                trace acc )
            skipped_calls_map []
        in
        let ltr =
          impure_fun_ltr
          :: modified_ltr Formal modified_params
               (modified_ltr Global modified_globals skipped_functions)
        in
        Reporting.log_error summary ~loc:pname_loc ~ltr IssueType.impure_function impure_fun_desc ) ;
  summary


let checker {exe_env; Callbacks.summary} : Summary.t =
  let proc_name = Summary.get_proc_name summary in
  let pdesc = Summary.get_proc_desc summary in
  let pname_loc = Procdesc.get_loc pdesc in
  let tenv = Exe_env.get_tenv exe_env proc_name in
  summary.payloads.pulse
  |> Option.map ~f:(fun pre_posts ->
         List.fold pre_posts ~init:ImpurityDomain.pure ~f:(fun acc pre_post ->
             let modified = extract_impurity tenv pdesc pre_post in
             ImpurityDomain.join acc modified ) )
  |> report_errors summary proc_name pname_loc
