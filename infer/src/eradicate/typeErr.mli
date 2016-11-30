(*
 * Copyright (c) 2014 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils


(** Module for Type Error messages. *)


module type InstrRefT =
sig
  type t [@@deriving compare]
  val equal : t -> t -> bool
  type generator
  val create_generator : Procdesc.Node.t -> generator
  val gen : generator -> t
  val get_node : t -> Procdesc.Node.t
  val hash : t -> int
  val replace_node : t -> Procdesc.Node.t -> t
end (* InstrRefT *)

module InstrRef : InstrRefT

module Strict :
sig
  val signature_get_strict :
    Tenv.t -> Annotations.annotated_signature -> Annot.t option
end (* Strict *)


type origin_descr =
  string *
  Location.t option *
  Annotations.annotated_signature option  (* callee signature *)

type parameter_not_nullable =
  Annotations.annotation *
  string * (* description *)
  int * (* parameter number *)
  Procname.t *
  Location.t * (* callee location *)
  origin_descr

(** Instance of an error *)
type err_instance =
  | Condition_redundant of (bool * (string option) * bool)
  | Inconsistent_subclass_return_annotation of Procname.t * Procname.t
  | Inconsistent_subclass_parameter_annotation of string * int * Procname.t * Procname.t
  | Field_not_initialized of Ident.fieldname * Procname.t
  | Field_not_mutable of Ident.fieldname * origin_descr
  | Field_annotation_inconsistent of Annotations.annotation * Ident.fieldname * origin_descr
  | Field_over_annotated of Ident.fieldname * Procname.t
  | Null_field_access of string option * Ident.fieldname * origin_descr * bool
  | Call_receiver_annotation_inconsistent
    of Annotations.annotation * string option * Procname.t * origin_descr
  | Parameter_annotation_inconsistent of parameter_not_nullable
  | Return_annotation_inconsistent of Annotations.annotation * Procname.t * origin_descr
  | Return_over_annotated of Procname.t


val node_reset_forall : Procdesc.Node.t -> unit

type st_report_error =
  Procname.t ->
  Procdesc.t ->
  string ->
  Location.t ->
  ?advice: string option ->
  ?field_name: Ident.fieldname option ->
  ?origin_loc: Location.t option ->
  ?exception_kind: (string -> Localise.error_desc -> exn) ->
  ?always_report: bool ->
  string ->
  unit

val report_error :
  Tenv.t -> st_report_error ->
  (Procdesc.Node.t -> Procdesc.Node.t) ->
  err_instance -> InstrRef.t option -> Location.t ->
  Procdesc.t -> unit

val report_forall_checks_and_reset : Tenv.t -> st_report_error -> Procdesc.t -> unit

val reset : unit -> unit
