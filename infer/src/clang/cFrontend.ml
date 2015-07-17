(*
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(** Translate one file into a cfg. Create a tenv, cg and cfg file for a source file    *)
(** given its ast in json format. Translate the json file into a cfg by adding all     *)
(** the type and class declarations to the tenv, adding all the functions and methods  *)
(** declarations as procdescs to the cfg, and adding the control flow graph of all the *)
(** code of those functions and methods to the cfg   *)

module L = Logging

open Utils
open CFrontend_utils
open CGen_trans
open Clang_ast_t

(* Translate one global declaration *)
let rec translate_one_declaration tenv cg cfg namespace dec =
  let ns_suffix = Ast_utils.namespace_to_string namespace in
  let info = Clang_ast_proj.get_decl_tuple dec in
  CLocation.update_curr_file info;
  let source_range = info.Clang_ast_t.di_source_range in
  let should_translate_enum = CLocation.should_translate_enum source_range in
  match dec with
  | FunctionDecl(di, name_info, qt, fdecl_info) ->
      let name = name_info.Clang_ast_t.ni_name in
      CMethod_declImpl.function_decl tenv cfg cg namespace false di name qt fdecl_info [] None CContext.ContextNoCls
  | TypedefDecl (decl_info, name_info, opt_type, typedef_decl_info) ->
      let name = name_info.Clang_ast_t.ni_name in
      CTypes_decl.do_typedef_declaration tenv namespace
        decl_info name opt_type typedef_decl_info
  (* Currently C/C++ record decl treated in the same way *)
  | CXXRecordDecl (decl_info, name_info, opt_type, decl_list, decl_context_info, record_decl_info)
  | RecordDecl (decl_info, name_info, opt_type, decl_list, decl_context_info, record_decl_info) ->
      let record_name = name_info.Clang_ast_t.ni_name in
      CTypes_decl.do_record_declaration tenv namespace
        decl_info record_name opt_type decl_list decl_context_info record_decl_info

  | VarDecl(decl_info, name_info, t, _) ->
      let name = name_info.Clang_ast_t.ni_name in
      CVar_decl.global_var_decl tenv namespace decl_info name t

  | ObjCInterfaceDecl(decl_info, name_info, decl_list, decl_context_info, obj_c_interface_decl_info) ->
      let name = name_info.Clang_ast_t.ni_name in
      let curr_class =
        ObjcInterface_decl.interface_declaration tenv name decl_list obj_c_interface_decl_info in
      CMethod_declImpl.process_methods tenv cg cfg curr_class namespace decl_list

  | ObjCProtocolDecl(decl_info, name_info, decl_list, decl_context_info, obj_c_protocol_decl_info) ->
      let name = name_info.Clang_ast_t.ni_name in
      let curr_class = ObjcProtocol_decl.protocol_decl tenv name decl_list in
      CMethod_declImpl.process_methods tenv cg cfg curr_class namespace decl_list

  | ObjCCategoryDecl(decl_info, name_info, decl_list, decl_context_info, category_decl_info) ->
      let name = name_info.Clang_ast_t.ni_name in
      let curr_class =
        ObjcCategory_decl.category_decl tenv name category_decl_info decl_list in
      CMethod_declImpl.process_methods tenv cg cfg curr_class namespace decl_list

  | ObjCCategoryImplDecl(decl_info, name_info, decl_list, decl_context_info, category_impl_info) ->
      let name = name_info.Clang_ast_t.ni_name in
      let curr_class =
        ObjcCategory_decl.category_impl_decl tenv name decl_info category_impl_info decl_list in
      CMethod_declImpl.process_methods tenv cg cfg curr_class namespace decl_list

  | ObjCImplementationDecl(decl_info, name_info, decl_list, decl_context_info, idi) ->
      let name = name_info.Clang_ast_t.ni_name in
      let curr_class =
        ObjcInterface_decl.interface_impl_declaration tenv name decl_list idi in
      CMethod_declImpl.process_methods tenv cg cfg curr_class namespace decl_list

  | EnumDecl(decl_info, name_info, opt_type, decl_list, decl_context_info, enum_decl_info)
  when should_translate_enum ->
      let name = name_info.Clang_ast_t.ni_name in
      CEnum_decl.enum_decl name tenv cfg cg namespace decl_list opt_type

  | LinkageSpecDecl(decl_info, decl_list, decl_context_info) ->
      Printing.log_out "ADDING: LinkageSpecDecl decl list\n";
      list_iter (translate_one_declaration tenv cg cfg namespace) decl_list
  | NamespaceDecl(decl_info, name_info, decl_list, decl_context_info, _) ->
      let name = ns_suffix^name_info.Clang_ast_t.ni_name in
      list_iter (translate_one_declaration tenv cg cfg (Some name)) decl_list
  | EmptyDecl _ ->
      Printing.log_out "Passing from EmptyDecl. Treated as skip\n";
  | dec ->
      Printing.log_stats "\nWARNING: found Declaration %s skipped\n" (Ast_utils.string_of_decl dec)

(** Preprocess declarations to create method signatures of function declarations. *)
let preprocess_one_declaration tenv cg cfg dec =
  let info = Clang_ast_proj.get_decl_tuple dec in
  CLocation.update_curr_file info;
  match dec with
  | FunctionDecl(di, name_info, qt, fdecl_info) ->
      let name = name_info.Clang_ast_t.ni_name in
      ignore (CMethod_declImpl.create_function_signature di fdecl_info name qt false None)
  | _ -> ()

(* Translates a file by translating the ast into a cfg. *)
let compute_icfg tenv source_file ast =
  match ast with
  | TranslationUnitDecl(_, decl_list, _) ->
      CFrontend_config.global_translation_unit_decls:= decl_list;
      Printing.log_out "\n Start creating icfg\n";
      let cg = Cg.create () in
      let cfg = Cfg.Node.create_cfg () in
      list_iter (preprocess_one_declaration tenv cg cfg) decl_list;
      list_iter (translate_one_declaration tenv cg cfg None) decl_list;
      Printing.log_out "\n Finished creating icfg\n";
      (cg, cfg)
  | _ -> assert false (* NOTE: Assumes that an AST alsways starts with a TranslationUnitDecl *)

let init_global_state source_file =
  Sil.curr_language := Sil.C_CPP;
  DB.current_source := source_file;
  DB.Results_dir.init ();
  Ident.reset_name_generator ();
  CMethod_signature.reset_map ();
  CGlobal_vars.reset_map ();
  CFrontend_config.global_translation_unit_decls := [];
  ObjcProperty_decl.reset_property_table ();
  CFrontend_utils.General_utils.reset_block_counter ()

let do_source_file source_file ast =
  let tenv = Sil.create_tenv () in
  CTypes_decl.add_predefined_types tenv;
  init_global_state source_file;
  CLocation.init_curr_source_file source_file;
  Config.nLOC := FileLOC.file_get_loc (DB.source_file_to_string source_file);
  Printing.log_out "\n Start building call/cfg graph for '%s'....\n"
    (DB.source_file_to_string source_file);
  let call_graph, cfg = compute_icfg tenv (DB.source_file_to_string source_file) ast in
  Printing.log_out "\n End building call/cfg graph for '%s'.\n"
    (DB.source_file_to_string source_file);
  (* This part below is a boilerplate in every frontends. *)
  (* This could be moved in the cfg_infer module *)
  let source_dir = DB.source_dir_from_source_file !DB.current_source in
  let tenv_file = DB.source_dir_get_internal_file source_dir ".tenv" in
  let cfg_file = DB.source_dir_get_internal_file source_dir ".cfg" in
  let cg_file = DB.source_dir_get_internal_file source_dir ".cg" in
  Cfg.add_removetemps_instructions cfg;
  Preanal.doit cfg tenv;
  Cfg.add_abstraction_instructions cfg;
  Cg.store_to_file cg_file call_graph;
  Cfg.store_cfg_to_file cfg_file true cfg;
  (*Logging.out "Tenv %a@." Sil.pp_tenv tenv;*)
  (*Printing.print_tenv tenv;*)
  (*Printing.print_procedures cfg; *)
  Sil.store_tenv_to_file tenv_file tenv;
  if !CFrontend_config.stats_mode then Cfg.check_cfg_connectedness cfg;
  if !CFrontend_config.stats_mode || !CFrontend_config.debug_mode || !CFrontend_config.testing_mode then
    (Dotty.print_icfg_dotty cfg [];
      Cg.save_call_graph_dotty None Specs.get_specs call_graph)

