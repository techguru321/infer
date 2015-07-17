(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

module L = Logging
module F = Format
open Utils

(** Generic serializer *)
type 'a serializer = (string -> 'a option) * (DB.filename -> 'a option) * (DB.filename -> 'a -> unit)

(** Serialization key, used to distinguish versions of serializers and avoid assert faults *)
type key = int

(** current key for tenv, procedure summary, cfg, error trace, call graph *)
let tenv_key, summary_key, cfg_key, trace_key, cg_key, analysis_results_key, cluster_key = (425184201, 160179325, 1062389858, 221487792, 477305409, 799050016, 579094948)

(** version of the binary files, to be incremented for each change *)
let version = 24

(** Generate random keys, to be used in an ocaml toplevel *)
let generate_keys () =
  Random.self_init ();
  let max_rand_int = 0x3FFFFFFF (* determined by Rand library *) in
  let gen () = Random.int max_rand_int in
  gen (), gen (), gen (), gen (), gen (), gen ()


let create_serializer (key : key) : 'a serializer =
  let match_data ((key': key), (version': int), (value: 'a)) source_msg =
    if key <> key' then
      begin
        L.err "Wrong key in when loading data from %s@\n" source_msg;
        None
      end
    else if version <> version' then
      begin
        L.err "Wrong version in when loading data from %s@\n" source_msg;
        None
      end
    else Some value in
  let from_string (str : string) : 'a option =
    try
      match_data (Marshal.from_string str 0) "string"
    with Sys_error s -> None in
  let from_file (_fname : DB.filename) : 'a option =
    try
      let fname = DB.filename_to_string _fname in
      let inc = open_in_bin fname in
      let value_option = match_data (Marshal.from_channel inc) fname in
      close_in inc;
      value_option
    with Sys_error s -> None in
  let to_file (fname : DB.filename) (value : 'a) =
    let outc = open_out_bin (DB.filename_to_string fname) in
    Marshal.to_channel outc (key, version, value) [];
    close_out outc in
  (from_string, from_file, to_file)


let from_string (serializer : 'a serializer) =
  let (s, _, _) = serializer in s

let from_file (serializer : 'a serializer) =
  let (_, s, _) = serializer in s

let to_file (serializer : 'a serializer) =
  let (_, _, s) = serializer in s
