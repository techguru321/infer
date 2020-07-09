(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Variables *)
module Var : sig
  type t [@@deriving compare, equal, sexp]
  type strength = t -> [`Universal | `Existential | `Anonymous] option

  val pp : t pp

  module Map : Map.S with type key := t

  module Set : sig
    include NS.Set.S with type elt := t

    val sexp_of_t : t -> Sexp.t
    val t_of_sexp : Sexp.t -> t
    val ppx : strength -> t pp
    val pp : t pp
    val pp_xs : t pp
    val of_regs : Llair.Reg.Set.t -> t
  end

  val of_reg : Llair.Reg.t -> t
  val fresh : string -> wrt:Set.t -> t * Set.t

  val identified : name:string -> id:int -> t
  (** Variable with the given [id]. Variables are compared by [id] alone,
      [name] is used only for printing. The only way to ensure [identified]
      variables do not clash with [fresh] variables is to pass the
      [identified] variables to [fresh] in [wrt]:
      [Var.fresh name ~wrt:(Var.Set.of_ (Var.identified ~name ~id))]. *)

  val id : t -> int
  val name : t -> string

  module Subst : sig
    type var := t
    type t [@@deriving compare, equal, sexp]
    type x = {sub: t; dom: Set.t; rng: Set.t}

    val pp : t pp
    val empty : t
    val freshen : Set.t -> wrt:Set.t -> x * Set.t
    val invert : t -> t
    val restrict : t -> Set.t -> x
    val is_empty : t -> bool
    val domain : t -> Set.t
    val range : t -> Set.t
    val fold : t -> init:'a -> f:(var -> var -> 'a -> 'a) -> 'a
  end
end

(** Terms *)
module Term : sig
  type term
  type formula = term

  val ppx : Var.strength -> term pp
  val pp : term pp

  module Map : Map.S with type key := term

  (** Construct *)

  (** terms *)

  (* variables *)
  val var : Var.t -> term

  (* constants *)
  val zero : term
  val one : term
  val integer : Z.t -> term
  val rational : Q.t -> term

  (* arithmetic *)
  val neg : term -> term
  val add : term -> term -> term
  val sub : term -> term -> term
  val mulq : Q.t -> term -> term
  val mul : term -> term -> term

  (* sequences *)
  val splat : term -> term
  val sized : seq:term -> siz:term -> term
  val extract : seq:term -> off:term -> len:term -> term
  val concat : term array -> term

  (* if-then-else *)
  val ite : cnd:formula -> thn:term -> els:term -> term

  (** formulas *)

  (* constants *)
  val true_ : formula
  val false_ : formula

  (* comparisons *)
  val eq : term -> term -> formula
  val dq : term -> term -> formula
  val lt : term -> term -> formula
  val le : term -> term -> formula

  (* connectives *)
  val not_ : formula -> formula
  val and_ : formula -> formula -> formula
  val or_ : formula -> formula -> formula
  val conditional : cnd:formula -> thn:formula -> els:formula -> formula

  (** Convert *)

  val of_exp : Llair.Exp.t -> term

  (** Destruct *)

  val d_int : term -> Z.t option

  (** Access *)

  val const_of : term -> Q.t option

  (** Transform *)

  val disjuncts : term -> term list
  val rename : Var.Subst.t -> term -> term

  (** Traverse *)

  val fold_vars : term -> init:'a -> f:('a -> Var.t -> 'a) -> 'a

  (** Query *)

  val is_true : formula -> bool
  val is_false : formula -> bool
  val fv : term -> Var.Set.t

  type t = term [@@deriving compare, equal, sexp]
end

(** Inference System *)
module Context : sig
  type t [@@deriving compare, equal, sexp]
  type classes = Term.t list Term.Map.t

  val classes : t -> classes
  (** [classes r] maps each equivalence class representative to the other
      terms [r] proves equal to it. *)

  val diff_classes : t -> t -> classes
  (** [diff_classes r s] is the equality classes of [r] omitting equalities
      in [s]. *)

  val pp : t pp
  val pp_classes : t pp
  val ppx_classes : Var.strength -> classes pp

  include Invariant.S with type t := t

  val true_ : t
  (** The diagonal relation, which only equates each term with itself. *)

  val and_term : Var.Set.t -> Term.t -> t -> Var.Set.t * t
  (** Conjoin a (Boolean) term to a relation. *)

  val and_ : Var.Set.t -> t -> t -> Var.Set.t * t
  (** Conjunction. *)

  val orN : Var.Set.t -> t list -> Var.Set.t * t
  (** Nary disjunction. *)

  val rename : t -> Var.Subst.t -> t
  (** Apply a renaming substitution to the relation. *)

  val fv : t -> Var.Set.t
  (** The variables occurring in the terms of the relation. *)

  val is_true : t -> bool
  (** Test if the relation is diagonal. *)

  val is_false : t -> bool
  (** Test if the relation is empty / inconsistent. *)

  val entails_eq : t -> Term.t -> Term.t -> bool
  (** Test if an equation is entailed by a relation. *)

  val class_of : t -> Term.t -> Term.t list
  (** Equivalence class of [e]: all the terms [f] in the relation such that
      [e = f] is implied by the relation. *)

  val normalize : t -> Term.t -> Term.t
  (** Normalize a term [e] to [e'] such that [e = e'] is implied by the
      relation, where [e'] and its subterms are expressed in terms of the
      relation's canonical representatives of each equivalence class. *)

  val difference : t -> Term.t -> Term.t -> Z.t option
  (** The difference as an offset. [difference r a b = Some k] if [r]
      implies [a = b+k], or [None] if [a] and [b] are not equal up to an
      integer offset. *)

  val fold_terms : t -> init:'a -> f:('a -> Term.t -> 'a) -> 'a

  (** Solution Substitutions *)
  module Subst : sig
    type t

    val pp : t pp
    val is_empty : t -> bool

    val fold :
      t -> init:'a -> f:(key:Term.t -> data:Term.t -> 'a -> 'a) -> 'a

    val subst : t -> Term.t -> Term.t
    (** Apply a substitution recursively to subterms. *)

    val partition_valid : Var.Set.t -> t -> t * Var.Set.t * t
    (** Partition ∃xs. σ into equivalent ∃xs. τ ∧ ∃ks. ν where ks
        and ν are maximal where ∃ks. ν is universally valid, xs ⊇ ks
        and ks ∩ fv(τ) = ∅. *)
  end

  val apply_subst : Var.Set.t -> Subst.t -> t -> Var.Set.t * t
  (** Relation induced by applying a substitution to a set of equations
      generating the argument relation. *)

  val solve_for_vars : Var.Set.t list -> t -> Subst.t
  (** [solve_for_vars vss r] is a solution substitution that is entailed by
      [r] and consists of oriented equalities [x ↦ e] that map terms [x]
      with free variables contained in (the union of) a prefix [uss] of
      [vss] to terms [e] with free variables contained in as short a prefix
      of [uss] as possible. *)

  val elim : Var.Set.t -> t -> t
  (** Weaken relation by removing oriented equations [k ↦ _] for [k] in
      [ks]. *)
end
