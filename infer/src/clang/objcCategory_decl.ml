(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open Utils
open CFrontend_utils

module L = Logging

(** In this module an ObjC category declaration or implementation is processed. The category    *)
(** is saved in the tenv as a struct with the corresponding fields and methods , and the class it belongs to *)

(* Name used for category with no name, i.e., "" *)
let noname_category class_name =
  CFrontend_config.emtpy_name_category^class_name

let cat_class_decl dr =
  match dr.Clang_ast_t.dr_name with
  | Some n -> n.Clang_ast_t.ni_name
  | _ -> assert false

let get_curr_class_from_category name decl_ref_opt =
  match decl_ref_opt with
  | Some dr ->
      let class_name = cat_class_decl dr in
      CContext.ContextCategory (name, class_name)
  | _ -> assert false

let get_curr_class_from_category_decl name ocdi =
  get_curr_class_from_category name ocdi.Clang_ast_t.odi_class_interface

let get_curr_class_from_category_impl name ocidi =
  get_curr_class_from_category name ocidi.Clang_ast_t.ocidi_class_interface

let add_category_decl type_ptr_to_sil_type tenv category_impl_info =
  let decl_ref_opt = category_impl_info.Clang_ast_t.ocidi_category_decl in
  Ast_utils.add_type_from_decl_ref type_ptr_to_sil_type tenv decl_ref_opt true

let add_class_decl type_ptr_to_sil_type tenv category_decl_info =
  let decl_ref_opt = category_decl_info.Clang_ast_t.odi_class_interface in
  Ast_utils.add_type_from_decl_ref type_ptr_to_sil_type tenv decl_ref_opt true

let add_category_implementation type_ptr_to_sil_type tenv category_decl_info =
  let decl_ref_opt = category_decl_info.Clang_ast_t.odi_implementation in
  Ast_utils.add_type_from_decl_ref type_ptr_to_sil_type tenv decl_ref_opt false

(* Add potential extra fields defined only in the category *)
(* to the corresponding class. Update the tenv accordingly.*)
let process_category type_ptr_to_sil_type tenv curr_class decl_info decl_list =
  let fields = CField_decl.get_fields type_ptr_to_sil_type tenv curr_class decl_list in
  let methods = ObjcProperty_decl.get_methods curr_class decl_list in
  let class_name = CContext.get_curr_class_name curr_class in
  let mang_name = Mangled.from_string class_name in
  let class_tn_name = Sil.TN_csu (Sil.Class, mang_name) in
  let decl_key = `DeclPtr decl_info.Clang_ast_t.di_pointer in
  Ast_utils.update_sil_types_map decl_key (Sil.Tvar class_tn_name);
  (match Sil.tenv_lookup tenv class_tn_name with
   | Some Sil.Tstruct (intf_fields, _, _, _, superclass, intf_methods, annotation) ->
       let new_fields = General_utils.append_no_duplicates_fields fields intf_fields in
       let new_fields = CFrontend_utils.General_utils.sort_fields new_fields in
       let new_methods = General_utils.append_no_duplicates_methods methods intf_methods in
       let class_type_info =
         Sil.Tstruct (
           new_fields, [], Sil.Class, Some mang_name, superclass, new_methods, annotation
         ) in
       Printing.log_out " Updating info for class '%s' in tenv\n" class_name;
       Sil.tenv_add tenv class_tn_name class_type_info
   | _ -> ());
  Sil.Tvar class_tn_name

let category_decl type_ptr_to_sil_type tenv decl =
  let open Clang_ast_t in
  match decl with
  | ObjCCategoryDecl (decl_info, name_info, decl_list, decl_context_info, cdi) ->
      let name = name_info.Clang_ast_t.ni_name in
      let curr_class = get_curr_class_from_category_decl name cdi in
      Printing.log_out "ADDING: ObjCCategoryDecl for '%s'\n" name;
      let _ = add_class_decl type_ptr_to_sil_type tenv cdi in
      let typ = process_category type_ptr_to_sil_type tenv curr_class decl_info decl_list in
      let _ = add_category_implementation type_ptr_to_sil_type tenv cdi in
      typ
  | _ -> assert false

let category_impl_decl type_ptr_to_sil_type tenv decl =
  let open Clang_ast_t in
  match decl with
  | ObjCCategoryImplDecl (decl_info, name_info, decl_list, decl_context_info, cii) ->
      let name = name_info.Clang_ast_t.ni_name in
      let curr_class = get_curr_class_from_category_impl name cii in
      Printing.log_out "ADDING: ObjCCategoryImplDecl for '%s'\n" name;
      let _ = add_category_decl type_ptr_to_sil_type tenv cii in
      let typ = process_category type_ptr_to_sil_type tenv curr_class decl_info decl_list in
      typ
  | _ -> assert false

