(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

module F = Format

(** Abstract domains and domain combinators *)

module type S = sig
  type astate

  val initial : astate
  val (<=) : lhs:astate -> rhs:astate -> bool (* fst \sqsubseteq snd? *)
  val join : astate -> astate -> astate
  val widen : prev:astate -> next:astate -> num_iters:int -> astate
  val pp : F.formatter -> astate -> unit
end

(** Lift a pre-domain to a domain *)
module BottomLifted (Domain : S) : sig
  type astate =
    | Bottom
    | NonBottom of Domain.astate

  include S with type astate := astate
end

(** Cartesian product of two domains. *)
module Pair (Domain1 : S) (Domain2 : S) : S with type astate = Domain1.astate * Domain2.astate

(** Lift a set to a domain. The elements of the set should be drawn from a *finite* collection of
    possible values, since the widening operator here is just union. *)
module FiniteSet (Set : PrettyPrintable.PPSet) : sig
  include PrettyPrintable.PPSet with type t = Set.t and type elt = Set.elt
  include S with type astate = t
end

(** Lift a map whose value type is an abstract domain to a domain. *)
module Map (Map : PrettyPrintable.PPMap) (ValueDomain : S) : sig
  include PrettyPrintable.PPMap with type 'a t = 'a Map.t and type key = Map.key
  include S with type astate = ValueDomain.astate Map.t
end

(** Boolean domain ordered by p || ~q. Useful when you want a boolean that's true only when it's
    true in both branches. *)
module BooleanAnd : S with type astate = bool
