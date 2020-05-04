(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

type t = {nullability: Nullability.t; origin: TypeOrigin.t} [@@deriving compare]

let create origin = {nullability= TypeOrigin.get_nullability origin; origin}

let get_nullability {nullability} = nullability

let is_nonnullish {nullability} = Nullability.is_nonnullish nullability

let pp fmt {nullability} = Nullability.pp fmt nullability

let join t1 t2 =
  let joined_nullability = Nullability.join t1.nullability t2.nullability in
  let is_equal_to_t1 = Nullability.equal t1.nullability joined_nullability in
  let is_equal_to_t2 = Nullability.equal t2.nullability joined_nullability in
  (* Origin complements nullability information. It is the best effort to explain how was the nullability inferred.
     If nullability is fully determined by one of the arguments, origin should be get from this argument.
     Otherwise we apply heuristics to choose origin either from t1 or t2.
  *)
  let joined_origin =
    match (is_equal_to_t1, is_equal_to_t2) with
    | _ when Nullability.equal t1.nullability Nullability.Null ->
        t1.origin
    | _ when Nullability.equal t2.nullability Nullability.Null ->
        t2.origin
    | true, false ->
        (* Nullability was fully determined by t1. *)
        t1.origin
    | false, true ->
        (* Nullability was fully determined by t2 *)
        t2.origin
    | false, false | true, true ->
        (* Nullability is not fully determined by neither t1 nor t2
           Let TypeOrigin logic to decide what to prefer in this case.
        *)
        TypeOrigin.join t1.origin t2.origin
  in
  {nullability= joined_nullability; origin= joined_origin}


let get_origin t = t.origin

let origin_is_fun_defined t =
  match get_origin t with TypeOrigin.MethodCall {is_defined; _} -> is_defined | _ -> false
