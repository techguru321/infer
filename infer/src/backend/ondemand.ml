(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** Module for on-demand analysis. *)

module L = Logging
module F = Format
open Utils

let trace () = Config.from_env_variable "INFER_TRACE_ONDEMAND"
let one_cluster_per_procedure () = false

let () = Config.ondemand_enabled :=
    Config.from_env_variable "INFER_ONDEMAND" &&
    not Config.analyze_models

let across_files () = true

(** Name of the ondemand file *)
let ondemand_file () = Config.get_env_variable "INFER_ONDEMAND_FILE"

(** Read the directories to analyze from the ondemand file. *)
let read_dirs_to_analyze () =
  let lines_opt = match ondemand_file () with
    | None -> None
    | Some fname -> Utils.read_file fname in
  match lines_opt with
  | None ->
      None
  | Some lines ->
      let res = ref StringSet.empty in
      let do_line line =
        let source_dir = DB.source_dir_from_source_file (DB.source_file_from_string line) in
        res := StringSet.add (DB.source_dir_to_string source_dir) !res in
      IList.iter do_line lines;
      Some !res

type analyze_ondemand = Procname.t -> unit

type get_proc_desc = Procname.t -> Cfg.Procdesc.t option

type callbacks =
  {
    analyze_ondemand : analyze_ondemand;
    get_proc_desc : get_proc_desc;
  }

let callbacks_ref = ref None

let set_callbacks  (callbacks : callbacks) =
  callbacks_ref := Some callbacks

let unset_callbacks () =
  callbacks_ref := None

let nesting = ref 0

let procedure_should_be_analyzed curr_pdesc proc_name =
  match AttributesTable.load_attributes proc_name with
  | Some proc_attributes ->
      let currently_analyzed =
        Specs.summary_exists proc_name &&
        Specs.is_active proc_name in
      let already_analyzed = match Specs.get_summary proc_name with
        | Some summary ->
            Specs.get_timestamp summary > 0
        | None ->
            false in
      (* The procedure to be analyzed is in the same file as the current one. *)
      let same_file proc_attributes =
        (Cfg.Procdesc.get_loc curr_pdesc).Location.file
        =
        proc_attributes.ProcAttributes.loc.Location.file in

      !Config.ondemand_enabled &&
      proc_attributes.ProcAttributes.is_defined && (* we have the implementation *)
      not currently_analyzed && (* avoid infinite loops *)
      not already_analyzed && (* avoid re-analysis of the same procedure *)
      (across_files () || (* whether to push the analysis into other files *)
       same_file proc_attributes)
  | None ->
      false

type global_state =
  {
    name_generator : Ident.NameGenerator.t;
  }

let do_analysis curr_pdesc proc_name =
  let curr_pname = Cfg.Procdesc.get_proc_name curr_pdesc in

  let really_do_analysis analyze_proc proc_desc =
    if trace () then L.stderr "[%d] really_do_analysis %a -> %a@."
        !nesting
        Procname.pp curr_pname
        Procname.pp proc_name;

    let preprocess () =
      incr nesting;
      let attributes_opt =
        Some (Cfg.Procdesc.get_attributes proc_desc) in
      let call_graph =
        let cg = Cg.create () in
        Cg.add_defined_node cg proc_name;
        cg in
      Specs.reset_summary call_graph proc_name attributes_opt;
      Specs.set_status proc_name Specs.ACTIVE;
      let old_state =
        {
          name_generator = Ident.NameGenerator.get_current ();
        } in
      old_state in

    let restore old_state =
      Ident.NameGenerator.set_current old_state.name_generator in

    let postprocess () =
      decr nesting;
      let summary = Specs.get_summary_unsafe "ondemand" proc_name in
      let summary' =
        { summary with
          Specs.status = Specs.INACTIVE;
          timestamp = summary.Specs.timestamp + 1 } in
      Specs.add_summary proc_name summary';
      Checkers.ST.store_summary proc_name in

    let old_state = preprocess () in
    try
      analyze_proc proc_name;
      postprocess ();
      restore old_state;
    with e ->
      L.stderr "ONDEMAND EXCEPTION %a %s %s@."
        Procname.pp proc_name
        (Printexc.to_string e)
        (Printexc.get_backtrace ());
      restore old_state;
      raise e in

  match !callbacks_ref with
  | Some callbacks
    when procedure_should_be_analyzed curr_pdesc proc_name ->
      begin
        match callbacks.get_proc_desc proc_name with
        | Some proc_desc ->
            really_do_analysis callbacks.analyze_ondemand proc_desc
        | None -> ()
      end
  | _ ->
      () (* skipping *)
