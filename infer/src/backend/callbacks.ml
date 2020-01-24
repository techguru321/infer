(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

(** Module to register and invoke callbacks *)

type proc_callback_args =
  {get_procs_in_file: Procname.t -> Procname.t list; summary: Summary.t; exe_env: Exe_env.t}

type proc_callback_t = proc_callback_args -> Summary.t

type cluster_callback_args =
  {procedures: Procname.t list; source_file: SourceFile.t; exe_env: Exe_env.t}

type cluster_callback_t = cluster_callback_args -> unit

type procedure_callback =
  {name: string; dynamic_dispatch: bool; language: Language.t; callback: proc_callback_t}

type cluster_callback = {name: string; language: Language.t; callback: cluster_callback_t}

let procedure_callbacks = ref []

let cluster_callbacks = ref []

let register_procedure_callback ~name ?(dynamic_dispatch = false) language
    (callback : proc_callback_t) =
  procedure_callbacks := {name; dynamic_dispatch; language; callback} :: !procedure_callbacks


let register_cluster_callback ~name language (callback : cluster_callback_t) =
  cluster_callbacks := {name; language; callback} :: !cluster_callbacks


(** Invoke all registered procedure callbacks on the given procedure. *)
let iterate_procedure_callbacks exe_env summary =
  let proc_desc = Summary.get_proc_desc summary in
  let proc_name = Procdesc.get_proc_name proc_desc in
  let procedure_language = Procname.get_language proc_name in
  Language.curr_language := procedure_language ;
  let get_procs_in_file proc_name =
    let source_file =
      match Attributes.load proc_name with
      | Some {ProcAttributes.translation_unit} ->
          Some translation_unit
      | None ->
          None
    in
    Option.value_map source_file ~default:[] ~f:SourceFiles.proc_names_of_source
  in
  let is_specialized = Procdesc.is_specialized proc_desc in
  List.fold ~init:summary
    ~f:(fun summary {name; dynamic_dispatch; language; callback} ->
      if Language.equal language procedure_language && (dynamic_dispatch || not is_specialized) then (
        PerfEvent.(
          log (fun logger ->
              log_begin_event logger ~name ~categories:["backend"]
                ~arguments:[("proc", `String (Procname.to_string proc_name))]
                () )) ;
        let summary = callback {get_procs_in_file; summary; exe_env} in
        PerfEvent.(log (fun logger -> log_end_event logger ())) ;
        summary )
      else summary )
    !procedure_callbacks


(** Invoke all registered cluster callbacks on a cluster of procedures. *)
let iterate_cluster_callbacks procedures exe_env source_file =
  if !cluster_callbacks <> [] then
    let environment = {procedures; source_file; exe_env} in
    let language_matches language =
      match procedures with
      | procname :: _ ->
          Language.equal language (Procname.get_language procname)
      | _ ->
          true
    in
    List.iter
      ~f:(fun {language; callback} ->
        if language_matches language then (
          Language.curr_language := language ;
          callback environment ) )
      !cluster_callbacks
