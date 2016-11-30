(*
 * Copyright (c) 2014 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

module L = Logging
module P = Printf


(** Describe the origin of values propagated by the checker. *)


type proc_origin =
  {
    pname : Procname.t;
    loc: Location.t;
    annotated_signature : Annotations.annotated_signature;
    is_library : bool;
  } [@@deriving compare]

type t =
  | Const of Location.t
  | Field of Ident.fieldname * Location.t
  | Formal of Mangled.t
  | Proc of proc_origin
  | New
  | ONone
  | Undef
[@@deriving compare]

let equal o1 o2 = 0 = compare o1 o2

let to_string = function
  | Const _ -> "Const"
  | Field (fn, _) -> "Field " ^ Ident.fieldname_to_simplified_string fn
  | Formal s -> "Formal " ^ Mangled.to_string s
  | Proc po ->
      Printf.sprintf
        "Fun %s"
        (Procname.to_simplified_string po.pname)
  | New -> "New"
  | ONone -> "ONone"
  | Undef -> "Undef"

let get_description tenv origin =
  let atline loc =
    " at line " ^ (string_of_int loc.Location.line) in
  match origin with
  | Const loc ->
      Some ("null constant" ^ atline loc, Some loc, None)
  | Field (fn, loc) ->
      Some ("field " ^ Ident.fieldname_to_simplified_string fn ^ atline loc, Some loc, None)
  | Formal s ->
      Some ("method parameter " ^ Mangled.to_string s, None, None)
  | Proc po ->
      let strict = match TypeErr.Strict.signature_get_strict tenv po.annotated_signature with
        | Some ann ->
            let str = "@Strict" in
            (match ann.Annot.parameters with
             | par1 :: _ -> Printf.sprintf "%s(%s) " str par1
             | [] -> Printf.sprintf "%s " str)
        | None -> "" in
      let modelled_in =
        if Models.is_modelled_nullable po.pname
        then " modelled in " ^ ModelTables.this_file
        else "" in
      let description = Printf.sprintf
          "call to %s%s%s%s"
          strict
          (Procname.to_simplified_string po.pname)
          modelled_in
          (atline po.loc) in
      Some (description, Some po.loc, Some po.annotated_signature)
  | New
  | ONone
  | Undef -> None


let join o1 o2 = match o1, o2 with (* left priority *)
  | Undef, _
  | _, Undef -> Undef
  | _ -> o1
