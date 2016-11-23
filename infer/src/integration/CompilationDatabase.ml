(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

type compilation_data = {
  dir : string;
  command : string;
  args : string;
}

type t = compilation_data DB.SourceFileMap.t ref
let empty () = ref DB.SourceFileMap.empty

let get_size database = DB.SourceFileMap.cardinal !database

let iter database f = DB.SourceFileMap.iter f !database

let find database key = DB.SourceFileMap.find key !database

let parse_command_and_arguments command_and_arguments =
  let regexp = Str.regexp "[^\\][ ]" in
  let index = Str.search_forward regexp command_and_arguments 0 in
  let command = Str.string_before command_and_arguments (index+1) in
  let arguments = Str.string_after command_and_arguments (index+1) in
  command, arguments

(** Parse the compilation database json file into the compilationDatabase
    map. The json file consists of an array of json objects that contain the file
    to be compiled, the directory to be compiled in, and the compilation command as a list
    and as a string. We pack this information into the compilationDatabase map, and remove the
    clang invocation part, because we will use a clang wrapper. *)
let decode_json_file (database : t) json_path =
  let exit_format_error () =
    failwith ("Json file doesn't have the expected format") in
  let json = Yojson.Basic.from_file json_path in
  let get_dir el =
    match el with
    | ("directory", `String dir) -> Some dir
    | _ -> None in
  let get_file el =
    match el with
    | ("file", `String file) -> Some file
    | _ -> None in
  let get_cmd el =
    match el with
    | ("command", `String cmd) -> Some cmd
    | _ -> None in
  let rec parse_json json =
    match json with
    | `List arguments ->
        IList.iter parse_json arguments
    | `Assoc l ->
        let dir = match IList.find_map_opt get_dir l with
          | Some dir -> dir
          | None -> exit_format_error () in
        let file = match IList.find_map_opt get_file l with
          | Some file -> file
          | None -> exit_format_error () in
        let cmd = match IList.find_map_opt get_cmd l with
          | Some cmd -> cmd
          | None -> exit_format_error () in
        let command, args = parse_command_and_arguments cmd in
        let compilation_data = { dir; command; args;} in
        let source_file = DB.source_file_from_abs_path file in
        database := DB.SourceFileMap.add source_file compilation_data !database
    | _ -> exit_format_error () in
  parse_json json

let from_json_files  db_json_files =
  let db = empty () in
  IList.iter (decode_json_file db) db_json_files;
  db
