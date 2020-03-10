(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

val log_caught_exception :
     CFrontend_config.translation_unit_context
  -> string
  -> Logging.ocaml_pos
  -> Clang_ast_t.source_location * Clang_ast_t.source_location
  -> string option
  -> unit

val log_unexpected_decl :
     CFrontend_config.translation_unit_context
  -> Logging.ocaml_pos
  -> Clang_ast_t.source_location * Clang_ast_t.source_location
  -> string option
  -> unit
