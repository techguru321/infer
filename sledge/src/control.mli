(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** The analysis' semantics of control flow. *)

type exec_opts =
  { bound: int  (** Loop/recursion unrolling bound *)
  ; skip_throw: bool  (** Treat throw as unreachable *)
  ; function_summaries: bool  (** Use function summarisation *) }

val exec_pgm : exec_opts -> Llair.t -> unit
