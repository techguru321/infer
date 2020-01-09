(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging
open ConcurrencyModels

let attrs_of_pname = Summary.OnDisk.proc_resolve_attributes

module AnnotationAliases = struct
  let of_json = function
    | `List aliases ->
        List.map ~f:Yojson.Basic.Util.to_string aliases
    | _ ->
        L.(die UserError)
          "Couldn't parse thread-safety annotation aliases; expected list of strings"
end

type container_access = ContainerRead | ContainerWrite

let make_android_support_template suffix methods =
  let open MethodMatcher in
  [ {default with classname= "android.support.v4.util." ^ suffix; methods}
  ; {default with classname= "androidx.core.util." ^ suffix; methods} ]


let is_java_container_write =
  let open MethodMatcher in
  let array_methods =
    ["append"; "clear"; "delete"; "put"; "remove"; "removeAt"; "removeAtRange"; "setValueAt"]
  in
  make_android_support_template "Pools$SimplePool" ["acquire"; "release"]
  @ make_android_support_template "SimpleArrayMap"
      ["clear"; "ensureCapacity"; "put"; "putAll"; "remove"; "removeAt"; "setValueAt"]
  @ make_android_support_template "SparseArrayCompat" array_methods
  @ [ {default with classname= "android.util.SparseArray"; methods= array_methods}
    ; { default with
        classname= "java.util.List"
      ; methods= ["add"; "addAll"; "clear"; "remove"; "set"] }
    ; {default with classname= "java.util.Map"; methods= ["clear"; "put"; "putAll"; "remove"]} ]
  |> of_records


let is_java_container_read =
  let open MethodMatcher in
  let array_methods = ["clone"; "get"; "indexOfKey"; "indexOfValue"; "keyAt"; "size"; "valueAt"] in
  make_android_support_template "SimpleArrayMap"
    [ "containsKey"
    ; "containsValue"
    ; "get"
    ; "hashCode"
    ; "indexOfKey"
    ; "isEmpty"
    ; "keyAt"
    ; "size"
    ; "valueAt" ]
  @ make_android_support_template "SparseArrayCompat" array_methods
  @ [ {default with classname= "android.util.SparseArray"; methods= array_methods}
    ; { default with
        classname= "java.util.List"
      ; methods=
          [ "contains"
          ; "containsAll"
          ; "equals"
          ; "get"
          ; "hashCode"
          ; "indexOf"
          ; "isEmpty"
          ; "iterator"
          ; "lastIndexOf"
          ; "listIterator"
          ; "size"
          ; "toArray" ] }
    ; { default with
        classname= "java.util.Map"
      ; methods=
          [ "containsKey"
          ; "containsValue"
          ; "entrySet"
          ; "equals"
          ; "get"
          ; "hashCode"
          ; "isEmpty"
          ; "keySet"
          ; "size"
          ; "values" ] } ]
  |> of_records


let is_cpp_container_read =
  let is_container_operator pname_qualifiers =
    QualifiedCppName.extract_last pname_qualifiers
    |> Option.exists ~f:(fun (last, _) -> String.equal last "operator[]")
  in
  let matcher = QualifiedCppName.Match.of_fuzzy_qual_names ["std::map::find"] in
  fun pname ->
    let pname_qualifiers = Procname.get_qualifiers pname in
    QualifiedCppName.Match.match_qualifiers matcher pname_qualifiers
    || is_container_operator pname_qualifiers


let is_cpp_container_write =
  let matcher =
    QualifiedCppName.Match.of_fuzzy_qual_names ["std::map::operator[]"; "std::map::erase"]
  in
  fun pname -> QualifiedCppName.Match.match_qualifiers matcher (Procname.get_qualifiers pname)


let get_container_access pn tenv =
  match pn with
  | Procname.Java _ when is_java_container_write tenv pn [] ->
      Some ContainerWrite
  | Procname.Java _ when is_java_container_read tenv pn [] ->
      Some ContainerRead
  | Procname.Java _ ->
      None
  (* The following order matters: we want to check if pname is a container write
     before we check if pname is a container read. This is due to a different
     treatment between std::map::operator[] and all other operator[]. *)
  | (Procname.ObjC_Cpp _ | C _) when is_cpp_container_write pn ->
      Some ContainerWrite
  | (Procname.ObjC_Cpp _ | C _) when is_cpp_container_read pn ->
      Some ContainerRead
  | _ ->
      None


(** holds of procedure names which should not be analyzed in order to avoid known sources of
    inaccuracy *)
let should_skip =
  let matcher =
    lazy
      (QualifiedCppName.Match.of_fuzzy_qual_names ~prefix:true
         [ "folly::AtomicStruct"
         ; "folly::fbstring_core"
         ; "folly::Future"
         ; "folly::futures"
         ; "folly::LockedPtr"
         ; "folly::Optional"
         ; "folly::Promise"
         ; "folly::ThreadLocal"
         ; "folly::detail::SingletonHolder"
         ; "std::atomic"
         ; "std::vector" ])
  in
  function
  | Procname.ObjC_Cpp cpp_pname as pname ->
      Procname.ObjC_Cpp.is_destructor cpp_pname
      || QualifiedCppName.Match.match_qualifiers (Lazy.force matcher)
           (Procname.get_qualifiers pname)
  | _ ->
      false


let has_return_annot predicate pn = Annotations.pname_has_return_annot pn ~attrs_of_pname predicate

let is_functional pname =
  let is_annotated_functional = has_return_annot Annotations.ia_is_functional in
  let is_modeled_functional = function
    | Procname.Java java_pname -> (
      match (Procname.Java.get_class_name java_pname, Procname.Java.get_method java_pname) with
      | "android.content.res.Resources", method_name ->
          (* all methods of Resources are considered @Functional except for the ones in this
             blacklist *)
          let non_functional_resource_methods =
            [ "getAssets"
            ; "getConfiguration"
            ; "getSystem"
            ; "newTheme"
            ; "openRawResource"
            ; "openRawResourceFd" ]
          in
          not (List.mem ~equal:String.equal non_functional_resource_methods method_name)
      | _ ->
          false )
    | _ ->
        false
  in
  is_annotated_functional pname || is_modeled_functional pname


let nsobject = Typ.Name.Objc.from_qual_name (QualifiedCppName.of_qual_string "NSObject")

let acquires_ownership pname tenv =
  let is_nsobject_init = function
    | Procname.ObjC_Cpp {kind= Procname.ObjC_Cpp.ObjCInstanceMethod; method_name= "init"; class_name}
      ->
        Typ.Name.equal class_name nsobject
    | _ ->
        false
  in
  let is_allocation pn =
    Procname.equal pn BuiltinDecl.__new
    || Procname.equal pn BuiltinDecl.__new_array
    || is_nsobject_init pn
  in
  (* identify library functions that maintain ownership invariants behind the scenes *)
  let is_owned_in_library = function
    | Procname.Java java_pname -> (
      match (Procname.Java.get_class_name java_pname, Procname.Java.get_method java_pname) with
      | "javax.inject.Provider", "get" ->
          (* in dependency injection, the library allocates fresh values behind the scenes *)
          true
      | ("java.lang.Class" | "java.lang.reflect.Constructor"), "newInstance" ->
          (* reflection can perform allocations *)
          true
      | "java.lang.Object", "clone" ->
          (* cloning is like allocation *)
          true
      | "java.lang.ThreadLocal", "get" ->
          (* ThreadLocal prevents sharing between threads behind the scenes *)
          true
      | ("android.app.Activity" | "android.view.View"), "findViewById" ->
          (* assume findViewById creates fresh View's (note: not always true) *)
          true
      | ( ( "android.support.v4.util.Pools$Pool"
          | "android.support.v4.util.Pools$SimplePool"
          | "android.support.v4.util.Pools$SynchronizedPool"
          | "androidx.core.util.Pools$Pool"
          | "androidx.core.util.Pools$SimplePool"
          | "androidx.core.util.Pools$SynchronizedPool" )
        , "acquire" ) ->
          (* a pool should own all of its objects *)
          true
      | _ ->
          false )
    | _ ->
        false
  in
  is_allocation pname || is_owned_in_library pname
  || PatternMatch.override_exists is_owned_in_library tenv pname


(* return true if the given procname boxes a primitive type into a reference type *)
let is_box = function
  | Procname.Java java_pname -> (
    match (Procname.Java.get_class_name java_pname, Procname.Java.get_method java_pname) with
    | ( ( "java.lang.Boolean"
        | "java.lang.Byte"
        | "java.lang.Char"
        | "java.lang.Double"
        | "java.lang.Float"
        | "java.lang.Integer"
        | "java.lang.Long"
        | "java.lang.Short" )
      , "valueOf" ) ->
        true
    | _ ->
        false )
  | _ ->
      false


(* Methods in @ThreadConfined classes and methods annotated with @ThreadConfined are assumed to all
  run on the same thread. For the moment we won't warn on accesses resulting from use of such
  methods at all. In future we should account for races between these methods and methods from
  completely different classes that don't necessarily run on the same thread as the confined
  object. *)
let is_thread_confined_method tenv pname =
  ConcurrencyModels.find_override_or_superclass_annotated ~attrs_of_pname
    Annotations.ia_is_thread_confined tenv pname
  |> Option.is_some


let threadsafe_annotations =
  Annotations.thread_safe :: AnnotationAliases.of_json Config.threadsafe_aliases


(* returns true if the annotation is @ThreadSafe, @ThreadSafe(enableChecks = true), or is defined
   as an alias of @ThreadSafe in a .inferconfig file. *)
let is_thread_safe item_annot =
  let f ((annot : Annot.t), _) =
    List.exists ~f:(Annotations.annot_ends_with annot) threadsafe_annotations
    &&
    match annot.Annot.parameters with
    | [Annot.{name= Some "enableChecks"; value= "false"}] ->
        false
    | _ ->
        true
  in
  List.exists ~f item_annot


(* returns true if the annotation is @ThreadSafe(enableChecks = false) *)
let is_assumed_thread_safe item_annot =
  let f (annot, _) =
    Annotations.annot_ends_with annot Annotations.thread_safe
    &&
    match annot.Annot.parameters with
    | [Annot.{name= Some "enableChecks"; value= "false"}] ->
        true
    | _ ->
        false
  in
  List.exists ~f item_annot


let is_assumed_thread_safe tenv pname =
  ConcurrencyModels.find_override_or_superclass_annotated ~attrs_of_pname is_assumed_thread_safe
    tenv pname
  |> Option.is_some


(* return true if we should compute a summary for the procedure. if this returns false, we won't
         analyze the procedure or report any warnings on it *)
(* note: in the future, we will want to analyze the procedures in all of these cases in order to
         find more bugs. this is just a temporary measure to avoid obvious false positives *)
let should_analyze_proc tenv pn =
  (not
     ( match pn with
     | Procname.Java java_pname ->
         Procname.Java.is_class_initializer java_pname
         || Typ.Name.Java.is_external (Procname.Java.get_class_type_name java_pname)
     (* third party code may be hard to change, not useful to report races there *)
     | _ ->
         false ))
  && (not (FbThreadSafety.is_logging_method pn))
  && (not (is_assumed_thread_safe tenv pn))
  && not (should_skip pn)


let get_current_class_and_threadsafe_superclasses tenv pname =
  get_current_class_and_annotated_superclasses is_thread_safe tenv pname


let is_thread_safe_method pname tenv =
  match find_override_or_superclass_annotated ~attrs_of_pname is_thread_safe tenv pname with
  | Some (DirectlyAnnotated | Override _) ->
      true
  | _ ->
      false


let is_marked_thread_safe pname tenv =
  ((* current class not marked [@NotThreadSafe] *)
   not
     (PatternMatch.check_current_class_attributes Annotations.ia_is_not_thread_safe tenv pname))
  && ConcurrencyModels.find_override_or_superclass_annotated ~attrs_of_pname is_thread_safe tenv
       pname
     |> Option.is_some


let is_safe_access (access : 'a HilExp.Access.t) prefix_exp tenv =
  match (access, HilExp.AccessExpression.get_typ prefix_exp tenv) with
  | ( HilExp.Access.FieldAccess fieldname
    , Some ({Typ.desc= Tstruct typename} | {desc= Tptr ({desc= Tstruct typename}, _)}) ) -> (
    match Tenv.lookup tenv typename with
    | Some struct_typ ->
        Annotations.struct_typ_has_annot struct_typ Annotations.ia_is_thread_confined
        || Annotations.field_has_annot fieldname struct_typ Annotations.ia_is_thread_confined
        || Annotations.field_has_annot fieldname struct_typ Annotations.ia_is_volatile
    | None ->
        false )
  | _ ->
      false


let is_builder_class tname = String.is_suffix ~suffix:"$Builder" (Typ.Name.to_string tname)

let is_builder_method java_pname = is_builder_class (Procname.Java.get_class_type_name java_pname)

let should_flag_interface_call tenv exps call_flags pname =
  let thread_safe_or_thread_confined annot =
    Annotations.ia_is_thread_safe annot || Annotations.ia_is_thread_confined annot
  in
  (* is this function in library code from the JDK core libraries or Android? *)
  let is_java_library java_pname =
    Procname.Java.get_package java_pname
    |> Option.exists ~f:(fun package_name ->
           String.is_prefix ~prefix:"java." package_name
           || String.is_prefix ~prefix:"android." package_name
           || String.is_prefix ~prefix:"com.google." package_name )
  in
  let receiver_is_not_safe exps tenv =
    List.hd exps
    |> Option.bind ~f:(fun exp -> HilExp.get_access_exprs exp |> List.hd)
    |> Option.map ~f:HilExp.AccessExpression.truncate
    |> Option.exists ~f:(function
         | Some (receiver_prefix, receiver_access) ->
             not (is_safe_access receiver_access receiver_prefix tenv)
         | _ ->
             true )
  in
  let implements_threadsafe_interface java_pname tenv =
    (* generated classes implementing this interface are always threadsafe *)
    Procname.Java.get_class_type_name java_pname
    |> fun tname -> PatternMatch.is_subtype_of_str tenv tname "android.os.IInterface"
  in
  match pname with
  | Procname.Java java_pname ->
      call_flags.CallFlags.cf_interface
      && (not (is_java_library java_pname))
      && (not (is_builder_method java_pname))
      (* can't ask anyone to annotate interfaces in library code, and Builders should always be
         thread-safe (would be unreasonable to ask everyone to annotate them) *)
      && ConcurrencyModels.find_override_or_superclass_annotated ~attrs_of_pname
           thread_safe_or_thread_confined tenv pname
         |> Option.is_none
      && receiver_is_not_safe exps tenv
      && not (implements_threadsafe_interface java_pname tenv)
  | _ ->
      false


let is_synchronized_container callee_pname (access_exp : HilExp.AccessExpression.t) tenv =
  let is_threadsafe_collection pn tenv =
    match pn with
    | Procname.Java java_pname ->
        let typename = Procname.Java.get_class_type_name java_pname in
        let aux tn _ =
          match Typ.Name.name tn with
          | "java.util.concurrent.ConcurrentMap"
          | "java.util.concurrent.CopyOnWriteArrayList"
          | "android.support.v4.util.Pools$SynchronizedPool"
          | "androidx.core.util.Pools$SynchronizedPool" ->
              true
          | _ ->
              false
        in
        PatternMatch.supertype_exists tenv aux typename
    | _ ->
        false
  in
  if is_threadsafe_collection callee_pname tenv then true
  else
    let is_annotated_synchronized base_typename container_field tenv =
      match Tenv.lookup tenv base_typename with
      | Some base_typ ->
          Annotations.field_has_annot container_field base_typ
            Annotations.ia_is_synchronized_collection
      | None ->
          false
    in
    let open HilExp in
    match
      AccessExpression.to_accesses access_exp
      |> snd
      |> List.rev_filter ~f:Access.is_field_or_array_access
    with
    | Access.FieldAccess base_field :: Access.FieldAccess container_field :: _
      when Procname.is_java callee_pname ->
        let base_typename = Fieldname.get_class_name base_field in
        is_annotated_synchronized base_typename container_field tenv
    | [Access.FieldAccess container_field] -> (
      match (AccessExpression.get_base access_exp |> snd).desc with
      | Typ.Tstruct base_typename | Tptr ({Typ.desc= Tstruct base_typename}, _) ->
          is_annotated_synchronized base_typename container_field tenv
      | _ ->
          false )
    | _ ->
        false


(** check that callee is abstract and accepts one argument. In addition, its argument type must be
    equal to its return type. *)
let is_abstract_getthis_like callee =
  attrs_of_pname callee
  |> Option.exists ~f:(fun (attrs : ProcAttributes.t) ->
         attrs.is_abstract
         &&
         match attrs.formals with
         | [(_, typ)] when Typ.equal typ attrs.ret_type ->
             true
         | _ ->
             false )


let creates_builder callee =
  (match callee with Procname.Java jpname -> Procname.Java.is_static jpname | _ -> false)
  && String.equal "create" (Procname.get_method callee)
  && attrs_of_pname callee
     |> Option.exists ~f:(fun (attrs : ProcAttributes.t) ->
            match attrs.ret_type with
            | Typ.{desc= Tptr ({desc= Tstruct ret_class}, _)} ->
                is_builder_class ret_class
            | _ ->
                false )


let is_builder_passthrough callee =
  match callee with
  | Procname.Java java_pname ->
      (not (Procname.Java.is_static java_pname))
      && is_builder_method java_pname
      && attrs_of_pname callee
         |> Option.exists ~f:(fun (attrs : ProcAttributes.t) ->
                match attrs.formals with
                | (_, typ) :: _ when Typ.equal typ attrs.ret_type ->
                    true
                | _ ->
                    false )
  | _ ->
      false
