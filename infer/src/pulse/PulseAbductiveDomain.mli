(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module AbstractAddress = PulseDomain.AbstractAddress
module Attributes = PulseDomain.Attributes

(* layer on top of {!PulseDomain} to propagate operations on the current state to the pre-condition
   when necessary

   The abstract type [t] is a pre/post pair in the style of biabduction.
*)

include AbstractDomain.NoJoin

val mk_initial : Procdesc.t -> t

(** stack operations like {!PulseDomain.Stack} but that also take care of propagating facts to the
    precondition *)
module Stack : sig
  val add : Var.t -> PulseDomain.Stack.value -> t -> t

  val remove_vars : Var.t list -> t -> t

  val fold : (Var.t -> PulseDomain.Stack.value -> 'a -> 'a) -> t -> 'a -> 'a

  val find_opt : Var.t -> t -> PulseDomain.Stack.value option

  val eval : Var.t -> t -> t * PulseDomain.AddrTracePair.t
  (** return the value of the variable in the stack or create a fresh one if needed *)

  val mem : Var.t -> t -> bool

  val exists : (Var.t -> PulseDomain.Stack.value -> bool) -> t -> bool
end

(** stack operations like {!PulseDomain.Heap} but that also take care of propagating facts to the
    precondition *)
module Memory : sig
  module Access = PulseDomain.Memory.Access
  module Edges = PulseDomain.Memory.Edges

  val add_attributes : AbstractAddress.t -> Attributes.t -> t -> t

  val add_edge : AbstractAddress.t -> Access.t -> PulseDomain.AddrTracePair.t -> t -> t

  val check_valid :
       unit PulseDomain.InterprocAction.t
    -> AbstractAddress.t
    -> t
    -> (t, PulseDomain.Invalidation.t PulseDomain.Trace.t) result

  val find_opt : AbstractAddress.t -> t -> PulseDomain.Memory.cell option

  val find_edge_opt : AbstractAddress.t -> Access.t -> t -> PulseDomain.AddrTracePair.t option

  val set_cell : AbstractAddress.t -> PulseDomain.Memory.cell -> t -> t

  val invalidate :
       AbstractAddress.t * PulseDomain.ValueHistory.t
    -> PulseDomain.Invalidation.t PulseDomain.InterprocAction.t
    -> t
    -> t

  val get_closure_proc_name : AbstractAddress.t -> t -> Typ.Procname.t option

  val is_std_vector_reserved : AbstractAddress.t -> t -> bool

  val std_vector_reserve : AbstractAddress.t -> t -> t

  val eval_edge : AbstractAddress.t -> Access.t -> t -> t * PulseDomain.AddrTracePair.t
  (** [eval_edge addr access astate] follows the edge [addr --access--> .] in memory and returns
      what it points to or creates a fresh value if that edge didn't exist.  *)
end

val is_local : Var.t -> t -> bool

module PrePost : sig
  type domain_t = t

  type t = private domain_t

  val pp : Format.formatter -> t -> unit

  val of_post : Procdesc.t -> domain_t -> t

  val apply :
       Typ.Procname.t
    -> Location.t
    -> t
    -> formals:Var.t list
    -> actuals:((AbstractAddress.t * PulseDomain.ValueHistory.t) * Typ.t) list
    -> domain_t
    -> (domain_t * AbstractAddress.t option, PulseDiagnostic.t) result
  (** return the abstract state after the call along with an optional return value *)
end

val discard_unreachable : t -> t
(** garbage collect unreachable addresses in the state to make it smaller, just for convenience and
    keep its size down *)
