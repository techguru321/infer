(*
 * Copyright (c) 2018-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open! AbstractDomain.Types
module ItvPure = Itv.ItvPure
module Relation = BufferOverrunDomainRelation

module Condition : sig
  type t
end

module ConditionTrace : sig
  type t

  val get_report_location : t -> Location.t

  val get_val_traces : t -> BufferOverrunTrace.Issue.t
end

module ConditionSet : sig
  type t

  type summary_t

  val empty : t

  val pp : Format.formatter -> t -> unit

  val pp_summary : Format.formatter -> summary_t -> unit

  val add_array_access :
       Location.t
    -> offset:ItvPure.t
    -> idx:ItvPure.t
    -> size:ItvPure.t
    -> is_collection_add:bool
    -> idx_sym_exp:Relation.SymExp.t option
    -> size_sym_exp:Relation.SymExp.t option
    -> relation:Relation.t
    -> idx_traces:BufferOverrunTrace.Set.t
    -> arr_traces:BufferOverrunTrace.Set.t
    -> t
    -> t

  val add_alloc_size : Location.t -> length:ItvPure.t -> BufferOverrunTrace.Set.t -> t -> t

  val add_binary_operation :
       Typ.IntegerWidths.t
    -> Location.t
    -> Binop.t
    -> lhs:ItvPure.t
    -> rhs:ItvPure.t
    -> lhs_traces:BufferOverrunTrace.Set.t
    -> rhs_traces:BufferOverrunTrace.Set.t
    -> t
    -> t

  val join : t -> t -> t

  val subst :
       summary_t
    -> Bounds.Bound.eval_sym * (Symb.Symbol.t -> BufferOverrunTrace.Set.t)
    -> Relation.SubstMap.t
    -> Relation.t
    -> Typ.Procname.t
    -> Location.t
    -> t

  val check_all : report:(Condition.t -> ConditionTrace.t -> IssueType.t -> unit) -> t -> t
  (** Check the conditions, call [report] on those that trigger an issue, returns those that needs to be propagated to callers. *)

  val for_summary : t -> summary_t

  val forget_locs : AbsLoc.PowLoc.t -> t -> t
end

val description : markup:bool -> Condition.t -> ConditionTrace.t -> string
