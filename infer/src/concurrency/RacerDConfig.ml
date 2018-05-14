(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
module F = Format
module L = Logging

module AnnotationAliases = struct
  let of_json = function
    | `List aliases ->
        List.map ~f:Yojson.Basic.Util.to_string aliases
    | _ ->
        L.(die UserError)
          "Couldn't parse thread-safety annotation aliases; expected list of strings"
end

module Models = struct
  type lock = Lock | Unlock | LockedIfTrue | NoEffect

  type thread = BackgroundThread | MainThread | MainThreadIfTrue | UnknownThread

  type container_access = ContainerRead | ContainerWrite

  let is_thread_utils_type java_pname =
    let pn = Typ.Procname.Java.get_class_name java_pname in
    String.is_suffix ~suffix:"ThreadUtils" pn || String.is_suffix ~suffix:"ThreadUtil" pn


  let is_thread_utils_method method_name_str = function
    | Typ.Procname.Java java_pname ->
        is_thread_utils_type java_pname
        && String.equal (Typ.Procname.Java.get_method java_pname) method_name_str
    | _ ->
        false


  let get_thread = function
    | Typ.Procname.Java java_pname when is_thread_utils_type java_pname -> (
      match Typ.Procname.Java.get_method java_pname with
      | "assertMainThread" | "assertOnUiThread" | "checkOnMainThread" ->
          MainThread
      | "isMainThread" | "isUiThread" ->
          MainThreadIfTrue
      | "assertOnBackgroundThread" | "assertOnNonUiThread" | "checkOnNonUiThread" ->
          BackgroundThread
      | _ ->
          UnknownThread )
    | _ ->
        UnknownThread


  let get_lock =
    let is_cpp_lock =
      let matcher_lock =
        QualifiedCppName.Match.of_fuzzy_qual_names
          [ "apache::thrift::concurrency::ReadWriteMutex::acquireRead"
          ; "apache::thrift::concurrency::ReadWriteMutex::acquireWrite"
          ; "folly::MicroSpinLock::lock"
          ; "folly::RWSpinLock::lock"
          ; "folly::RWSpinLock::lock_shared"
          ; "folly::SharedMutexImpl::lockExclusiveImpl"
          ; "folly::SharedMutexImpl::lockSharedImpl"
          ; "std::mutex::lock"
          ; "std::unique_lock::lock"
          ; "std::lock" ]
      in
      let matcher_lock_constructor =
        QualifiedCppName.Match.of_fuzzy_qual_names
          [ "std::lock_guard::lock_guard"
          ; "std::unique_lock::unique_lock"
          ; "folly::LockedPtr::LockedPtr" ]
      in
      fun pname actuals ->
        QualifiedCppName.Match.match_qualifiers matcher_lock (Typ.Procname.get_qualifiers pname)
        || QualifiedCppName.Match.match_qualifiers matcher_lock_constructor
             (Typ.Procname.get_qualifiers pname)
           (* Passing additional parameter allows to defer the lock *)
           && Int.equal 2 (List.length actuals)
    and is_cpp_unlock =
      let matcher =
        QualifiedCppName.Match.of_fuzzy_qual_names
          [ "apache::thrift::concurrency::ReadWriteMutex::release"
          ; "folly::MicroSpinLock::unlock"
          ; "folly::RWSpinLock::unlock"
          ; "folly::RWSpinLock::unlock_shared"
          ; "folly::SharedMutexImpl::unlock"
          ; "folly::SharedMutexImpl::unlock_shared"
          ; "std::lock_guard::~lock_guard"
          ; "std::mutex::unlock"
          ; "std::unique_lock::unlock"
          ; "std::unique_lock::~unique_lock"
          ; "folly::LockedPtr::~LockedPtr" ]
      in
      fun pname ->
        QualifiedCppName.Match.match_qualifiers matcher (Typ.Procname.get_qualifiers pname)
    and is_cpp_trylock =
      let matcher =
        QualifiedCppName.Match.of_fuzzy_qual_names
          ["std::unique_lock::owns_lock"; "std::unique_lock::try_lock"]
      in
      fun pname ->
        QualifiedCppName.Match.match_qualifiers matcher (Typ.Procname.get_qualifiers pname)
    in
    fun pname actuals ->
      match pname with
      | Typ.Procname.Java java_pname
        -> (
          if is_thread_utils_method "assertHoldsLock" (Typ.Procname.Java java_pname) then Lock
          else
            match
              (Typ.Procname.Java.get_class_name java_pname, Typ.Procname.Java.get_method java_pname)
            with
            | ( ( "java.util.concurrent.locks.Lock"
                | "java.util.concurrent.locks.ReentrantLock"
                | "java.util.concurrent.locks.ReentrantReadWriteLock$ReadLock"
                | "java.util.concurrent.locks.ReentrantReadWriteLock$WriteLock" )
              , ("lock" | "lockInterruptibly") ) ->
                Lock
            | ( ( "java.util.concurrent.locks.Lock"
                | "java.util.concurrent.locks.ReentrantLock"
                | "java.util.concurrent.locks.ReentrantReadWriteLock$ReadLock"
                | "java.util.concurrent.locks.ReentrantReadWriteLock$WriteLock" )
              , "unlock" ) ->
                Unlock
            | ( ( "java.util.concurrent.locks.Lock"
                | "java.util.concurrent.locks.ReentrantLock"
                | "java.util.concurrent.locks.ReentrantReadWriteLock$ReadLock"
                | "java.util.concurrent.locks.ReentrantReadWriteLock$WriteLock" )
              , "tryLock" ) ->
                LockedIfTrue
            | ( "com.facebook.buck.util.concurrent.AutoCloseableReadWriteUpdateLock"
              , ("readLock" | "updateLock" | "writeLock") ) ->
                Lock
            | _ ->
                NoEffect )
      | (Typ.Procname.ObjC_Cpp _ | C _) as pname when is_cpp_lock pname actuals ->
          Lock
      | (Typ.Procname.ObjC_Cpp _ | C _) as pname when is_cpp_unlock pname ->
          Unlock
      | (Typ.Procname.ObjC_Cpp _ | C _) as pname when is_cpp_trylock pname ->
          LockedIfTrue
      | pname when Typ.Procname.equal pname BuiltinDecl.__set_locked_attribute ->
          Lock
      | pname when Typ.Procname.equal pname BuiltinDecl.__delete_locked_attribute ->
          Unlock
      | _ ->
          NoEffect


  let get_container_access =
    let is_cpp_container_read =
      let is_container_operator pname_qualifiers =
        match QualifiedCppName.extract_last pname_qualifiers with
        | Some (last, _) ->
            String.equal last "operator[]"
        | None ->
            false
      in
      let matcher = QualifiedCppName.Match.of_fuzzy_qual_names ["std::map::find"] in
      fun pname ->
        let pname_qualifiers = Typ.Procname.get_qualifiers pname in
        QualifiedCppName.Match.match_qualifiers matcher pname_qualifiers
        || is_container_operator pname_qualifiers
    and is_cpp_container_write =
      let matcher =
        QualifiedCppName.Match.of_fuzzy_qual_names ["std::map::operator[]"; "std::map::erase"]
      in
      fun pname ->
        QualifiedCppName.Match.match_qualifiers matcher (Typ.Procname.get_qualifiers pname)
    in
    fun pn tenv ->
      match pn with
      | Typ.Procname.Java java_pname ->
          let typename = Typ.Name.Java.from_string (Typ.Procname.Java.get_class_name java_pname) in
          let get_container_access_ typename =
            match (Typ.Name.name typename, Typ.Procname.Java.get_method java_pname) with
            | ( ("android.util.SparseArray" | "android.support.v4.util.SparseArrayCompat")
              , ( "append"
                | "clear"
                | "delete"
                | "put"
                | "remove"
                | "removeAt"
                | "removeAtRange"
                | "setValueAt" ) ) ->
                Some ContainerWrite
            | ( ("android.util.SparseArray" | "android.support.v4.util.SparseArrayCompat")
              , ("clone" | "get" | "indexOfKey" | "indexOfValue" | "keyAt" | "size" | "valueAt") ) ->
                Some ContainerRead
            | ( "android.support.v4.util.SimpleArrayMap"
              , ( "clear"
                | "ensureCapacity"
                | "put"
                | "putAll"
                | "remove"
                | "removeAt"
                | "setValueAt" ) ) ->
                Some ContainerWrite
            | ( "android.support.v4.util.SimpleArrayMap"
              , ( "containsKey"
                | "containsValue"
                | "get"
                | "hashCode"
                | "indexOfKey"
                | "isEmpty"
                | "keyAt"
                | "size"
                | "valueAt" ) ) ->
                Some ContainerRead
            | "android.support.v4.util.Pools$SimplePool", ("acquire" | "release") ->
                Some ContainerWrite
            | "java.util.List", ("add" | "addAll" | "clear" | "remove" | "set") ->
                Some ContainerWrite
            | ( "java.util.List"
              , ( "contains"
                | "containsAll"
                | "equals"
                | "get"
                | "hashCode"
                | "indexOf"
                | "isEmpty"
                | "iterator"
                | "lastIndexOf"
                | "listIterator"
                | "size"
                | "toArray" ) ) ->
                Some ContainerRead
            | "java.util.Map", ("clear" | "put" | "putAll" | "remove") ->
                Some ContainerWrite
            | ( "java.util.Map"
              , ( "containsKey"
                | "containsValue"
                | "entrySet"
                | "equals"
                | "get"
                | "hashCode"
                | "isEmpty"
                | "keySet"
                | "size"
                | "values" ) ) ->
                Some ContainerRead
            | _ ->
                None
          in
          PatternMatch.supertype_find_map_opt tenv get_container_access_ typename
      (* The following order matters: we want to check if pname is a container write
         before we check if pname is a container read. This is due to a different
         treatment between std::map::operator[] and all other operator[]. *)
      | (Typ.Procname.ObjC_Cpp _ | C _) as pname
        when is_cpp_container_write pname ->
          Some ContainerWrite
      | (Typ.Procname.ObjC_Cpp _ | C _) as pname when is_cpp_container_read pname ->
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
      | Typ.Procname.ObjC_Cpp cpp_pname as pname ->
          Typ.Procname.ObjC_Cpp.is_destructor cpp_pname
          || QualifiedCppName.Match.match_qualifiers (Lazy.force matcher)
               (Typ.Procname.get_qualifiers pname)
      | _ ->
          false


  (** return true if this function is library code from the JDK core libraries or Android *)
  let is_java_library = function
    | Typ.Procname.Java java_pname -> (
      match Typ.Procname.Java.get_package java_pname with
      | Some package_name ->
          String.is_prefix ~prefix:"java." package_name
          || String.is_prefix ~prefix:"android." package_name
          || String.is_prefix ~prefix:"com.google." package_name
      | None ->
          false )
    | _ ->
        false


  let is_builder_function = function
    | Typ.Procname.Java java_pname ->
        String.is_suffix ~suffix:"$Builder" (Typ.Procname.Java.get_class_name java_pname)
    | _ ->
        false


  let has_return_annot predicate pn =
    Annotations.pname_has_return_annot pn ~attrs_of_pname:Summary.proc_resolve_attributes predicate


  let is_functional pname =
    let is_annotated_functional = has_return_annot Annotations.ia_is_functional in
    let is_modeled_functional = function
      | Typ.Procname.Java java_pname -> (
        match
          (Typ.Procname.Java.get_class_name java_pname, Typ.Procname.Java.get_method java_pname)
        with
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


  let acquires_ownership pname tenv =
    let is_allocation pn =
      Typ.Procname.equal pn BuiltinDecl.__new || Typ.Procname.equal pn BuiltinDecl.__new_array
    in
    (* identify library functions that maintain ownership invariants behind the scenes *)
    let is_owned_in_library = function
      | Typ.Procname.Java java_pname -> (
        match
          (Typ.Procname.Java.get_class_name java_pname, Typ.Procname.Java.get_method java_pname)
        with
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
            | "android.support.v4.util.Pools$SynchronizedPool" )
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


  let is_threadsafe_collection pn tenv =
    match pn with
    | Typ.Procname.Java java_pname ->
        let typename = Typ.Name.Java.from_string (Typ.Procname.Java.get_class_name java_pname) in
        let aux tn _ =
          match Typ.Name.name tn with
          | "java.util.concurrent.ConcurrentMap"
          | "java.util.concurrent.CopyOnWriteArrayList"
          | "android.support.v4.util.Pools$SynchronizedPool" ->
              true
          | _ ->
              false
        in
        PatternMatch.supertype_exists tenv aux typename
    | _ ->
        false


  (* return true if the given procname boxes a primitive type into a reference type *)
  let is_box = function
    | Typ.Procname.Java java_pname -> (
      match
        (Typ.Procname.Java.get_class_name java_pname, Typ.Procname.Java.get_method java_pname)
      with
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
  let is_thread_confined_method tenv pdesc =
    Annotations.pdesc_return_annot_ends_with pdesc Annotations.thread_confined
    || PatternMatch.check_current_class_attributes Annotations.ia_is_thread_confined tenv
         (Procdesc.get_proc_name pdesc)


  let threadsafe_annotations =
    Annotations.thread_safe :: AnnotationAliases.of_json Config.threadsafe_aliases


  (* returns true if the annotation is @ThreadSafe, @ThreadSafe(enableChecks = true), or is defined
     as an alias of @ThreadSafe in a .inferconfig file. *)
  let is_thread_safe item_annot =
    let f ((annot: Annot.t), _) =
      List.exists
        ~f:(fun annot_string ->
          Annotations.annot_ends_with annot annot_string
          || String.equal annot.class_name annot_string )
        threadsafe_annotations
      && match annot.Annot.parameters with ["false"] -> false | _ -> true
    in
    List.exists ~f item_annot


  (* returns true if the annotation is @ThreadSafe(enableChecks = false) *)
  let is_assumed_thread_safe item_annot =
    let f (annot, _) =
      Annotations.annot_ends_with annot Annotations.thread_safe
      && match annot.Annot.parameters with ["false"] -> true | _ -> false
    in
    List.exists ~f item_annot


  let pdesc_is_assumed_thread_safe pdesc tenv =
    is_assumed_thread_safe (Annotations.pdesc_get_return_annot pdesc)
    || PatternMatch.check_current_class_attributes is_assumed_thread_safe tenv
         (Procdesc.get_proc_name pdesc)


  (* return true if we should compute a summary for the procedure. if this returns false, we won't
      analyze the procedure or report any warnings on it *)
  (* note: in the future, we will want to analyze the procedures in all of these cases in order to
      find more bugs. this is just a temporary measure to avoid obvious false positives *)
  let should_analyze_proc pdesc tenv =
    let pn = Procdesc.get_proc_name pdesc in
    not
      ( match pn with
      | Typ.Procname.Java java_pname ->
          Typ.Procname.Java.is_class_initializer java_pname
          || Typ.Name.Java.is_external (Typ.Procname.Java.get_class_type_name java_pname)
      (* third party code may be hard to change, not useful to report races there *)
      | _ ->
          false )
    && not (FbThreadSafety.is_logging_method pn) && not (pdesc_is_assumed_thread_safe pdesc tenv)
    && not (should_skip pn)


  let get_current_class_and_annotated_superclasses is_annot tenv pname =
    match pname with
    | Typ.Procname.Java java_pname ->
        let current_class = Typ.Procname.Java.get_class_type_name java_pname in
        let annotated_classes =
          PatternMatch.find_superclasses_with_attributes is_annot tenv current_class
        in
        Some (current_class, annotated_classes)
    | _ ->
        None


  let is_annotated_or_overriden_annotated_method is_annot pname tenv =
    PatternMatch.override_exists
      (fun pn ->
        Annotations.pname_has_return_annot pn ~attrs_of_pname:Summary.proc_resolve_attributes
          is_annot )
      tenv pname


  (* we don't want to warn on methods that run on the UI thread because they should always be
        single-threaded *)
  let runs_on_ui_thread tenv proc_desc =
    (* assume that methods annotated with @UiThread, @OnEvent, @OnBind, @OnMount, @OnUnbind,
          @OnUnmount always run on the UI thread *)
    let is_annot annot =
      Annotations.ia_is_ui_thread annot || Annotations.ia_is_on_bind annot
      || Annotations.ia_is_on_event annot || Annotations.ia_is_on_mount annot
      || Annotations.ia_is_on_unbind annot || Annotations.ia_is_on_unmount annot
    in
    let pname = Procdesc.get_proc_name proc_desc in
    Annotations.pdesc_has_return_annot proc_desc is_annot
    || is_annotated_or_overriden_annotated_method is_annot pname tenv
    ||
    match get_current_class_and_annotated_superclasses Annotations.ia_is_ui_thread tenv pname with
    | Some (_, _ :: _) ->
        true
    | Some (current_class, _) ->
        PatternMatch.is_subtype_of_str tenv current_class "android.app.Service"
        && not (PatternMatch.is_subtype_of_str tenv current_class "android.app.IntentService")
    | _ ->
        false


  let get_current_class_and_threadsafe_superclasses tenv pname =
    get_current_class_and_annotated_superclasses is_thread_safe tenv pname


  let is_thread_safe_class pname tenv =
    not
      ((* current class not marked thread-safe *)
       PatternMatch.check_current_class_attributes Annotations.ia_is_not_thread_safe tenv pname)
    &&
    (* current class or superclass is marked thread-safe *)
    match get_current_class_and_threadsafe_superclasses tenv pname with
    | Some (_, thread_safe_annotated_classes) ->
        not (List.is_empty thread_safe_annotated_classes)
    | _ ->
        false


  let is_thread_safe_method pname tenv =
    is_annotated_or_overriden_annotated_method is_thread_safe pname tenv


  let is_marked_thread_safe pdesc tenv =
    let pname = Procdesc.get_proc_name pdesc in
    is_thread_safe_class pname tenv || is_thread_safe_method pname tenv


  (* return true if procedure is at an abstraction boundary or reporting has been explicitly
     requested via @ThreadSafe *)
  let should_report_on_proc proc_desc tenv =
    let proc_name = Procdesc.get_proc_name proc_desc in
    is_thread_safe_method proc_name tenv
    || not
         ( match proc_name with
         | Typ.Procname.Java java_pname ->
             Typ.Procname.Java.is_autogen_method java_pname
         | _ ->
             false )
       && Procdesc.get_access proc_desc <> PredSymb.Private
       && not (Annotations.pdesc_return_annot_ends_with proc_desc Annotations.visibleForTesting)


  let is_call_of_class_or_superclass ?(method_prefix= false) ?(actuals_pred= fun _ -> true)
      class_names method_name tenv pn actuals =
    actuals_pred actuals
    &&
    match pn with
    | Typ.Procname.Java java_pname ->
        let classname = Typ.Procname.Java.get_class_type_name java_pname in
        let mthd = Typ.Procname.Java.get_method java_pname in
        let is_target_class =
          let targets = List.map class_names ~f:Typ.Name.Java.from_string in
          fun tname _ -> List.mem targets tname ~equal:Typ.Name.equal
        in
        ( if method_prefix then String.is_prefix mthd ~prefix:method_name
        else String.equal mthd method_name )
        && PatternMatch.supertype_exists tenv is_target_class classname
    | _ ->
        false


  (** magical value from https://developer.android.com/topic/performance/vitals/anr *)
  let android_anr_time_limit = 5.0

  (** can this timeout cause an anr? *)
  let is_excessive_timeout =
    let time_units =
      String.Map.of_alist_exn
        [ ("NANOSECONDS", 0.000_000_001)
        ; ("MICROSECONDS", 0.000_001)
        ; ("MILLISECONDS", 0.001)
        ; ("SECONDS", 1.0)
        ; ("MINUTES", 60.0)
        ; ("HOURS", 3_600.0)
        ; ("DAYS", 86_400.0) ]
    in
    fun duration_exp timeunit_exp ->
      match (duration_exp, timeunit_exp) with
      | HilExp.Constant (Const.Cint duration_lit), HilExp.AccessExpression timeunit_acc_exp -> (
        match AccessExpression.to_access_path timeunit_acc_exp with
        | _, [AccessPath.FieldAccess field]
          when String.equal "java.util.concurrent.TimeUnit" (Typ.Fieldname.Java.get_class field) ->
            let fieldname = Typ.Fieldname.Java.get_field field in
            let duration = float_of_int (IntLit.to_int duration_lit) in
            String.Map.find time_units fieldname
            |> Option.value_map ~default:false ~f:(fun unit_in_secs ->
                   unit_in_secs *. duration >. android_anr_time_limit )
        | _ ->
            false )
      | _ ->
          false


  (** It's surprisingly difficult making any sense of the official documentation on java.io classes
                as to whether methods may block.  We approximate these by calls in traditionally blocking
                classes (non-channel based I/O), to methods `(Reader|InputStream).read*`.
                Initially, (Writer|OutputStream).(flush|close) were also matched, but this generated too
                many reports *)
  let is_blocking_java_io =
    is_call_of_class_or_superclass ["java.io.Reader"; "java.io.InputStream"] ~method_prefix:true
      "read"


  let actuals_are_empty_or_timeout = function
    | [_] ->
        true
    | [_; duration; timeunit] ->
        is_excessive_timeout duration timeunit
    | _ ->
        false


  (** is the method called CountDownLath.await or on subclass? *)
  let is_countdownlatch_await =
    is_call_of_class_or_superclass ~actuals_pred:actuals_are_empty_or_timeout
      ["java.util.concurrent.CountDownLatch"] "await"


  (** an IBinder.transact call is an RPC.  If the 4th argument (5th counting `this` as the first)
           is int-zero then a reply is expected and returned from the remote process, thus potentially
           blocking.  If the 4th argument is anything else, we assume a one-way call which doesn't block.
        *)
  let is_two_way_binder_transact =
    let actuals_pred actuals =
      List.nth actuals 4 |> Option.value_map ~default:false ~f:HilExp.is_int_zero
    in
    is_call_of_class_or_superclass ~actuals_pred ["android.os.IBinder"] "transact"


  (** is it a call to android.view.View.getWindowVisibleDisplayFrame or on sublass? *)
  let is_getWindowVisibleDisplayFrame =
    is_call_of_class_or_superclass ["android.view.View"] "getWindowVisibleDisplayFrame"


  (** is it a call to Future.get() or on sublass? *)
  let is_future_get =
    is_call_of_class_or_superclass ~actuals_pred:actuals_are_empty_or_timeout
      ["java.util.concurrent.Future"] "get"


  let is_accountManager_setUserData =
    is_call_of_class_or_superclass ["android.accounts.AccountManager"] "setUserData"


  let is_asyncTask_get =
    is_call_of_class_or_superclass ~actuals_pred:actuals_are_empty_or_timeout
      ["android.os.AsyncTask"] "get"


  let may_block =
    let matchers =
      [ is_blocking_java_io
      ; is_countdownlatch_await
      ; is_two_way_binder_transact
      ; is_getWindowVisibleDisplayFrame
      ; is_future_get
      ; is_accountManager_setUserData
      ; is_asyncTask_get ]
    in
    fun tenv pn actuals -> List.exists matchers ~f:(fun matcher -> matcher tenv pn actuals)


  let is_synchronized_library_call =
    let targets = ["java.lang.StringBuffer"; "java.util.Hashtable"; "java.util.Vector"] in
    fun tenv pn ->
      not (Typ.Procname.is_constructor pn)
      &&
      match pn with
      | Typ.Procname.Java java_pname ->
          let classname = Typ.Procname.Java.get_class_type_name java_pname in
          List.exists targets ~f:(PatternMatch.is_subtype_of_str tenv classname)
      | _ ->
          false
end
