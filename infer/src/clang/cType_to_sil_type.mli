(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

val get_builtin_objc_typename :  [< `ObjCClass | `ObjCId ] -> Typename.t

val get_builtin_objc_type : [< `ObjCClass | `ObjCId ] -> Sil.typ

val sil_type_of_builtin_type_kind : Clang_ast_t.builtin_type_kind -> Sil.typ

val type_ptr_to_sil_type : (Tenv.t -> Clang_ast_t.decl -> Sil.typ) ->
  Tenv.t -> Clang_ast_t.type_ptr -> Sil.typ
