(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Equality over uninterpreted functions and linear rational arithmetic *)

type 'a term_map = 'a Map.M(Term).t [@@deriving compare, equal, sexp]

let empty_map = Map.empty (module Term)

type subst = Term.t term_map [@@deriving compare, equal, sexp]

let pp_subst fs s =
  Format.fprintf fs "@[<1>[%a]@]"
    (List.pp ",@ " (fun fs (k, v) ->
         Format.fprintf fs "@[%a ↦ %a@]" Term.pp k Term.pp v ))
    (Map.to_alist s)

(** Theory Solver *)

let rec is_constant e =
  match (e : Term.t) with
  | Var _ | Nondet _ -> false
  | Ap1 (_, x) -> is_constant x
  | Ap2 (_, x, y) -> is_constant x && is_constant y
  | Ap3 (_, x, y, z) -> is_constant x && is_constant y && is_constant z
  | ApN (_, xs) | RecN (_, xs) -> Vector.for_all ~f:is_constant xs
  | Add args | Mul args ->
      Qset.for_all ~f:(fun arg _ -> is_constant arg) args
  | Label _ | Float _ | Integer _ -> true

type kind = Interpreted | Simplified | Atomic | Uninterpreted
[@@deriving compare]

let classify e =
  match (e : Term.t) with
  | Add _ | Mul _ -> Interpreted
  | Ap2 ((Eq | Dq), _, _) -> Simplified
  | Ap1 _ | Ap2 _ | Ap3 _ | ApN _ -> Uninterpreted
  | RecN _ | Var _ | Integer _ | Float _ | Nondet _ | Label _ -> Atomic

let solve e f =
  [%Trace.call fun {pf} -> pf "%a@ %a" Term.pp e Term.pp f]
  ;
  let rec solve_ e f s =
    let solve_uninterp e f =
      match ((e : Term.t), (f : Term.t)) with
      | Integer {data= m}, Integer {data= n} when not (Z.equal m n) -> None
      | _ -> (
        match (is_constant e, is_constant f) with
        (* orient equation to discretionarily prefer term that is constant
           or compares smaller as class representative *)
        | true, false -> Some (Map.add_exn s ~key:f ~data:e)
        | false, true -> Some (Map.add_exn s ~key:e ~data:f)
        | _ ->
            let key, data =
              if Term.compare e f > 0 then (e, f) else (f, e)
            in
            Some (Map.add_exn s ~key ~data) )
    in
    let concat_size args =
      Vector.fold_until args ~init:Term.zero
        ~f:(fun sum m ->
          match (m : Term.t) with
          | Ap2 (Memory, siz, _) -> Continue (Term.add siz sum)
          | _ -> Stop None )
        ~finish:(fun _ -> None)
    in
    match ((e : Term.t), (f : Term.t)) with
    | (Add _ | Mul _ | Integer _), _ | _, (Add _ | Mul _ | Integer _) -> (
        let e_f = Term.sub e f in
        match Term.solve_zero_eq e_f with
        | Some (key, data) -> Some (Map.add_exn s ~key ~data)
        | None -> solve_uninterp e_f Term.zero )
    | ApN (Concat, ms), ApN (Concat, ns) -> (
      match (concat_size ms, concat_size ns) with
      | Some p, Some q -> solve_uninterp e f >>= solve_ p q
      | _ -> solve_uninterp e f )
    | Ap2 (Memory, m, _), ApN (Concat, ns)
     |ApN (Concat, ns), Ap2 (Memory, m, _) -> (
      match concat_size ns with
      | Some p -> solve_uninterp e f >>= solve_ p m
      | _ -> solve_uninterp e f )
    | _ -> solve_uninterp e f
  in
  solve_ e f empty_map
  |>
  [%Trace.retn fun {pf} ->
    function Some s -> pf "%a" pp_subst s | None -> pf "false"]

(** Equality Relations *)

