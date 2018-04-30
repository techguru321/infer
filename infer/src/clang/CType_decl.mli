(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

module CProcname : sig
  val from_decl : ?tenv:Tenv.t -> is_cpp:bool -> Clang_ast_t.decl -> Typ.Procname.t
  (** Given decl, return its procname. This function should be used for all procedures
      present in original AST *)

  val from_decl_for_linters : is_cpp:bool -> Clang_ast_t.decl -> Typ.Procname.t
  (** This is used for bug hashing for linters. In ObjC the method names contain the parameter names,
      thus if people add new parameters, any bug about the method will be considered different which means
    reporting on unchanged code. So, in the ObjC method case, we create the method name only based on the
    first part of the name without the parameters *)

  (** WARNING: functions from this module should not be used if full decl is available in AST *)
  module NoAstDecl : sig
    val c_function_of_string : is_cpp:bool -> Tenv.t -> string -> Typ.Procname.t

    val cpp_method_of_string : Tenv.t -> Typ.Name.t -> string -> Typ.Procname.t

    val objc_method_of_string_kind :
      Typ.Name.t -> string -> Typ.Procname.ObjC_Cpp.kind -> Typ.Procname.t
  end

  val mk_fresh_block_procname : Typ.Procname.t -> Typ.Procname.t
  (** Makes a fresh name for a block defined inside the defining procedure.
    It updates the global block_counter *)

  val reset_block_counter : unit -> unit
end

(** Processes types and record declarations by adding them to the tenv *)

val get_record_typename : ?tenv:Tenv.t -> Clang_ast_t.decl -> Typ.Name.t

val add_types_from_decl_to_tenv : Tenv.t -> Clang_ast_t.decl -> Typ.desc

val add_predefined_types : Tenv.t -> unit
(** Add the predefined types objc_class which is a struct, and Class, which is a pointer to
    objc_class. *)

val qual_type_to_sil_type : Tenv.t -> Clang_ast_t.qual_type -> Typ.t

val class_from_pointer_type : Tenv.t -> Clang_ast_t.qual_type -> Typ.Name.t

val get_type_from_expr_info : Clang_ast_t.expr_info -> Tenv.t -> Typ.t
