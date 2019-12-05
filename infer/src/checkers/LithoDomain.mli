(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format

(** Access path + its parent procedure *)
module LocalAccessPath : sig
  type t = private {access_path: AccessPath.t; parent: Typ.Procname.t} [@@deriving compare]

  val make : AccessPath.t -> Typ.Procname.t -> t

  val make_from_access_expression : HilExp.AccessExpression.t -> Typ.Procname.t -> t

  val to_formal_option : t -> FormalMap.t -> t option

  val pp : F.formatter -> t -> unit
end

val suffixes : String.Set.t

(** Called procedure & location + its receiver *)
module MethodCall : sig
  type t = private {receiver: LocalAccessPath.t; procname: Typ.Procname.t; location: Location.t}
  [@@deriving compare]

  val make : LocalAccessPath.t -> Typ.Procname.t -> Location.t -> t

  val pp : F.formatter -> t -> unit

  val procname_to_string : t -> string
end

module CallSet : module type of AbstractDomain.FiniteSet (MethodCall)

module OldDomain : module type of AbstractDomain.Map (LocalAccessPath) (CallSet)

module NewDomain : AbstractDomain.S

include module type of AbstractDomain.Pair (OldDomain) (NewDomain)

val empty : t

val add : LocalAccessPath.t -> CallSet.t -> t -> t

val remove : LocalAccessPath.t -> t -> t

val mem : LocalAccessPath.t -> t -> bool

val find : LocalAccessPath.t -> t -> CallSet.t

val bindings : t -> (LocalAccessPath.t * CallSet.t) list

val assign : lhs:LocalAccessPath.t -> rhs:LocalAccessPath.t -> t -> t

val call_create : LocalAccessPath.t -> Typ.name -> Location.t -> t -> t
(** Semantics of builder creation method *)

val call_builder : ret:LocalAccessPath.t -> receiver:LocalAccessPath.t -> MethodCall.t -> t -> t
(** Semantics of builder's methods, e.g. [prop] *)

val call_build_method : ret:LocalAccessPath.t -> receiver:LocalAccessPath.t -> t -> t
(** Semantics of builder's final build method *)

val check_required_props :
  check_on_string_set:(Typ.name -> MethodCall.t list -> String.Set.t -> unit) -> t -> unit

val substitute : f_sub:(LocalAccessPath.t -> LocalAccessPath.t option) -> t -> t
(** Substitute each access path in the domain using [f_sub]. If [f_sub] returns None, the original
    access path is retained; otherwise, the new one is used *)

val iter_call_chains : f:(AccessPath.t -> MethodCall.t list -> unit) -> t -> unit
(** Apply [f] to each maximal call chain encoded in [t] *)
