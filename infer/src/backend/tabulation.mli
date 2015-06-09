(*
* Copyright (c) 2009 -2013 Monoidics ltd.
* Copyright (c) 2013 - Facebook.
* All rights reserved.
*)

(** Interprocedural footprint analysis *)

(** Frame and anti-frame *)
type splitting

(** Remove constant string or class from a prop *)
val remove_constant_string_class : 'a Prop.t -> Prop.normal Prop.t

(** Check if the attribute change is a mismatch between a kind of allocation and a different kind of deallocation *)
val check_attr_dealloc_mismatch : Sil.attribute -> Sil.attribute -> unit

(** Check whether a sexp contains a dereference without null check, and return the line number and path position *)
val find_dereference_without_null_check_in_sexp : Sil.strexp -> (int * Sil.path_pos) option

(** raise a cast exception *)
val raise_cast_exception :
Utils.ml_location -> Procname.t option -> Sil.exp -> Sil.exp -> Sil.exp -> 'a

(** check if a prop is an exception *)
val prop_is_exn : Cfg.Procdesc.t -> 'a Prop.t -> bool

(** when prop is an exception, return the exception name *)
val prop_get_exn_name : Cfg.Procdesc.t -> 'a Prop.t -> Mangled.t

(** search in prop contains an error state *)
val lookup_global_errors : 'a Prop.t -> Mangled.t option

(** Dump a splitting *)
val d_splitting : splitting -> unit

(** Execute the function call and return the list of results with return value *)
val exe_function_call: Sil.tenv -> Cfg.cfg -> Ident.t list -> Cfg.Procdesc.t -> Procname.t -> Sil.location -> (Sil.exp * Sil.typ) list -> Prop.normal Prop.t -> Paths.Path.t -> (Prop.normal Prop.t * Paths.Path.t) list
