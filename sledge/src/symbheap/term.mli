(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Terms

    Pure (heap-independent) terms are complex arithmetic, bitwise-logical,
    etc. operations over literal values and variables.

    Terms for operations that are uninterpreted in the analyzer are
    represented in curried form, where [App] is an application of a function
    symbol to an argument. This is done to simplify the definition of
    'subterm' and make it explicit. The specific constructor functions
    indicate and check the expected arity of the function symbols. *)

type comparator_witness

type op1 =
  | Extract of {unsigned: bool; bits: int}
      (** Interpret integer argument with given signedness and bitwidth. *)
  | Convert of {unsigned: bool; dst: Typ.t; src: Typ.t}
      (** Convert between specified types, possibly with loss of
          information. If [src] is an [Integer] type, then [unsigned]
          indicates that the argument should be interpreted as an [unsigned]
          integer. If [src] is a [Float] type and [dst] is an [Integer]
          type, then [unsigned] indidates that the result should be the
          nearest non-negative value. *)
[@@deriving compare, equal, hash, sexp]

type op2 =
  | Splat  (** Iterated concatenation of a single byte *)
  | Memory  (** Size-tagged byte-array *)
  | Eq  (** Equal test *)
  | Dq  (** Disequal test *)
  | Lt  (** Less-than test *)
  | Le  (** Less-than-or-equal test *)
  | Ord  (** Ordered test (neither arg is nan) *)
  | Uno  (** Unordered test (some arg is nan) *)
  | Div  (** Division *)
  | Rem  (** Remainder of division *)
  | And  (** Conjunction, boolean or bitwise *)
  | Or  (** Disjunction, boolean or bitwise *)
  | Xor  (** Exclusive-or, bitwise *)
  | Shl  (** Shift left, bitwise *)
  | Lshr  (** Logical shift right, bitwise *)
  | Ashr  (** Arithmetic shift right, bitwise *)
[@@deriving compare, equal, hash, sexp]

type op3 = Conditional  (** If-then-else *)
[@@deriving compare, equal, hash, sexp]

type qset = (t, comparator_witness) Qset.t

and t = private
  | Add of qset  (** Addition *)
  | Mul of qset  (** Multiplication *)
  | Concat of {args: t vector}  (** Byte-array concatenation *)
  | Var of {id: int; name: string}  (** Local variable / virtual register *)
  | Nondet of {msg: string}
      (** Anonymous local variable with arbitrary value, representing
          non-deterministic approximation of value described by [msg] *)
  | Label of {parent: string; name: string}
      (** Address of named code block within parent function *)
  | Ap1 of op1 * t
  | Ap2 of op2 * t * t
  | Ap3 of op3 * t * t * t
  | App of {op: t; arg: t}
      (** Application of function symbol to argument, curried *)
  | Record  (** Record (array / struct) constant *)
  | Select  (** Select an index from a record *)
  | Update  (** Constant record with updated index *)
  | Struct_rec of {elts: t vector}
      (** Struct constant that may recursively refer to itself
          (transitively) from [elts]. NOTE: represented by cyclic values. *)
  | Integer of {data: Z.t}
      (** Integer constant, or if [typ] is a [Pointer], null pointer value
          that never refers to an object *)
  | Float of {data: string}  (** Floating-point constant *)
[@@deriving compare, equal, hash, sexp]

val comparator : (t, comparator_witness) Comparator.t

type term = t

val pp_full : ?is_x:(term -> bool) -> t pp
val pp : t pp
val invariant : ?partial:bool -> t -> unit

(** Term.Var is re-exported as Var *)
module Var : sig
  type t = private term [@@deriving compare, equal, hash, sexp]
  type var = t

  include Comparator.S with type t := t

  module Set : sig
    type t = (var, comparator_witness) Set.t
    [@@deriving compare, equal, sexp]

    val pp_full : ?is_x:(term -> bool) -> t pp
    val pp : t pp
    val empty : t
    val of_option : var option -> t
    val of_list : var list -> t
    val of_vector : var vector -> t
    val of_regs : Reg.Set.t -> t
  end

  val pp : t pp

  include Invariant.S with type t := t

  val of_reg : Reg.t -> t
  val of_term : term -> t option
  val fresh : string -> wrt:Set.t -> t * Set.t
  val name : t -> string

  module Subst : sig
    type t [@@deriving compare, equal, sexp]

    val pp : t pp
    val empty : t
    val freshen : Set.t -> wrt:Set.t -> t
    val invert : t -> t
    val restrict : t -> Set.t -> t
    val is_empty : t -> bool
    val domain : t -> Set.t
    val range : t -> Set.t
    val apply_set : t -> Set.t -> Set.t
  end
end

(** Construct *)

val var : Var.t -> t
val nondet : string -> t
val label : parent:string -> name:string -> t
val true_ : t
val false_ : t
val null : t
val zero : t
val one : t
val minus_one : t
val splat : byt:t -> siz:t -> t
val memory : siz:t -> arr:t -> t
val concat : t array -> t
val bool : bool -> t
val integer : Z.t -> t
val rational : Q.t -> t
val float : string -> t
val eq : t -> t -> t
val dq : t -> t -> t
val lt : t -> t -> t
val le : t -> t -> t
val ord : t -> t -> t
val uno : t -> t -> t
val neg : t -> t
val add : t -> t -> t
val sub : t -> t -> t
val mul : t -> t -> t
val div : t -> t -> t
val rem : t -> t -> t
val and_ : t -> t -> t
val or_ : t -> t -> t
val xor : t -> t -> t
val not_ : t -> t
val shl : t -> t -> t
val lshr : t -> t -> t
val ashr : t -> t -> t
val conditional : cnd:t -> thn:t -> els:t -> t
val record : t list -> t
val select : rcd:t -> idx:t -> t
val update : rcd:t -> elt:t -> idx:t -> t
val extract : ?unsigned:bool -> bits:int -> t -> t
val convert : ?unsigned:bool -> dst:Typ.t -> src:Typ.t -> t -> t
val size_of : Typ.t -> t option
val of_exp : Exp.t -> t

(** Access *)

val iter : t -> f:(t -> unit) -> unit
val fold_vars : t -> init:'a -> f:('a -> Var.t -> 'a) -> 'a
val fold_terms : t -> init:'a -> f:('a -> t -> 'a) -> 'a
val fold : t -> init:'a -> f:(t -> 'a -> 'a) -> 'a

(** Transform *)

val map : t -> f:(t -> t) -> t
val rename : Var.Subst.t -> t -> t

(** Query *)

val fv : t -> Var.Set.t
val is_true : t -> bool
val is_false : t -> bool
val classify : t -> [> `Atomic | `Interpreted | `Simplified | `Uninterpreted]
val solve : t -> t -> (t, t, comparator_witness) Map.t option
