(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** Attributes of a procedure. *)

open Utils

type objc_accessor_type =
  | Objc_getter of Ident.fieldname
  | Objc_setter of Ident.fieldname

type t =
  {
    access : Sil.access; (** visibility access *)
    captured : (Mangled.t * Sil.typ) list; (** name and type of variables captured in blocks *)
    err_log: Errlog.t; (** Error log for the procedure *)
    exceptions : string list; (** exceptions thrown by the procedure *)
    formals : (string * Sil.typ) list; (** name and type of formal parameters *)
    func_attributes : Sil.func_attribute list;
    is_abstract : bool; (** the procedure is abstract *)
    mutable is_bridge_method : bool; (** the procedure is a bridge method *)
    is_defined : bool; (** true if the procedure is defined, and not just declared *)
    is_generated : bool; (** the procedure has been generated *)
    is_objc_instance_method : bool; (** the procedure is an objective-C instance method *)
    is_cpp_instance_method : bool; (** the procedure is an C++ instance method *)
    objc_accessor : objc_accessor_type option; (** the proc is ObjC accessor *)
    mutable is_synthetic_method : bool; (** the procedure is a synthetic method *)
    language : Config.language; (** language of the procedure *)
    loc : Location.t; (** location of this procedure in the source code *)
    mutable locals : (Mangled.t * Sil.typ) list; (** name and type of local variables *)
    method_annotation : Sil.method_annotation; (** annotations for java methods *)
    proc_flags : proc_flags; (** flags of the procedure *)
    proc_name : Procname.t; (** name of the procedure *)
    ret_type : Sil.typ; (** return type *)
  }

(** Create a copy of a proc_attributes *)
val copy : t -> t

(** Create a proc_attributes with default values. *)
val default : Procname.t -> Config.language -> t
