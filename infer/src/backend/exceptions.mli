(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

open Utils

(** Functions for logging and printing exceptions *)

type exception_visibility = (** visibility of the exception *)
  | Exn_user (** always add to error log *)
  | Exn_developer (** only add to error log in developer mode *)
  | Exn_system (** never add to error log *)

type exception_severity = (** severity of bugs *)
  | High (* high severity bug *)
  | Medium (* medium severity bug *)
  | Low (* low severity bug *)

(** kind of error/warning *)
type err_kind =
    Kwarning | Kerror | Kinfo

(** class of error *)
type err_class = Checker | Prover | Nocat

exception Abduction_case_not_implemented of ml_location
exception Analysis_stops of Localise.error_desc * ml_location option
exception Array_of_pointsto of ml_location
exception Array_out_of_bounds_l1 of Localise.error_desc * ml_location
exception Array_out_of_bounds_l2 of Localise.error_desc * ml_location
exception Array_out_of_bounds_l3 of Localise.error_desc * ml_location
exception Assertion_failure of string * Localise.error_desc
exception Bad_footprint of ml_location
exception Class_cast_exception of Localise.error_desc * ml_location
exception Codequery of Localise.error_desc
exception Comparing_floats_for_equality of Localise.error_desc * ml_location
exception Condition_always_true_false of Localise.error_desc * bool * ml_location
exception Condition_is_assignment of Localise.error_desc * ml_location
exception Dangling_pointer_dereference of Sil.dangling_kind option * Localise.error_desc * ml_location
exception Deallocate_stack_variable of Localise.error_desc
exception Deallocate_static_memory of Localise.error_desc
exception Deallocation_mismatch of Localise.error_desc * ml_location
exception Divide_by_zero of Localise.error_desc * ml_location
exception Field_not_null_checked of Localise.error_desc * ml_location
exception Eradicate of string * Localise.error_desc
exception Checkers of string * Localise.error_desc
exception Inherently_dangerous_function of Localise.error_desc
exception Internal_error of Localise.error_desc
exception Java_runtime_exception of Mangled.t * string * Localise.error_desc
exception Leak of bool * Prop.normal Prop.t * Sil.hpred * (exception_visibility * Localise.error_desc) * bool * Sil.resource * ml_location
exception Missing_fld of Ident.fieldname * ml_location
exception Premature_nil_termination of Localise.error_desc * ml_location
exception Null_dereference of Localise.error_desc * ml_location
exception Null_test_after_dereference of Localise.error_desc * ml_location
exception Parameter_not_null_checked of Localise.error_desc * ml_location
exception Pointer_size_mismatch of Localise.error_desc * ml_location
exception Precondition_not_found of Localise.error_desc * ml_location
exception Precondition_not_met of Localise.error_desc * ml_location
exception Retain_cycle of Prop.normal Prop.t * Sil.hpred * Localise.error_desc * ml_location
exception Return_expression_required of Localise.error_desc * ml_location
exception Return_statement_missing of Localise.error_desc * ml_location
exception Return_value_ignored of Localise.error_desc * ml_location
exception Skip_function of Localise.error_desc
exception Skip_pointer_dereference of Localise.error_desc * ml_location
exception Stack_variable_address_escape of Localise.error_desc * ml_location
exception Symexec_memory_error of ml_location
exception Tainted_value_reaching_sensitive_function of Localise.error_desc * ml_location
exception Unary_minus_applied_to_unsigned_expression of Localise.error_desc * ml_location
exception Uninitialized_value of Localise.error_desc * ml_location
exception Unknown_proc
exception Use_after_free of Localise.error_desc * ml_location
exception Wrong_argument_number of ml_location

(** string describing an error class *)
val err_class_string : err_class -> string

(** string describing an error kind *)
val err_kind_string : err_kind -> string

(** Return true if the exception is not serious and should be handled in timeout mode *)
val handle_exception : exn -> bool

(** print a description of the exception to the html output *)
val print_exception_html : string -> exn -> unit

(** pretty print an error given its (id,key), location, kind, name, description, and optional ml location *)
val pp_err : int * int -> Sil.location -> err_kind -> Localise.t -> Localise.error_desc ->
Utils.ml_location option -> Format.formatter -> unit -> unit

(** Turn an exception into an error name, error description,
location in ml source, and category *)
val recognize_exception : exn ->
(Localise.t * Localise.error_desc * (ml_location option) * exception_visibility *
exception_severity * err_kind option * err_class)
