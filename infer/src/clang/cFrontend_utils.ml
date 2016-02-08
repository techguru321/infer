(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** Module for utility functions for the whole frontend. Includes functions for printing,  *)
(** for transformations of ast nodes and general utility functions such as  functions on lists *)

open Utils

module L = Logging
module F = Format

module Printing =
struct
  let log_out fmt =
    let pp = if !CFrontend_config.debug_mode then Format.fprintf else Format.ifprintf in
    pp Format.std_formatter fmt

  let log_err fmt =
    let pp = if !CFrontend_config.debug_mode then Format.fprintf else Format.ifprintf in
    pp Format.err_formatter fmt


  let annotation_to_string (annotation, _) =
    "< " ^ annotation.Sil.class_name ^ " : " ^
    (IList.to_string (fun x -> x) annotation.Sil.parameters) ^ " >"

  let field_to_string (fieldname, typ, annotation) =
    (Ident.fieldname_to_string fieldname) ^ " " ^
    (Sil.typ_to_string typ) ^  (IList.to_string annotation_to_string annotation)

  let log_stats fmt =
    let pp =
      if !CFrontend_config.stats_mode || !CFrontend_config.debug_mode
      then Format.fprintf else Format.ifprintf in
    pp Format.std_formatter fmt

  let print_tenv tenv =
    Sil.tenv_iter (fun typname typ ->
        match typname with
        | Typename.TN_csu (Csu.Class _, _) | Typename.TN_csu (Csu.Protocol, _) ->
            (match typ with
             | Sil.Tstruct { Sil.instance_fields; superclasses; def_methods; struct_annotations } ->
                 print_endline (
                   (Typename.to_string typname) ^ " " ^
                   (Sil.item_annotation_to_string struct_annotations) ^ "\n" ^
                   "---> superclass and protocols " ^ (IList.to_string (fun tn ->
                       "\t" ^ (Typename.to_string tn) ^ "\n") superclasses) ^
                   "---> methods " ^
                   (IList.to_string (fun x ->"\t" ^ (Procname.to_string x) ^ "\n") def_methods)
                   ^ "  " ^
                   "\t---> fields " ^ (IList.to_string field_to_string instance_fields) ^ "\n")
             | _ -> ())
        | _ -> ()
      ) tenv

  let print_tenv_struct_unions tenv =
    Sil.tenv_iter (fun typname typ ->
        match typname with
        | Typename.TN_csu (Csu.Struct, _) | Typename.TN_csu (Csu.Union, _) ->
            (match typ with
             | Sil.Tstruct { Sil.instance_fields } ->
                 print_endline (
                   (Typename.to_string typname)^"\n"^
                   "\t---> fields "^(IList.to_string (fun (fieldname, typ, _) ->
                       match typ with
                       | Sil.Tvar tname -> "tvar"^(Typename.to_string tname)
                       | Sil.Tstruct _ | _ ->
                           "\t struct "^(Ident.fieldname_to_string fieldname)^" "^
                           (Sil.typ_to_string typ)^"\n") instance_fields
                     )
                 )
             | _ -> ()
            )
        | Typename.TN_typedef typname ->
            print_endline ((Mangled.to_string typname)^"-->"^(Sil.typ_to_string typ))
        | _ -> ()
      ) tenv

  let print_procedures cfg =
    let procs = Cfg.get_all_procs cfg in
    print_endline
      (IList.to_string (fun pdesc ->
           let pname = Cfg.Procdesc.get_proc_name pdesc in
           "name> "^
           (Procname.to_string pname) ^
           " defined? " ^ (string_of_bool (Cfg.Procdesc.is_defined pdesc)) ^ "\n")
          procs)

  let print_failure_info pointer =
    L.err "AST Element> %s IN FILE> %s @.@." pointer !CFrontend_config.json

  let print_nodes nodes =
    IList.iter (fun node -> print_endline (Cfg.Node.get_description Utils.pe_text node)) nodes

  let instrs_to_string instrs =
    let pp fmt () = Format.fprintf fmt "%a" (Sil.pp_instr_list Utils.pe_text) instrs in
    pp_to_string pp ()

end

