(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils


(* Module for warnings detected at translation time by the frontend *)

(* Run frontend checkers on an AST node *)
val run_frontend_checkers_on_an :
  CLintersContext.context -> CTL.ast_node -> CLintersContext.context

(** Same as run_frontend_checkers_on_an except special-cased on the translation
    unit. Translation unit level checkers may return multiple issues, which is
    why special-casing is necessary here. *)
val run_translation_unit_checker :
  CLintersContext.context -> Clang_ast_t.decl -> unit
