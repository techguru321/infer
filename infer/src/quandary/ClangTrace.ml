(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
module F = Format
module L = Logging

module SourceKind = struct
  type t =
    | CommandLineFlag of (Var.t * Typ.desc)  (** source that was read from a command line flag *)
    | Endpoint of (Mangled.t * Typ.desc)  (** source originating from formal of an endpoint *)
    | EnvironmentVariable  (** source that was read from an environment variable *)
    | ReadFile  (** source that was read from a file *)
    | Other  (** for testing or uncategorized sources *)
    | UserControlledEndpoint of (Mangled.t * Typ.desc)
        (** source originating from formal of an endpoint that is known to hold user-controlled data *)
    [@@deriving compare]

  let matches ~caller ~callee = Int.equal 0 (compare caller callee)

  let of_string = function
    | "CommandLineFlag" ->
        L.die UserError "User-specified CommandLineFlag sources are not supported"
    | "Endpoint" ->
        Endpoint (Mangled.from_string "NONE", Typ.Tvoid)
    | "EnvironmentVariable" ->
        EnvironmentVariable
    | "ReadFile" ->
        ReadFile
    | "UserControlledEndpoint" ->
        Endpoint (Mangled.from_string "NONE", Typ.Tvoid)
    | _ ->
        Other


  let external_sources =
    List.map
      ~f:(fun {QuandaryConfig.Source.procedure; kind; index} ->
        (QualifiedCppName.Match.of_fuzzy_qual_names [procedure], kind, index) )
      (QuandaryConfig.Source.of_json Config.quandary_sources)


  let endpoints = String.Set.of_list (QuandaryConfig.Endpoint.of_json Config.quandary_endpoints)

  (* return Some(source kind) if [procedure_name] is in the list of externally specified sources *)
  let get_external_source qualified_pname =
    let return = None in
    List.find_map
      ~f:(fun (qualifiers, kind, index) ->
        if QualifiedCppName.Match.match_qualifiers qualifiers qualified_pname then
          let source_index = try Some (int_of_string index) with Failure _ -> return in
          Some (of_string kind, source_index)
        else None )
      external_sources


  let get pname actuals tenv =
    let return = None in
    match pname with
    | Typ.Procname.ObjC_Cpp cpp_name
      -> (
        let qualified_pname = Typ.Procname.get_qualifiers pname in
        match
          ( QualifiedCppName.to_list
              (Typ.Name.unqualified_name (Typ.Procname.objc_cpp_get_class_type_name cpp_name))
          , Typ.Procname.get_method pname )
        with
        | ( ["std"; ("basic_istream" | "basic_iostream")]
          , ("getline" | "read" | "readsome" | "operator>>") ) ->
            Some (ReadFile, Some 1)
        | _ ->
            get_external_source qualified_pname )
    | Typ.Procname.C _
      when Config.developer_mode && Typ.Procname.equal pname BuiltinDecl.__global_access
      -> (
        (* is this var a command line flag created by the popular C++ gflags library for creating
           command-line flags (https://github.com/gflags/gflags)? *)
        let is_gflag access_path =
          let pvar_is_gflag pvar =
            String.is_substring ~substring:"FLAGS_" (Pvar.get_simplified_name pvar)
          in
          match access_path with
          | (Var.ProgramVar pvar, _), _ ->
              Pvar.is_global pvar && pvar_is_gflag pvar
          | _ ->
              false
        in
        (* accessed global will be passed to us as the only parameter *)
        match actuals with
        | [(HilExp.AccessPath access_path)] when is_gflag access_path ->
            let (global_pvar, _), _ = access_path in
            let typ_desc =
              match AccessPath.get_typ access_path tenv with
              | Some {Typ.desc} ->
                  desc
              | None ->
                  Typ.void_star.desc
            in
            Some (CommandLineFlag (global_pvar, typ_desc), None)
        | _ ->
            None )
    | Typ.Procname.C _ -> (
      match Typ.Procname.to_string pname with
      | "getenv" ->
          Some (EnvironmentVariable, return)
      | _ ->
          get_external_source (Typ.Procname.get_qualifiers pname) )
    | Typ.Procname.Block _ ->
        None
    | pname ->
        L.(die InternalError) "Non-C++ procname %a in C++ analysis" Typ.Procname.pp pname


  let get_tainted_formals pdesc tenv =
    if PredSymb.equal_access (Procdesc.get_attributes pdesc).ProcAttributes.access PredSymb.Private
    then Source.all_formals_untainted pdesc
    else
      let is_thrift_service cpp_pname =
        let is_thrift_service_ typename _ =
          match QualifiedCppName.to_list (Typ.Name.unqualified_name typename) with
          | ["facebook"; "fb303"; "cpp2"; ("FacebookServiceSvIf" | "FacebookServiceSvAsyncIf")] ->
              true
          | _ ->
              false
        in
        let typename = Typ.Procname.objc_cpp_get_class_type_name cpp_pname in
        PatternMatch.supertype_exists tenv is_thrift_service_ typename
      in
      (* taint all formals except for [this] *)
      let taint_all_but_this ~make_source =
        List.map
          ~f:(fun (name, typ) ->
            let taint =
              match Mangled.to_string name with
              | "this" ->
                  None
              | _ ->
                  Some (make_source name typ.Typ.desc)
            in
            (name, typ, taint) )
          (Procdesc.get_formals pdesc)
      in
      match Procdesc.get_proc_name pdesc with
      | Typ.Procname.ObjC_Cpp cpp_pname as pname ->
          let qualified_pname =
            F.sprintf "%s::%s"
              (Typ.Procname.objc_cpp_get_class_name cpp_pname)
              (Typ.Procname.get_method pname)
          in
          if String.Set.mem endpoints qualified_pname then
            taint_all_but_this ~make_source:(fun name desc -> UserControlledEndpoint (name, desc))
          else if is_thrift_service cpp_pname then
            taint_all_but_this ~make_source:(fun name desc -> Endpoint (name, desc))
          else Source.all_formals_untainted pdesc
      | _ ->
          Source.all_formals_untainted pdesc


  let pp fmt = function
    | Endpoint (formal_name, _) ->
        F.fprintf fmt "Endpoint[%s]" (Mangled.to_string formal_name)
    | EnvironmentVariable ->
        F.fprintf fmt "EnvironmentVariable"
    | ReadFile ->
        F.fprintf fmt "File"
    | CommandLineFlag (var, _) ->
        F.fprintf fmt "CommandLineFlag[%a]" Var.pp var
    | Other ->
        F.fprintf fmt "Other"
    | UserControlledEndpoint (formal_name, _) ->
        F.fprintf fmt "UserControlledEndpoint[%s]" (Mangled.to_string formal_name)
end

module CppSource = Source.Make (SourceKind)

module SinkKind = struct
  type t =
    | BufferAccess  (** read/write an array *)
    | CreateFile  (** create/open a file *)
    | HeapAllocation  (** heap memory allocation *)
    | Network  (** network access *)
    | ShellExec  (** shell exec function *)
    | SQL  (** SQL query *)
    | StackAllocation  (** stack memory allocation *)
    | Other  (** for testing or uncategorized sinks *)
    [@@deriving compare]

  let matches ~caller ~callee = Int.equal 0 (compare caller callee)

  let of_string = function
    | "BufferAccess" ->
        BufferAccess
    | "CreateFile" ->
        CreateFile
    | "HeapAllocation" ->
        HeapAllocation
    | "Network" ->
        Network
    | "ShellExec" ->
        ShellExec
    | "SQL" ->
        SQL
    | "StackAllocation" ->
        StackAllocation
    | _ ->
        Other


  let external_sinks =
    List.map
      ~f:(fun {QuandaryConfig.Sink.procedure; kind; index} ->
        (QualifiedCppName.Match.of_fuzzy_qual_names [procedure], kind, index) )
      (QuandaryConfig.Sink.of_json Config.quandary_sinks)


  (* taint the nth parameter (0-indexed) *)
  let taint_nth n kind actuals =
    if n < List.length actuals then Some (kind, IntSet.singleton n) else None


  (* taint all parameters after the nth (exclusive) *)
  let taint_after_nth n kind actuals =
    match
      List.filter_mapi ~f:(fun actual_num _ -> Option.some_if (actual_num > n) actual_num) actuals
    with
    | [] ->
        None
    | to_taint ->
        Some (kind, IntSet.of_list to_taint)


  let taint_all kind actuals =
    Some (kind, IntSet.of_list (List.mapi ~f:(fun actual_num _ -> actual_num) actuals))


  (* return Some(sink kind) if [procedure_name] is in the list of externally specified sinks *)
  let get_external_sink pname actuals =
    let qualified_pname = Typ.Procname.get_qualifiers pname in
    List.find_map
      ~f:(fun (qualifiers, kind, index) ->
        if QualifiedCppName.Match.match_qualifiers qualifiers qualified_pname then
          let kind = of_string kind in
          try
            let n = int_of_string index in
            taint_nth n kind actuals
          with Failure _ ->
            (* couldn't parse the index, just taint everything *)
            taint_all kind actuals
        else None )
      external_sinks


  let get pname actuals _ =
    let is_buffer_like pname =
      (* assume it's a buffer class if it's "vector-y", "array-y", or "string-y". don't want to
         report on accesses to maps etc., but also want to recognize custom vectors like fbvector
         rather than overfitting to std::vector *)
      let typename =
        Typ.Procname.get_qualifiers pname |> QualifiedCppName.strip_template_args
        |> QualifiedCppName.to_qual_string |> String.lowercase
      in
      String.is_substring ~substring:"vec" typename
      || String.is_substring ~substring:"array" typename
      || String.is_substring ~substring:"string" typename
    in
    match pname with
    | Typ.Procname.ObjC_Cpp cpp_name -> (
      match
        ( QualifiedCppName.to_list
            (Typ.Name.unqualified_name (Typ.Procname.objc_cpp_get_class_type_name cpp_name))
        , Typ.Procname.get_method pname )
      with
      | ( ["std"; ("basic_fstream" | "basic_ifstream" | "basic_ofstream")]
        , ("basic_fstream" | "basic_ifstream" | "basic_ofstream" | "open") ) ->
          taint_nth 1 CreateFile actuals
      | _, "operator[]" when Config.developer_mode && is_buffer_like pname ->
          taint_nth 1 BufferAccess actuals
      | _ ->
          get_external_sink pname actuals )
    | Typ.Procname.C _
      when Config.developer_mode && Typ.Procname.equal pname BuiltinDecl.__array_access ->
        taint_all BufferAccess actuals
    | Typ.Procname.C _ when Typ.Procname.equal pname BuiltinDecl.__set_array_length ->
        (* called when creating a stack-allocated array *)
        taint_nth 1 StackAllocation actuals
    | Typ.Procname.C _ -> (
      match Typ.Procname.to_string pname with
      | "creat" | "fopen" | "freopen" | "open" ->
          taint_nth 0 CreateFile actuals
      | "curl_easy_setopt"
        -> (
          (* magic constant for setting request URL *)
          let controls_request = function
            | 10002 (* CURLOPT_URL *) | 10015 (* CURLOPT_POSTFIELDS *) ->
                true
            | _ ->
                false
          in
          (* first two actuals are curl object + integer code for data kind. *)
          match List.nth actuals 1 with
          | Some exp -> (
            match HilExp.eval exp with
            | Some Const.Cint i ->
                (* check if the data kind might be CURLOPT_URL *)
                if controls_request (IntLit.to_int i) then taint_after_nth 1 Network actuals
                else None
            | _ ->
                (* can't statically resolve data kind; taint it just in case *)
                taint_after_nth 1 Network actuals )
          | None ->
              None )
      | "execl" | "execlp" | "execle" | "execv" | "execve" | "execvp" | "system" ->
          taint_all ShellExec actuals
      | "openat" ->
          taint_nth 1 CreateFile actuals
      | "popen" ->
          taint_nth 0 ShellExec actuals
      | ("brk" | "calloc" | "malloc" | "realloc" | "sbrk") when Config.developer_mode ->
          taint_all HeapAllocation actuals
      | "rename" ->
          taint_all CreateFile actuals
      | "strcpy" when Config.developer_mode ->
          (* warn if source array is tainted *)
          taint_nth 1 BufferAccess actuals
      | ("memcpy" | "memmove" | "memset" | "strncpy" | "wmemcpy" | "wmemmove")
        when Config.developer_mode ->
          (* warn if count argument is tainted *)
          taint_nth 2 BufferAccess actuals
      | _ ->
          get_external_sink pname actuals )
    | Typ.Procname.Block _ ->
        None
    | pname ->
        L.(die InternalError) "Non-C++ procname %a in C++ analysis" Typ.Procname.pp pname


  let pp fmt kind =
    F.fprintf fmt
      ( match kind with
      | BufferAccess ->
          "BufferAccess"
      | CreateFile ->
          "CreateFile"
      | HeapAllocation ->
          "HeapAllocation"
      | Network ->
          "Network"
      | ShellExec ->
          "ShellExec"
      | SQL ->
          "SQL"
      | StackAllocation ->
          "StackAllocation"
      | Other ->
          "Other" )
end

module CppSink = Sink.Make (SinkKind)

module CppSanitizer = struct
  type t =
    | Escape  (** escaped string to sanitize SQL injection or ShellExec sinks *)
    | All  (** sanitizes all forms of taint *)
    [@@deriving compare]

  let equal = [%compare.equal : t]

  let of_string = function "Escape" -> Escape | _ -> All

  let external_sanitizers =
    List.map
      ~f:(fun {QuandaryConfig.Sanitizer.procedure; kind} ->
        (QualifiedCppName.Match.of_fuzzy_qual_names [procedure], of_string kind) )
      (QuandaryConfig.Sanitizer.of_json Config.quandary_sanitizers)


  let get pname =
    let qualified_pname = Typ.Procname.get_qualifiers pname in
    List.find_map
      ~f:(fun (qualifiers, kind) ->
        if QualifiedCppName.Match.match_qualifiers qualifiers qualified_pname then Some kind
        else None )
      external_sanitizers


  let pp fmt = function Escape -> F.fprintf fmt "Escape" | All -> F.fprintf fmt "All"
end

include Trace.Make (struct
  module Source = CppSource
  module Sink = CppSink
  module Sanitizer = CppSanitizer

  (* return true if code injection is possible because the source is a string/is not sanitized *)
  let is_injection_possible ?typ sanitizers =
    let is_escaped = List.mem sanitizers Sanitizer.Escape ~equal:Sanitizer.equal in
    not is_escaped
    &&
    match typ with
    | Some (Typ.Tint _ | Tfloat _ | Tvoid) ->
        false
    | _ ->
        (* possible a string/object/struct type; assume injection possible *)
        true


  let get_report source sink sanitizers =
    match (Source.kind source, Sink.kind sink) with
    | _ when List.mem sanitizers Sanitizer.All ~equal:Sanitizer.equal ->
        (* the All sanitizer clears any form of taint; don't report *)
        None
    | UserControlledEndpoint (_, typ), CreateFile ->
        Option.some_if (is_injection_possible ~typ sanitizers) IssueType.untrusted_file
    | (Endpoint (_, typ) | CommandLineFlag (_, typ)), CreateFile ->
        Option.some_if (is_injection_possible ~typ sanitizers) IssueType.untrusted_file_risk
    | UserControlledEndpoint (_, typ), Network ->
        Option.some_if (is_injection_possible ~typ sanitizers) IssueType.untrusted_url
    | (Endpoint (_, typ) | CommandLineFlag (_, typ)), Network ->
        Option.some_if (is_injection_possible ~typ sanitizers) IssueType.untrusted_url_risk
    | (EnvironmentVariable | ReadFile), Network ->
        None
    | (UserControlledEndpoint (_, typ) | CommandLineFlag (_, typ)), SQL ->
        if is_injection_possible ~typ sanitizers then Some IssueType.sql_injection
        else
          (* no injection risk, but still user-controlled *)
          Some IssueType.user_controlled_sql_risk
    | Endpoint (_, typ), SQL ->
        if is_injection_possible ~typ sanitizers then
          (* code injection if the caller of the endpoint doesn't sanitize on its end *)
          Some IssueType.remote_code_execution_risk
        else
          (* no injection risk, but still user-controlled *)
          Some IssueType.user_controlled_sql_risk
    | (UserControlledEndpoint (_, typ) | CommandLineFlag (_, typ)), ShellExec ->
        (* we know the user controls the endpoint, so it's code injection without a sanitizer *)
        Option.some_if (is_injection_possible ~typ sanitizers) IssueType.shell_injection
    | Endpoint (_, typ), ShellExec ->
        (* code injection if the caller of the endpoint doesn't sanitize on its end *)
        Option.some_if (is_injection_possible ~typ sanitizers) IssueType.remote_code_execution_risk
    | UserControlledEndpoint _, BufferAccess ->
        (* untrusted data from an endpoint flowing into a buffer *)
        Some IssueType.quandary_taint_error
    | Endpoint _, (BufferAccess | HeapAllocation | StackAllocation) ->
        (* may want to report this in the future, but don't care for now *)
        None
    | (CommandLineFlag _ | EnvironmentVariable | ReadFile | Other), BufferAccess ->
        (* untrusted flag, environment var, or file data flowing to buffer *)
        Some IssueType.quandary_taint_error
    | (EnvironmentVariable | ReadFile | Other), ShellExec ->
        (* untrusted flag, environment var, or file data flowing to shell *)
        Option.some_if (is_injection_possible sanitizers) IssueType.shell_injection
    | (EnvironmentVariable | ReadFile | Other), SQL ->
        (* untrusted flag, environment var, or file data flowing to SQL *)
        Option.some_if (is_injection_possible sanitizers) IssueType.sql_injection
    | ( (CommandLineFlag _ | UserControlledEndpoint _ | EnvironmentVariable | ReadFile | Other)
      , HeapAllocation ) ->
        (* untrusted data of any kind flowing to heap allocation. this can cause crashes or DOS. *)
        Some IssueType.quandary_taint_error
    | ( (CommandLineFlag _ | UserControlledEndpoint _ | EnvironmentVariable | ReadFile | Other)
      , StackAllocation ) ->
        (* untrusted data of any kind flowing to stack buffer allocation. trying to allocate a stack
           buffer that's too large will cause a stack overflow. *)
        Some IssueType.untrusted_variable_length_array
    | (EnvironmentVariable | ReadFile), CreateFile ->
        None
    | Other, _ ->
        (* Other matches everything *)
        Some IssueType.quandary_taint_error
    | _, Other ->
        Some IssueType.quandary_taint_error
end)
