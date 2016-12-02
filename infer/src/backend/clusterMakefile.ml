(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

module L = Logging
module F = Format
module CLOpt = CommandLineOption

(** Module to create a makefile with dependencies between clusters *)

let cluster_should_be_analyzed cluster =
  let fname = DB.source_dir_to_string cluster in
  let in_ondemand_config = Option.map (StringSet.mem fname) Ondemand.dirs_to_analyze in
  let check_modified () =
    let modified =
      DB.file_was_updated_after_start (DB.filename_from_string fname) in
    if modified &&
       Config.developer_mode
    then L.stdout "Modified: %s@." fname;
    modified in
  begin
    match in_ondemand_config with
    | Some b -> (* ondemand config file is specified *)
        b
    | None when Config.reactive_mode  ->
        check_modified ()
    | None ->
        true
  end


let pp_prolog fmt clusters =
  let compilation_dbs_cmd =
    IList.map (F.sprintf "--clang-compilation-db-files %s") !Config.clang_compilation_db_files
    |> String.concat " " in
  F.fprintf fmt "INFERANALYZE= %s -results_dir '%s' %s \n@."
    (Config.bin_dir // (CLOpt.exe_name Analyze))
    (Escape.escape_map
       (fun c -> if c = '#' then Some "\\#" else None)
       Config.results_dir)
    compilation_dbs_cmd;
  F.fprintf fmt "CLUSTERS=";

  IList.iteri
    (fun i cl ->
       if cluster_should_be_analyzed cl
       then F.fprintf fmt "%a " Cluster.pp_cluster_name (i+1))
    clusters;

  F.fprintf fmt "@.@.default: test@.@.all: test@.@.";
  F.fprintf fmt "test: $(CLUSTERS)@.";
  if Config.show_progress_bar then F.fprintf fmt "\t@@echo@\n@."

let pp_epilog fmt () =
  F.fprintf fmt "@.clean:@.\trm -f $(CLUSTERS)@."

let create_cluster_makefile (clusters: Cluster.t list) (fname: string) =
  let outc = open_out fname in
  let fmt = Format.formatter_of_out_channel outc in
  let do_cluster cluster_nr cluster =
    F.fprintf fmt "#%s@\n" (DB.source_dir_to_string cluster);
    Cluster.pp_cluster fmt (cluster_nr + 1, cluster) in
  pp_prolog fmt clusters;
  IList.iteri do_cluster clusters;
  pp_epilog fmt () ;
  close_out outc
