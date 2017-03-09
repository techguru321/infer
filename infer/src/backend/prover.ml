(*
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

(** Functions for Propositions (i.e., Symbolic Heaps) *)

module L = Logging
module F = Format

let decrease_indent_when_exception thunk =
  try (thunk ())
  with exn when SymOp.exn_not_failure exn -> (L.d_decrease_indent 1; raise exn)

let compute_max_from_nonempty_int_list l =
  uw (List.max_elt ~cmp:IntLit.compare_value l)

let compute_min_from_nonempty_int_list l =
  uw (List.min_elt ~cmp:IntLit.compare_value l)

let rec list_rev_acc acc = function
  | [] -> acc
  | x:: l -> list_rev_acc (x:: acc) l

let rec remove_redundancy have_same_key acc = function
  | [] -> List.rev acc
  | [x] -> List.rev (x:: acc)
  | x:: ((y:: l') as l) ->
      if have_same_key x y then remove_redundancy have_same_key acc (x:: l')
      else remove_redundancy have_same_key (x:: acc) l

let rec is_java_class tenv (typ: Typ.t) =
  match typ with
  | Tstruct name -> Typename.Java.is_class name
  | Tarray (inner_typ, _) | Tptr (inner_typ, _) -> is_java_class tenv inner_typ
  | _ -> false

(** Negate an atom *)
let atom_negate tenv = function
  | Sil.Aeq (Exp.BinOp (Binop.Le, e1, e2), Exp.Const (Const.Cint i)) when IntLit.isone i ->
      Prop.mk_inequality tenv (Exp.lt e2 e1)
  | Sil.Aeq (Exp.BinOp (Binop.Lt, e1, e2), Exp.Const (Const.Cint i)) when IntLit.isone i ->
      Prop.mk_inequality tenv (Exp.le e2 e1)
  | Sil.Aeq (e1, e2) -> Sil.Aneq (e1, e2)
  | Sil.Aneq (e1, e2) -> Sil.Aeq (e1, e2)
  | Sil.Apred (a, es) -> Sil.Anpred (a, es)
  | Sil.Anpred (a, es) -> Sil.Apred (a, es)

(** {2 Ordinary Theorem Proving} *)

let (++) = IntLit.add
let (--) = IntLit.sub

(** Reasoning about constraints of the form x-y <= n *)

module DiffConstr : sig

  type t
  val to_leq : t -> Exp.t * Exp.t
  val to_lt : t -> Exp.t * Exp.t
  val to_triple : t -> Exp.t * Exp.t * IntLit.t
  val from_leq : t list -> Exp.t * Exp.t -> t list
  val from_lt : t list -> Exp.t * Exp.t -> t list
  val saturate : t list -> bool * t list

end = struct

  type t = Exp.t * Exp.t * IntLit.t [@@deriving compare]

  let equal = [%compare.equal : t]

  let to_leq (e1, e2, n) =
    Exp.BinOp(Binop.MinusA, e1, e2), Exp.int n
  let to_lt (e1, e2, n) =
    Exp.int (IntLit.zero -- n -- IntLit.one), Exp.BinOp(Binop.MinusA, e2, e1)
  let to_triple entry = entry

  let from_leq acc (e1, e2) =
    match e1, e2 with
    | Exp.BinOp (Binop.MinusA, (Exp.Var id11 as e11), (Exp.Var id12 as e12)),
      Exp.Const (Const.Cint n)
      when not (Ident.equal id11 id12) ->
        (match IntLit.to_signed n with
         | None -> acc (* ignore: constraint algorithm only terminates on signed integers *)
         | Some n' ->
             (e11, e12, n') :: acc)
    | _ -> acc
  let from_lt acc (e1, e2) =
    match e1, e2 with
    | Exp.Const (Const.Cint n),
      Exp.BinOp (Binop.MinusA, (Exp.Var id21 as e21), (Exp.Var id22 as e22))
      when not (Ident.equal id21 id22) ->
        (match IntLit.to_signed n with
         | None -> acc (* ignore: constraint algorithm only terminates on signed integers *)
         | Some n' ->
             let m = IntLit.zero -- n' -- IntLit.one in
             (e22, e21, m) :: acc)
    | _ -> acc

  let rec generate ((e1, e2, n) as constr) acc = function
    | [] -> false, acc
    | (f1, f2, m):: rest ->
        let equal_e2_f1 = Exp.equal e2 f1 in
        let equal_e1_f2 = Exp.equal e1 f2 in
        if equal_e2_f1 && equal_e1_f2 && IntLit.lt (n ++ m) IntLit.zero then
          true, [] (* constraints are inconsistent *)
        else if equal_e2_f1 && equal_e1_f2 then
          generate constr acc rest
        else if equal_e2_f1 then
          let constr_new = (e1, f2, n ++ m) in
          generate constr (constr_new:: acc) rest
        else if equal_e1_f2 then
          let constr_new = (f1, e2, m ++ n) in
          generate constr (constr_new:: acc) rest
        else
          generate constr acc rest

  let sort_then_remove_redundancy constraints =
    let constraints_sorted = List.sort ~cmp:compare constraints in
    let have_same_key (e1, e2, _) (f1, f2, _) = [%compare.equal: Exp.t * Exp.t] (e1, e2) (f1, f2) in
    remove_redundancy have_same_key [] constraints_sorted

  let remove_redundancy constraints =
    let constraints' = sort_then_remove_redundancy constraints in
    List.filter ~f:(fun entry -> List.exists ~f:(equal entry) constraints') constraints

  let rec combine acc_todos acc_seen constraints_new constraints_old =
    match constraints_new, constraints_old with
    | [], [] -> List.rev acc_todos, List.rev acc_seen
    | [], _ -> List.rev acc_todos, list_rev_acc constraints_old acc_seen
    | _, [] -> list_rev_acc constraints_new acc_todos, list_rev_acc constraints_new acc_seen
    | constr:: rest, constr':: rest' ->
        let e1, e2, n = constr in
        let f1, f2, m = constr' in
        let c1 = [%compare: Exp.t * Exp.t] (e1, e2) (f1, f2) in
        if Int.equal c1 0 && IntLit.lt n m then
          combine acc_todos acc_seen constraints_new rest'
        else if Int.equal c1 0 then
          combine acc_todos acc_seen rest constraints_old
        else if c1 < 0 then
          combine (constr:: acc_todos) (constr:: acc_seen) rest constraints_old
        else
          combine acc_todos (constr':: acc_seen) constraints_new rest'

  let rec _saturate seen todos =
    (* seen is a superset of todos. "seen" is sorted and doesn't have redundancy. *)
    match todos with
    | [] -> false, seen
    | constr:: rest ->
        let inconsistent, constraints_new = generate constr [] seen in
        if inconsistent then true, []
        else
          let constraints_new' = sort_then_remove_redundancy constraints_new in
          let todos_new, seen_new = combine [] [] constraints_new' seen in
          (* Important to use queue here. Otherwise, might diverge *)
          let rest_new = remove_redundancy (rest @ todos_new) in
          let seen_new' = sort_then_remove_redundancy seen_new in
          _saturate seen_new' rest_new

  let saturate constraints =
    let constraints_cleaned = sort_then_remove_redundancy constraints in
    _saturate constraints_cleaned constraints_cleaned
end

(** Return true if the two types have sizes which can be compared *)
let type_size_comparable t1 t2 = match t1, t2 with
  | Typ.Tint _, Typ.Tint _ -> true
  | _ -> false

(** Compare the size of comparable types *)
let type_size_compare t1 t2 =
  let ik_compare ik1 ik2 =
    let ik_size = function
      | Typ.IChar | Typ.ISChar | Typ.IUChar | Typ.IBool -> 1
      | Typ.IShort | Typ.IUShort -> 2
      | Typ.IInt | Typ.IUInt -> 3
      | Typ.ILong | Typ.IULong -> 4
      | Typ.ILongLong | Typ.IULongLong -> 5
      | Typ.I128 | Typ.IU128 -> 6 in
    let n1 = ik_size ik1 in
    let n2 = ik_size ik2 in
    n1 - n2 in
  match t1, t2 with
  | Typ.Tint ik1, Typ.Tint ik2 ->
      Some (ik_compare ik1 ik2)
  | _ -> None

(** Check <= on the size of comparable types *)
let check_type_size_leq t1 t2 = match type_size_compare t1 t2 with
  | None -> false
  | Some n -> n <= 0

(** Check < on the size of comparable types *)
let check_type_size_lt t1 t2 = match type_size_compare t1 t2 with
  | None -> false
  | Some n -> n < 0

(** Reasoning about inequalities *)
module Inequalities : sig
  (** type for inequalities (and implied disequalities) *)
  type t

  (** Extract inequalities and disequalities from [prop] *)
  val from_prop : Tenv.t -> Prop.normal Prop.t -> t

  (** Check [t |- e1!=e2]. Result [false] means "don't know". *)
  val check_ne : t -> Exp.t -> Exp.t -> bool

  (** Check [t |- e1<=e2]. Result [false] means "don't know". *)
  val check_le : t -> Exp.t -> Exp.t -> bool

  (** Check [t |- e1<e2]. Result [false] means "don't know". *)
  val check_lt : t -> Exp.t -> Exp.t -> bool

  (** Find a IntLit.t n such that [t |- e<=n] if possible. *)
  val compute_upper_bound : t -> Exp.t -> IntLit.t option

  (** Find a IntLit.t n such that [t |- n<e] if possible. *)
  val compute_lower_bound : t -> Exp.t -> IntLit.t option

  (** Return [true] if a simple inconsistency is detected *)
  val inconsistent : t -> bool

(*
  (** Extract inequalities and disequalities from [pi] *)
  val from_pi : Sil.atom list -> t

  (** Extract inequalities and disequalities from [sigma] *)
  val from_sigma : Sil.hpred list -> t

  (** Join two sets of inequalities *)
  val join : t -> t -> t

  (** Pretty print inequalities and disequalities *)
  val pp : printenv -> Format.formatter -> t -> unit

  (** Pretty print <= *)
  val d_leqs : t -> unit

  (** Pretty print < *)
  val d_lts : t -> unit

  (** Pretty print <> *)
  val d_neqs : t -> unit
*)
end = struct

  type t = {
    mutable leqs: (Exp.t * Exp.t) list; (** le fasts [e1 <= e2] *)
    mutable lts: (Exp.t * Exp.t) list; (** lt facts [e1 < e2] *)
    mutable neqs: (Exp.t * Exp.t) list; (** ne facts [e1 != e2] *)
  }

  let inconsistent_ineq = { leqs = [(Exp.one, Exp.zero)]; lts = []; neqs = [] }

  let leq_compare (e1, e2) (f1, f2) =
    let c1 = Exp.compare e1 f1 in
    if c1 <> 0 then c1 else Exp.compare e2 f2
  let lt_compare (e1, e2) (f1, f2) =
    let c2 = Exp.compare e2 f2 in
    if c2 <> 0 then c2 else - (Exp.compare e1 f1)

  let leqs_sort_then_remove_redundancy leqs =
    let leqs_sorted = List.sort ~cmp:leq_compare leqs in
    let have_same_key leq1 leq2 =
      match leq1, leq2 with
      | (e1, Exp.Const (Const.Cint n1)), (e2, Exp.Const (Const.Cint n2)) ->
          Exp.equal e1 e2 && IntLit.leq n1 n2
      | _, _ -> false in
    remove_redundancy have_same_key [] leqs_sorted
  let lts_sort_then_remove_redundancy lts =
    let lts_sorted = List.sort ~cmp:lt_compare lts in
    let have_same_key lt1 lt2 =
      match lt1, lt2 with
      | (Exp.Const (Const.Cint n1), e1), (Exp.Const (Const.Cint n2), e2) ->
          Exp.equal e1 e2 && IntLit.geq n1 n2
      | _, _ -> false in
    remove_redundancy have_same_key [] lts_sorted

  let saturate { leqs = leqs; lts = lts; neqs = neqs } =
    let diff_constraints1 =
      List.fold
        ~f:DiffConstr.from_lt
        ~init:(List.fold ~f:DiffConstr.from_leq ~init:[] leqs)
        lts in
    let inconsistent, diff_constraints2 = DiffConstr.saturate diff_constraints1 in
    if inconsistent then inconsistent_ineq
    else begin
      let umap_add umap e new_upper =
        try
          let old_upper = Exp.Map.find e umap in
          if IntLit.leq old_upper new_upper then umap else Exp.Map.add e new_upper umap
        with Not_found -> Exp.Map.add e new_upper umap in
      let lmap_add lmap e new_lower =
        try
          let old_lower = Exp.Map.find e lmap in
          if IntLit.geq old_lower new_lower then lmap else Exp.Map.add e new_lower lmap
        with Not_found -> Exp.Map.add e new_lower lmap in
      let rec umap_create_from_leqs umap = function
        | [] -> umap
        | (e1, Exp.Const (Const.Cint upper1)):: leqs_rest ->
            let umap' = umap_add umap e1 upper1 in
            umap_create_from_leqs umap' leqs_rest
        | _:: leqs_rest -> umap_create_from_leqs umap leqs_rest in
      let rec lmap_create_from_lts lmap = function
        | [] -> lmap
        | (Exp.Const (Const.Cint lower1), e1):: lts_rest ->
            let lmap' = lmap_add lmap e1 lower1 in
            lmap_create_from_lts lmap' lts_rest
        | _:: lts_rest -> lmap_create_from_lts lmap lts_rest in
      let rec umap_improve_by_difference_constraints umap = function
        | [] -> umap
        | constr:: constrs_rest ->
            try
              let e1, e2, n = DiffConstr.to_triple constr (* e1 - e2 <= n *) in
              let upper2 = Exp.Map.find e2 umap in
              let new_upper1 = upper2 ++ n in
              let new_umap = umap_add umap e1 new_upper1 in
              umap_improve_by_difference_constraints new_umap constrs_rest
            with Not_found ->
              umap_improve_by_difference_constraints umap constrs_rest in
      let rec lmap_improve_by_difference_constraints lmap = function
        | [] -> lmap
        | constr:: constrs_rest -> (* e2 - e1 > -n-1 *)
            try
              let e1, e2, n = DiffConstr.to_triple constr (* e2 - e1 > -n-1 *) in
              let lower1 = Exp.Map.find e1 lmap in
              let new_lower2 = lower1 -- n -- IntLit.one in
              let new_lmap = lmap_add lmap e2 new_lower2 in
              lmap_improve_by_difference_constraints new_lmap constrs_rest
            with Not_found ->
              lmap_improve_by_difference_constraints lmap constrs_rest in
      let leqs_res =
        let umap = umap_create_from_leqs Exp.Map.empty leqs in
        let umap' = umap_improve_by_difference_constraints umap diff_constraints2 in
        let leqs' = Exp.Map.fold
            (fun e upper acc_leqs -> (e, Exp.int upper):: acc_leqs)
            umap' [] in
        let leqs'' = (List.map ~f:DiffConstr.to_leq diff_constraints2) @ leqs' in
        leqs_sort_then_remove_redundancy leqs'' in
      let lts_res =
        let lmap = lmap_create_from_lts Exp.Map.empty lts in
        let lmap' = lmap_improve_by_difference_constraints lmap diff_constraints2 in
        let lts' = Exp.Map.fold
            (fun e lower acc_lts -> (Exp.int lower, e):: acc_lts)
            lmap' [] in
        let lts'' = (List.map ~f:DiffConstr.to_lt diff_constraints2) @ lts' in
        lts_sort_then_remove_redundancy lts'' in
      { leqs = leqs_res; lts = lts_res; neqs = neqs }
    end

  (** Extract inequalities and disequalities from [pi] *)
  let from_pi pi =
    let leqs = ref [] in (* <= facts *)
    let lts = ref [] in (* < facts *)
    let neqs = ref [] in (* != facts *)
    let process_atom = function
      | Sil.Aneq (e1, e2) -> (* != *)
          neqs := (e1, e2) :: !neqs
      | Sil.Aeq (Exp.BinOp (Binop.Le, e1, e2), Exp.Const (Const.Cint i)) when IntLit.isone i ->
          leqs := (e1, e2) :: !leqs (* <= *)
      | Sil.Aeq (Exp.BinOp (Binop.Lt, e1, e2), Exp.Const (Const.Cint i)) when IntLit.isone i ->
          lts := (e1, e2) :: !lts (* < *)
      | Sil.Aeq _
      | Sil.Apred _ | Anpred _ -> () in
    List.iter ~f:process_atom pi;
    saturate { leqs = !leqs; lts = !lts; neqs = !neqs }

  let from_sigma tenv sigma =
    let lookup = Tenv.lookup tenv in
    let leqs = ref [] in
    let lts = ref [] in
    let add_lt_minus1_e e =
      lts := (Exp.minus_one, e)::!lts in
    let type_opt_is_unsigned = function
      | Some Typ.Tint ik -> Typ.ikind_is_unsigned ik
      | _ -> false in
    let type_of_texp = function
      | Exp.Sizeof (t, _, _) -> Some t
      | _ -> None in
    let texp_is_unsigned texp = type_opt_is_unsigned @@ type_of_texp texp in
    let strexp_lt_minus1 = function
      | Sil.Eexp (e, _) -> add_lt_minus1_e e
      | _ -> () in
    let rec strexp_extract = function
      | Sil.Eexp (e, _), t ->
          if type_opt_is_unsigned t then add_lt_minus1_e e
      | Sil.Estruct (fsel, _), t ->
          let get_field_type f =
            Option.bind t (fun t' ->
                Option.map ~f:fst @@ Typ.Struct.get_field_type_and_annotation ~lookup f t'
              ) in
          List.iter ~f:(fun (f, se) -> strexp_extract (se, get_field_type f)) fsel
      | Sil.Earray (len, isel, _), t ->
          let elt_t = match t with
            | Some Typ.Tarray (t, _) -> Some t
            | _ -> None in
          add_lt_minus1_e len;
          List.iter ~f:(fun (idx, se) ->
              add_lt_minus1_e idx;
              strexp_extract (se, elt_t)) isel in
    let hpred_extract = function
      | Sil.Hpointsto(_, se, texp) ->
          if texp_is_unsigned texp then strexp_lt_minus1 se;
          strexp_extract (se, type_of_texp texp)
      | Sil.Hlseg _ | Sil.Hdllseg _ -> () in
    List.iter ~f:hpred_extract sigma;
    saturate { leqs = !leqs; lts = !lts; neqs = [] }

  let join ineq1 ineq2 =
    let leqs_new = ineq1.leqs @ ineq2.leqs in
    let lts_new = ineq1.lts @ ineq2.lts in
    let neqs_new = ineq1.neqs @ ineq2.neqs in
    saturate { leqs = leqs_new; lts = lts_new; neqs = neqs_new }

  let from_prop tenv prop =
    let sigma = prop.Prop.sigma in
    let pi = prop.Prop.pi in
    let ineq_sigma = from_sigma tenv sigma in
    let ineq_pi = from_pi pi in
    saturate (join ineq_sigma ineq_pi)

  (** Return true if the two pairs of expressions are equal *)
  let exp_pair_eq (e1, e2) (f1, f2) =
    Exp.equal e1 f1 && Exp.equal e2 f2

  (** Check [t |- e1<=e2]. Result [false] means "don't know". *)
  let check_le { leqs = leqs; lts = lts; neqs = _ } e1 e2 =
    (* L.d_str "check_le "; Sil.d_exp e1; L.d_str " "; Sil.d_exp e2; L.d_ln (); *)
    match e1, e2 with
    | Exp.Const (Const.Cint n1), Exp.Const (Const.Cint n2) -> IntLit.leq n1 n2
    | Exp.BinOp (Binop.MinusA, Exp.Sizeof (t1, None, _), Exp.Sizeof (t2, None, _)),
      Exp.Const(Const.Cint n2)
      when IntLit.isminusone n2 && type_size_comparable t1 t2 ->
        (* [ sizeof(t1) - sizeof(t2) <= -1 ] *)
        check_type_size_lt t1 t2
    | e, Exp.Const (Const.Cint n) -> (* [e <= n' <= n |- e <= n] *)
        List.exists ~f:(function
            | e', Exp.Const (Const.Cint n') -> Exp.equal e e' && IntLit.leq n' n
            | _, _ -> false) leqs
    | Exp.Const (Const.Cint n), e -> (* [ n-1 <= n' < e |- n <= e] *)
        List.exists ~f:(function
            | Exp.Const (Const.Cint n'), e' -> Exp.equal e e' && IntLit.leq (n -- IntLit.one) n'
            | _, _ -> false) lts
    | _ -> Exp.equal e1 e2

  (** Check [prop |- e1<e2]. Result [false] means "don't know". *)
  let check_lt { leqs = leqs; lts = lts; neqs = _ } e1 e2 =
    (* L.d_str "check_lt "; Sil.d_exp e1; L.d_str " "; Sil.d_exp e2; L.d_ln (); *)
    match e1, e2 with
    | Exp.Const (Const.Cint n1), Exp.Const (Const.Cint n2) -> IntLit.lt n1 n2
    | Exp.Const (Const.Cint n), e -> (* [n <= n' < e  |- n < e] *)
        List.exists ~f:(function
            | Exp.Const (Const.Cint n'), e' -> Exp.equal e e' && IntLit.leq n n'
            | _, _ -> false) lts
    | e, Exp.Const (Const.Cint n) -> (* [e <= n' <= n-1 |- e < n] *)
        List.exists ~f:(function
            | e', Exp.Const (Const.Cint n') -> Exp.equal e e' && IntLit.leq n' (n -- IntLit.one)
            | _, _ -> false) leqs
    | _ -> false

  (** Check [prop |- e1!=e2]. Result [false] means "don't know". *)
  let check_ne ineq _e1 _e2 =
    let e1, e2 = if Exp.compare _e1 _e2 <= 0 then _e1, _e2 else _e2, _e1 in
    List.exists ~f:(exp_pair_eq (e1, e2)) ineq.neqs || check_lt ineq e1 e2 || check_lt ineq e2 e1

  (** Find a IntLit.t n such that [t |- e<=n] if possible. *)
  let compute_upper_bound { leqs = leqs; lts = _; neqs = _ } e1 =
    match e1 with
    | Exp.Const (Const.Cint n1) -> Some n1
    | _ ->
        let e_upper_list =
          List.filter ~f:(function
              | e', Exp.Const (Const.Cint _) -> Exp.equal e1 e'
              | _, _ -> false) leqs in
        let upper_list =
          List.map ~f:(function
              | _, Exp.Const (Const.Cint n) -> n
              | _ -> assert false) e_upper_list in
        if List.is_empty upper_list then None
        else Some (compute_min_from_nonempty_int_list upper_list)

  (** Find a IntLit.t n such that [t |- n < e] if possible. *)
  let compute_lower_bound { leqs = _; lts = lts; neqs = _ } e1 =
    match e1 with
    | Exp.Const (Const.Cint n1) -> Some (n1 -- IntLit.one)
    | Exp.Sizeof _ -> Some IntLit.zero
    | _ ->
        let e_lower_list =
          List.filter ~f:(function
              | Exp.Const (Const.Cint _), e' -> Exp.equal e1 e'
              | _, _ -> false) lts in
        let lower_list =
          List.map ~f:(function
              | Exp.Const (Const.Cint n), _ -> n
              | _ -> assert false) e_lower_list in
        if List.is_empty lower_list then None
        else Some (compute_max_from_nonempty_int_list lower_list)

  (** Return [true] if a simple inconsistency is detected *)
  let inconsistent ({ leqs = leqs; lts = lts; neqs = neqs } as ineq) =
    let inconsistent_neq (e1, e2) =
      check_le ineq e1 e2 && check_le ineq e2 e1 in
    let inconsistent_leq (e1, e2) = check_lt ineq e2 e1 in
    let inconsistent_lt (e1, e2) = check_le ineq e2 e1 in
    List.exists ~f:inconsistent_neq neqs ||
    List.exists ~f:inconsistent_leq leqs ||
    List.exists ~f:inconsistent_lt lts

(*
  (** Pretty print inequalities and disequalities *)
  let pp pe fmt { leqs = leqs; lts = lts; neqs = neqs } =
    let pp_leq fmt (e1, e2) = F.fprintf fmt "%a<=%a" (Sil.pp_exp pe) e1 (Sil.pp_exp pe) e2 in
    let pp_lt fmt (e1, e2) = F.fprintf fmt "%a<%a" (Sil.pp_exp pe) e1 (Sil.pp_exp pe) e2 in
    let pp_neq fmt (e1, e2) = F.fprintf fmt "%a!=%a" (Sil.pp_exp pe) e1 (Sil.pp_exp pe) e2 in
    Format.fprintf fmt "%a %a %a" (pp_seq pp_leq) leqs (pp_seq pp_lt) lts (pp_seq pp_neq) neqs

  let d_leqs { leqs = leqs; lts = lts; neqs = neqs } =
    let elist = List.map ~f:(fun (e1, e2) -> Exp.BinOp(Binop.Le, e1, e2)) leqs in
    Sil.d_exp_list elist

  let d_lts { leqs = leqs; lts = lts; neqs = neqs } =
    let elist = List.map ~f:(fun (e1, e2) -> Exp.BinOp(Binop.Lt, e1, e2)) lts in
    Sil.d_exp_list elist

  let d_neqs { leqs = leqs; lts = lts; neqs = neqs } =
    let elist = List.map ~f:(fun (e1, e2) -> Exp.BinOp(Binop.Ne, e1, e2)) lts in
    Sil.d_exp_list elist
*)
end
(* End of module Inequalities *)

(** Check [prop |- e1=e2]. Result [false] means "don't know". *)
let check_equal tenv prop e1 e2 =
  let n_e1 = Prop.exp_normalize_prop tenv prop e1 in
  let n_e2 = Prop.exp_normalize_prop tenv prop e2 in
  let check_equal () =
    Exp.equal n_e1 n_e2 in
  let check_equal_const () =
    match n_e1, n_e2 with
    | Exp.BinOp (Binop.PlusA, e1, Exp.Const (Const.Cint d)), e2
    | e2, Exp.BinOp (Binop.PlusA, e1, Exp.Const (Const.Cint d)) ->
        if Exp.equal e1 e2 then IntLit.iszero d
        else false
    | Exp.Const c1, Exp.Lindex(Exp.Const c2, Exp.Const (Const.Cint i)) when IntLit.iszero i ->
        Const.equal c1 c2
    | Exp.Lindex(Exp.Const c1, Exp.Const (Const.Cint i)), Exp.Const c2 when IntLit.iszero i ->
        Const.equal c1 c2
    | _, _ -> false in
  let check_equal_pi () =
    let eq = Sil.Aeq(n_e1, n_e2) in
    let n_eq = Prop.atom_normalize_prop tenv prop eq in
    let pi = prop.Prop.pi in
    List.exists ~f:(Sil.equal_atom n_eq) pi in
  check_equal () || check_equal_const () || check_equal_pi ()

(** Check [ |- e=0]. Result [false] means "don't know". *)
let check_zero tenv e =
  check_equal tenv Prop.prop_emp e Exp.zero

(** [is_root prop base_exp exp] checks whether [base_exp =
    exp.offlist] for some list of offsets [offlist]. If so, it returns
    [Some(offlist)]. Otherwise, it returns [None]. Assumes that
    [base_exp] points to the beginning of a structure, not the middle.
*)
let is_root tenv prop base_exp exp =
  let rec f offlist_past e = match e with
    | Exp.Var _ | Exp.Const _ | Exp.UnOp _ | Exp.BinOp _ | Exp.Exn _ | Exp.Closure _ | Exp.Lvar _
    | Exp.Sizeof _ ->
        if check_equal tenv prop base_exp e
        then Some offlist_past
        else None
    | Exp.Cast(_, sub_exp) -> f offlist_past sub_exp
    | Exp.Lfield(sub_exp, fldname, typ) -> f (Sil.Off_fld (fldname, typ) :: offlist_past) sub_exp
    | Exp.Lindex(sub_exp, e) -> f (Sil.Off_index e :: offlist_past) sub_exp
  in f [] exp

(** Get upper and lower bounds of an expression, if any *)
let get_bounds tenv prop _e =
  let e_norm = Prop.exp_normalize_prop tenv prop _e in
  let e_root, off = match e_norm with
    | Exp.BinOp (Binop.PlusA, e, Exp.Const (Const.Cint n1)) ->
        e, IntLit.neg n1
    | Exp.BinOp (Binop.MinusA, e, Exp.Const (Const.Cint n1)) ->
        e, n1
    | _ ->
        e_norm, IntLit.zero in
  let ineq = Inequalities.from_prop tenv prop in
  let upper_opt = Inequalities.compute_upper_bound ineq e_root in
  let lower_opt = Inequalities.compute_lower_bound ineq e_root in
  let (+++) n_opt k = match n_opt with
    | None -> None
    | Some n -> Some (n ++ k) in
  upper_opt +++ off, lower_opt +++ off

(** Check whether [prop |- e1!=e2]. *)
let check_disequal tenv prop e1 e2 =
  let spatial_part = prop.Prop.sigma in
  let n_e1 = Prop.exp_normalize_prop tenv prop e1 in
  let n_e2 = Prop.exp_normalize_prop tenv prop e2 in
  let check_disequal_const () =
    match n_e1, n_e2 with
    | Exp.Const c1, Exp.Const c2 ->
        (Const.kind_equal c1 c2) && not (Const.equal c1 c2)
    | Exp.Const c1, Exp.Lindex(Exp.Const c2, Exp.Const (Const.Cint d)) ->
        if IntLit.iszero d
        then not (Const.equal c1 c2) (* offset=0 is no offset *)
        else Const.equal c1 c2 (* same base, different offsets *)
    | Exp.BinOp (Binop.PlusA, e1, Exp.Const (Const.Cint d1)),
      Exp.BinOp (Binop.PlusA, e2, Exp.Const (Const.Cint d2)) ->
        if Exp.equal e1 e2 then IntLit.neq d1 d2
        else false
    | Exp.BinOp (Binop.PlusA, e1, Exp.Const (Const.Cint d)), e2
    | e2, Exp.BinOp (Binop.PlusA, e1, Exp.Const (Const.Cint d)) ->
        if Exp.equal e1 e2 then not (IntLit.iszero d)
        else false
    | Exp.Lindex(Exp.Const c1, Exp.Const (Const.Cint d)), Exp.Const c2 ->
        if IntLit.iszero d then not (Const.equal c1 c2) else Const.equal c1 c2
    | Exp.Lindex(Exp.Const c1, Exp.Const d1), Exp.Lindex (Exp.Const c2, Exp.Const d2) ->
        Const.equal c1 c2 && not (Const.equal d1 d2)
    | Exp.Const (Const.Cint n), Exp.BinOp (Binop.Mult, Exp.Sizeof _, e21)
    | Exp.Const (Const.Cint n), Exp.BinOp (Binop.Mult, e21, Sizeof _)
    | Exp.BinOp (Binop.Mult, Exp.Sizeof _, e21), Exp.Const (Const.Cint n)
    | Exp.BinOp (Binop.Mult, e21, Exp.Sizeof _), Exp.Const (Const.Cint n) ->
        IntLit.iszero n && not (Exp.is_zero e21)
    | _, _ -> false in
  let ineq = lazy (Inequalities.from_prop tenv prop) in
  let check_pi_implies_disequal e1 e2 =
    Inequalities.check_ne (Lazy.force ineq) e1 e2 in
  let neq_spatial_part () =
    let rec f sigma_irrelevant e = function
      | [] -> None
      | Sil.Hpointsto (base, _, _) as hpred :: sigma_rest ->
          (match is_root tenv prop base e with
           | None ->
               let sigma_irrelevant' = hpred :: sigma_irrelevant
               in f sigma_irrelevant' e sigma_rest
           | Some _ ->
               let sigma_irrelevant' = List.rev_append sigma_irrelevant sigma_rest
               in Some (true, sigma_irrelevant'))
      | Sil.Hlseg (k, _, e1, e2, _) as hpred :: sigma_rest ->
          (match is_root tenv prop e1 e with
           | None ->
               let sigma_irrelevant' = hpred :: sigma_irrelevant
               in f sigma_irrelevant' e sigma_rest
           | Some _ ->
               if (Sil.equal_lseg_kind k Sil.Lseg_NE || check_pi_implies_disequal e1 e2) then
                 let sigma_irrelevant' = List.rev_append sigma_irrelevant sigma_rest
                 in Some (true, sigma_irrelevant')
               else if (Exp.equal e2 Exp.zero) then
                 let sigma_irrelevant' = List.rev_append sigma_irrelevant sigma_rest
                 in Some (false, sigma_irrelevant')
               else
                 let sigma_rest' = List.rev_append sigma_irrelevant sigma_rest
                 in f [] e2 sigma_rest')
      | Sil.Hdllseg (Sil.Lseg_NE, _, iF, _, _, iB, _) :: sigma_rest ->
          if is_root tenv prop iF e <> None || is_root tenv prop iB e <> None then
            let sigma_irrelevant' = List.rev_append sigma_irrelevant sigma_rest
            in Some (true, sigma_irrelevant')
          else
            let sigma_irrelevant' = List.rev_append sigma_irrelevant sigma_rest
            in Some (false, sigma_irrelevant')
      | Sil.Hdllseg (Sil.Lseg_PE, _, iF, _, oF, _, _) as hpred :: sigma_rest ->
          (match is_root tenv prop iF e with
           | None ->
               let sigma_irrelevant' = hpred :: sigma_irrelevant
               in f sigma_irrelevant' e sigma_rest
           | Some _ ->
               if (check_pi_implies_disequal iF oF) then
                 let sigma_irrelevant' = List.rev_append sigma_irrelevant sigma_rest
                 in Some (true, sigma_irrelevant')
               else if (Exp.equal oF Exp.zero) then
                 let sigma_irrelevant' = List.rev_append sigma_irrelevant sigma_rest
                 in Some (false, sigma_irrelevant')
               else
                 let sigma_rest' = List.rev_append sigma_irrelevant sigma_rest
                 in f [] oF sigma_rest') in
    let f_null_check sigma_irrelevant e sigma_rest =
      if not (Exp.equal e Exp.zero) then f sigma_irrelevant e sigma_rest
      else
        let sigma_irrelevant' = List.rev_append sigma_irrelevant sigma_rest
        in Some (false, sigma_irrelevant')
    in match f_null_check [] n_e1 spatial_part with
    | None -> false
    | Some (e1_allocated, spatial_part_leftover) ->
        (match f_null_check [] n_e2 spatial_part_leftover with
         | None -> false
         | Some ((e2_allocated : bool), _) -> e1_allocated || e2_allocated) in
  let neq_pure_part () =
    check_pi_implies_disequal n_e1 n_e2 in
  check_disequal_const () || neq_pure_part () || neq_spatial_part ()

(** Check [prop |- e1<=e2], to be called from normalized atom *)
let check_le_normalized tenv prop e1 e2 =
  (* L.d_str "check_le_normalized "; Sil.d_exp e1; L.d_str " "; Sil.d_exp e2; L.d_ln (); *)
  let eL, eR, off = match e1, e2 with
    | Exp.BinOp(Binop.MinusA, f1, f2), Exp.Const (Const.Cint n) ->
        if Exp.equal f1 f2
        then Exp.zero, Exp.zero, n
        else f1, f2, n
    | _ ->
        e1, e2, IntLit.zero in
  let ineq = Inequalities.from_prop tenv prop in
  let upper_lower_check () =
    let upperL_opt = Inequalities.compute_upper_bound ineq eL in
    let lowerR_opt = Inequalities.compute_lower_bound ineq eR in
    match upperL_opt, lowerR_opt with
    | None, _ | _, None -> false
    | Some upper1, Some lower2 -> IntLit.leq upper1 (lower2 ++ IntLit.one ++ off) in
  (upper_lower_check ())
  || (Inequalities.check_le ineq e1 e2)
  || (check_equal tenv prop e1 e2)

(** Check [prop |- e1<e2], to be called from normalized atom *)
let check_lt_normalized tenv prop e1 e2 =
  (* L.d_str "check_lt_normalized "; Sil.d_exp e1; L.d_str " "; Sil.d_exp e2; L.d_ln (); *)
  let ineq = Inequalities.from_prop tenv prop in
  let upper_lower_check () =
    let upper1_opt = Inequalities.compute_upper_bound ineq e1 in
    let lower2_opt = Inequalities.compute_lower_bound ineq e2 in
    match upper1_opt, lower2_opt with
    | None, _ | _, None -> false
    | Some upper1, Some lower2 -> IntLit.leq upper1 lower2 in
  (upper_lower_check ()) || (Inequalities.check_lt ineq e1 e2)

(** Given an atom and a proposition returns a unique identifier.
    We use this to distinguish among different queries. *)
let get_smt_key a p =
  let tmp_filename = Filename.temp_file "smt_query" ".cns" in
  let outc_tmp = open_out tmp_filename in
  let fmt_tmp = F.formatter_of_out_channel outc_tmp in
  let () = F.fprintf fmt_tmp "%a%a" (Sil.pp_atom Pp.text) a (Prop.pp_prop Pp.text) p in
  Out_channel.close outc_tmp;
  Digest.to_hex (Digest.file tmp_filename)

(** Check whether [prop |- a]. False means dont know. *)
let check_atom tenv prop a0 =
  let a = Prop.atom_normalize_prop tenv prop a0 in
  let prop_no_fp = Prop.set prop ~pi_fp:[] ~sigma_fp:[] in
  if Config.smt_output then begin
    let key = get_smt_key a prop_no_fp in
    let key_filename =
      let source = (State.get_loc ()).file in
      DB.Results_dir.path_to_filename
        (DB.Results_dir.Abs_source_dir source)
        [(key ^ ".cns")] in
    let outc = open_out (DB.filename_to_string key_filename) in
    let fmt = F.formatter_of_out_channel outc in
    L.d_str ("ID: "^key); L.d_ln ();
    L.d_str "CHECK_ATOM_BOUND: "; Sil.d_atom a; L.d_ln ();
    L.d_str "WHERE:"; L.d_ln(); Prop.d_prop prop_no_fp; L.d_ln (); L.d_ln ();
    F.fprintf fmt "ID: %s @\nCHECK_ATOM_BOUND: %a@\nWHERE:@\n%a"
      key (Sil.pp_atom Pp.text) a (Prop.pp_prop Pp.text) prop_no_fp;
    Out_channel.close outc;
  end;
  match a with
  | Sil.Aeq (Exp.BinOp (Binop.Le, e1, e2), Exp.Const (Const.Cint i))
    when IntLit.isone i -> check_le_normalized tenv prop e1 e2
  | Sil.Aeq (Exp.BinOp (Binop.Lt, e1, e2), Exp.Const (Const.Cint i))
    when IntLit.isone i -> check_lt_normalized tenv prop e1 e2
  | Sil.Aeq (e1, e2) -> check_equal tenv prop e1 e2
  | Sil.Aneq (e1, e2) -> check_disequal tenv prop e1 e2
  | Sil.Apred _ | Anpred _ -> List.exists ~f:(Sil.equal_atom a) prop.Prop.pi

(** Check [prop |- e1<=e2]. Result [false] means "don't know". *)
let check_le tenv prop e1 e2 =
  let e1_le_e2 = Exp.BinOp (Binop.Le, e1, e2) in
  check_atom tenv prop (Prop.mk_inequality tenv e1_le_e2)

(** Check whether [prop |- allocated(e)]. *)
let check_allocatedness tenv prop e =
  let n_e = Prop.exp_normalize_prop tenv prop e in
  let spatial_part = prop.Prop.sigma in
  let f = function
    | Sil.Hpointsto (base, _, _) ->
        is_root tenv prop base n_e <> None
    | Sil.Hlseg (k, _, e1, e2, _) ->
        if Sil.equal_lseg_kind k Sil.Lseg_NE || check_disequal tenv prop e1 e2 then
          is_root tenv prop e1 n_e <> None
        else
          false
    | Sil.Hdllseg (k, _, iF, oB, oF, iB, _) ->
        if Sil.equal_lseg_kind k Sil.Lseg_NE ||
           check_disequal tenv prop iF oF ||
           check_disequal tenv prop iB oB
        then
          is_root tenv prop iF n_e <> None || is_root tenv prop iB n_e <> None
        else
          false
  in List.exists ~f spatial_part

(** Compute an upper bound of an expression *)
let compute_upper_bound_of_exp tenv p e =
  let ineq = Inequalities.from_prop tenv p in
  Inequalities.compute_upper_bound ineq e

(** Check if two hpreds have the same allocated lhs *)
let check_inconsistency_two_hpreds tenv prop =
  let sigma = prop.Prop.sigma in
  let rec f e sigma_seen = function
    | [] -> false
    | (Sil.Hpointsto (e1, _, _) as hpred) :: sigma_rest
    | (Sil.Hlseg (Sil.Lseg_NE, _, e1, _, _) as hpred) :: sigma_rest ->
        if Exp.equal e1 e then true
        else f e (hpred:: sigma_seen) sigma_rest
    | (Sil.Hdllseg (Sil.Lseg_NE, _, iF, _, _, iB, _) as hpred) :: sigma_rest ->
        if Exp.equal iF e || Exp.equal iB e then true
        else f e (hpred:: sigma_seen) sigma_rest
    | Sil.Hlseg (Sil.Lseg_PE, _, e1, Exp.Const (Const.Cint i), _) as hpred :: sigma_rest
      when IntLit.iszero i ->
        if Exp.equal e1 e then true
        else f e (hpred:: sigma_seen) sigma_rest
    | Sil.Hlseg (Sil.Lseg_PE, _, e1, e2, _) as hpred :: sigma_rest ->
        if Exp.equal e1 e
        then
          let prop' = Prop.normalize tenv (Prop.from_sigma (sigma_seen@sigma_rest)) in
          let prop_new = Prop.conjoin_eq tenv e1 e2 prop' in
          let sigma_new = prop_new.Prop.sigma in
          let e_new = Prop.exp_normalize_prop tenv prop_new e
          in f e_new [] sigma_new
        else f e (hpred:: sigma_seen) sigma_rest
    | Sil.Hdllseg (Sil.Lseg_PE, _, e1, _, Exp.Const (Const.Cint i), _, _) as hpred :: sigma_rest
      when IntLit.iszero i ->
        if Exp.equal e1 e then true
        else f e (hpred:: sigma_seen) sigma_rest
    | Sil.Hdllseg (Sil.Lseg_PE, _, e1, _, e3, _, _) as hpred :: sigma_rest ->
        if Exp.equal e1 e
        then
          let prop' = Prop.normalize tenv (Prop.from_sigma (sigma_seen@sigma_rest)) in
          let prop_new = Prop.conjoin_eq tenv e1 e3 prop' in
          let sigma_new = prop_new.Prop.sigma in
          let e_new = Prop.exp_normalize_prop tenv prop_new e
          in f e_new [] sigma_new
        else f e (hpred:: sigma_seen) sigma_rest in
  let rec check sigma_seen = function
    | [] -> false
    | (Sil.Hpointsto (e1, _, _) as hpred) :: sigma_rest
    | (Sil.Hlseg (Sil.Lseg_NE, _, e1, _, _) as hpred) :: sigma_rest ->
        if (f e1 [] (sigma_seen@sigma_rest)) then true
        else check (hpred:: sigma_seen) sigma_rest
    | Sil.Hdllseg (Sil.Lseg_NE, _, iF, _, _, iB, _) as hpred :: sigma_rest ->
        if f iF [] (sigma_seen@sigma_rest) || f iB [] (sigma_seen@sigma_rest) then true
        else check (hpred:: sigma_seen) sigma_rest
    | (Sil.Hlseg (Sil.Lseg_PE, _, _, _, _) as hpred) :: sigma_rest
    | (Sil.Hdllseg (Sil.Lseg_PE, _, _, _, _, _, _) as hpred) :: sigma_rest ->
        check (hpred:: sigma_seen) sigma_rest in
  check [] sigma

(** Inconsistency checking ignoring footprint. *)
let check_inconsistency_base tenv prop =
  let pi = prop.Prop.pi in
  let sigma = prop.Prop.sigma in
  let inconsistent_ptsto _ =
    check_allocatedness tenv prop Exp.zero in
  let inconsistent_this_self_var () =
    match State.get_prop_tenv_pdesc () with
    | None -> false
    | Some (_, _, pdesc) ->
        let procedure_attr =
          Procdesc.get_attributes pdesc in
        let is_java_this pvar =
          Config.equal_language procedure_attr.ProcAttributes.language Config.Java &&
          Pvar.is_this pvar in
        let is_objc_instance_self pvar =
          Config.equal_language procedure_attr.ProcAttributes.language Config.Clang &&
          Mangled.equal (Pvar.get_name pvar) (Mangled.from_string "self") &&
          procedure_attr.ProcAttributes.is_objc_instance_method in
        let is_cpp_this pvar =
          Config.equal_language procedure_attr.ProcAttributes.language Config.Clang &&
          Pvar.is_this pvar &&
          procedure_attr.ProcAttributes.is_cpp_instance_method in
        let do_hpred = function
          | Sil.Hpointsto (Exp.Lvar pv, Sil.Eexp (e, _), _) ->
              Exp.equal e Exp.zero &&
              Pvar.is_seed pv &&
              (is_java_this pv || is_cpp_this pv || is_objc_instance_self pv)
          | _ -> false in
        List.exists ~f:do_hpred sigma in
  let inconsistent_atom = function
    | Sil.Aeq (e1, e2) ->
        (match e1, e2 with
         | Exp.Const c1, Exp.Const c2 -> not (Const.equal c1 c2)
         | _ -> check_disequal tenv prop e1 e2)
    | Sil.Aneq (e1, e2) ->
        (match e1, e2 with
         | Exp.Const c1, Exp.Const c2 -> Const.equal c1 c2
         | _ -> Exp.equal e1 e2)
    | Sil.Apred _ | Anpred _ -> false in
  let inconsistent_inequalities () =
    let ineq = Inequalities.from_prop tenv prop in
    (*
    L.d_strln "Inequalities:";
    L.d_strln "Prop: "; Prop.d_prop prop; L.d_ln ();
    L.d_str "leqs: "; Inequalities.d_leqs ineq; L.d_ln ();
    L.d_str "lts: "; Inequalities.d_lts ineq; L.d_ln ();
    L.d_str "neqs: "; Inequalities.d_neqs ineq; L.d_ln ();
    *)
    Inequalities.inconsistent ineq in
  inconsistent_ptsto ()
  || check_inconsistency_two_hpreds tenv prop
  || List.exists ~f:inconsistent_atom pi
  || inconsistent_inequalities ()
  || inconsistent_this_self_var ()

(** Inconsistency checking. *)
let check_inconsistency tenv prop =
  (check_inconsistency_base tenv prop)
  ||
  (check_inconsistency_base tenv (Prop.normalize tenv (Prop.extract_footprint prop)))

(** Inconsistency checking for the pi part ignoring footprint. *)
let check_inconsistency_pi tenv pi =
  check_inconsistency_base tenv (Prop.normalize tenv (Prop.from_pi pi))

(** {2 Abduction prover} *)

type subst2 = Sil.subst * Sil.subst

type exc_body =
  | EXC_FALSE
  | EXC_FALSE_HPRED of Sil.hpred
  | EXC_FALSE_EXPS of Exp.t * Exp.t
  | EXC_FALSE_SEXPS of Sil.strexp * Sil.strexp
  | EXC_FALSE_ATOM of Sil.atom
  | EXC_FALSE_SIGMA of Sil.hpred list

exception IMPL_EXC of string * subst2 * exc_body

exception MISSING_EXC of string

type check =
  | Bounds_check
  | Class_cast_check of Exp.t * Exp.t * Exp.t

let d_typings typings =
  let d_elem (exp, texp) =
    Sil.d_exp exp; L.d_str ": "; Sil.d_texp_full texp; L.d_str " " in
  List.iter ~f:d_elem typings

(** Module to encapsulate operations on the internal state of the prover *)
module ProverState : sig
  val reset : Prop.normal Prop.t -> Prop.exposed Prop.t -> unit
  val checks : check list ref

  (** type for array bounds checks *)
  type bounds_check =
    | BClen_imply of Exp.t * Exp.t * Exp.t list (** coming from array_len_imply *)
    | BCfrom_pre of Sil.atom (** coming implicitly from preconditions *)

  val add_bounds_check : bounds_check -> unit
  val add_frame_fld : Sil.hpred -> unit
  val add_frame_typ : Exp.t * Exp.t -> unit
  val add_missing_fld : Sil.hpred -> unit
  val add_missing_pi : Sil.atom -> unit
  val add_missing_sigma : Sil.hpred list -> unit
  val add_missing_typ : Exp.t * Exp.t -> unit

  val atom_is_array_bounds_check : Sil.atom -> bool (** check if atom in pre is a bounds check *)

  val get_bounds_checks : unit -> bounds_check list
  val get_frame_fld : unit -> Sil.hpred list
  val get_frame_typ : unit -> (Exp.t * Exp.t) list
  val get_missing_fld : unit -> Sil.hpred list
  val get_missing_pi : unit -> Sil.atom list
  val get_missing_sigma : unit -> Sil.hpred list
  val get_missing_typ : unit -> (Exp.t * Exp.t) list

  val d_implication : Sil.subst * Sil.subst -> 'a Prop.t * 'b Prop.t -> unit
  val d_implication_error : string * (Sil.subst * Sil.subst) * exc_body -> unit
end = struct
  type bounds_check =
    | BClen_imply of Exp.t * Exp.t * Exp.t list
    | BCfrom_pre of Sil.atom

  let implication_lhs = ref Prop.prop_emp
  let implication_rhs = ref (Prop.expose Prop.prop_emp)
  let fav_in_array_len = ref (Sil.fav_new ()) (* free variables in array len position *)
  let bounds_checks = ref [] (* delayed bounds check for arrays *)
  let frame_fld = ref []
  let missing_fld = ref []
  let missing_pi = ref []
  let missing_sigma = ref []
  let frame_typ = ref []
  let missing_typ = ref []
  let checks = ref []

  (** free vars in array len position in current strexp part of prop *)
  let prop_fav_len prop =
    let fav = Sil.fav_new () in
    let do_hpred = function
      | Sil.Hpointsto (_, Sil.Earray (Exp.Var _ as len, _, _), _) ->
          Sil.exp_fav_add fav len
      | _ -> () in
    List.iter ~f:do_hpred prop.Prop.sigma;
    fav

  let reset lhs rhs =
    checks := [];
    implication_lhs := lhs;
    implication_rhs := rhs;
    fav_in_array_len := prop_fav_len rhs;
    bounds_checks := [];
    frame_fld := [];
    frame_typ := [];
    missing_fld := [];
    missing_pi := [];
    missing_sigma := [];
    missing_typ := []

  let add_bounds_check bounds_check =
    bounds_checks := bounds_check :: !bounds_checks

  let add_frame_fld hpred =
    frame_fld := hpred :: !frame_fld

  let add_missing_fld hpred =
    missing_fld := hpred :: !missing_fld

  let add_frame_typ typing =
    frame_typ := typing :: !frame_typ

  let add_missing_typ typing =
    missing_typ := typing :: !missing_typ

  let add_missing_pi a =
    missing_pi := a :: !missing_pi

  let add_missing_sigma sigma =
    missing_sigma := sigma @ !missing_sigma

  (** atom considered array bounds check if it contains vars present in array length position in the
      pre *)
  let atom_is_array_bounds_check atom =
    let fav_a = Sil.atom_fav atom in
    Prop.atom_is_inequality atom &&
    Sil.fav_exists fav_a (fun a -> Sil.fav_mem !fav_in_array_len a)

  let get_bounds_checks () = !bounds_checks
  let get_frame_fld () = !frame_fld
  let get_frame_typ () = !frame_typ
  let get_missing_fld () = !missing_fld
  let get_missing_pi () = !missing_pi
  let get_missing_sigma () = !missing_sigma
  let get_missing_typ () = !missing_typ

  let _d_missing sub =
    L.d_strln "SUB: ";
    L.d_increase_indent 1; Prop.d_sub sub; L.d_decrease_indent 1;
    if !missing_pi <> [] && !missing_sigma <> []
    then (L.d_ln (); Prop.d_pi !missing_pi; L.d_str "*"; L.d_ln (); Prop.d_sigma !missing_sigma)
    else if !missing_pi <> []
    then (L.d_ln (); Prop.d_pi !missing_pi)
    else if !missing_sigma <> []
    then (L.d_ln (); Prop.d_sigma !missing_sigma);
    if !missing_fld <> [] then
      begin
        L.d_ln ();
        L.d_strln "MISSING FLD: "; L.d_increase_indent 1; Prop.d_sigma !missing_fld; L.d_decrease_indent 1
      end;
    if !missing_typ <> [] then
      begin
        L.d_ln ();
        L.d_strln "MISSING TYPING: "; L.d_increase_indent 1; d_typings !missing_typ; L.d_decrease_indent 1
      end

  let d_missing sub = (* optional print of missing: if print something, prepend with newline *)
    if !missing_pi <> [] || !missing_sigma <> [] || !missing_fld <> [] || !missing_typ <> [] || Sil.sub_to_list sub <> [] then
      begin
        L.d_ln ();
        L.d_str "[";
        _d_missing sub;
        L.d_str "]"
      end

  let d_frame_fld () = (* optional print of frame fld: if print something, prepend with newline *)
    if !frame_fld <> [] then
      begin
        L.d_ln ();
        L.d_strln "[FRAME FLD:";
        L.d_increase_indent 1; Prop.d_sigma !frame_fld; L.d_str "]"; L.d_decrease_indent 1
      end

  let d_frame_typ () = (* optional print of frame typ: if print something, prepend with newline *)
    if !frame_typ <> [] then
      begin
        L.d_ln ();
        L.d_strln "[FRAME TYPING:";
        L.d_increase_indent 1; d_typings !frame_typ; L.d_str "]"; L.d_decrease_indent 1
      end

  (** Dump an implication *)
  let d_implication (sub1, sub2) (p1, p2) =
    let p1, p2 = Prop.prop_sub sub1 p1, Prop.prop_sub sub2 p2 in
    L.d_strln "SUB:";
    L.d_increase_indent 1; Prop.d_sub sub1; L.d_decrease_indent 1; L.d_ln ();
    Prop.d_prop p1;
    d_missing sub2; L.d_ln ();
    L.d_strln "|-";
    Prop.d_prop p2;
    d_frame_fld ();
    d_frame_typ ()

  let d_implication_error (s, subs, body) =
    let p1, p2 = !implication_lhs,!implication_rhs in
    let d_inner () = match body with
      | EXC_FALSE ->
          ()
      | EXC_FALSE_HPRED hpred ->
          L.d_str " on ";
          Sil.d_hpred hpred;
      | EXC_FALSE_EXPS (e1, e2) ->
          L.d_str " on ";
          Sil.d_exp e1; L.d_str ","; Sil.d_exp e2;
      | EXC_FALSE_SEXPS (se1, se2) ->
          L.d_str " on ";
          Sil.d_sexp se1; L.d_str ","; Sil.d_sexp se2;
      | EXC_FALSE_ATOM a ->
          L.d_str " on ";
          Sil.d_atom a;
      | EXC_FALSE_SIGMA sigma ->
          L.d_str " on ";
          Prop.d_sigma sigma in
    L.d_ln ();
    L.d_strln "$$$$$$$ Implication";
    d_implication subs (p1, p2); L.d_ln ();
    L.d_str ("$$$$$$ error: " ^ s); d_inner ();
    L.d_strln " returning FALSE";
    L.d_ln ()
end

let d_impl = ProverState.d_implication
let d_impl_err = ProverState.d_implication_error

(** extend a substitution *)
let extend_sub sub v e =
  let new_sub = Sil.sub_of_list [v, e] in
  Sil.sub_join new_sub (Sil.sub_range_map (Sil.exp_sub new_sub) sub)

(** Extend [sub1] and [sub2] to witnesses that each instance of
    [e1[sub1]] is an instance of [e2[sub2]]. Raise IMPL_FALSE if not
    possible. *)
let exp_imply tenv calc_missing subs e1_in e2_in : subst2 =
  let e1 = Prop.exp_normalize_noabs tenv (fst subs) e1_in in
  let e2 = Prop.exp_normalize_noabs tenv (snd subs) e2_in in
  let var_imply subs v1 v2 : subst2 =
    match Ident.is_primed v1, Ident.is_primed v2 with
    | false, false ->
        if Ident.equal v1 v2 then subs
        else if calc_missing && Ident.is_footprint v1 && Ident.is_footprint v2
        then
          let () = ProverState.add_missing_pi (Sil.Aeq (e1_in, e2_in)) in
          subs
        else raise (IMPL_EXC ("exps", subs, (EXC_FALSE_EXPS (e1, e2))))
    | true, false -> raise (IMPL_EXC ("exps", subs, (EXC_FALSE_EXPS (e1, e2))))
    | false, true ->
        let sub2' = extend_sub (snd subs) v2 (Sil.exp_sub (fst subs) (Exp.Var v1)) in
        (fst subs, sub2')
    | true, true ->
        let v1' = Ident.create_fresh Ident.knormal in
        let sub1' = extend_sub (fst subs) v1 (Exp.Var v1') in
        let sub2' = extend_sub (snd subs) v2 (Exp.Var v1') in
        (sub1', sub2') in
  let rec do_imply subs e1 e2 : subst2 =
    L.d_str "do_imply "; Sil.d_exp e1; L.d_str " "; Sil.d_exp e2; L.d_ln ();
    match e1, e2 with
    | Exp.Var v1, Exp.Var v2 ->
        var_imply subs v1 v2
    | e1, Exp.Var v2 ->
        let occurs_check v e = (* check whether [v] occurs in normalized [e] *)
          if Sil.fav_mem (Sil.exp_fav e) v
          && Sil.fav_mem (Sil.exp_fav (Prop.exp_normalize_prop tenv Prop.prop_emp e)) v
          then raise (IMPL_EXC ("occurs check", subs, (EXC_FALSE_EXPS (e1, e2)))) in
        if Ident.is_primed v2 then
          let () = occurs_check v2 e1 in
          let sub2' = extend_sub (snd subs) v2 e1 in
          (fst subs, sub2')
        else
          raise (IMPL_EXC ("expressions not equal", subs, (EXC_FALSE_EXPS (e1, e2))))
    | e1, Exp.BinOp (Binop.PlusA, Exp.Var v2, e2)
    | e1, Exp.BinOp (Binop.PlusA, e2, Exp.Var v2)
      when Ident.is_primed v2 || Ident.is_footprint v2 ->
        let e' = Exp.BinOp (Binop.MinusA, e1, e2) in
        do_imply subs (Prop.exp_normalize_noabs tenv Sil.sub_empty e') (Exp.Var v2)
    | Exp.Var _, e2 ->
        if calc_missing then
          let () = ProverState.add_missing_pi (Sil.Aeq (e1_in, e2_in)) in
          subs
        else raise (IMPL_EXC ("expressions not equal", subs, (EXC_FALSE_EXPS (e1, e2))))
    | Exp.Lvar pv1, Exp.Const _ when Pvar.is_global pv1 ->
        if calc_missing then
          let () = ProverState.add_missing_pi (Sil.Aeq (e1_in, e2_in)) in
          subs
        else raise (IMPL_EXC ("expressions not equal", subs, (EXC_FALSE_EXPS (e1, e2))))
    | Exp.Lvar v1, Exp.Lvar v2 ->
        if Pvar.equal v1 v2 then subs
        else raise (IMPL_EXC ("expressions not equal", subs, (EXC_FALSE_EXPS (e1, e2))))
    | Exp.Const c1, Exp.Const c2 ->
        if (Const.equal c1 c2) then subs
        else raise (IMPL_EXC ("constants not equal", subs, (EXC_FALSE_EXPS (e1, e2))))
    | Exp.Const (Const.Cint _), Exp.BinOp (Binop.PlusPI, _, _) ->
        raise (IMPL_EXC ("pointer+index cannot evaluate to a constant", subs, (EXC_FALSE_EXPS (e1, e2))))
    | Exp.Const (Const.Cint n1), Exp.BinOp (Binop.PlusA, f1, Exp.Const (Const.Cint n2)) ->
        do_imply subs (Exp.int (n1 -- n2)) f1
    | Exp.BinOp(op1, e1, f1), Exp.BinOp(op2, e2, f2) when Binop.equal op1 op2 ->
        do_imply (do_imply subs e1 e2) f1 f2
    | Exp.BinOp (Binop.PlusA, Exp.Var v1, e1), e2 ->
        do_imply subs (Exp.Var v1) (Exp.BinOp (Binop.MinusA, e2, e1))
    | Exp.BinOp (Binop.PlusPI, Exp.Lvar pv1, e1), e2 ->
        do_imply subs (Exp.Lvar pv1) (Exp.BinOp (Binop.MinusA, e2, e1))
    | Exp.Sizeof (t1, None, st1), Exp.Sizeof (t2, None, st2)
      when Typ.equal t1 t2 && Subtype.equal_modulo_flag st1 st2 -> subs
    | Exp.Sizeof (t1, Some d1, st1), Exp.Sizeof (t2, Some d2, st2)
      when Typ.equal t1 t2 && Exp.equal d1 d2 && Subtype.equal_modulo_flag st1 st2 -> subs
    | e', Exp.Const (Const.Cint n)
    | Exp.Const (Const.Cint n), e'
      when IntLit.iszero n && check_disequal tenv Prop.prop_emp e' Exp.zero ->
        raise (IMPL_EXC ("expressions not equal", subs, (EXC_FALSE_EXPS (e1, e2))))
    | e1, Exp.Const _ ->
        raise (IMPL_EXC ("lhs not constant", subs, (EXC_FALSE_EXPS (e1, e2))))
    | Exp.Lfield(e1, fd1, _), Exp.Lfield(e2, fd2, _) when Ident.equal_fieldname fd1 fd2 ->
        do_imply subs e1 e2
    | Exp.Lindex(e1, f1), Exp.Lindex(e2, f2) ->
        do_imply (do_imply subs e1 e2) f1 f2
    | _ ->
        d_impl_err ("exp_imply not implemented", subs, (EXC_FALSE_EXPS (e1, e2)));
        raise (Exceptions.Abduction_case_not_implemented __POS__) in
  do_imply subs e1 e2

(** Convert a path (from lhs of a |-> to a field name present only in
    the rhs) into an id. If the lhs was a footprint var, the id is a
    new footprint var. Othewise it is a var with the path in the name
    and stamp - 1 *)
let path_to_id path =
  let rec f = function
    | Exp.Var id ->
        if Ident.is_footprint id then None
        else Some (Ident.name_to_string (Ident.get_name id) ^ (string_of_int (Ident.get_stamp id)))
    | Exp.Lfield (e, fld, _) ->
        (match f e with
         | None -> None
         | Some s -> Some (s ^ "_" ^ (Ident.fieldname_to_string fld)))
    | Exp.Lindex (e, ind) ->
        (match f e with
         | None -> None
         | Some s -> Some (s ^ "_" ^ (Exp.to_string ind)))
    | Exp.Lvar _ ->
        Some (Exp.to_string path)
    | Exp.Const (Const.Cstr s) ->
        Some ("_const_str_" ^ s)
    | Exp.Const (Const.Cclass c) ->
        Some ("_const_class_" ^ Ident.name_to_string c)
    | Exp.Const _ -> None
    | _ ->
        L.d_str "path_to_id undefined on "; Sil.d_exp path; L.d_ln ();
        assert false (* None *) in
  if !Config.footprint then Ident.create_fresh Ident.kfootprint
  else match f path with
    | None -> Ident.create_fresh Ident.kfootprint
    | Some s -> Ident.create_path s

(** Implication for the length of arrays *)
let array_len_imply tenv calc_missing subs len1 len2 indices2 =
  match len1, len2 with
  | _, Exp.Var _
  | _, Exp.BinOp (Binop.PlusA, Exp.Var _, _)
  | _, Exp.BinOp (Binop.PlusA, _, Exp.Var _)
  | Exp.BinOp (Binop.Mult, _, _), _ ->
      (try exp_imply tenv calc_missing subs len1 len2 with
       | IMPL_EXC (s, subs', x) ->
           raise (IMPL_EXC ("array len:" ^ s, subs', x)))
  | _ ->
      ProverState.add_bounds_check (ProverState.BClen_imply (len1, len2, indices2));
      subs

(** Extend [sub1] and [sub2] to witnesses that each instance of
    [se1[sub1]] is an instance of [se2[sub2]]. Raise IMPL_FALSE if not
    possible. *)
let rec sexp_imply tenv source calc_index_frame calc_missing subs se1 se2 typ2 : subst2 * (Sil.strexp option) * (Sil.strexp option) =
  (* L.d_str "sexp_imply "; Sil.d_sexp se1; L.d_str " "; Sil.d_sexp se2;
     L.d_str " : "; Typ.d_full typ2; L.d_ln(); *)
  match se1, se2 with
  | Sil.Eexp (e1, _), Sil.Eexp (e2, _) ->
      (exp_imply tenv calc_missing subs e1 e2, None, None)
  | Sil.Estruct (fsel1, inst1), Sil.Estruct (fsel2, _) ->
      let subs', fld_frame, fld_missing = struct_imply tenv source calc_missing subs fsel1 fsel2 typ2 in
      let fld_frame_opt = if fld_frame <> [] then Some (Sil.Estruct (fld_frame, inst1)) else None in
      let fld_missing_opt = if fld_missing <> [] then Some (Sil.Estruct (fld_missing, inst1)) else None in
      subs', fld_frame_opt, fld_missing_opt
  | Sil.Estruct _, Sil.Eexp (e2, _) ->
      begin
        let e2' = Sil.exp_sub (snd subs) e2 in
        match e2' with
        | Exp.Var id2 when Ident.is_primed id2 ->
            let id2' = Ident.create_fresh Ident.knormal in
            let sub2' = extend_sub (snd subs) id2 (Exp.Var id2') in
            (fst subs, sub2'), None, None
        | _ ->
            d_impl_err ("sexp_imply not implemented", subs, (EXC_FALSE_SEXPS (se1, se2)));
            raise (Exceptions.Abduction_case_not_implemented __POS__)
      end
  | Sil.Earray (len1, esel1, inst1), Sil.Earray (len2, esel2, _) ->
      let indices2 = List.map ~f:fst esel2 in
      let subs' = array_len_imply tenv calc_missing subs len1 len2 indices2 in
      let subs'', index_frame, index_missing =
        array_imply tenv source calc_index_frame calc_missing subs' esel1 esel2 typ2 in
      let index_frame_opt = if index_frame <> []
        then Some (Sil.Earray (len1, index_frame, inst1))
        else None in
      let index_missing_opt =
        if index_missing <> [] &&
           (Config.allow_missing_index_in_proc_call || !Config.footprint)
        then Some (Sil.Earray (len1, index_missing, inst1))
        else None in
      subs'', index_frame_opt, index_missing_opt
  | Sil.Eexp (_, inst), Sil.Estruct (fsel, inst') ->
      d_impl_err ("WARNING: function call with parameters of struct type, treating as unknown", subs, (EXC_FALSE_SEXPS (se1, se2)));
      let fsel' =
        let g (f, _) = (f, Sil.Eexp (Exp.Var (Ident.create_fresh Ident.knormal), inst)) in
        List.map ~f:g fsel in
      sexp_imply tenv source calc_index_frame calc_missing subs (Sil.Estruct (fsel', inst')) se2 typ2
  | Sil.Eexp _, Sil.Earray (len, _, inst)
  | Sil.Estruct _, Sil.Earray (len, _, inst) ->
      let se1' = Sil.Earray (len, [(Exp.zero, se1)], inst) in
      sexp_imply tenv source calc_index_frame calc_missing subs se1' se2 typ2
  | Sil.Earray (len, _, _), Sil.Eexp (_, inst) ->
      let se2' = Sil.Earray (len, [(Exp.zero, se2)], inst) in
      let typ2' = Typ.Tarray (typ2, None) in
      (* In the sexp_imply, struct_imply, array_imply, and sexp_imply_nolhs functions, the typ2
         argument is only used by eventually passing its value to Typ.Struct.fld, Exp.Lfield,
         Typ.Struct.fld, or Typ.array_elem.  None of these are sensitive to the length field
         of Tarray, so forgetting the length of typ2' here is not a problem. *)
      sexp_imply tenv source true calc_missing subs se1 se2' typ2' (* calculate index_frame because the rhs is a singleton array *)
  | _ ->
      d_impl_err ("sexp_imply not implemented", subs, (EXC_FALSE_SEXPS (se1, se2)));
      raise (Exceptions.Abduction_case_not_implemented __POS__)

and struct_imply tenv source calc_missing subs fsel1 fsel2 typ2 : subst2 * ((Ident.fieldname * Sil.strexp) list) * ((Ident.fieldname * Sil.strexp) list) =
  let lookup = Tenv.lookup tenv in
  match fsel1, fsel2 with
  | _, [] -> subs, fsel1, []
  | (f1, se1) :: fsel1', (f2, se2) :: fsel2' ->
      begin
        match Ident.compare_fieldname f1 f2 with
        | 0 ->
            let typ' = Typ.Struct.fld_typ ~lookup ~default:Typ.Tvoid f2 typ2 in
            let subs', se_frame, se_missing =
              sexp_imply tenv (Exp.Lfield (source, f2, typ2)) false calc_missing subs se1 se2 typ' in
            let subs'', fld_frame, fld_missing = struct_imply tenv source calc_missing subs' fsel1' fsel2' typ2 in
            let fld_frame' = match se_frame with
              | None -> fld_frame
              | Some se -> (f1, se):: fld_frame in
            let fld_missing' = match se_missing with
              | None -> fld_missing
              | Some se -> (f1, se):: fld_missing in
            subs'', fld_frame', fld_missing'
        | n when n < 0 ->
            let subs', fld_frame, fld_missing = struct_imply tenv source calc_missing subs fsel1' fsel2 typ2 in
            subs', ((f1, se1) :: fld_frame), fld_missing
        | _ ->
            let typ' = Typ.Struct.fld_typ ~lookup ~default:Typ.Tvoid f2 typ2 in
            let subs' =
              sexp_imply_nolhs tenv (Exp.Lfield (source, f2, typ2)) calc_missing subs se2 typ' in
            let subs', fld_frame, fld_missing = struct_imply tenv source calc_missing subs' fsel1 fsel2' typ2 in
            let fld_missing' = (f2, se2) :: fld_missing in
            subs', fld_frame, fld_missing'
      end
  | [], (f2, se2) :: fsel2' ->
      let typ' = Typ.Struct.fld_typ ~lookup ~default:Typ.Tvoid f2 typ2 in
      let subs' = sexp_imply_nolhs tenv (Exp.Lfield (source, f2, typ2)) calc_missing subs se2 typ' in
      let subs'', fld_frame, fld_missing = struct_imply tenv source calc_missing subs' [] fsel2' typ2 in
      subs'', fld_frame, (f2, se2):: fld_missing

and array_imply tenv source calc_index_frame calc_missing subs esel1 esel2 typ2
  : subst2 * ((Exp.t * Sil.strexp) list) * ((Exp.t * Sil.strexp) list)
  =
  let typ_elem = Typ.array_elem (Some Typ.Tvoid) typ2 in
  match esel1, esel2 with
  | _,[] -> subs, esel1, []
  | (e1, se1) :: esel1', (e2, se2) :: esel2' ->
      let e1n = Prop.exp_normalize_noabs tenv (fst subs) e1 in
      let e2n = Prop.exp_normalize_noabs tenv (snd subs) e2 in
      let n = Exp.compare e1n e2n in
      if n < 0 then array_imply tenv source calc_index_frame calc_missing subs esel1' esel2 typ2
      else if n > 0 then array_imply tenv source calc_index_frame calc_missing subs esel1 esel2' typ2
      else (* n=0 *)
        let subs', _, _ =
          sexp_imply tenv (Exp.Lindex (source, e1)) false calc_missing subs se1 se2 typ_elem in
        array_imply tenv source calc_index_frame calc_missing subs' esel1' esel2' typ2
  | [], (e2, se2) :: esel2' ->
      let subs' = sexp_imply_nolhs tenv (Exp.Lindex (source, e2)) calc_missing subs se2 typ_elem in
      let subs'', index_frame, index_missing = array_imply tenv source calc_index_frame calc_missing subs' [] esel2' typ2 in
      let index_missing' = (e2, se2) :: index_missing in
      subs'', index_frame, index_missing'

and sexp_imply_nolhs tenv source calc_missing subs se2 typ2 =
  match se2 with
  | Sil.Eexp (_e2, _) ->
      let e2 = Sil.exp_sub (snd subs) _e2 in
      begin
        match e2 with
        | Exp.Var v2 when Ident.is_primed v2 ->
            let v2' = path_to_id source in
            (* L.d_str "called path_to_id on "; Sil.d_exp e2; *)
            (* L.d_str " returns "; Sil.d_exp (Exp.Var v2'); L.d_ln (); *)
            let sub2' = extend_sub (snd subs) v2 (Exp.Var v2') in
            (fst subs, sub2')
        | Exp.Var _ ->
            if calc_missing then subs
            else raise (IMPL_EXC ("exp only in rhs is not a primed var", subs, EXC_FALSE))
        | Exp.Const _ when calc_missing ->
            let id = path_to_id source in
            ProverState.add_missing_pi (Sil.Aeq (Exp.Var id, _e2));
            subs
        | _ ->
            raise (IMPL_EXC ("exp only in rhs is not a primed var", subs, EXC_FALSE))
      end
  | Sil.Estruct (fsel2, _) ->
      (fun (x, _, _) -> x) (struct_imply tenv source calc_missing subs [] fsel2 typ2)
  | Sil.Earray (_, esel2, _) ->
      (fun (x, _, _) -> x) (array_imply tenv source false calc_missing subs [] esel2 typ2)

let rec exp_list_imply tenv calc_missing subs l1 l2 = match l1, l2 with
  | [],[] -> subs
  | e1:: l1, e2:: l2 ->
      exp_list_imply tenv calc_missing (exp_imply tenv calc_missing subs e1 e2) l1 l2
  | _ -> assert false

let filter_ne_lhs sub e0 = function
  | Sil.Hpointsto (e, _, _) -> if Exp.equal e0 (Sil.exp_sub sub e) then Some () else None
  | Sil.Hlseg (Sil.Lseg_NE, _, e, _, _) ->
      if Exp.equal e0 (Sil.exp_sub sub e) then Some () else None
  | Sil.Hdllseg (Sil.Lseg_NE, _, e, _, _, e', _) ->
      if Exp.equal e0 (Sil.exp_sub sub e) || Exp.equal e0 (Sil.exp_sub sub e')
      then Some ()
      else None
  | _ -> None

let filter_hpred sub hpred2 hpred1 = match (Sil.hpred_sub sub hpred1), hpred2 with
  | Sil.Hlseg(Sil.Lseg_NE, hpara1, e1, f1, el1), Sil.Hlseg(Sil.Lseg_PE, _, _, _, _) ->
      if Sil.equal_hpred (Sil.Hlseg(Sil.Lseg_PE, hpara1, e1, f1, el1)) hpred2 then Some false else None
  | Sil.Hlseg(Sil.Lseg_PE, hpara1, e1, f1, el1), Sil.Hlseg(Sil.Lseg_NE, _, _, _, _) ->
      if Sil.equal_hpred (Sil.Hlseg(Sil.Lseg_NE, hpara1, e1, f1, el1)) hpred2 then Some true else None (* return missing disequality *)
  | Sil.Hpointsto(e1, _, _), Sil.Hlseg(_, _, e2, _, _) ->
      if Exp.equal e1 e2 then Some false else None
  | hpred1, hpred2 -> if Sil.equal_hpred hpred1 hpred2 then Some false else None

let hpred_has_primed_lhs sub hpred =
  let rec find_primed e = match e with
    | Exp.Lfield (e, _, _) ->
        find_primed e
    | Exp.Lindex (e, _) ->
        find_primed e
    | Exp.BinOp (Binop.PlusPI, e1, _) ->
        find_primed e1
    | _ ->
        Sil.fav_exists (Sil.exp_fav e) Ident.is_primed in
  let exp_has_primed e = find_primed (Sil.exp_sub sub e) in
  match hpred with
  | Sil.Hpointsto (e, _, _) ->
      exp_has_primed e
  | Sil.Hlseg (_, _, e, _, _) ->
      exp_has_primed e
  | Sil.Hdllseg (_, _, iF, _, _, iB, _) ->
      exp_has_primed iF && exp_has_primed iB

let move_primed_lhs_from_front subs sigma = match sigma with
  | [] -> sigma
  | hpred:: _ ->
      if hpred_has_primed_lhs (snd subs) hpred then
        let (sigma_primed, sigma_unprimed) =
          List.partition_tf ~f:(hpred_has_primed_lhs (snd subs)) sigma
        in match sigma_unprimed with
        | [] -> raise (IMPL_EXC ("every hpred has primed lhs, cannot proceed", subs, (EXC_FALSE_SIGMA sigma)))
        | _:: _ -> sigma_unprimed @ sigma_primed
      else sigma

(** [expand_hpred_pointer calc_index_frame hpred] expands [hpred] if it is a |-> whose lhs is a Lfield or Lindex or ptr+off.
    Return [(changed, calc_index_frame', hpred')] where [changed] indicates whether the predicate has changed. *)
let expand_hpred_pointer =
  let count = ref 0 in
  fun tenv calc_index_frame hpred ->
    let rec expand changed calc_index_frame hpred = match hpred with
      | Sil.Hpointsto (Lfield (adr_base, fld, adr_typ), cnt, cnt_texp) ->
          let cnt_texp' =
            match
              match adr_typ with
              | Tstruct name -> (
                  match Tenv.lookup tenv name with
                  | Some _ ->
                      (* type of struct at adr_base is known *)
                      Some (Exp.Sizeof (adr_typ, None, Subtype.exact))
                  | None -> None
                )
              | _ -> None
            with
            | Some se -> se
            | None ->
                match cnt_texp with
                | Sizeof (cnt_typ, len, st) ->
                    (* type of struct at adr_base is unknown (typically Tvoid), but
                       type of contents is known, so construct struct type for single fld:cnt_typ *)
                    let name = Typename.C.from_string ("counterfeit" ^ string_of_int !count) in
                    incr count ;
                    let fields = [(fld, cnt_typ, Annot.Item.empty)] in
                    ignore (Tenv.mk_struct tenv ~fields name) ;
                    Exp.Sizeof (Tstruct name, len, st)
                | _ ->
                    (* type of struct at adr_base and of contents are both unknown: give up *)
                    raise (Failure "expand_hpred_pointer: Unexpected non-sizeof type in Lfield") in
          let hpred' = Sil.Hpointsto (adr_base, Estruct ([(fld, cnt)], Sil.inst_none), cnt_texp') in
          expand true true hpred'
      | Sil.Hpointsto (Exp.Lindex (e, ind), se, t) ->
          let t' = match t with
            | Exp.Sizeof (t_, len, st) -> Exp.Sizeof (Typ.Tarray (t_, None), len, st)
            | _ -> raise (Failure "expand_hpred_pointer: Unexpected non-sizeof type in Lindex") in
          let len = match t' with
            | Exp.Sizeof (_, Some len, _) -> len
            | _ -> Exp.get_undefined false in
          let hpred' = Sil.Hpointsto (e, Sil.Earray (len, [(ind, se)], Sil.inst_none), t') in
          expand true true hpred'
      | Sil.Hpointsto (Exp.BinOp (Binop.PlusPI, e1, e2), Sil.Earray (len, esel, inst), t) ->
          let shift_exp e = Exp.BinOp (Binop.PlusA, e, e2) in
          let len' = shift_exp len in
          let esel' = List.map ~f:(fun (e, se) -> (shift_exp e, se)) esel in
          let hpred' = Sil.Hpointsto (e1, Sil.Earray (len', esel', inst), t) in
          expand true calc_index_frame hpred'
      | _ -> changed, calc_index_frame, hpred in
    expand false calc_index_frame hpred

module Subtyping_check =
struct

  (** check that t1 and t2 are the same primitive type *)
  let check_subtype_basic_type t1 t2 =
    match t2 with
    | Typ.Tint Typ.IInt | Typ.Tint Typ.IBool
    | Typ.Tint Typ.IChar | Typ.Tfloat Typ.FDouble
    | Typ.Tfloat Typ.FFloat | Typ.Tint Typ.ILong
    | Typ.Tint Typ.IShort -> Typ.equal t1 t2
    | _ -> false

  (** check if t1 is a subtype of t2, in Java *)
  let rec check_subtype_java tenv (t1: Typ.t) (t2: Typ.t) =
    match t1, t2 with
    | Tstruct (TN_csu (Class Java, _) as cn1), Tstruct (TN_csu (Class Java, _) as cn2) ->
        Subtype.is_known_subtype tenv cn1 cn2
    | Tarray (dom_type1, _), Tarray (dom_type2, _) ->
        check_subtype_java tenv dom_type1 dom_type2
    | Tptr (dom_type1, _), Tptr (dom_type2, _) ->
        check_subtype_java tenv dom_type1 dom_type2
    | Tarray _, Tstruct (TN_csu (Class Java, _) as cn2) ->
        Typename.equal cn2 Typename.Java.java_io_serializable
        || Typename.equal cn2 Typename.Java.java_lang_cloneable
        || Typename.equal cn2 Typename.Java.java_lang_object
    | _ -> check_subtype_basic_type t1 t2

  (** check if t1 is a subtype of t2 *)
  let check_subtype tenv t1 t2 =
    if is_java_class tenv t1
    then
      check_subtype_java tenv t1 t2
    else
      match Typ.name t1, Typ.name t2 with
      | Some cn1, Some cn2 -> Subtype.is_known_subtype tenv cn1 cn2
      | _ -> false

  let rec case_analysis_type tenv ((t1: Typ.t), st1) ((t2: Typ.t), st2) =
    match t1, t2 with
    | Tstruct (TN_csu (Class Java, _) as cn1), Tstruct (TN_csu (Class Java, _) as cn2) ->
        Subtype.case_analysis tenv (cn1, st1) (cn2, st2)
    | Tstruct (TN_csu (Class Java, _) as cn1), Tarray _
      when (Typename.equal cn1 Typename.Java.java_io_serializable
            || Typename.equal cn1 Typename.Java.java_lang_cloneable
            || Typename.equal cn1 Typename.Java.java_lang_object) &&
           st1 <> Subtype.exact ->
        Some st1, None
    | Tstruct cn1, Tstruct cn2
      (* cn1 <: cn2 or cn2 <: cn1 is implied in Java when we get two types compared *)
      (* that get through the type system, but not in C++ because of multiple inheritance, *)
      (* and not in ObjC because of being weakly typed, *)
      (* and the algorithm will only work correctly if this is the case *)
      when Subtype.is_known_subtype tenv cn1 cn2 || Subtype.is_known_subtype tenv cn2 cn1 ->
        Subtype.case_analysis tenv (cn1, st1) (cn2, st2)
    | Tarray (dom_type1, _), Tarray (dom_type2, _) ->
        case_analysis_type tenv (dom_type1, st1) (dom_type2, st2)
    | Tptr (dom_type1, _), Tptr (dom_type2, _) ->
        case_analysis_type tenv (dom_type1, st1) (dom_type2, st2)
    | _ when check_subtype_basic_type t1 t2 ->
        Some st1, None
    | _ ->
        (* The case analysis did not succeed *)
        None, Some st1

  (** perform case analysis on [texp1 <: texp2], and return the updated types in the true and false
      case, if they are possible *)
  let subtype_case_analysis tenv texp1 texp2 =
    match texp1, texp2 with
    | Exp.Sizeof (t1, len1, st1), Exp.Sizeof (t2, len2, st2) ->
        begin
          let pos_opt, neg_opt = case_analysis_type tenv (t1, st1) (t2, st2) in
          let pos_type_opt = match pos_opt with
            | None -> None
            | Some st1' ->
                let t1', len1' = if check_subtype tenv t1 t2 then t1, len1 else t2, len2 in
                Some (Exp.Sizeof (t1', len1', st1')) in
          let neg_type_opt = match neg_opt with
            | None -> None
            | Some st1' -> Some (Exp.Sizeof (t1, len1, st1')) in
          pos_type_opt, neg_type_opt
        end
    | _ -> (* don't know, consider both possibilities *)
        Some texp1, Some texp1
end

let cast_exception tenv texp1 texp2 e1 subs =
  let _ = match texp1, texp2 with
    | Exp.Sizeof (t1, _, _), Exp.Sizeof (t2, _, st2) ->
        if Config.developer_mode ||
           (Subtype.is_cast st2 &&
            not (Subtyping_check.check_subtype tenv t1 t2)) then
          ProverState.checks := Class_cast_check (texp1, texp2, e1) :: !ProverState.checks
    | _ -> () in
  raise (IMPL_EXC ("class cast exception", subs, EXC_FALSE))

(** get all methods that override [supertype].[pname] in [tenv].
    Note: supertype should be a type T rather than a pointer to type T
    Note: [pname] wil never be included in the returned result *)
let get_overrides_of tenv supertype pname =
  let typ_has_method pname (typ: Typ.t) =
    match typ with
    | Tstruct name -> (
        match Tenv.lookup tenv name with
        | Some { methods } ->
            List.exists ~f:(fun m -> Typ.Procname.equal pname m) methods
        | None ->
            false
      )
    | _ -> false in
  let gather_overrides tname _ overrides_acc =
    let typ = Typ.Tstruct tname in
    (* get all types in the type environment that are non-reflexive subtypes of [supertype] *)
    if not (Typ.equal typ supertype) && Subtyping_check.check_subtype tenv typ supertype then
      (* only select the ones that implement [pname] as overrides *)
      let resolved_pname =
        Typ.Procname.replace_class pname tname in
      if typ_has_method resolved_pname typ then (typ, resolved_pname) :: overrides_acc
      else overrides_acc
    else overrides_acc in
  Tenv.fold gather_overrides tenv []

(** Check the equality of two types ignoring flags in the subtyping components *)
let texp_equal_modulo_subtype_flag texp1 texp2 = match texp1, texp2 with
  | Exp.Sizeof (t1, len1, st1), Exp.Sizeof (t2, len2, st2) ->
      [%compare.equal: Typ.t * Exp.t option] (t1, len1) (t2, len2)
      && Subtype.equal_modulo_flag st1 st2
  | _ -> Exp.equal texp1 texp2

(** check implication between type expressions *)
let texp_imply tenv subs texp1 texp2 e1 calc_missing =
  (* check whether the types could be subject to dynamic cast: *)
  (* classes and arrays in Java, and just classes in C++ and ObjC *)
  let types_subject_to_dynamic_cast =
    match texp1, texp2 with
    | Exp.Sizeof (typ1, _, _), Exp.Sizeof (typ2, _, _) -> (
        match typ1, typ2 with
        | (Tstruct _ | Tarray _), (Tstruct _ | Tarray _) ->
            is_java_class tenv typ1
            || (Typ.is_cpp_class typ1 && Typ.is_cpp_class typ2)
            || (Typ.is_objc_class typ1 && Typ.is_objc_class typ2)
        | _ ->
            false
      )
    | _ -> false in
  if types_subject_to_dynamic_cast then
    begin
      let pos_type_opt, neg_type_opt = Subtyping_check.subtype_case_analysis tenv texp1 texp2 in
      let has_changed = match pos_type_opt with
        | Some texp1' ->
            not (texp_equal_modulo_subtype_flag texp1' texp1)
        | None -> false in
      if calc_missing then (* footprint *)
        begin
          match pos_type_opt with
          | None -> cast_exception tenv texp1 texp2 e1 subs
          | Some _ ->
              if has_changed then None, pos_type_opt (* missing *)
              else pos_type_opt, None (* frame *)
        end
      else (* re-execution *)
        begin
          match neg_type_opt with
          | Some _ -> cast_exception tenv texp1 texp2 e1 subs
          | None ->
              if has_changed then cast_exception tenv texp1 texp2 e1 subs (* missing *)
              else pos_type_opt, None (* frame *)
        end
    end
  else
    None, None

(** pre-process implication between a non-array and an array: the non-array is turned into an array
    of length given by its type only active in type_size mode *)
let sexp_imply_preprocess se1 texp1 se2 = match se1, texp1, se2 with
  | Sil.Eexp (_, inst), Exp.Sizeof _, Sil.Earray _ when Config.type_size ->
      let se1' = Sil.Earray (texp1, [(Exp.zero, se1)], inst) in
      L.d_strln_color Orange "sexp_imply_preprocess"; L.d_str " se1: "; Sil.d_sexp se1; L.d_ln (); L.d_str " se1': "; Sil.d_sexp se1'; L.d_ln ();
      se1'
  | _ -> se1

(** handle parameter subtype: when the type of a callee variable in the caller is a strict subtype
    of the one in the callee, add a type frame and type missing *)
let handle_parameter_subtype tenv prop1 sigma2 subs (e1, se1, texp1) (se2, texp2) =
  let is_callee = match e1 with
    | Exp.Lvar pv -> Pvar.is_callee pv
    | _ -> false in
  let is_allocated_lhs e =
    let filter = function
      | Sil.Hpointsto(e', _, _) -> Exp.equal e' e
      | _ -> false in
    List.exists ~f:filter prop1.Prop.sigma in
  let type_rhs e =
    let sub_opt = ref None in
    let filter = function
      | Sil.Hpointsto(e', _, Exp.Sizeof(t, len, sub)) when Exp.equal e' e ->
          sub_opt := Some (t, len, sub);
          true
      | _ -> false in
    if List.exists ~f:filter sigma2 then !sub_opt else None in
  let add_subtype () = match texp1, texp2, se1, se2 with
    | Exp.Sizeof (Tptr (t1, _), None, _), Exp.Sizeof (Tptr (t2, _), None, _),
      Sil.Eexp (e1', _), Sil.Eexp (e2', _)
      when not (is_allocated_lhs e1') ->
        begin
          match type_rhs e2' with
          | Some (t2_ptsto, len2, sub2) ->
              if not (Typ.equal t1 t2) && Subtyping_check.check_subtype tenv t1 t2
              then begin
                let pos_type_opt, _ =
                  Subtyping_check.subtype_case_analysis tenv
                    (Exp.Sizeof (t1, None, Subtype.subtypes))
                    (Exp.Sizeof (t2_ptsto, len2, sub2)) in
                match pos_type_opt with
                | Some t1_noptr ->
                    ProverState.add_frame_typ (e1', t1_noptr);
                    ProverState.add_missing_typ (e2', t1_noptr)
                | None -> cast_exception tenv texp1 texp2 e1 subs
              end
          | None -> ()
        end
    | _ -> () in
  if is_callee && !Config.footprint then add_subtype ()

let rec hpred_imply tenv calc_index_frame calc_missing subs prop1 sigma2 hpred2 : subst2 * Prop.normal Prop.t = match hpred2 with
  | Sil.Hpointsto (_e2, se2, texp2) ->
      let e2 = Sil.exp_sub (snd subs) _e2 in
      let _ = match e2 with
        | Exp.Lvar _ -> ()
        | Exp.Var v -> if Ident.is_primed v then
              (d_impl_err ("rhs |-> not implemented", subs, (EXC_FALSE_HPRED hpred2));
               raise (Exceptions.Abduction_case_not_implemented __POS__))
        | _ -> () in
      (match Prop.prop_iter_create prop1 with
       | None -> raise (IMPL_EXC ("lhs is empty", subs, EXC_FALSE))
       | Some iter1 ->
           (match Prop.prop_iter_find iter1 (filter_ne_lhs (fst subs) e2) with
            | None -> raise (IMPL_EXC ("lhs does not have e|->", subs, (EXC_FALSE_HPRED hpred2)))
            | Some iter1' ->
                (match Prop.prop_iter_current tenv iter1' with
                 | Sil.Hpointsto (e1, se1, texp1), _ ->
                     (try
                        let typ2 = Exp.texp_to_typ (Some Typ.Tvoid) texp2 in
                        let typing_frame, typing_missing = texp_imply tenv subs texp1 texp2 e1 calc_missing in
                        let se1' = sexp_imply_preprocess se1 texp1 se2 in
                        let subs', fld_frame, fld_missing = sexp_imply tenv e1 calc_index_frame calc_missing subs se1' se2 typ2 in
                        if calc_missing then
                          begin
                            handle_parameter_subtype tenv prop1 sigma2 subs (e1, se1, texp1) (se2, texp2);
                            (match fld_missing with
                             | Some fld_missing ->
                                 ProverState.add_missing_fld (Sil.Hpointsto(_e2, fld_missing, texp1))
                             | None -> ());
                            (match fld_frame with
                             | Some fld_frame ->
                                 ProverState.add_frame_fld (Sil.Hpointsto(e1, fld_frame, texp1))
                             | None -> ());
                            (match typing_missing with
                             | Some t_missing ->
                                 ProverState.add_missing_typ (_e2, t_missing)
                             | None -> ());
                            (match typing_frame with
                             | Some t_frame ->
                                 ProverState.add_frame_typ (e1, t_frame)
                             | None -> ())
                          end;
                        let prop1' = Prop.prop_iter_remove_curr_then_to_prop tenv iter1'
                        in (subs', prop1')
                      with
                      | IMPL_EXC (s, _, _) when calc_missing ->
                          raise (MISSING_EXC s))
                 | Sil.Hlseg (Sil.Lseg_NE, para1, e1, f1, elist1), _ -> (* Unroll lseg *)
                     let n' = Exp.Var (Ident.create_fresh Ident.kprimed) in
                     let (_, para_inst1) = Sil.hpara_instantiate para1 e1 n' elist1 in
                     let hpred_list1 = para_inst1@[Prop.mk_lseg tenv Sil.Lseg_PE para1 n' f1 elist1] in
                     let iter1'' = Prop.prop_iter_update_current_by_list iter1' hpred_list1 in
                     L.d_increase_indent 1;
                     let res =
                       decrease_indent_when_exception
                         (fun () -> hpred_imply tenv calc_index_frame calc_missing subs (Prop.prop_iter_to_prop tenv iter1'') sigma2 hpred2) in
                     L.d_decrease_indent 1;
                     res
                 | Sil.Hdllseg (Sil.Lseg_NE, para1, iF1, oB1, oF1, iB1, elist1), _
                   when Exp.equal (Sil.exp_sub (fst subs) iF1) e2 -> (* Unroll dllseg forward *)
                     let n' = Exp.Var (Ident.create_fresh Ident.kprimed) in
                     let (_, para_inst1) = Sil.hpara_dll_instantiate para1 iF1 oB1 n' elist1 in
                     let hpred_list1 = para_inst1@[Prop.mk_dllseg tenv Sil.Lseg_PE para1 n' iF1 oF1 iB1 elist1] in
                     let iter1'' = Prop.prop_iter_update_current_by_list iter1' hpred_list1 in
                     L.d_increase_indent 1;
                     let res =
                       decrease_indent_when_exception
                         (fun () -> hpred_imply tenv calc_index_frame calc_missing subs (Prop.prop_iter_to_prop tenv iter1'') sigma2 hpred2) in
                     L.d_decrease_indent 1;
                     res
                 | Sil.Hdllseg (Sil.Lseg_NE, para1, iF1, oB1, oF1, iB1, elist1), _
                   when Exp.equal (Sil.exp_sub (fst subs) iB1) e2 -> (* Unroll dllseg backward *)
                     let n' = Exp.Var (Ident.create_fresh Ident.kprimed) in
                     let (_, para_inst1) = Sil.hpara_dll_instantiate para1 iB1 n' oF1 elist1 in
                     let hpred_list1 = para_inst1@[Prop.mk_dllseg tenv Sil.Lseg_PE para1 iF1 oB1 iB1 n' elist1] in
                     let iter1'' = Prop.prop_iter_update_current_by_list iter1' hpred_list1 in
                     L.d_increase_indent 1;
                     let res =
                       decrease_indent_when_exception
                         (fun () -> hpred_imply tenv calc_index_frame calc_missing subs (Prop.prop_iter_to_prop tenv iter1'') sigma2 hpred2) in
                     L.d_decrease_indent 1;
                     res
                 | _ -> assert false
                )
           )
      )
  | Sil.Hlseg (k, para2, _e2, _f2, _elist2) -> (* for now ignore implications between PE and NE *)
      let e2, f2 = Sil.exp_sub (snd subs) _e2, Sil.exp_sub (snd subs) _f2 in
      let _ = match e2 with
        | Exp.Lvar _ -> ()
        | Exp.Var v -> if Ident.is_primed v then
              (d_impl_err ("rhs |-> not implemented", subs, (EXC_FALSE_HPRED hpred2));
               raise (Exceptions.Abduction_case_not_implemented __POS__))
        | _ -> ()
      in
      if Exp.equal e2 f2 && Sil.equal_lseg_kind k Sil.Lseg_PE then (subs, prop1)
      else
        (match Prop.prop_iter_create prop1 with
         | None -> raise (IMPL_EXC ("lhs is empty", subs, EXC_FALSE))
         | Some iter1 ->
             (match Prop.prop_iter_find iter1 (filter_hpred (fst subs) (Sil.hpred_sub (snd subs) hpred2)) with
              | None ->
                  let elist2 = List.map ~f:(fun e -> Sil.exp_sub (snd subs) e) _elist2 in
                  let _, para_inst2 = Sil.hpara_instantiate para2 e2 f2 elist2 in
                  L.d_increase_indent 1;
                  let res =
                    decrease_indent_when_exception
                      (fun () -> sigma_imply tenv calc_index_frame false subs prop1 para_inst2) in
                  (* calc_missing is false as we're checking an instantiation of the original list *)
                  L.d_decrease_indent 1;
                  res
              | Some iter1' ->
                  let elist2 = List.map ~f:(fun e -> Sil.exp_sub (snd subs) e) _elist2 in
                  (* force instantiation of existentials *)
                  let subs' = exp_list_imply tenv calc_missing subs (f2:: elist2) (f2:: elist2) in
                  let prop1' = Prop.prop_iter_remove_curr_then_to_prop tenv iter1' in
                  let hpred1 = match Prop.prop_iter_current tenv iter1' with
                    | hpred1, b ->
                        if b then ProverState.add_missing_pi (Sil.Aneq(_e2, _f2)); (* for PE |- NE *)
                        hpred1
                  in match hpred1 with
                  | Sil.Hlseg _ -> (subs', prop1')
                  | Sil.Hpointsto _ -> (* unroll rhs list and try again *)
                      let n' = Exp.Var (Ident.create_fresh Ident.kprimed) in
                      let (_, para_inst2) = Sil.hpara_instantiate para2 _e2 n' elist2 in
                      let hpred_list2 = para_inst2@[Prop.mk_lseg tenv Sil.Lseg_PE para2 n' _f2 _elist2] in
                      L.d_increase_indent 1;
                      let res =
                        decrease_indent_when_exception
                          (fun () ->
                             try sigma_imply tenv calc_index_frame calc_missing subs prop1 hpred_list2
                             with exn when SymOp.exn_not_failure exn ->
                               begin
                                 (L.d_strln_color Red) "backtracking lseg: trying rhs of length exactly 1";
                                 let (_, para_inst3) = Sil.hpara_instantiate para2 _e2 _f2 elist2 in
                                 sigma_imply tenv calc_index_frame calc_missing subs prop1 para_inst3
                               end) in
                      L.d_decrease_indent 1;
                      res
                  | Sil.Hdllseg _ -> assert false
             )
        )
  | Sil.Hdllseg (Sil.Lseg_PE, _, _, _, _, _, _) ->
      (d_impl_err ("rhs dllsegPE not implemented", subs, (EXC_FALSE_HPRED hpred2));
       raise (Exceptions.Abduction_case_not_implemented __POS__))
  | Sil.Hdllseg (_, para2, iF2, oB2, oF2, iB2, elist2) ->
      (* for now ignore implications between PE and NE *)
      let iF2, oF2 = Sil.exp_sub (snd subs) iF2, Sil.exp_sub (snd subs) oF2 in
      let iB2, oB2 = Sil.exp_sub (snd subs) iB2, Sil.exp_sub (snd subs) oB2 in
      let _ = match oF2 with
        | Exp.Lvar _ -> ()
        | Exp.Var v -> if Ident.is_primed v then
              (d_impl_err ("rhs dllseg not implemented", subs, (EXC_FALSE_HPRED hpred2));
               raise (Exceptions.Abduction_case_not_implemented __POS__))
        | _ -> ()
      in
      let _ = match oB2 with
        | Exp.Lvar _ -> ()
        | Exp.Var v -> if Ident.is_primed v then
              (d_impl_err ("rhs dllseg not implemented", subs, (EXC_FALSE_HPRED hpred2));
               raise (Exceptions.Abduction_case_not_implemented __POS__))
        | _ -> ()
      in
      (match Prop.prop_iter_create prop1 with
       | None -> raise (IMPL_EXC ("lhs is empty", subs, EXC_FALSE))
       | Some iter1 ->
           (match Prop.prop_iter_find iter1 (filter_hpred (fst subs) (Sil.hpred_sub (snd subs) hpred2)) with
            | None ->
                let elist2 = List.map ~f:(fun e -> Sil.exp_sub (snd subs) e) elist2 in
                let _, para_inst2 =
                  if Exp.equal iF2 iB2 then
                    Sil.hpara_dll_instantiate para2 iF2 oB2 oF2 elist2
                  else assert false (* Only base case of rhs list considered for now *) in
                L.d_increase_indent 1;
                let res =
                  decrease_indent_when_exception
                    (fun () -> sigma_imply tenv calc_index_frame false subs prop1 para_inst2) in
                (* calc_missing is false as we're checking an instantiation of the original list *)
                L.d_decrease_indent 1;
                res
            | Some iter1' -> (* Only consider implications between identical listsegs for now *)
                let elist2 = List.map ~f:(fun e -> Sil.exp_sub (snd subs) e) elist2 in
                (* force instantiation of existentials *)
                let subs' =
                  exp_list_imply tenv calc_missing subs
                    (iF2:: oB2:: oF2:: iB2:: elist2) (iF2:: oB2:: oF2:: iB2:: elist2) in
                let prop1' = Prop.prop_iter_remove_curr_then_to_prop tenv iter1'
                in (subs', prop1')
           )
      )

(** Check that [sigma1] implies [sigma2] and return two substitution
    instantiations for the primed variables of [sigma1] and [sigma2]
    and a frame. Raise IMPL_FALSE if the implication cannot be
    proven. *)
and sigma_imply tenv calc_index_frame calc_missing subs prop1 sigma2 : (subst2 * Prop.normal Prop.t) =
  let is_constant_string_class subs = function (* if the hpred represents a constant string, return the string *)
    | Sil.Hpointsto (_e2, _, _) ->
        let e2 = Sil.exp_sub (snd subs) _e2 in
        (match e2 with
         | Exp.Const (Const.Cstr s) -> Some (s, true)
         | Exp.Const (Const.Cclass c) -> Some (Ident.name_to_string c, false)
         | _ -> None)
    | _ -> None in
  let mk_constant_string_hpred s = (* create an hpred from a constant string *)
    let len = IntLit.of_int (1 + String.length s) in
    let root = Exp.Const (Const.Cstr s) in
    let sexp =
      let index = Exp.int (IntLit.of_int (String.length s)) in
      match !Config.curr_language with
      | Config.Clang ->
          Sil.Earray
            (Exp.int len, [(index, Sil.Eexp (Exp.zero, Sil.inst_none))], Sil.inst_none)
      | Config.Java ->
          let mk_fld_sexp s =
            let fld = Ident.create_fieldname (Mangled.from_string s) 0 in
            let se = Sil.Eexp (Exp.Var (Ident.create_fresh Ident.kprimed), Sil.Inone) in
            (fld, se) in
          let fields = ["java.lang.String.count"; "java.lang.String.hash"; "java.lang.String.offset"; "java.lang.String.value"] in
          Sil.Estruct (List.map ~f:mk_fld_sexp fields, Sil.inst_none) in
    let const_string_texp =
      match !Config.curr_language with
      | Config.Clang ->
          Exp.Sizeof (Typ.Tarray (Typ.Tint Typ.IChar, Some len), None, Subtype.exact)
      | Config.Java ->
          let object_type = Typename.Java.from_string "java.lang.String" in
          Exp.Sizeof (Tstruct object_type, None, Subtype.exact) in
    Sil.Hpointsto (root, sexp, const_string_texp) in
  let mk_constant_class_hpred s = (* creat an hpred from a constant class *)
    let root = Exp.Const (Const.Cclass (Ident.string_to_name s)) in
    let sexp = (* TODO: add appropriate fields *)
      Sil.Estruct
        ([(Ident.create_fieldname (Mangled.from_string "java.lang.Class.name") 0,
           Sil.Eexp ((Exp.Const (Const.Cstr s), Sil.Inone)))], Sil.inst_none) in
    let class_texp =
      let class_type = Typename.Java.from_string "java.lang.Class" in
      Exp.Sizeof (Tstruct class_type, None, Subtype.exact) in
    Sil.Hpointsto (root, sexp, class_texp) in
  try
    (match move_primed_lhs_from_front subs sigma2 with
     | [] ->
         L.d_strln "Final Implication";
         d_impl subs (prop1, Prop.prop_emp);
         (subs, prop1)
     | hpred2 :: sigma2' ->
         L.d_strln "Current Implication";
         d_impl subs (prop1, Prop.normalize tenv (Prop.from_sigma (hpred2 :: sigma2')));
         L.d_ln ();
         L.d_ln ();
         let normal_case hpred2' =
           let (subs', prop1') =
             try
               L.d_increase_indent 1;
               let res =
                 decrease_indent_when_exception
                   (fun () -> hpred_imply tenv calc_index_frame calc_missing subs prop1 sigma2 hpred2') in
               L.d_decrease_indent 1;
               res
             with IMPL_EXC _ when calc_missing ->
               begin
                 match is_constant_string_class subs hpred2' with
                 | Some (s, is_string) -> (* allocate constant string hpred1', do implication, then add hpred1' as missing *)
                     let hpred1' = if is_string then mk_constant_string_hpred s else mk_constant_class_hpred s in
                     let prop1' =
                       Prop.normalize tenv (Prop.set prop1 ~sigma:(hpred1' :: prop1.Prop.sigma)) in
                     let subs', frame_prop = hpred_imply tenv calc_index_frame calc_missing subs prop1' sigma2 hpred2' in
                     (* ProverState.add_missing_sigma [hpred1']; *)
                     subs', frame_prop
                 | None ->
                     let subs' = match hpred2' with
                       | Sil.Hpointsto (e2, se2, te2) ->
                           let typ2 = Exp.texp_to_typ (Some Typ.Tvoid) te2 in
                           sexp_imply_nolhs tenv e2 calc_missing subs se2 typ2
                       | _ -> subs in
                     ProverState.add_missing_sigma [hpred2'];
                     subs', prop1
               end in
           L.d_increase_indent 1;
           let res =
             decrease_indent_when_exception
               (fun () -> sigma_imply tenv calc_index_frame calc_missing subs' prop1' sigma2') in
           L.d_decrease_indent 1;
           res in
         (match hpred2 with
          | Sil.Hpointsto(_e2, se2, t) ->
              let changed, calc_index_frame', hpred2' = expand_hpred_pointer tenv calc_index_frame (Sil.Hpointsto (Prop.exp_normalize_noabs tenv (snd subs) _e2, se2, t)) in
              if changed
              then sigma_imply tenv calc_index_frame' calc_missing subs prop1 (hpred2' :: sigma2') (* calc_index_frame=true *)
              else normal_case hpred2'
          | _ -> normal_case hpred2)
    )
  with IMPL_EXC (s, _, _) when calc_missing ->
    L.d_strln ("Adding rhs as missing: " ^ s);
    ProverState.add_missing_sigma sigma2;
    subs, prop1

let prepare_prop_for_implication tenv (_, sub2) pi1 sigma1 =
  let pi1' = (Prop.pi_sub sub2 (ProverState.get_missing_pi ())) @ pi1 in
  let sigma1' = (Prop.sigma_sub sub2 (ProverState.get_missing_sigma ())) @ sigma1 in
  let ep = Prop.set Prop.prop_emp ~sub:sub2 ~sigma:sigma1' ~pi:pi1' in
  Prop.normalize tenv ep

let imply_pi tenv calc_missing (sub1, sub2) prop pi2 =
  let do_atom a =
    let a' = Sil.atom_sub sub2 a in
    try
      if not (check_atom tenv prop a')
      then raise (IMPL_EXC ("rhs atom missing in lhs", (sub1, sub2), (EXC_FALSE_ATOM a')))
    with
    | IMPL_EXC _ when calc_missing ->
        L.d_str "imply_pi: adding missing atom "; Sil.d_atom a; L.d_ln ();
        ProverState.add_missing_pi a in
  List.iter ~f:do_atom pi2

let imply_atom tenv calc_missing (sub1, sub2) prop a =
  imply_pi tenv calc_missing (sub1, sub2) prop [a]

(** Check pure implications before looking at the spatial part. Add
    necessary instantiations for equalities and check that instantiations
    are possible for disequalities. *)
let rec pre_check_pure_implication tenv calc_missing subs pi1 pi2 =
  match pi2 with
  | [] -> subs
  | (Sil.Aeq (e2_in, f2_in) as a) :: pi2' when not (Prop.atom_is_inequality a) ->
      let e2, f2 = Sil.exp_sub (snd subs) e2_in, Sil.exp_sub (snd subs) f2_in in
      if Exp.equal e2 f2 then pre_check_pure_implication tenv calc_missing subs pi1 pi2'
      else
        (match e2, f2 with
         | Exp.Var v2, f2
           when Ident.is_primed v2 (* && not (Sil.mem_sub v2 (snd subs)) *) ->
             (* The commented-out condition should always hold. *)
             let sub2' = extend_sub (snd subs) v2 f2 in
             pre_check_pure_implication tenv calc_missing (fst subs, sub2') pi1 pi2'
         | e2, Exp.Var v2
           when Ident.is_primed v2 (* && not (Sil.mem_sub v2 (snd subs)) *) ->
             (* The commented-out condition should always hold. *)
             let sub2' = extend_sub (snd subs) v2 e2 in
             pre_check_pure_implication tenv calc_missing (fst subs, sub2') pi1 pi2'
         | _ ->
             let pi1' = Prop.pi_sub (fst subs) pi1 in
             let prop_for_impl = prepare_prop_for_implication tenv subs pi1' [] in
             imply_atom tenv calc_missing subs prop_for_impl (Sil.Aeq (e2_in, f2_in));
             pre_check_pure_implication tenv calc_missing subs pi1 pi2'
        )
  | (Sil.Aneq (e, _) | Apred (_, e :: _) | Anpred (_, e :: _)) :: _
    when not calc_missing && (match e with Var v -> not (Ident.is_primed v) | _ -> true) ->
      raise (IMPL_EXC ("ineq e2=f2 in rhs with e2 not primed var",
                       (Sil.sub_empty, Sil.sub_empty), EXC_FALSE))
  | (Sil.Aeq _ | Aneq _ | Apred _ | Anpred _) :: pi2' ->
      pre_check_pure_implication tenv calc_missing subs pi1 pi2'

(** Perform the array bound checks delayed (to instantiate variables) by the prover.
    If there is a provable violation of the array bounds, set the prover status to Bounds_check
    and make the proof fail. *)
let check_array_bounds tenv (sub1, sub2) prop =
  let check_failed atom =
    ProverState.checks := Bounds_check :: !ProverState.checks;
    L.d_str_color Red "bounds_check failed: provable atom: "; Sil.d_atom atom; L.d_ln();
    if (not Config.bound_error_allowed_in_procedure_call) then
      raise (IMPL_EXC ("bounds check", (sub1, sub2), EXC_FALSE)) in
  let fail_if_le e' e'' =
    let lt_ineq = Prop.mk_inequality tenv (Exp.BinOp(Binop.Le, e', e'')) in
    if check_atom tenv prop lt_ineq then check_failed lt_ineq in
  let check_bound = function
    | ProverState.BClen_imply (len1_, len2_, _indices2) ->
        let len1 = Sil.exp_sub sub1 len1_ in
        let len2 = Sil.exp_sub sub2 len2_ in
        (* L.d_strln_color Orange "check_bound ";
           Sil.d_exp len1; L.d_str " "; Sil.d_exp len2; L.d_ln(); *)
        let indices_to_check = match len2 with
          | _ -> [Exp.BinOp(Binop.PlusA, len2, Exp.minus_one)] (* only check len *) in
        List.iter ~f:(fail_if_le len1) indices_to_check
    | ProverState.BCfrom_pre _atom ->
        let atom_neg = atom_negate tenv (Sil.atom_sub sub2 _atom) in
        (* L.d_strln_color Orange "BCFrom_pre"; Sil.d_atom atom_neg; L.d_ln (); *)
        if check_atom tenv prop atom_neg then check_failed atom_neg in
  List.iter ~f:check_bound (ProverState.get_bounds_checks ())

(** [check_implication_base] returns true if [prop1|-prop2],
    ignoring the footprint part of the props *)
let check_implication_base pname tenv check_frame_empty calc_missing prop1 prop2 =
  try
    ProverState.reset prop1 prop2;
    let filter (id, e) =
      Ident.is_normal id && Sil.fav_for_all (Sil.exp_fav e) Ident.is_normal in
    let sub1_base =
      Sil.sub_filter_pair ~f:filter prop1.Prop.sub in
    let pi1, pi2 = Prop.get_pure prop1, Prop.get_pure prop2 in
    let sigma1, sigma2 = prop1.Prop.sigma, prop2.Prop.sigma in
    let subs = pre_check_pure_implication tenv calc_missing (prop1.Prop.sub, sub1_base) pi1 pi2 in
    let pi2_bcheck, pi2_nobcheck = (* find bounds checks implicit in pi2 *)
      List.partition_tf ~f:ProverState.atom_is_array_bounds_check pi2 in
    List.iter ~f:(fun a -> ProverState.add_bounds_check (ProverState.BCfrom_pre a)) pi2_bcheck;
    L.d_strln "pre_check_pure_implication";
    L.d_strln "pi1:";
    L.d_increase_indent 1; Prop.d_pi pi1; L.d_decrease_indent 1; L.d_ln ();
    L.d_strln "pi2:";
    L.d_increase_indent 1; Prop.d_pi pi2; L.d_decrease_indent 1; L.d_ln ();
    if pi2_bcheck <> []
    then (L.d_str "pi2 bounds checks: "; Prop.d_pi pi2_bcheck; L.d_ln ());
    L.d_strln "returns";
    L.d_strln "sub1: ";
    L.d_increase_indent 1; Prop.d_sub (fst subs); L.d_decrease_indent 1; L.d_ln ();
    L.d_strln "sub2: ";
    L.d_increase_indent 1; Prop.d_sub (snd subs); L.d_decrease_indent 1; L.d_ln ();
    let (sub1, sub2), frame_prop = sigma_imply tenv false calc_missing subs prop1 sigma2 in
    let pi1' = Prop.pi_sub sub1 pi1 in
    let sigma1' = Prop.sigma_sub sub1 sigma1 in
    L.d_ln ();
    let prop_for_impl = prepare_prop_for_implication tenv (sub1, sub2) pi1' sigma1' in
    (* only deal with pi2 without bound checks *)
    imply_pi tenv calc_missing (sub1, sub2) prop_for_impl pi2_nobcheck;
    (* handle implicit bound checks, plus those from array_len_imply *)
    check_array_bounds tenv (sub1, sub2) prop_for_impl;
    L.d_strln "Result of Abduction";
    L.d_increase_indent 1; d_impl (sub1, sub2) (prop1, prop2); L.d_decrease_indent 1; L.d_ln ();
    L.d_strln"returning TRUE";
    let frame = frame_prop.Prop.sigma in
    if check_frame_empty && frame <> [] then raise (IMPL_EXC("frame not empty", subs, EXC_FALSE));
    Some ((sub1, sub2), frame)
  with
  | IMPL_EXC (s, subs, body) ->
      d_impl_err (s, subs, body);
      None
  | MISSING_EXC s ->
      L.d_strln ("WARNING: footprint failed to find MISSING because: " ^ s);
      None
  | (Exceptions.Abduction_case_not_implemented _ as exn) ->
      Reporting.log_error pname exn;
      None

type implication_result =
  | ImplOK of
      (check list * Sil.subst * Sil.subst * Sil.hpred list * (Sil.atom list) * (Sil.hpred list) *
       (Sil.hpred list) * (Sil.hpred list) * ((Exp.t * Exp.t) list) * ((Exp.t * Exp.t) list))
  | ImplFail of check list

(** [check_implication_for_footprint p1 p2] returns
    [Some(sub, frame, missing)] if [sub(p1 * missing) |- sub(p2 * frame)]
    where [sub] is a substitution which instantiates the
    primed vars of [p1] and [p2], which are assumed to be disjoint. *)
let check_implication_for_footprint pname tenv p1 (p2: Prop.exposed Prop.t) =
  let check_frame_empty = false in
  let calc_missing = true in
  match check_implication_base pname tenv check_frame_empty calc_missing p1 p2 with
  | Some ((sub1, sub2), frame) ->
      ImplOK (!ProverState.checks, sub1, sub2, frame, ProverState.get_missing_pi (), ProverState.get_missing_sigma (), ProverState.get_frame_fld (), ProverState.get_missing_fld (), ProverState.get_frame_typ (), ProverState.get_missing_typ ())
  | None -> ImplFail !ProverState.checks

(** [check_implication p1 p2] returns true if [p1|-p2] *)
let check_implication pname tenv p1 p2 =
  let check p1 p2 =
    let check_frame_empty = true in
    let calc_missing = false in
    match check_implication_base pname tenv check_frame_empty calc_missing p1 p2 with
    | Some _ -> true
    | None -> false in
  check p1 p2 &&
  (if !Config.footprint then check (Prop.normalize tenv (Prop.extract_footprint p1)) (Prop.extract_footprint p2) else true)

(** {2 Cover: miminum set of pi's whose disjunction is equivalent to true} *)

(** check if the pi's in [cases] cover true *)
let is_cover tenv cases =
  let cnt = ref 0 in (* counter for timeout checks, as this function can take exponential time *)
  let check () =
    incr cnt;
    if Int.equal (!cnt mod 100) 0 then SymOp.check_wallclock_alarm () in
  let rec _is_cover acc_pi cases =
    check ();
    match cases with
    | [] -> check_inconsistency_pi tenv acc_pi
    | (pi, _):: cases' ->
        List.for_all ~f:(fun a -> _is_cover ((atom_negate tenv a) :: acc_pi) cases') pi in
  _is_cover [] cases

exception NO_COVER

(** Find miminum set of pi's in [cases] whose disjunction covers true *)
let find_minimum_pure_cover tenv cases =
  let cases =
    let compare (pi1, _) (pi2, _) = Int.compare (List.length pi1) (List.length pi2)
    in List.sort ~cmp:compare cases in
  let rec grow seen todo = match todo with
    | [] -> raise NO_COVER
    | (pi, x):: todo' ->
        if is_cover tenv ((pi, x):: seen) then (pi, x):: seen
        else grow ((pi, x):: seen) todo' in
  let rec _shrink seen todo = match todo with
    | [] -> seen
    | (pi, x):: todo' ->
        if is_cover tenv (seen @ todo') then _shrink seen todo'
        else _shrink ((pi, x):: seen) todo' in
  let shrink cases =
    if List.length cases > 2 then _shrink [] cases
    else cases
  in try Some (shrink (grow [] cases))
  with NO_COVER -> None

(*
(** Check [prop |- e1<e2]. Result [false] means "don't know". *)
let check_lt prop e1 e2 =
  let e1_lt_e2 = Exp.BinOp (Binop.Lt, e1, e2) in
  check_atom prop (Prop.mk_inequality e1_lt_e2)

let filter_ptsto_lhs sub e0 = function
  | Sil.Hpointsto (e, _, _) -> if Exp.equal e0 (Sil.exp_sub sub e) then Some () else None
  | _ -> None
*)
