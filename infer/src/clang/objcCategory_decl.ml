(*
* Copyright (c) 2013 - Facebook.
* All rights reserved.
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
  | Some n -> n
  | _ -> assert false

let get_class_from_category_decl category_decl_info =
  match category_decl_info.Clang_ast_t.odi_class_interface with
  | Some dr -> cat_class_decl dr
  | _ -> assert false

let get_class_from_category_impl category_impl_info =
  match category_impl_info.Clang_ast_t.ocidi_class_interface with
  | Some dr -> cat_class_decl dr
  | _ -> assert false

let get_category_name_from_category_impl category_impl_info =
  match category_impl_info.Clang_ast_t.ocidi_category_decl with
  | Some dr -> cat_class_decl dr
  | _ -> assert false

(* Add potential extra fields defined only in the category *)
(* to the corresponding class. Update the tenv accordingly.*)
let process_category tenv name class_name decl_list =
  let name = if name ="" then noname_category class_name else name in
  Printing.log_out "Now name is '%s'\n" name;
  let curr_class = CContext.ContextCategory (name, class_name) in
  let fields = CField_decl.get_fields tenv curr_class decl_list in
  let methods = ObjcProperty_decl.get_methods curr_class decl_list in
  let mang_name = Mangled.from_string class_name in
  let class_tn_name = Sil.TN_csu (Sil.Class, mang_name) in
  match Sil.tenv_lookup tenv class_tn_name with
  | Some Sil.Tstruct (intf_fields, _, _, _, superclass, intf_methods, annotation) ->
      let new_fields = General_utils.append_no_duplicates_fields fields intf_fields in
      let new_fields = CFrontend_utils.General_utils.sort_fields new_fields in
      let new_methods = General_utils.append_no_duplicates_methods methods intf_methods in
      let class_type_info =
        Sil.Tstruct (
          new_fields, [], Sil.Class, Some mang_name, superclass, new_methods, annotation
        ) in
      Printing.log_out " Updating info for class '%s' in tenv\n" class_name;
      Sil.tenv_add tenv class_tn_name class_type_info;
      curr_class
  | _ -> assert false

let category_decl tenv name category_decl_info decl_list =
  Printing.log_out "ADDING: ObjCCategoryDecl for '%s'\n" name;
  let class_name = get_class_from_category_decl category_decl_info in
  process_category tenv name class_name decl_list

let category_impl_decl tenv name decl_info category_impl_decl_info decl_list =
  let category_name = get_category_name_from_category_impl category_impl_decl_info in
  Printing.log_out "ADDING: ObjCCategoryImplDecl for '%s'\n" category_name;
  let cat_class = get_class_from_category_impl category_impl_decl_info in
  process_category tenv category_name cat_class decl_list

