(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

(** Module for error logs. *)

type node_tag =
  | Condition of bool
  | Exception of Typ.name
  | Procedure_start of Typ.Procname.t
  | Procedure_end of Typ.Procname.t

(** Element of a loc trace *)
type loc_trace_elem = private
  { lt_level: int  (** nesting level of procedure calls *)
  ; lt_loc: Location.t  (** source location at the current step in the trace *)
  ; lt_description: string  (** description of the current step in the trace *)
  ; lt_node_tags: node_tag list  (** tags describing the node at the current location *) }

val make_trace_element : int -> Location.t -> string -> node_tag list -> loc_trace_elem
(** build a loc_trace_elem from its constituents (unambiguously identified by their types). *)

(** Trace of locations *)
type loc_trace = loc_trace_elem list

val compute_local_exception_line : loc_trace -> int option
(** Look at all the trace steps and find those that are arising any exception,
    then bind them to the closest step at level 0.
    This extra information adds value to the report itself, and may avoid
    digging into the trace to understand the cause of the report. *)

type node_id_key = private {node_id: int; node_key: Caml.Digest.t}

type err_key = private
  { err_kind: Exceptions.err_kind
  ; in_footprint: bool
  ; err_name: IssueType.t
  ; err_desc: Localise.error_desc
  ; severity: string }
[@@deriving compare]

(** Data associated to a specific error *)
type err_data = private
  { node_id_key: node_id_key
  ; session: int
  ; loc: Location.t
  ; loc_in_ml_source: Logging.ocaml_pos option
  ; loc_trace: loc_trace
  ; err_class: Exceptions.err_class
  ; visibility: Exceptions.visibility
  ; linters_def_file: string option
  ; doc_url: string option  (** url to documentation of the issue type *)
  ; access: string option }

(** Type of the error log *)
type t [@@deriving compare]

val equal : t -> t -> bool

val empty : unit -> t
(** Empty error log *)

(** type of the function to be passed to iter *)
type iter_fun = err_key -> err_data -> unit

val iter : iter_fun -> t -> unit
(** Apply f to nodes and error names *)

val fold : (err_key -> err_data -> 'a -> 'a) -> t -> 'a -> 'a

val pp_loc_trace_elem : Format.formatter -> loc_trace_elem -> unit  [@@warning "-32"]

val pp_loc_trace : Format.formatter -> loc_trace -> unit

val pp_errors : Format.formatter -> t -> unit
(** Print errors from error log *)

val pp_warnings : Format.formatter -> t -> unit
(** Print warnings from error log *)

val pp_html : SourceFile.t -> DB.Results_dir.path -> Format.formatter -> t -> unit
(** Print an error log in html format *)

val size : (Exceptions.err_kind -> bool -> bool) -> t -> int
(** Return the number of elements in the error log which satisfy the filter.  *)

val update : t -> t -> unit
(** Update an old error log with a new one *)

val log_issue :
  Typ.Procname.t -> ?clang_method_kind:string -> Exceptions.err_kind -> t -> Location.t
  -> int * Caml.Digest.t -> int -> loc_trace -> ?linters_def_file:string -> ?doc_url:string
  -> ?access:string -> exn -> unit
