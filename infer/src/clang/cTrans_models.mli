(*
* Copyright (c) 2013 - Facebook.
* All rights reserved.
*)

val is_cf_non_null_alloc : Procname.t option -> bool

val is_alloc : Procname.t option -> bool

val is_alloc_model : Sil.typ -> Procname.t option -> bool

val is_objc_memory_model_controlled : string -> bool

val builtin_predefined_model : Clang_ast_t.stmt -> Sil.exp -> Sil.exp * bool

val is_assert_log : Sil.exp -> bool

val is_handleFailureInMethod : string -> bool

val is_modeled_builtin : string -> bool

val is_toll_free_bridging : Procname.t option -> bool

val get_predefined_model_method_signature : string -> string -> (string -> string -> Procname.t) ->
  CMethod_signature.method_signature option

val is_dispatch_function_name : string -> (string * int) option
