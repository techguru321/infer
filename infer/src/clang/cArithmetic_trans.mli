(*
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(** Utility module for translating unary and binary operations and compound assignments *)

val bin_op_to_string : Clang_ast_t.binary_operator_info -> string

val binary_operation_instruction : CContext.t -> Clang_ast_t.binary_operator_info -> Sil.exp -> Sil.typ -> Sil.exp ->
Sil.location -> bool -> Sil.exp * Sil.instr list * Ident.t list

val unary_operation_instruction : Clang_ast_t.unary_operator_info -> Sil.exp -> Sil.typ -> Sil.location ->
Ident.t list * Sil.exp * Sil.instr list

val compound_assignment_binary_operation_instruction : Clang_ast_t.binary_operator_info -> Sil.exp ->
Sil.typ -> Sil.exp -> Sil.location -> Ident.t list * Sil.exp * Sil.instr list

val assignment_arc_mode : CContext.t -> Sil.exp -> Sil.typ -> Sil.exp -> Sil.location -> bool -> bool -> Sil.exp * Sil.instr list * Ident.t list

