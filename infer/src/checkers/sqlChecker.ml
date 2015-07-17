(*
* Copyright (c) 2014 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

open Utils

module L = Logging


(** Find SQL statements in string concatenations *)
let callback_sql all_procs get_proc_desc idenv tenv proc_name proc_desc =
  let verbose = false in

  (* Case insensitive SQL statement patterns *)
  let sql_start =
    let _sql_start = [
      "select.*from.*";
      "insert into.*";
      "update .* set.*";
      "delete .* from.*";
      ] in
    list_map Str.regexp_case_fold _sql_start in

  (* Check for SQL string concatenations *)
  let do_instr const_map node = function
    | Sil.Call (_, Sil.Const (Sil.Cfun pn), (Sil.Var i1, _):: (Sil.Var i2, _):: [], l, _)
    when Procname.java_get_class pn = "java.lang.StringBuilder"
    && Procname.java_get_method pn = "append" ->
        let rvar1 = Sil.Var i1 in
        let rvar2 = Sil.Var i2 in
        begin
          let matches s r = Str.string_match r s 0 in
          match const_map node rvar1, const_map node rvar2 with
          | Some (Sil.Cstr ""), Some (Sil.Cstr s2) ->
              if list_exists (matches s2) sql_start then
                begin
                  L.stdout
                    "%s%s@."
                    "Possible SQL query using string concatenation. "
                    "Please consider using a prepared statement instead.";
                  let linereader = Printer.LineReader.create () in
                  L.stdout "%a@." (Checkers.PP.pp_loc_range linereader 2 2) l
                end
          | _ -> ()
        end
    | _ -> () in

  try
    let const_map = ConstantPropagation.build_const_map proc_desc in
    if verbose then L.stdout "Analyzing %a...\n@." Procname.pp proc_name;
    Cfg.Procdesc.iter_instrs (do_instr const_map) proc_desc
  with _ -> ()
