(*
 * Copyright (c) 2014 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

type const_map = Cfg.Node.t -> Sil.exp -> Const.t option

(** Build a const map lazily. *)
val build_const_map : Tenv.t -> Cfg.Procdesc.t -> const_map
