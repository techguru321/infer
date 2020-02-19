(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module L = Logging

(* Boilerplate to write/read our summaries alongside the summaries of other analyzers *)
module Payload = SummaryPayload.Make (struct
  type t = ResourceLeakDomain.t

  let field = Payloads.Fields.lab_resource_leaks
end)

module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = ResourceLeakDomain

  type extras = unit

  let is_closeable_typename tenv typename =
    let is_closable_interface typename _ =
      match Typ.Name.name typename with
      | "java.io.AutoCloseable" | "java.io.Closeable" ->
          true
      | _ ->
          false
    in
    PatternMatch.supertype_exists tenv is_closable_interface typename


  let is_closeable_procname tenv procname =
    match procname with
    | Procname.Java java_procname ->
        is_closeable_typename tenv (Procname.Java.get_class_type_name java_procname)
    | _ ->
        false


  let _acquires_resource tenv procname =
    (* We assume all constructors of a subclass of Closeable acquire a resource *)
    Procname.is_constructor procname && is_closeable_procname tenv procname


  let _releases_resource tenv procname =
    (* We assume the close method of a Closeable releases all of its resources *)
    String.equal "close" (Procname.get_method procname) && is_closeable_procname tenv procname


  (** Take an abstract state and instruction, produce a new abstract state *)
  let exec_instr (astate : ResourceLeakDomain.t) {ProcData.summary= _; tenv= _} _
      (instr : HilInstr.t) =
    match instr with
    | Call (_return_opt, Direct _callee_procname, _actuals, _, _loc) ->
        (* function call [return_opt] := invoke [callee_procname]([actuals]) *)
        astate
    | Assign (_lhs_access_path, _rhs_exp, _loc) ->
        (* an assignment [lhs_access_path] := [rhs_exp] *)
        astate
    | Assume (_assume_exp, _, _, _loc) ->
        (* a conditional assume([assume_exp]). blocks if [assume_exp] evaluates to false *)
        astate
    | Call (_, Indirect _, _, _, _) ->
        (* This should never happen in Java. Fail if it does. *)
        L.(die InternalError) "Unexpected indirect call %a" HilInstr.pp instr
    | Metadata _ ->
        astate


  let pp_session_name _node fmt = F.pp_print_string fmt "resource leaks"
end

module CFG = ProcCfg.Normal
(** 5(a) Type of CFG to analyze--Exceptional to follow exceptional control-flow edges, Normal to
    ignore them *)

(* Create an intraprocedural abstract interpreter from the transfer functions we defined *)
module Analyzer = LowerHil.MakeAbstractInterpreter (TransferFunctions (CFG))

(** Report an error when we have acquired more resources than we have released *)
let report_if_leak _post _summary (_proc_data : unit ProcData.t) = ()

(* Callback for invoking the checker from the outside--registered in RegisterCheckers *)
let checker {Callbacks.summary; exe_env} : Summary.t =
  let proc_name = Summary.get_proc_name summary in
  let tenv = Exe_env.get_tenv exe_env proc_name in
  let proc_data = ProcData.make summary tenv () in
  match Analyzer.compute_post proc_data ~initial:ResourceLeakDomain.initial with
  | Some post ->
      report_if_leak post summary proc_data ;
      Payload.update_summary post summary
  | None ->
      L.(die InternalError) "Analyzer failed to compute post for %a" Procname.pp proc_name
