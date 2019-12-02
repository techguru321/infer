(*
 * Copyright (c) 2009-2013, Monoidics ltd.
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** The Smallfoot Intermediate Language: Annotations *)

open! IStd
module F = Format

type parameter = {name: string option; value: string} [@@deriving compare]

type parameters = parameter list [@@deriving compare]

(** Type to represent one [@Annotation]. *)
type t =
  { class_name: string  (** name of the annotation *)
  ; parameters: parameters  (** currently only one string parameter *) }
[@@deriving compare]

let equal = [%compare.equal: t]

let volatile = {class_name= "volatile"; parameters= []}

let final = {class_name= "final"; parameters= []}

let is_final x = equal final x

(** Pretty print an annotation. *)
let prefix = match Language.curr_language_is Java with true -> "@" | false -> "_"

let pp_parameter fmt {name; value} =
  match name with
  | None ->
      F.fprintf fmt "\"%s\"" value
  | Some name ->
      F.fprintf fmt "%s=\"%s\"" name value


let pp fmt annotation =
  let pp_sep fmt _ = F.pp_print_string fmt ", " in
  F.fprintf fmt "%s%s%a" prefix annotation.class_name
    (F.pp_print_list ~pp_sep pp_parameter)
    annotation.parameters


module Item = struct
  (* Don't use nonrec due to https://github.com/janestreet/ppx_compare/issues/2 *)
  (* type nonrec t = list (t, bool) [@@deriving compare]; *)

  (** Annotation for one item: a list of annotations with visibility. *)
  type t_ = (t * bool) list [@@deriving compare]

  type t = t_ [@@deriving compare]

  (** Pretty print an item annotation. *)
  let pp fmt ann =
    let pp fmt (a, _) = pp fmt a in
    F.fprintf fmt "<%a>" (Pp.seq pp) ann


  (** Empty item annotation. *)
  let empty = []

  (** Check if the item annotation is empty. *)
  let is_empty ia = List.is_empty ia

  let is_final ia = List.exists ia ~f:(fun (x, b) -> b && is_final x)
end

module Class = struct
  let objc_str = "ObjC-Class"

  let cpp_str = "Cpp-Class"

  let of_string class_string = [({class_name= class_string; parameters= []}, true)]

  let objc = of_string objc_str

  let cpp = of_string cpp_str
end

module Method = struct
  type t = {return: Item.t; params: Item.t list}

  (** Pretty print a method annotation. *)
  let pp s fmt {return; params} = F.fprintf fmt "%a %s(%a)" Item.pp return s (Pp.seq Item.pp) params

  (** Empty method annotation. *)
  let empty = {return= []; params= []}

  (** Check if the method annotation is empty. *)
  let is_empty {return; params} = Item.is_empty return && List.for_all ~f:Item.is_empty params
end
