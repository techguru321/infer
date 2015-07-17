(*
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

module type CTrans = sig
(** Translates instructions: (statements and expressions) from the ast into sil *)

(** It receives the context, a list of statements and the exit node and it returns a list of cfg nodes *)
(** that reporesent the translation of the stmts into sil. *)
  val instructions_trans : CContext.t -> Clang_ast_t.stmt list -> Cfg.Node.t -> Cfg.Node.t list

  (** It receives the context and a statement and a warning string and returns the translated sil expression *)
  (** that represents the translation of the stmts into sil. *)
  val expression_trans : CContext.t -> Clang_ast_t.stmt -> string -> Sil.exp

end


module CTrans_funct(M: CModule_type.CMethod_declaration) : CTrans

