(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open NS0
include Map_intf

module Make (Key : sig
  type t [@@deriving compare, sexp_of]
end) : S with type key = Key.t = struct
  module KeyMap = Core.Map.Make_plain (Key)
  module Key = KeyMap.Key

  type key = Key.t

  include KeyMap.Tree

  let compare = compare_direct

  let to_map t =
    Core.Map.Using_comparator.of_tree ~comparator:Key.comparator t

  let of_map m = Base.Map.Using_comparator.to_tree m

  let merge_skewed x y ~combine =
    of_map (Core.Map.merge_skewed (to_map x) (to_map y) ~combine)

  let map_endo t ~f = map_endo map t ~f

  let merge_endo t u ~f =
    let change = ref false in
    let t' =
      merge t u ~f:(fun ~key side ->
          let f_side = f ~key side in
          ( match (side, f_side) with
          | (`Both (data, _) | `Left data), Some data' when data' == data ->
              ()
          | _ -> change := true ) ;
          f_side )
    in
    if !change then t' else t

  let fold_until m ~init ~f ~finish =
    let fold m ~init ~f =
      let f ~key ~data s = f s (key, data) in
      fold m ~init ~f
    in
    let f s (k, v) = f ~key:k ~data:v s in
    Container.fold_until ~fold ~init ~f ~finish m

  let root_key_exn m =
    let@ {return} = with_return in
    binary_search_segmented m `Last_on_left ~segment_of:(fun ~key ~data:_ ->
        return key )
    |> ignore ;
    raise (Not_found_s (Atom __LOC__))

  let choose_exn m =
    let@ {return} = with_return in
    binary_search_segmented m `Last_on_left ~segment_of:(fun ~key ~data ->
        return (key, data) )
    |> ignore ;
    raise (Not_found_s (Atom __LOC__))

  let choose m = try Some (choose_exn m) with Not_found_s _ -> None
  let pop m = choose m |> Option.map ~f:(fun (k, v) -> (k, v, remove m k))

  let pop_min_elt m =
    min_elt m |> Option.map ~f:(fun (k, v) -> (k, v, remove m k))

  let is_singleton m =
    try
      let l, _, r = split m (root_key_exn m) in
      is_empty l && is_empty r
    with Not_found_s _ -> false

  let find_and_remove m k =
    let found = ref None in
    let m =
      change m k ~f:(fun v ->
          found := v ;
          None )
    in
    Option.map ~f:(fun v -> (v, m)) !found

  let pp pp_k pp_v fs m =
    Format.fprintf fs "@[<1>[%a]@]"
      (List.pp ",@ " (fun fs (k, v) ->
           Format.fprintf fs "@[%a@ @<2>↦ %a@]" pp_k k pp_v v ))
      (to_alist m)

  let pp_diff ~data_equal pp_key pp_val pp_diff_val fs (x, y) =
    let pp_diff_elt fs = function
      | k, `Left v ->
          Format.fprintf fs "-- [@[%a@ @<2>↦ %a@]]" pp_key k pp_val v
      | k, `Right v ->
          Format.fprintf fs "++ [@[%a@ @<2>↦ %a@]]" pp_key k pp_val v
      | k, `Unequal vv ->
          Format.fprintf fs "[@[%a@ @<2>↦ %a@]]" pp_key k pp_diff_val vv
    in
    let sd = Sequence.to_list (symmetric_diff ~data_equal x y) in
    if not (List.is_empty sd) then
      Format.fprintf fs "[@[<hv>%a@]];@ " (List.pp ";@ " pp_diff_elt) sd
end
