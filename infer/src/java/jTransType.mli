(*
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

open Javalib_pack
open Sawja_pack

(** transforms a Java type into a Sil named type  *)
val get_named_type : JBasics.value_type -> Typ.t

(** transforms a Java class name into a Sil class name *)
val typename_of_classname : JBasics.class_name -> Typename.t

(** returns a name for a field based on a class name and a field name  *)
val create_fieldname : JBasics.class_name -> JBasics.field_signature -> Ident.fieldname

val get_method_kind : JCode.jcode Javalib.jmethod -> Procname.method_kind

(** returns a procedure name based on the class name and the method's signature. *)
val get_method_procname :
  JBasics.class_name -> JBasics.method_signature -> Procname.method_kind -> Procname.java

(** [get_class_struct_typ program tenv cn] returns the struct_typ representation of the class *)
val get_class_struct_typ: JClasspath.program -> Tenv.t -> JBasics.class_name -> StructTyp.t

(** [get_class_type_no_pointer program tenv cn] returns the sil type representation of the class
    without the pointer part *)
val get_class_type_no_pointer: JClasspath.program -> Tenv.t -> JBasics.class_name -> Typ.t

(** [get_class_type program tenv cn] returns the sil type representation of the class  *)
val get_class_type : JClasspath.program -> Tenv.t -> JBasics.class_name -> Typ.t

(** return true if [field_name] is the autogenerated C.$assertionsDisabled field for class C *)
val is_autogenerated_assert_field : Ident.fieldname -> bool

(** [is_closeable program tenv typ] check if typ is an implemtation of the Closeable interface *)
val is_closeable : JClasspath.program -> Tenv.t -> Typ.t -> bool

(** transforms a Java object type to a Typ.t *)
val object_type : JClasspath.program -> Tenv.t -> JBasics.object_type -> Typ.t

(** create sizeof expressions from the object type and the list of subtypes *)
val sizeof_of_object_type : JClasspath.program -> Tenv.t -> JBasics.object_type -> Subtype.t
  -> Exp.t

(** transforms a Java type to a Typ.t. *)
val value_type : JClasspath.program -> Tenv.t -> JBasics.value_type -> Typ.t

(** return the type of a formal parameter, looking up the class name in case of "this" *)
val param_type :
  JClasspath.program -> Tenv.t -> JBasics.class_name -> JBir.var -> JBasics.value_type -> Typ.t

(** Returns the return type of the method based on the return type specified in ms.
    If the method is the initialiser, return the type Object instead. *)
val return_type :
  JClasspath.program -> Tenv.t -> JBasics.method_signature -> JContext.meth_kind -> Typ.t

(** translates the type of an expression *)
val expr_type : JContext.t -> JBir.expr -> Typ.t

(** translates a conversion type from Java to Sil. *)
val cast_type : JBir.conv -> Typ.t

val package_to_string : string list -> string option

(** [create_array_type typ dim] creates an array type with dimension dim and content typ *)
val create_array_type : Typ.t -> int -> Typ.t

(** [extract_cn_type_np] returns the internal type of type when typ is a pointer type, otherwise returns typ *)
val extract_cn_type_np : Typ.t -> Typ.t

(** [extract_cn_type_np] returns the Java class name of typ when typ is a pointer type, otherwise returns None *)
val extract_cn_no_obj : Typ.t -> JBasics.class_name option

(** returns a string representation of a Java basic type. *)
val string_of_basic_type : JBasics.java_basic_type -> string

(** returns a string representation of a Java type *)
val string_of_type : JBasics.value_type -> string

(** returns a string representation of an object Java type *)
val object_type_to_string : JBasics.object_type -> string

val vt_to_java_type : JBasics.value_type -> Procname.java_type

val cn_to_java_type : JBasics.class_name -> Procname.java_type

(** Add the types of the models to the type environment passed as parameter *)
val add_models_types : Tenv.t -> unit

(** list of methods that are never returning null *)
val never_returning_null : Procname.java list
