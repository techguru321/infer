(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

(** Module for Type Error messages. *)

module type InstrRefT = sig
  type t [@@deriving compare]

  val equal : t -> t -> bool

  type generator

  val create_generator : Procdesc.Node.t -> generator

  val gen : generator -> t

  val get_node : t -> Procdesc.Node.t

  val hash : t -> int

  val replace_node : t -> Procdesc.Node.t -> t
end

(* InstrRefT *)
module InstrRef : InstrRefT

(* callee signature *)

(** Instance of an error *)
type err_instance =
  | Condition_redundant of
      {is_always_true: bool; condition_descr: string option; nonnull_origin: TypeOrigin.t}
  | Inconsistent_subclass of
      { inheritance_violation: InheritanceRule.violation
      ; violation_type: InheritanceRule.violation_type
      ; base_proc_name: Procname.t
      ; overridden_proc_name: Procname.t }
  | Field_not_initialized of {is_strict_mode: bool; field_name: Fieldname.t}
  | Over_annotation of
      { over_annotated_violation: OverAnnotatedRule.violation
      ; violation_type: OverAnnotatedRule.violation_type }
  | Nullable_dereference of
      { dereference_violation: DereferenceRule.violation
      ; dereference_location: Location.t
      ; dereference_type: DereferenceRule.dereference_type
      ; nullable_object_descr: string option
      ; nullable_object_origin: TypeOrigin.t }
  | Bad_assignment of
      { assignment_violation: AssignmentRule.violation
      ; assignment_location: Location.t
      ; assignment_type: AssignmentRule.assignment_type
      ; rhs_origin: TypeOrigin.t }
[@@deriving compare]

val node_reset_forall : Procdesc.Node.t -> unit

type st_report_error =
     Procname.t
  -> Procdesc.t
  -> IssueType.t
  -> Location.t
  -> ?field_name:Fieldname.t option
  -> ?exception_kind:(IssueType.t -> Localise.error_desc -> exn)
  -> ?severity:Exceptions.severity
  -> string
  -> unit

val report_error :
     Tenv.t
  -> st_report_error
  -> (Procdesc.Node.t -> Procdesc.Node.t)
  -> err_instance
  -> InstrRef.t option
  -> Location.t
  -> Procdesc.t
  -> unit

val report_forall_checks_and_reset : Tenv.t -> st_report_error -> Procdesc.t -> unit

val reset : unit -> unit