module Ast_utils =
struct
  type type_ptr_to_sil_type = Sil.tenv -> Clang_ast_t.type_ptr -> Sil.typ

  let string_of_decl decl =
    let name = Clang_ast_proj.get_decl_kind_string decl in
    let info = Clang_ast_proj.get_decl_tuple decl in
    Printf.sprintf "<\"%s\"> '%d'" name info.Clang_ast_t.di_pointer

  let string_of_unary_operator_kind = function
    | `PostInc -> "PostInc"
    | `PostDec -> "PostDec"
    | `PreInc -> "PreInc"
    | `PreDec -> "PreDec"
    | `AddrOf -> "AddrOf"
    | `Deref -> "Deref"
    | `Plus -> "Plus"
    | `Minus -> "Minus"
    | `Not -> "Not"
    | `LNot -> "LNot"
    | `Real -> "Real"
    | `Imag -> "Imag"
    | `Extension -> "Extension"
    | `Coawait -> "Coawait"

  let string_of_stmt stmt =
    let name = Clang_ast_proj.get_stmt_kind_string stmt in
    let info, _ = Clang_ast_proj.get_stmt_tuple stmt in
    Printf.sprintf "<\"%s\"> '%d'" name info.Clang_ast_t.si_pointer

  let get_stmts_from_stmt stmt =
    let open Clang_ast_t in
    match stmt with
    | OpaqueValueExpr (_, lstmt, _, opaque_value_expr_info) ->
        (match opaque_value_expr_info.Clang_ast_t.ovei_source_expr with
         | Some stmt -> lstmt @ [stmt]
         | _ -> lstmt)
    (* given that this has not been translated, looking up for variables *)
    (* inside leads to inconsistencies *)
    | ObjCAtCatchStmt (stmt_info, stmt_list, obj_c_message_expr_kind) ->
        []
    | _ -> snd (Clang_ast_proj.get_stmt_tuple stmt)

  let fold_qual_name qual_name_list =
    match qual_name_list with
    | [] -> ""
    | name :: quals ->
        let s = (IList.fold_right (fun el res -> res ^ el ^ "::") quals "") ^ name in
        let no_slash = Str.global_replace (Str.regexp "/") "_" s in
        no_slash

  let get_qualified_name name_info =
    fold_qual_name name_info.Clang_ast_t.ni_qual_name

  let get_unqualified_name name_info =
    let name = match name_info.Clang_ast_t.ni_qual_name with
      | name :: quals -> name
      | [] -> name_info.Clang_ast_t.ni_name in
    fold_qual_name [name]

  let get_class_name_from_member member_name_info =
    match member_name_info.Clang_ast_t.ni_qual_name with
    | _ :: class_qual_list -> fold_qual_name class_qual_list
    | [] -> assert false

  let make_name_decl name = {
    Clang_ast_t.ni_name = name;
    ni_qual_name = [name];
  }

  let make_qual_name_decl class_name_quals name = {
    Clang_ast_t.ni_name = name;
    ni_qual_name = name :: class_name_quals;
  }

  let property_name property_impl_decl_info =
    let no_property_name = make_name_decl "WARNING_NO_PROPERTY_NAME" in
    match property_impl_decl_info.Clang_ast_t.opidi_property_decl with
    | Some decl_ref ->
        (match decl_ref.Clang_ast_t.dr_name with
         | Some n -> n
         | _ -> no_property_name)
    | None -> no_property_name

  let generated_ivar_name property_name =
    match property_name.Clang_ast_t.ni_qual_name with
    | [name; class_name] ->
        let ivar_name = "_" ^ name in
        { Clang_ast_t.ni_name = ivar_name;
          ni_qual_name = [ivar_name; class_name]
        }
    | _ -> make_name_decl property_name.Clang_ast_t.ni_name

  let property_attribute_compare att1 att2 =
    match att1, att2 with
      `Readonly, `Readonly -> 0
    | `Readonly, _ -> -1
    | _, `Readonly -> 1
    | `Assign, `Assign -> 0
    | `Assign, _ -> -1
    | _, `Assign -> 1
    | `Readwrite, `Readwrite -> 0
    | `Readwrite, _ -> -1
    | _, `Readwrite -> 1
    | `Retain, `Retain -> 0
    | `Retain, _ -> -1
    | _, `Retain -> 1
    | `Copy, `Copy -> 0
    | `Copy, _ -> -1
    | _, `Copy -> 1
    | `Nonatomic, `Nonatomic -> 0
    | `Nonatomic, _ -> -1
    | _, `Nonatomic -> 1
    | `Atomic, `Atomic -> 0
    | `Atomic, _ -> 1
    | _, `Atomic -> 1
    | `Weak, `Weak -> 0
    | `Weak, _ -> -1
    | _, `Weak -> 1
    | `Strong, `Strong -> 0
    | `Strong, _ -> -1
    | _, `Strong -> 1
    | `Unsafe_unretained, `Unsafe_unretained -> 0
    | `Unsafe_unretained, _ -> -1
    | _, `Unsafe_unretained -> 1
    | `ExplicitGetter, `ExplicitGetter -> 0
    | `ExplicitGetter, _ -> -1
    | _, `ExplicitGetter -> 1
    | `ExplicitSetter, `ExplicitSetter -> 0

  let property_attribute_eq att1 att2 =
    property_attribute_compare att1 att2 = 0

  let get_memory_management_attributes () =
    [`Assign; `Retain; `Copy; `Weak; `Strong; `Unsafe_unretained]

  let is_retain attribute_opt =
    match attribute_opt with
    | Some attribute ->
        attribute = `Retain || attribute = `Strong
    | _ -> false

  let is_copy attribute_opt =
    match attribute_opt with
    | Some attribute ->
        attribute = `Copy
    | _ -> false

  let name_opt_of_name_info_opt name_info_opt =
    match name_info_opt with
    | Some name_info -> Some (get_qualified_name name_info)
    | None -> None

  let rec getter_attribute_opt attributes =
    match attributes with
    | [] -> None
    | attr:: rest ->
        match attr with
        | `Getter getter -> getter.Clang_ast_t.dr_name
        | _ -> (getter_attribute_opt rest)

  let rec setter_attribute_opt attributes =
    match attributes with
    | [] -> None
    | attr:: rest ->
        match attr with
        | `Setter setter -> setter.Clang_ast_t.dr_name
        | _ -> (setter_attribute_opt rest)

  let pointer_counter = ref 0

  let get_fresh_pointer () =
    pointer_counter := !pointer_counter + 1;
    let internal_pointer = -(!pointer_counter) in
    internal_pointer

  let get_invalid_pointer () =
    CFrontend_config.invalid_pointer

  let type_from_unary_expr_or_type_trait_expr_info info =
    match info.Clang_ast_t.uttei_type_ptr with
    | Some tp -> Some tp
    | None -> None

  let get_decl decl_ptr =
    try
      Some (Clang_ast_main.PointerMap.find decl_ptr !CFrontend_config.pointer_decl_index)
    with Not_found -> Printing.log_stats "decl with pointer %d not found\n" decl_ptr; None

  let get_decl_opt decl_ptr_opt =
    match decl_ptr_opt with
    | Some decl_ptr -> get_decl decl_ptr
    | None -> None

  let get_decl_opt_with_decl_ref decl_ref_opt =
    match decl_ref_opt with
    | Some decl_ref -> get_decl decl_ref.Clang_ast_t.dr_decl_pointer
    | None -> None

  let update_sil_types_map type_ptr sil_type =
    CFrontend_config.sil_types_map :=
      Clang_ast_types.TypePointerMap.add type_ptr sil_type !CFrontend_config.sil_types_map

  let update_enum_map enum_constant_pointer sil_exp =
    let open Clang_ast_main in
    let (predecessor_pointer_opt, sil_exp_opt) =
      try PointerMap.find enum_constant_pointer !CFrontend_config.enum_map
      with Not_found -> assert false in
    let enum_map_value = (predecessor_pointer_opt, Some sil_exp) in
    CFrontend_config.enum_map :=
      PointerMap.add enum_constant_pointer enum_map_value !CFrontend_config.enum_map

  let add_enum_constant enum_constant_pointer predecessor_pointer_opt =
    let enum_map_value = (predecessor_pointer_opt, None) in
    CFrontend_config.enum_map :=
      Clang_ast_main.PointerMap.add enum_constant_pointer enum_map_value !CFrontend_config.enum_map

  let get_enum_constant_exp enum_constant_pointer =
    Clang_ast_main.PointerMap.find enum_constant_pointer !CFrontend_config.enum_map

  let get_type type_ptr =
    try
      (* There is chance for success only if type_ptr is in fact clang pointer *)
      (let raw_ptr = Clang_ast_types.type_ptr_to_clang_pointer type_ptr in
       try
         Some (Clang_ast_main.PointerMap.find raw_ptr !CFrontend_config.pointer_type_index)
       with Not_found -> Printing.log_stats "type with pointer %d not found\n" raw_ptr; None)
    with Clang_ast_types.Not_Clang_Pointer ->
      (* otherwise, function fails *)
      let type_str = Clang_ast_types.type_ptr_to_string type_ptr in
      Printing.log_stats "type %s is not clang pointer\n" type_str;
      None

  let get_desugared_type type_ptr =
    let typ_opt = get_type type_ptr in
    match typ_opt with
    | Some typ ->
        let type_info = Clang_ast_proj.get_type_tuple typ in
        (match type_info.Clang_ast_t.ti_desugared_type with
         | Some ptr -> get_type ptr
         | _ -> typ_opt)
    | _ -> typ_opt

  let get_decl_from_typ_ptr typ_ptr =
    let typ_opt = get_desugared_type typ_ptr in
    let typ = match typ_opt with Some t -> t | _ -> assert false in
    (* it needs extending to handle objC types *)
    match typ with
    | Clang_ast_t.RecordType (ti, decl_ptr) -> get_decl decl_ptr
    | _ -> None

  (*TODO take the attributes into account too. To be done after we get the attribute's arguments. *)
  let is_type_nonnull type_ptr =
    let open Clang_ast_t in
    match get_type type_ptr with
    | Some AttributedType (_, attr_info) -> attr_info.ati_attr_kind = `Nonnull
    | _ -> false

  let is_type_nullable type_ptr =
    let open Clang_ast_t in
    match get_type type_ptr with
    | Some AttributedType (_, attr_info) -> attr_info.ati_attr_kind = `Nullable
    | _ -> false

  let string_of_type_ptr type_ptr =
    match get_desugared_type type_ptr with
    | Some typ -> (Clang_ast_proj.get_type_tuple typ).Clang_ast_t.ti_raw
    | None -> ""

  let add_type_from_decl_ref type_ptr_to_sil_type tenv decl_ref_opt fail_if_not_found =
    match decl_ref_opt with (* translate interface first if found *)
    | Some dr ->
        ignore (type_ptr_to_sil_type tenv (`DeclPtr dr.Clang_ast_t.dr_decl_pointer));
    | _ -> if fail_if_not_found then assert false else ()

  let add_type_from_decl_ref_list type_ptr_to_sil_type tenv decl_ref_list =
    let add_elem dr =
      ignore (type_ptr_to_sil_type tenv (`DeclPtr dr.Clang_ast_t.dr_decl_pointer)) in
    IList.iter add_elem decl_ref_list

end

(* Global counter for anonymous block*)
let block_counter = ref 0

(* Returns a fresh index for a new anonymous block *)
let get_fresh_block_index () =
  block_counter := !block_counter +1;
  !block_counter

module General_utils =
struct

  type warning_desc = {
    name : string;
    description : string;
    suggestion : string; (* an optional suggestion or correction *)
    loc : Location.t;
  }

  type var_info = Clang_ast_t.decl_info * Clang_ast_t.type_ptr * Clang_ast_t.var_decl_info * bool

  let rec swap_elements_list l =
    match l with
    | el1:: el2:: rest ->
        el2:: el1:: (swap_elements_list rest)
    | [] -> []
    | _ -> assert false

  let rec string_from_list l =
    match l with
    | [] -> ""
    | [item] -> item
    | item:: l' -> item^" "^(string_from_list l')

  let get_fun_body fdecl_info = fdecl_info.Clang_ast_t.fdi_body

  let rec append_no_duplicates eq list1 list2 =
    match list2 with
    | el:: rest2 ->
        if (IList.mem eq el list1) then
          (append_no_duplicates eq list1 rest2)
        else (append_no_duplicates eq list1 rest2)@[el]
    | [] -> list1

  let append_no_duplicates_csu list1 list2 =
    append_no_duplicates Typename.equal list1 list2

  let append_no_duplicates_methods list1 list2 =
    append_no_duplicates Procname.equal list1 list2

  let append_no_duplicated_vars list1 list2 =
    let eq (m1, t1) (m2, t2) = (Mangled.equal m1 m2) && (Sil.typ_equal t1 t2) in
    append_no_duplicates eq list1 list2

  let append_no_duplicated_pvars list1 list2 =
    let eq (e1, t1) (e2, t2) = (Sil.exp_equal e1 e2) && (Sil.typ_equal t1 t2) in
    append_no_duplicates eq list1 list2


  let append_no_duplicates_annotations list1 list2 =
    let eq (annot1, _) (annot2, _) = annot1.Sil.class_name = annot2.Sil.class_name in
    append_no_duplicates eq list1 list2

  let add_no_duplicates_fields field_tuple l =
    let rec replace_field field_tuple l found =
      match field_tuple, l with
      | (field, typ, annot), ((old_field, old_typ, old_annot) as old_field_tuple :: rest) ->
          let ret_list, ret_found = replace_field field_tuple rest found in
          if Ident.fieldname_equal field old_field && Sil.typ_equal typ old_typ then
            let annotations = append_no_duplicates_annotations annot old_annot in
            (field, typ, annotations) :: ret_list, true
          else old_field_tuple :: ret_list, ret_found
      | _, [] -> [], found in
    let new_list, found = replace_field field_tuple l false in
    if found then new_list
    else field_tuple :: l

  let rec append_no_duplicates_fields list1 list2 =
    match list1 with
    | field_tuple :: rest ->
        let updated_list2 = append_no_duplicates_fields rest list2 in
        add_no_duplicates_fields field_tuple updated_list2
    | [] -> list2

  let sort_fields fields =
    let compare (name1, _, _) (name2, _, _) =
      Ident.fieldname_compare name1 name2 in
    IList.sort compare fields

  let rec collect_list_tuples l (a, a1, b, c, d) =
    match l with
    | [] -> (a, a1, b, c, d)
    | (a', a1', b', c', d'):: l' -> collect_list_tuples l' (a@a', a1@a1', b@b', c@c', d@d')

  let is_static_var var_decl_info =
    match var_decl_info.Clang_ast_t.vdi_storage_class with
    | Some sc -> sc = CFrontend_config.static
    | _ -> false

  let block_procname_with_index defining_proc i =
    Config.anonymous_block_prefix^(Procname.to_string defining_proc)^Config.anonymous_block_num_sep^(string_of_int i)

  (* Makes a fresh name for a block defined inside the defining procedure.*)
  (* It updates the global block_counter *)
  let mk_fresh_block_procname defining_proc =
    let name = block_procname_with_index defining_proc (get_fresh_block_index ()) in
    Procname.mangled_objc_block name

  (* Returns the next fresh name for a block defined inside the defining procedure *)
  (* It does not update the global block_counter *)
  let get_next_block_pvar defining_proc =
    let name = block_procname_with_index defining_proc (!block_counter +1) in
    Sil.mk_pvar (Mangled.from_string (CFrontend_config.temp_var^"_"^name)) defining_proc

  (* Reset  block counter *)
  let reset_block_counter () =
    block_counter := 0

  let mk_function_decl_info_from_block block_decl_info =
    {
      Clang_ast_t.fdi_storage_class = None;
      Clang_ast_t.fdi_is_inline = true; (* This value should not matter as we don't use it*)
      Clang_ast_t.fdi_is_module_private = true; (* This value should not matter as we don't use it*)
      Clang_ast_t.fdi_is_pure = false; (* This value should not matter as we don't use it*)
      Clang_ast_t.fdi_is_delete_as_written = false; (* This value should not matter as we don't use it*)
      Clang_ast_t.fdi_decls_in_prototype_scope =[];
      Clang_ast_t.fdi_parameters = block_decl_info.Clang_ast_t.bdi_parameters;
      Clang_ast_t.fdi_body = block_decl_info.Clang_ast_t.bdi_body;
    }

  let rec zip xs ys =
    match xs, ys with
    | [], _
    | _, [] -> []
    | x :: xs, y :: ys -> (x, y) :: zip xs ys

  let list_range i j =
    let rec aux n acc =
      if n < i then acc else aux (n -1) (n :: acc)
    in aux j [] ;;

  let replicate n el = IList.map (fun i -> el) (list_range 0 (n -1))

  let mk_class_field_name field_qual_name =
    let field_name = field_qual_name.Clang_ast_t.ni_name in
    let class_name = Ast_utils.get_class_name_from_member field_qual_name in
    Ident.create_fieldname (Mangled.mangled field_name class_name) 0

  let get_rel_file_path file_opt =
    match file_opt with
    | Some file ->
        (match !Config.project_root with
         | Some root ->
             DB.source_file_to_rel_path (DB.rel_source_file_from_abs_path root file)
         | None -> file)
    | None -> ""

  let mk_procname_from_function name function_decl_info_opt tp language =
    let file =
      match function_decl_info_opt with
      | Some (decl_info, function_decl_info) ->
          (match function_decl_info.Clang_ast_t.fdi_storage_class with
           | Some "static" ->
               let file_opt = (fst decl_info.Clang_ast_t.di_source_range).Clang_ast_t.sl_file in
               get_rel_file_path file_opt
           | _ -> "")
      | None -> "" in
    let type_string =
      match language with
      | CFrontend_config.CPP
      | CFrontend_config.OBJCPP -> Ast_utils.string_of_type_ptr tp
      | _ -> "" in
    let mangled = file ^ type_string in
    if String.length mangled == 0 then
      Procname.from_string_c_fun name
    else
      let crc = string_crc_hex32 mangled in
      Procname.mangled_c_fun name crc

  let mk_procname_from_objc_method class_name method_name method_kind =
    let mangled = Procname.mangled_of_objc_method_kind method_kind in
    Procname.mangled_c_method class_name method_name mangled

  let mk_procname_from_cpp_method class_name method_name tp =
    let type_name = Ast_utils.string_of_type_ptr tp in
    let type_name_crc = Some (string_crc_hex32 type_name) in
    Procname.mangled_c_method class_name method_name type_name_crc

  let get_var_name_string name_info var_decl_info =
    let clang_name = Ast_utils.get_qualified_name name_info in
    match clang_name, var_decl_info.Clang_ast_t.vdi_parm_index_in_function with
    | "", Some index -> "__param_" ^ string_of_int index
    | "", None -> assert false
    | _ -> clang_name

  let mk_sil_var name decl_info_type_ptr_opt procname outer_procname =
    let name_string = Ast_utils.get_qualified_name name in
    match decl_info_type_ptr_opt with
    | Some (decl_info, type_ptr, var_decl_info, should_be_mangled) ->
        let name_string = get_var_name_string name var_decl_info in
        let simple_name = Mangled.from_string name_string in
        if var_decl_info.Clang_ast_t.vdi_is_global then
          let global_mangled_name =
            if var_decl_info.Clang_ast_t.vdi_is_static_local then
              Mangled.from_string ((Procname.to_string outer_procname) ^ "_" ^ name_string)
            else simple_name in
          Sil.mk_pvar_global global_mangled_name
        else if not should_be_mangled then Sil.mk_pvar simple_name procname
        else
          let type_name = Ast_utils.string_of_type_ptr type_ptr in
          let start_location = fst decl_info.Clang_ast_t.di_source_range in
          let line_opt = start_location.Clang_ast_t.sl_line in
          let line_str = match line_opt with | Some line -> string_of_int line | None -> "" in
          let mangled = string_crc_hex32 (type_name ^ line_str) in
          let mangled_name = Mangled.mangled name_string mangled in
          Sil.mk_pvar mangled_name procname
    | None -> Sil.mk_pvar (Mangled.from_string name_string) procname

  let is_cpp_translation language =
    language = CFrontend_config.CPP || language = CFrontend_config.OBJCPP
end




