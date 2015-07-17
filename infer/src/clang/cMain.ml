(*
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(* Take as input an ast file and a C or ObjectiveC file such that the ast file
corresponds to the compilation of the C file with clang.
Parse the ast file into a data structure and translates it into a cfg. *)

module L = Logging

open Clang_ast_j
open CFrontend_config
open CFrontend_utils

let arg_desc =
  let base_arg =
    let options_to_keep = ["-results_dir"] in
    Config.dotty_cfg_libs := false; (* default behavior for this frontend *)
    let filter arg_desc =
      List.filter (fun desc -> let (option_name, _, _, _) = desc in List.mem option_name options_to_keep) arg_desc in
    let desc =
      (filter Utils.base_arg_desc) @
      [
      "-c",
      Arg.String (fun cfile -> source_file := Some cfile),
      Some "cfile",
      "C File to translate";
      "-x",
      Arg.String (fun lang -> CFrontend_config.lang_from_string lang),
      Some "cfile",
      "Language (c, objective-c, c++, objc-++)";
      "-ast",
      Arg.String (fun file -> ast_file := Some file),
      Some "file",
      "AST file for the translation";
      "-dotty_cfg_libs",
      Arg.Unit (fun _ -> Config.dotty_cfg_libs := true),
      None,
      "Prints the cfg of the code coming from the libraries";
      "-no_headers",
      Arg.Unit (fun _ -> CFrontend_config.no_translate_libs := true),
      None,
      "Do not translate code in header files (default)";
      "-headers",
      Arg.Unit (fun _ -> CFrontend_config.no_translate_libs := false),
      None,
      "Translate code in header files";
      "-testing_mode",
      Arg.Unit (fun _ -> CFrontend_config.testing_mode := true),
      None,
      "Mode for testing, where no libraries are translated, including enums defined in the libraries";
      "-debug",
      Arg.Unit (fun _ -> CFrontend_config.debug_mode := true),
      None,
      "Enables debug mode";
      "-stats",
      Arg.Unit (fun _ -> CFrontend_config.stats_mode := true),
      None,
      "Enables stats mode";
      "-project_root",
      Arg.String (fun s ->
            Config.project_root := Some (Utils.filename_to_absolute s)),
      Some "dir",
      "Toot directory of the project";
      "-fobjc-arc",
      Arg.Unit (fun s -> Config.arc_mode := true),
      None,
      "Translate with Objective-C Automatic Reference Counting (ARC)";
      "-models_mode",
      Arg.Unit (fun _ -> CFrontend_config.models_mode := true),
      None,
      "Mode for computing the models";
      ] in
    Utils.Arg2.create_options_desc false "Parsing Options" desc in
  base_arg

let usage =
  "\nUsage: InferClang -c C Files -ast AST Files -results_dir <output-dir> [options] \n"

let print_usage_exit () =
  Utils.Arg2.usage arg_desc usage;
  exit(1)

let () =
  Utils.Arg2.parse arg_desc (fun arg -> ()) usage

(* This function reads the json file in fname, validates it, and encoded in the AST data structure*)
(* defined in Clang_ast_t.  *)
let validate_decl_from_file fname =
  Ag_util.Json.from_file Clang_ast_j.read_decl fname

let validate_decl_from_stdin () =
  Ag_util.Json.from_channel Clang_ast_j.read_decl stdin

let do_run source_path ast_path =
  try
    let ast_filename, ast_decl =
      match ast_path with
      | Some path -> path, validate_decl_from_file path
      | None -> "stdin of " ^ source_path, validate_decl_from_stdin () in

    let ast_decl' = CAstProcessor.preprocess_ast_decl ast_decl in
    Printing.log_out "Original AST@.%a@." CAstProcessor.pp_ast_decl ast_decl;
    Printing.log_out "AST with explicit locations:@.%a@." CAstProcessor.pp_ast_decl ast_decl';

    CFrontend_config.pointer_decl_index := Clang_ast_main.index_decl_pointers ast_decl';
    CFrontend_config.json := ast_filename;
    CLocation.check_source_file source_path;
    let source_file = CLocation.source_file_from_path source_path in
    print_endline ("Start translation of AST from " ^ !CFrontend_config.json);
    CFrontend.do_source_file source_file ast_decl';
    print_endline ("End translation AST file " ^ !CFrontend_config.json ^ "... OK!")
  with
    (Yojson.Json_error s) as exc -> Printing.log_err "%s\n" s;
      raise exc

let _ =
  Config.print_types:= true;
  if Option.is_none !source_file then
    (Printing.log_err "Incorrect command line arguments\n";
      print_usage_exit ())
  else
    match !source_file with
    | Some path -> do_run path !ast_file
    | None -> assert false
