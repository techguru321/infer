(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format
module AbstractValue = PulseAbstractValue
module CallEvent = PulseCallEvent
module ConfigName = FbPulseConfigName
module DecompilerExpr = PulseDecompilerExpr
module Invalidation = PulseInvalidation
module TaintItem = PulseTaintItem
module Timestamp = PulseTimestamp
module Trace = PulseTrace
module ValueHistory = PulseValueHistory

type allocator =
  | CMalloc
  | CustomMalloc of Procname.t
  | CRealloc
  | CustomRealloc of Procname.t
  | CppNew
  | CppNewArray
  | JavaResource of JavaClassName.t
  | CSharpResource of CSharpClassName.t
  | ObjCAlloc
  | HackAsync
[@@deriving equal]

val pp_allocator : F.formatter -> allocator -> unit

(** Describes the source of taint in taint propagation.

    NOTE: [history] is ignored in equality and comparison. *)
type taint_in = {v: AbstractValue.t; history: ValueHistory.t} [@@deriving compare, equal]

module Tainted : sig
  type t =
    { source: TaintItem.t
    ; time_trace: Timestamp.trace
    ; hist: ValueHistory.t
    ; intra_procedural_only: bool }
  [@@deriving compare, equal]
end

module TaintedSet : PrettyPrintable.PPSet with type elt = Tainted.t

module TaintSink : sig
  type t = {sink: TaintItem.t; time: Timestamp.t; trace: Trace.t} [@@deriving compare, equal]
end

module TaintSinkSet : PrettyPrintable.PPSet with type elt = TaintSink.t

module TaintSanitized : sig
  type t = {sanitizer: TaintItem.t; time_trace: Timestamp.trace; trace: Trace.t}
  [@@deriving compare, equal]
end

module TaintSanitizedSet : PrettyPrintable.PPSet with type elt = TaintSanitized.t

module CopyOrigin : sig
  type t = CopyCtor | CopyAssignment | CopyToOptional | CopyInGetDefault
  [@@deriving compare, equal]

  val pp : Formatter.t -> t -> unit
end

module CopiedInto : sig
  type t =
    | IntoVar of {copied_var: Var.t}
    | IntoIntermediate of {copied_var: Var.t}
    | IntoField of {field: Fieldname.t}
  [@@deriving compare, equal]

  val is_copied_into_var : t -> bool

  val pp : F.formatter -> t -> unit
end

module ConfigUsage : sig
  type t = ConfigName of ConfigName.t | StringParam of {v: AbstractValue.t; config_type: string}
end

type t =
  | AddressOfCppTemporary of Var.t * ValueHistory.t
  | AddressOfStackVariable of Var.t * Location.t * ValueHistory.t
  | Allocated of allocator * Trace.t
  | AlwaysReachable
  | Closure of Procname.t
  | ConfigUsage of ConfigUsage.t
  | ConstString of string
  | CopiedInto of CopiedInto.t  (** records the copied var/field for each source address *)
  | CopiedReturn of
      {source: AbstractValue.t; is_const_ref: bool; from: CopyOrigin.t; copied_location: Location.t}
      (** records the copied value for the return address *)
  | DynamicType of Typ.t * SourceFile.t option
  | EndOfCollection
  | Initialized
  | Invalid of Invalidation.t * Trace.t
  | MustBeInitialized of Timestamp.t * Trace.t
  | MustBeValid of Timestamp.t * Trace.t * Invalidation.must_be_valid_reason option
  | MustNotBeTainted of TaintSinkSet.t
  | JavaResourceReleased
  | CSharpResourceReleased
  | HackAsyncAwaited
  | PropagateTaintFrom of taint_in list
  | RefCounted
  | ReturnedFromUnknown of AbstractValue.t list
  | SourceOriginOfCopy of {source: PulseAbstractValue.t; is_const_ref: bool}
      (** records the source value for a given copy to lookup the appropriate heap in non-disj
          domain *)
  | StaticType of Typ.Name.t
      (** type gotten or inferred from types in SIL instructions (only for Hack frontend)*)
  | StdMoved
  | StdVectorReserve
  | Tainted of TaintedSet.t
  | TaintSanitized of TaintSanitizedSet.t
  | Uninitialized
  | UnknownEffect of CallEvent.t * ValueHistory.t
      (** generated by calls to unknown functions to remember that a pointer has been passed to an
          unknown function and so everything reachable from it has potentially been affected in
          unknown ways *)
  | UnreachableAt of Location.t
      (** temporary marker to remember where a variable became unreachable; helps with accurately
          reporting leaks *)
  | UsedAsBranchCond of Procname.t * Location.t * Trace.t
  | WrittenTo of Timestamp.t * Trace.t
[@@deriving compare]

val pp : F.formatter -> t -> unit

val is_suitable_for_pre : t -> bool

val is_suitable_for_post : t -> bool

val filter_unreachable :
  AbstractValue.Set.t AbstractValue.Map.t -> (AbstractValue.t -> bool) -> t -> t option
(** update an attribute to get rid of abstract values that do not satisfy the given predicate; the
    result is [None] if the attribute becomes meaningless as a result *)

module Attributes : sig
  include PrettyPrintable.PPUniqRankSet with type elt = t

  val get_address_of_stack_variable : t -> (Var.t * Location.t * ValueHistory.t) option

  val get_closure_proc_name : t -> Procname.t option

  val get_config_usage : t -> ConfigUsage.t option

  val get_const_string : t -> string option

  val get_used_as_branch_cond : t -> (Procname.t * Location.t * Trace.t) option

  val get_copied_into : t -> CopiedInto.t option

  val get_copied_return : t -> (AbstractValue.t * bool * CopyOrigin.t * Location.t) option

  val remove_copied_return : t -> t

  val get_source_origin_of_copy : t -> (PulseAbstractValue.t * bool) option

  val get_allocation : t -> (allocator * Trace.t) option

  val remove_allocation : t -> t

  val is_ref_counted : t -> bool

  val get_unknown_effect : t -> (CallEvent.t * ValueHistory.t) option

  val get_dynamic_type_source_file : t -> (Typ.t * SourceFile.t option) option

  val get_static_type : t -> Typ.Name.t option

  val is_java_resource_released : t -> bool

  val is_csharp_resource_released : t -> bool

  val is_end_of_collection : t -> bool

  val get_invalid : t -> (Invalidation.t * Trace.t) option

  val get_tainted : t -> TaintedSet.t

  val remove_tainted : t -> t

  val get_propagate_taint_from : t -> taint_in list option

  val remove_propagate_taint_from : t -> t

  val get_returned_from_unknown : t -> AbstractValue.t list option

  val get_taint_sanitized : t -> TaintSanitizedSet.t

  val remove_taint_sanitized : t -> t

  val get_must_be_valid :
    t -> (Timestamp.t * Trace.t * Invalidation.must_be_valid_reason option) option

  val remove_must_be_valid : t -> t

  val get_must_not_be_tainted : t -> TaintSinkSet.t

  val get_written_to : t -> (Timestamp.t * Trace.t) option

  val is_always_reachable : t -> bool

  val is_modified : t -> bool

  val is_std_moved : t -> bool

  val is_std_vector_reserved : t -> bool

  val is_uninitialized : t -> bool

  val remove_uninitialized : t -> t

  val get_must_be_initialized : t -> (Timestamp.t * Trace.t) option

  val get_unreachable_at : t -> Location.t option

  val add_call_and_subst :
       (AbstractValue.t -> AbstractValue.t)
    -> Timestamp.t
    -> Procname.t
    -> Location.t
    -> ValueHistory.t
    -> t
    -> t

  val get_allocated_not_freed : t -> (allocator * Trace.t) option

  val make_suitable_for_pre_summary : t -> t

  val make_suitable_for_post_summary : t -> t
end
