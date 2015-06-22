(*
* Copyright (c) 2009 -2013 Monoidics ltd.
* Copyright (c) 2013 - Facebook.
* All rights reserved.
*)

(** Module for Procedure Names *)

open Utils

(** Type of procedure names *)
type t

type java_type = string option * string

(** Comparison for proc names *)
val compare : t -> t -> int

(** Equality for proc names *)
val equal : t -> t -> bool

(** Convert a string to a proc name *)
val from_string : string -> t

(** Create a C++ procedure name from plain and mangled name *)
val mangled_cpp : string -> string -> t

(** Create a static procedure name from a plain name and source file *)
val mangled_static : string -> DB.source_file -> t

(** Create a Java procedure name from its class_name method_name args_type_name return_type_name *)
val mangled_java : java_type -> java_type option -> string -> java_type list -> t

(** Create an objc procedure name from a class_name and method_name. *)
val mangled_objc : string -> string -> t

(** Create an objc block name. *)
val mangled_objc_block : string -> t

(** Return true if this is a Java procedure name *)
val is_java : t -> bool

(** Return true if this is an Objective-C procedure name *)
val is_objc : t -> bool

(** Replace package and classname of a java procname. *)
val java_replace_class : t -> string -> t

(** Replace the method of a java procname. *)
val java_replace_method : t -> string -> t

(** Replace the method of a java procname. *)
val java_replace_return_type : t -> java_type -> t

(** Replace the class name of an Objective-C procedure name. *)
val objc_replace_class : t -> string -> t

(** Return the class name of a java procedure name. *)
val java_get_class : t -> string

(** Return the simple class name of a java procedure name. *)
val java_get_simple_class : t -> string

(** Return the method name of a java procedure name. *)
val java_get_method : t -> string

(** Return the method name of a objc procedure name. *)
val clang_get_method : t -> string

(** Replace the method name of an existing java procname. *)
val java_replace_method : t -> string -> t

(** Return the return type of a java procedure name. *)
val java_get_return_type : t -> string

(** Return the parameters of a java procedure name. *)
val java_get_parameters : t -> string list

(** Check if the last parameter is a hidden inner class, and remove it if present.
This is used in private constructors, where a proxy constructor is generated
with an extra parameter and calls the normal constructor. *)
val java_remove_hidden_inner_class_parameter : t -> t option

(** Check if a class string is an anoynmous inner class name *)
val is_anonymous_inner_class_name : string -> bool

(** [is_constructor pname] returns true if [pname] is a constructor *)
val is_constructor : t -> bool

(** [java_is_close pname] returns true if the method name is "close" *)
val java_is_close : t -> bool

(** [is_class_initializer pname] returns true if [pname] is a class initializer *)
val is_class_initializer : t -> bool

(** [is_infer_undefined pn] returns true if [pn] is a special Infer undefined proc *)
val is_infer_undefined : t -> bool

(** Check if the procedure belongs to an anonymous inner class. *)
val java_is_anonymous_inner_class : t -> bool

(** Check if the procedure name is an anonymous inner class constructor. *)
val java_is_anonymous_inner_class_constructor : t -> bool

(** Check if the procedure name is an acess method (e.g. access$100 used to
access private members from a nested class. *)
val java_is_access_method : t -> bool

(** Check if the proc name has the type of a java vararg.
Note: currently only checks that the last argument has type Object[]. *)
val java_is_vararg : t -> bool

(** Convert a proc name to a string for the user to see *)
val to_string : t -> string

(** Convert a proc name into a easy string for the user to see in an IDE *)
val to_simplified_string : ?withclass: bool -> t -> string

(** Convert a proc name into a unique identifier *)
val to_unique_id : t -> string

(** Convert a proc name to a filename *)
val to_filename : t -> string

(** empty proc name *)
val empty : t

(** Pretty print a proc name *)
val pp : Format.formatter -> t -> unit

(** hash function for procname *)
val hash_pname : t -> int

(** hash tables with proc names as keys *)
module Hash : Hashtbl.S with type key = t

(** maps from proc names *)
module Map : Map.S with type key = t

(** sets of proc names *)
module Set : Set.S with type elt = t

(** Pretty print a set of proc names *)
val pp_set : Format.formatter -> Set.t -> unit
