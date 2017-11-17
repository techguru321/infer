(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

(** To be used in 'list_constraint *)
type accept_more
 and end_of_list

(** To be used in 'emptyness *)
type empty
 and non_empty

(* Type shorthands *)

type typ = Typ.t

type c = Typ.Procname.c

type objc_cpp = Typ.Procname.objc_cpp

type qual_name = QualifiedCppName.t

type templated_name = qual_name * Typ.template_arg list

type 'marker mtyp = typ

type 'captured_types capt = unit -> 'captured_types

(* Typ helpers *)

let template_args_of_template_spec_info = function
  | Typ.NoTemplate ->
      []
  | Typ.Template {args} ->
      args


let templated_name_of_class_name class_name =
  let open Typ in
  match class_name with
  | CStruct qual_name | CUnion qual_name | ObjcClass qual_name | ObjcProtocol qual_name ->
      (qual_name, [])
  | CppClass (qual_name, template_spec_info) ->
      (qual_name, template_args_of_template_spec_info template_spec_info)
  | JavaClass _ ->
      assert false


(** Little abstraction over arguments: currently actual args, we'll want formal args later *)
module FuncArg = struct
  type t = Exp.t * Typ.t

  let typ (_, ty) = ty
end

(* Intermediate matcher types *)

type ('f_in, 'f_out, 'captured_types, 'markers_in, 'markers_out) name_matcher =
  { on_objc_cpp: 'f_in -> objc_cpp -> ('f_out * 'captured_types capt) option
  ; on_qual_name: 'f_in -> qual_name -> ('f_out * 'captured_types capt) option
  ; get_markers: 'markers_in -> 'markers_out }

type ( 'f_in
     , 'f_out
     , 'captured_types_in
     , 'captured_types_out
     , 'markers_in
     , 'markers_out
     , 'list_constraint ) template_arg =
  { eat_template_arg:
      'f_in * 'captured_types_in capt * Typ.template_arg list
      -> ('f_out * 'captured_types_out capt * Typ.template_arg list) option
  ; add_marker: 'markers_in -> 'markers_out }

type ('f_in, 'f_out, 'captured_types, 'markers_in, 'markers_out, 'list_constraint) templ_matcher =
  { on_objc_cpp: 'f_in -> objc_cpp -> ('f_out * 'captured_types capt * Typ.template_arg list) option
  ; on_templated_name:
      'f_in -> templated_name -> ('f_out * 'captured_types capt * Typ.template_arg list) option
  ; get_markers: 'markers_in -> 'markers_out }

type ('f_in, 'f_out, 'captured_types, 'emptyness) path_extra =
  | PathEmpty : ('f, 'f, unit, empty) path_extra
  | PathNonEmpty:
      { on_objc_cpp: 'f_in -> objc_cpp -> ('f_out * 'captured_types capt) option }
      -> ('f_in, 'f_out, 'captured_types, non_empty) path_extra

type ('f_in, 'f_out, 'captured_types, 'markers_in, 'markers_out, 'emptyness) path_matcher =
  { on_templated_name: 'f_in -> templated_name -> ('f_out * 'captured_types capt) option
  ; path_extra: ('f_in, 'f_out, 'captured_types, 'emptyness) path_extra
  ; get_markers: 'markers_in -> 'markers_out }

type ('f_in, 'f_out, 'captured_types) proc_matcher =
  { on_objc_cpp: 'f_in -> objc_cpp -> ('f_out * 'captured_types) option
  ; on_c: 'f_in -> c -> ('f_out * 'captured_types) option }

type ('f_in, 'f_out, 'captured_types, 'markers, 'list_constraint) args_matcher =
  { on_proc: ('f_in, 'f_out, 'captured_types) proc_matcher
  ; on_args: 'captured_types -> FuncArg.t list -> FuncArg.t list option
  ; markers: 'markers }

type ('captured_types, 'markers, 'list_constraint) func_arg =
  { eat_func_arg: 'captured_types -> FuncArg.t list -> FuncArg.t list option
  ; marker_static_checker: 'markers -> bool }

type ('f_in, 'f_out) all_args_matcher =
  { on_objc_cpp: 'f_in -> objc_cpp -> FuncArg.t list -> 'f_out option
  ; on_c: 'f_in -> c -> FuncArg.t list -> 'f_out option }

type 'f matcher = Typ.Procname.t -> FuncArg.t list -> 'f option

(* they are actually just the same thing *)
type 'f dispatcher = 'f matcher

(* Combinators *)

let empty : ('f, 'f, unit, 'markers, 'markers, empty) path_matcher =
  let get_markers m = m in
  let get_capture () = () in
  let on_templated_name f (qual_name, template_args) =
    match (QualifiedCppName.extract_last qual_name, template_args) with
    | None, [] ->
        Some (f, get_capture)
    | None, _ ->
        assert false
    | Some _, _ ->
        None
  in
  {on_templated_name; path_extra= PathEmpty; get_markers}


let name_cons
    : ('f_in, 'f_out, 'captured_types, 'markers_in, 'markers_out, _) path_matcher -> string
      -> ('f_in, 'f_out, 'captured_types, 'markers_in, 'markers_out) name_matcher =
  fun m name ->
    let {on_templated_name; get_markers} = m in
    let on_qual_name f qual_name =
      match QualifiedCppName.extract_last qual_name with
      | Some (last, rest) when String.equal name last ->
          on_templated_name f (rest, [])
      | _ ->
          None
    in
    let on_objc_cpp f objc_cpp =
      if String.equal name objc_cpp.Typ.Procname.method_name then
        on_templated_name f (templated_name_of_class_name objc_cpp.Typ.Procname.class_name)
      else None
    in
    {on_objc_cpp; on_qual_name; get_markers}


let templ_begin
    : ('f_in, 'f_out, 'captured_types, 'markers_in, 'markers_out) name_matcher
      -> ('f_in, 'f_out, 'captured_types, 'markers_in, 'markers_out, accept_more) templ_matcher =
  fun m ->
    let {on_objc_cpp; on_qual_name; get_markers} = m in
    let on_templated_name f (qual_name, template_args) =
      match on_qual_name f qual_name with
      | None ->
          None
      | Some (f, captured_types) ->
          Some (f, captured_types, template_args)
    in
    let on_objc_cpp f objc_cpp =
      match on_objc_cpp f objc_cpp with
      | None ->
          None
      | Some (f, captured_types) ->
          let template_args =
            template_args_of_template_spec_info objc_cpp.Typ.Procname.template_args
          in
          Some (f, captured_types, template_args)
    in
    {on_objc_cpp; on_templated_name; get_markers}


let templ_cons
    : ( 'f_in
      , 'f_interm
      , 'captured_types_in
      , 'markers_interm
      , 'markers_out
      , accept_more )
      templ_matcher
      -> ( 'f_interm
         , 'f_out
         , 'captured_types_in
         , 'captured_types_out
         , 'markers_in
         , 'markers_interm
         , 'lc )
         template_arg
      -> ('f_in, 'f_out, 'captured_types_out, 'markers_in, 'markers_out, 'lc) templ_matcher =
  fun m template_arg ->
    let {on_objc_cpp; on_templated_name; get_markers} = m in
    let {eat_template_arg; add_marker} = template_arg in
    let get_markers m = get_markers (add_marker m) in
    let on_templated_name f templated_name =
      on_templated_name f templated_name |> Option.bind ~f:eat_template_arg
    in
    let on_objc_cpp f objc_cpp = on_objc_cpp f objc_cpp |> Option.bind ~f:eat_template_arg in
    {on_objc_cpp; on_templated_name; get_markers}


let templ_end
    : ('f_in, 'f_out, 'captured_types, 'markers_in, 'markers_out, _) templ_matcher
      -> ('f_in, 'f_out, 'captured_types, 'markers_in, 'markers_out, non_empty) path_matcher =
  let match_empty_templ_args (f, captured_types, template_args) =
    match template_args with [] -> Some (f, captured_types) | _ -> None
  in
  fun m ->
    let {on_objc_cpp; on_templated_name; get_markers} = m in
    let on_templated_name f templated_name =
      on_templated_name f templated_name |> Option.bind ~f:match_empty_templ_args
    in
    let on_objc_cpp f objc_cpp = on_objc_cpp f objc_cpp |> Option.bind ~f:match_empty_templ_args in
    {on_templated_name; path_extra= PathNonEmpty {on_objc_cpp}; get_markers}


let args_begin
    : ('f_in, 'f_out, 'captured_types, unit, 'markers, non_empty) path_matcher
      -> ('f_in, 'f_out, 'captured_types, 'markers, accept_more) args_matcher =
  let on_args _capt args = Some args in
  fun m ->
    let {on_templated_name; path_extra= PathNonEmpty {on_objc_cpp}; get_markers} = m in
    let markers = get_markers () in
    let get_captures (f, captured_types) = (f, captured_types ()) in
    let on_c f (c: c) =
      let template_args = template_args_of_template_spec_info c.template_args in
      on_templated_name f (c.name, template_args) |> Option.map ~f:get_captures
    in
    let on_objc_cpp f objc_cpp = on_objc_cpp f objc_cpp |> Option.map ~f:get_captures in
    let on_proc : (_, _, _) proc_matcher = {on_objc_cpp; on_c} in
    {on_proc; on_args; markers}


let args_cons
    : ('f_in, 'f_out, 'captured_types, 'markers, accept_more) args_matcher
      -> ('captured_types, 'markers, 'lc) func_arg
      -> ('f_in, 'f_out, 'captured_types, 'markers, 'lc) args_matcher =
  fun m func_arg ->
    let {on_proc; on_args; markers} = m in
    let {marker_static_checker; eat_func_arg} = func_arg in
    assert (marker_static_checker markers) ;
    let on_args capt args = on_args capt args |> Option.bind ~f:(eat_func_arg capt) in
    {on_proc; on_args; markers}


let args_end
    : ('f_in, 'f_out, 'captured_types, 'markers, _) args_matcher
      -> ('f_in, 'f_out) all_args_matcher =
  let match_empty_args f = function Some [] -> Some f | _ -> None in
  fun m ->
    let {on_proc= {on_c; on_objc_cpp}; on_args} = m in
    let on_args args (f, capt) = on_args capt args |> match_empty_args f in
    let on_c f c args = on_c f c |> Option.bind ~f:(on_args args) in
    let on_objc_cpp f objc_cpp args = on_objc_cpp f objc_cpp |> Option.bind ~f:(on_args args) in
    {on_c; on_objc_cpp}


let make_matcher : ('f_in, 'f_out) all_args_matcher -> 'f_in -> 'f_out matcher =
  fun m f ->
    let {on_c; on_objc_cpp} : (_, _) all_args_matcher = m in
    fun procname args ->
      match procname with
      | ObjC_Cpp objc_cpp ->
          on_objc_cpp f objc_cpp args
      | C c ->
          on_c f c args
      | _ ->
          None


(** Simple implementation of a dispatcher, could be optimized later *)
let make_dispatcher : 'f matcher list -> 'f dispatcher =
  fun matchers procname args -> List.find_map matchers ~f:(fun matcher -> matcher procname args)


(* Template arguments *)

let add_no_marker capture_markers = capture_markers

(** Eats all template args *)
let any_template_args
    : ('f, 'f, 'captured_types, 'captured_types, 'markers, 'markers, end_of_list) template_arg =
  let eat_template_arg (f, captured_types, _) = Some (f, captured_types, []) in
  {eat_template_arg; add_marker= add_no_marker}


(** Eats a type *)
let any_typ
    : ('f, 'f, 'captured_types, 'captured_types, 'markers, 'markers, accept_more) template_arg =
  let eat_template_arg (f, captured_types, template_args) =
    match template_args with (Typ.TType _) :: rest -> Some (f, captured_types, rest) | _ -> None
  in
  {eat_template_arg; add_marker= add_no_marker}


(** Captures a type than can be back-referenced *)
let capt_typ
    : 'marker
      -> ( 'marker mtyp -> 'f
         , 'f
         , 'captured_types
         , 'marker mtyp * 'captured_types
         , 'markers
         , 'marker * 'markers
         , accept_more )
         template_arg =
  fun marker ->
    let eat_template_arg (f, captured_types, template_args) =
      match template_args with
      | (Typ.TType ty) :: rest ->
          let captured_types () = (ty, captured_types ()) in
          Some (f ty, captured_types, rest)
      | _ ->
          None
    in
    let add_marker capture_markers = (marker, capture_markers) in
    {eat_template_arg; add_marker}


(** Captures an int *)
let capt_int
    : ( Int64.t -> 'f
      , 'f
      , 'captured_types
      , 'captured_types
      , 'markers
      , 'markers
      , accept_more )
      template_arg =
  let eat_template_arg (f, captured_types, template_args) =
    match template_args with (Typ.TInt i) :: rest -> Some (f i, captured_types, rest) | _ -> None
  in
  {eat_template_arg; add_marker= add_no_marker}


(** Captures all template args *)
let capt_all
    : ( Typ.template_arg list -> 'f
      , 'f
      , 'captured_types
      , 'captured_types
      , 'markers
      , 'markers
      , end_of_list )
      template_arg =
  let eat_template_arg (f, captured_types, template_args) =
    Some (f template_args, captured_types, [])
  in
  {eat_template_arg; add_marker= add_no_marker}


(* Function args *)

let no_checker _ = true

(** Eats all the args *)
let any_func_args : (_, _, end_of_list) func_arg =
  let eat_func_arg _capt _args = Some [] in
  {eat_func_arg; marker_static_checker= no_checker}


let eat_one_func_arg ~match_if capt = function
  | arg :: rest when match_if capt arg ->
      Some rest
  | _ ->
      None


(** Eats one arg *)
let any_arg : (_, _, accept_more) func_arg =
  let eat_func_arg capt = eat_one_func_arg ~match_if:(fun _ _ -> true) capt in
  {eat_func_arg; marker_static_checker= no_checker}


let mk_typ_nth
    : ('markers -> 'marker) -> ('captured_types -> 'marker mtyp) -> 'marker
      -> ('captured_types, 'markers, _) func_arg =
  fun get_m get_c marker ->
    let marker_static_checker markers = Polymorphic_compare.( = ) marker (get_m markers) in
    let eat_func_arg =
      eat_one_func_arg ~match_if:(fun capt func_arg ->
          Typ.equal (FuncArg.typ func_arg) (get_c capt) )
    in
    {eat_func_arg; marker_static_checker}


(** Matches first captured type *)
let typ1 : 'marker -> ('marker mtyp * _, 'marker * _, accept_more) func_arg =
  let pos1 (x, _) = x in
  fun marker -> mk_typ_nth pos1 pos1 marker


(** Matches second captured type *)
let typ2 : 'marker -> (_ * ('marker mtyp * _), _ * ('marker * _), accept_more) func_arg =
  let pos2 (_, (x, _)) = x in
  fun marker -> mk_typ_nth pos2 pos2 marker


(** Matches third captured type *)
let typ3 : 'marker -> (_ * (_ * ('marker mtyp * _)), _ * (_ * ('marker * _)), accept_more) func_arg =
  let pos3 (_, (_, (x, _))) = x in
  fun marker -> mk_typ_nth pos3 pos3 marker


(* Notation shorthands *)

let ( <! ) name_matcher () = templ_begin name_matcher

let ( >! ) templ_matcher () = templ_end templ_matcher

let ( $! ) path_matcher () = args_begin path_matcher

let ( >$! ) templ_matcher () = templ_matcher >! () $! ()

let ( &::! ) path_matcher name = name_cons path_matcher name

let ( $*! ) args_matcher () = args_end args_matcher

let ( $*--> ) all_args_matcher f = make_matcher all_args_matcher f

let ( ~- ) name = empty &::! name

let ( &+ ) templ_matcher template_arg = templ_cons templ_matcher template_arg

let ( < ) name_matcher template_arg = name_matcher <! () &+ template_arg

let ( >:: ) templ_matcher name = templ_matcher >! () &::! name

let ( $+ ) args_matcher func_arg = args_cons args_matcher func_arg

let ( >$ ) templ_matcher func_arg = templ_matcher >$! () $+ func_arg

let ( $--> ) args_matcher f = args_matcher $*! () $*--> f

let ( &+...>:: ) templ_matcher name = templ_matcher &+ any_template_args >:: name

let ( &:: ) path_matcher name = path_matcher < any_template_args >:: name

let ( <>:: ) name_matcher name = name_matcher <! () >:: name

let ( $ ) name_matcher func_arg = name_matcher < any_template_args >$ func_arg

let ( <>$ ) name_matcher func_arg = name_matcher <! () >$ func_arg

let ( >--> ) templ_matcher f = templ_matcher >$ any_func_args $--> f

let ( $+...$--> ) args_matcher f = args_matcher $+ any_func_args $--> f

let ( >$$--> ) templ_matcher f = templ_matcher >$! () $--> f

let ( $$--> ) name_matcher f = name_matcher < any_template_args >$$--> f

let ( <>$$--> ) name_matcher f = name_matcher <! () >$$--> f

let ( &--> ) name_matcher f = name_matcher < any_template_args >--> f

let ( <>--> ) name_matcher f = name_matcher <! () >--> f
