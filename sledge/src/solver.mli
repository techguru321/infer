(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Frame Inference Solver over Symbolic Heaps *)

open Fol
open Symbolic_heap

val infer_frame : Xsh.t -> Var.Set.t -> Xsh.t -> Xsh.t option
(** If [infer_frame p xs q] is [Some r], then [p ⊢ ∃xs. q * r]. The
    vocabulary of [r] is the vocabulary of [q] union [xs]. A goal is for [r]
    to be strong enough that for every model of [r], there exists an
    extension of it satisfying [q], such that the combination (with [xs]
    projected out) satisfies [p]. *)

(**/**)

val dump_query : int ref
val replay : string -> unit