(** see also [invariant] *)
type t =
  { sat: bool  (** [false] only if constraints are inconsistent *)
  ; rep: subst
        (** functional set of oriented equations: map [a] to [a'],
            indicating that [a = a'] holds, and that [a'] is the
            'rep(resentative)' of [a] *) }
[@@deriving compare, equal, sexp]

(** apply a subst to a term *)
let apply s a = Map.find s a |> Option.value ~default:a

let classes r =
  let add key data cls =
    if Term.equal key data then cls
    else Map.add_multi cls ~key:data ~data:key
  in
  Map.fold r.rep ~init:empty_map ~f:(fun ~key ~data cls ->
      match classify key with
      | Interpreted | Atomic -> add key data cls
      | Simplified | Uninterpreted ->
          add (Term.map ~f:(apply r.rep) key) data cls )

(** Pretty-printing *)

let pp fs {sat; rep} =
  let pp_alist pp_k pp_v fs alist =
    let pp_assoc fs (k, v) =
      Format.fprintf fs "[@[%a@ @<2>↦ %a@]]" pp_k k pp_v (k, v)
    in
    Format.fprintf fs "[@[<hv>%a@]]" (List.pp ";@ " pp_assoc) alist
  in
  let pp_term_v fs (k, v) = if not (Term.equal k v) then Term.pp fs v in
  Format.fprintf fs "@[{@[<hv>sat= %b;@ rep= %a@]}@]" sat
    (pp_alist Term.pp pp_term_v)
    (Map.to_alist rep)

let pp_diff fs (r, s) =
  let pp_sdiff_map pp_elt_diff equal nam fs x y =
    let sd = Sequence.to_list (Map.symmetric_diff ~data_equal:equal x y) in
    if not (List.is_empty sd) then
      Format.fprintf fs "%s= [@[<hv>%a@]];@ " nam
        (List.pp ";@ " pp_elt_diff)
        sd
  in
  let pp_sdiff_elt pp_key pp_val pp_sdiff_val fs = function
    | k, `Left v ->
        Format.fprintf fs "-- [@[%a@ @<2>↦ %a@]]" pp_key k pp_val v
    | k, `Right v ->
        Format.fprintf fs "++ [@[%a@ @<2>↦ %a@]]" pp_key k pp_val v
    | k, `Unequal vv ->
        Format.fprintf fs "[@[%a@ @<2>↦ %a@]]" pp_key k pp_sdiff_val vv
  in
  let pp_sdiff_term_map =
    let pp_sdiff_term fs (u, v) =
      Format.fprintf fs "-- %a ++ %a" Term.pp u Term.pp v
    in
    pp_sdiff_map (pp_sdiff_elt Term.pp Term.pp pp_sdiff_term) Term.equal
  in
  let pp_sat fs =
    if not (Bool.equal r.sat s.sat) then
      Format.fprintf fs "sat= @[-- %b@ ++ %b@];@ " r.sat s.sat
  in
  let pp_rep fs = pp_sdiff_term_map "rep" fs r.rep s.rep in
  Format.fprintf fs "@[{@[<hv>%t%t@]}@]" pp_sat pp_rep

(** Invariant *)

(** test membership in carrier *)
let in_car r e = Map.mem r.rep e

let rec iter_max_solvables e ~f =
  match classify e with
  | Interpreted -> Term.iter ~f:(iter_max_solvables ~f) e
  | _ -> f e

let invariant r =
  Invariant.invariant [%here] r [%sexp_of: t]
  @@ fun () ->
  Map.iteri r.rep ~f:(fun ~key:a ~data:_ ->
      (* no interpreted terms in carrier *)
      assert (Poly.(classify a <> Interpreted)) ;
      (* carrier is closed under subterms *)
      iter_max_solvables a ~f:(fun b ->
          assert (
            in_car r b
            || fail "@[subterm %a of %a not in carrier of@ %a@]" Term.pp b
                 Term.pp a pp r () ) ) )

(** Core operations *)

let true_ = {sat= true; rep= empty_map} |> check invariant

(** apply a subst to maximal non-interpreted subterms *)
let rec norm s a =
  match classify a with
  | Interpreted -> Term.map ~f:(norm s) a
  | Simplified -> apply s (Term.map ~f:(norm s) a)
  | Atomic | Uninterpreted -> apply s a

(** terms are congruent if equal after normalizing subterms *)
let congruent r a b =
  Term.equal (Term.map ~f:(norm r.rep) a) (Term.map ~f:(norm r.rep) b)

(** [lookup r a] is [b'] if [a ~ b = b'] for some equation [b = b'] in rep *)
let lookup r a =
  With_return.with_return
  @@ fun {return} ->
  (* congruent specialized to assume [a] canonized and [b] non-interpreted *)
  let semi_congruent r a b = Term.equal a (Term.map ~f:(apply r.rep) b) in
  Map.iteri r.rep ~f:(fun ~key ~data ->
      if semi_congruent r a key then return data ) ;
  a

(** rewrite a term into canonical form using rep and, for uninterpreted
    terms, congruence composed with rep *)
let rec canon r a =
  match classify a with
  | Interpreted -> Term.map ~f:(canon r) a
  | Simplified | Uninterpreted -> lookup r (Term.map ~f:(canon r) a)
  | Atomic -> apply r.rep a

(** add a term to the carrier *)
let rec extend a r =
  match classify a with
  | Interpreted | Simplified -> Term.fold ~f:extend a ~init:r
  | Uninterpreted ->
      Map.find_or_add r.rep a
        ~if_found:(fun _ -> r)
        ~default:a
        ~if_added:(fun rep -> Term.fold ~f:extend a ~init:{r with rep})
  | Atomic -> r

let extend a r = extend a r |> check invariant

let compose r s =
  let rep = Map.map ~f:(norm s) r.rep in
  let rep =
    Map.merge_skewed rep s ~combine:(fun ~key v1 v2 ->
        if Term.equal v1 v2 then v1
        else fail "domains intersect: %a" Term.pp key () )
  in
  {r with rep}

let merge a b r =
  [%Trace.call fun {pf} -> pf "%a@ %a@ %a" Term.pp a Term.pp b pp r]
  ;
  ( match solve a b with
  | Some s -> compose r s
  | None -> {r with sat= false} )
  |>
  [%Trace.retn fun {pf} r' ->
    pf "%a" pp_diff (r, r') ;
    invariant r']

(** find an unproved equation between congruent terms *)
let find_missing r =
  With_return.with_return
  @@ fun {return} ->
  Map.iteri r.rep ~f:(fun ~key:a ~data:a' ->
      Map.iteri r.rep ~f:(fun ~key:b ~data:b' ->
          if
            Term.compare a b < 0
            && (not (Term.equal a' b'))
            && congruent r a b
          then return (Some (a', b')) ) ) ;
  None

let rec close r =
  if not r.sat then r
  else
    match find_missing r with
    | Some (a', b') -> close (merge a' b' r)
    | None -> r

let close r =
  [%Trace.call fun {pf} -> pf "%a" pp r]
  ;
  close r
  |>
  [%Trace.retn fun {pf} r' ->
    pf "%a" pp_diff (r, r') ;
    invariant r']

(** Exposed interface *)

let and_eq a b r =
  [%Trace.call fun {pf} -> pf "%a = %a@ %a" Term.pp a Term.pp b pp r]
  ;
  ( if not r.sat then r
  else
    let a' = canon r a in
    let b' = canon r b in
    let r = extend a' r in
    let r = extend b' r in
    if Term.equal a' b' then r else close (merge a' b' r) )
  |>
  [%Trace.retn fun {pf} r' ->
    pf "%a" pp_diff (r, r') ;
    invariant r']

let is_true {sat; rep} =
  sat && Map.for_alli rep ~f:(fun ~key:a ~data:a' -> Term.equal a a')

let is_false {sat} = not sat
let entails_eq r d e = Term.equal (canon r d) (canon r e)

let entails r s =
  Map.for_alli s.rep ~f:(fun ~key:e ~data:e' -> entails_eq r e e')

let normalize = canon

let class_of r e =
  let e' = normalize r e in
  e' :: Map.find_multi (classes r) e'

let difference r a b =
  [%Trace.call fun {pf} -> pf "%a@ %a@ %a" Term.pp a Term.pp b pp r]
  ;
  let a = canon r a in
  let b = canon r b in
  ( if Term.equal a b then Some Z.zero
  else
    match normalize r (Term.sub a b) with
    | Integer {data} -> Some data
    | _ -> None )
  |>
  [%Trace.retn fun {pf} ->
    function Some d -> pf "%a" Z.pp_print d | None -> pf ""]

let and_ r s =
  if not r.sat then r
  else if not s.sat then s
  else
    let s, r =
      if Map.length s.rep <= Map.length r.rep then (s, r) else (r, s)
    in
    Map.fold s.rep ~init:r ~f:(fun ~key:e ~data:e' r -> and_eq e e' r)

let or_ r s =
  [%Trace.call fun {pf} -> pf "@[<hv 1>   %a@ @<2>∨ %a@]" pp r pp s]
  ;
  ( if not s.sat then r
  else if not r.sat then s
  else
    let merge_mems rs r s =
      Map.fold (classes s) ~init:rs ~f:(fun ~key:rep ~data:cls rs ->
          List.fold cls
            ~init:([rep], rs)
            ~f:(fun (reps, rs) exp ->
              match List.find ~f:(entails_eq r exp) reps with
              | Some rep -> (reps, and_eq exp rep rs)
              | None -> (exp :: reps, rs) )
          |> snd )
    in
    let rs = true_ in
    let rs = merge_mems rs r s in
    let rs = merge_mems rs s r in
    rs )
  |>
  [%Trace.retn fun {pf} -> pf "%a" pp]

(* assumes that f is injective and for any set of terms E, f[E] is disjoint
   from E *)
let map_terms ({sat= _; rep} as r) ~f =
  [%Trace.call fun {pf} -> pf "%a" pp r]
  ;
  let map m =
    Map.fold m ~init:m ~f:(fun ~key ~data m ->
        let key' = f key in
        let data' = f data in
        if Term.equal key' key then
          if Term.equal data' data then m else Map.set m ~key ~data:data'
        else Map.remove m key |> Map.add_exn ~key:key' ~data:data' )
  in
  let rep' = map rep in
  (if rep' == rep then r else {r with rep= rep'})
  |>
  [%Trace.retn fun {pf} r' ->
    pf "%a" pp_diff (r, r') ;
    invariant r']

let rename r sub = map_terms r ~f:(Term.rename sub)

let fold_terms r ~init ~f =
  Map.fold r.rep ~f:(fun ~key ~data z -> f (f z data) key) ~init

let fold_vars r ~init ~f =
  fold_terms r ~init ~f:(fun init -> Term.fold_vars ~f ~init)

let fv e = fold_vars e ~f:Set.add ~init:Var.Set.empty

let pp_classes x fs r =
  List.pp "@ @<2>∧ "
    (fun fs (key, data) ->
      Format.fprintf fs "@[%a@ = %a@]" (Term.ppx x) key
        (List.pp "@ = " (Term.ppx x))
        (List.sort ~compare:Term.compare data) )
    fs
    (Map.to_alist (classes r))

let pp_classes_diff x fs (r, s) =
  let clss = classes s in
  let clss =
    Map.filter_mapi clss ~f:(fun ~key:rep ~data:cls ->
        match
          List.filter cls ~f:(fun exp -> not (entails_eq r rep exp))
        with
        | [] -> None
        | cls -> Some cls )
  in
  List.pp "@ @<2>∧ "
    (fun fs (rep, cls) ->
      Format.fprintf fs "@[%a@ = %a@]" (Term.ppx x) rep
        (List.pp "@ = " (Term.ppx x))
        (List.sort ~compare:Term.compare cls) )
    fs (Map.to_alist clss)
