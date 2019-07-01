(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Symbolic Execution *)

val assume : Sh.t -> Exp.t -> Sh.t option
val return : Sh.t -> Var.t -> Exp.t -> Sh.t
val inst : Sh.t -> Llair.inst -> (Sh.t, unit) result

val intrinsic :
     skip_throw:bool
  -> Sh.t
  -> Var.t option
  -> Var.t
  -> Exp.t list
  -> (Sh.t, unit) result option
