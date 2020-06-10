(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Qset - Set with (signed) rational multiplicity for each element *)

open NS0

module type S = sig
  type elt
  type t

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val hash_fold_t : elt Hash.folder -> t Hash.folder
  val sexp_of_t : t -> Sexp.t
  val t_of_sexp : (Sexp.t -> elt) -> Sexp.t -> t
  val pp : (unit, unit) fmt -> (elt * Q.t) pp -> t pp

  (* constructors *)

  val empty : t
  (** The empty multiset over the provided order. *)

  val of_ : elt -> Q.t -> t

  val add : t -> elt -> Q.t -> t
  (** Add to multiplicity of single element. [O(log n)] *)

  val remove : t -> elt -> t
  (** Set the multiplicity of an element to zero. [O(log n)] *)

  val union : t -> t -> t
  (** Sum multiplicities pointwise. [O(n + m)] *)

  val map : t -> f:(elt -> Q.t -> elt * Q.t) -> t
  (** Map over the elements in ascending order. Preserves physical equality
      if [f] does. *)

  val map_counts : t -> f:(elt -> Q.t -> Q.t) -> t
  (** Map over the multiplicities of the elements in ascending order. *)

  (* queries *)

  val is_empty : t -> bool
  val is_singleton : t -> bool

  val length : t -> int
  (** Number of elements with non-zero multiplicity. [O(1)]. *)

  val count : t -> elt -> Q.t
  (** Multiplicity of an element. [O(log n)]. *)

  val choose_exn : t -> elt * Q.t
  (** Find an unspecified element. [O(1)]. *)

  val choose : t -> (elt * Q.t) option
  (** Find an unspecified element. [O(1)]. *)

  val pop : t -> (elt * Q.t * t) option
  (** Find and remove an unspecified element. [O(1)]. *)

  val min_elt : t -> (elt * Q.t) option
  (** Minimum element. [O(log n)]. *)

  val pop_min_elt : t -> (elt * Q.t * t) option
  (** Find and remove minimum element. [O(log n)]. *)

  val classify : t -> [`Zero | `One of elt * Q.t | `Many]
  (** Classify a set as either empty, singleton, or otherwise. *)

  val find_and_remove : t -> elt -> (Q.t * t) option
  (** Find and remove an element. *)

  val to_list : t -> (elt * Q.t) list
  (** Convert to a list of elements in ascending order. *)

  (* traversals *)

  val iter : t -> f:(elt -> Q.t -> unit) -> unit
  (** Iterate over the elements in ascending order. *)

  val exists : t -> f:(elt -> Q.t -> bool) -> bool
  (** Search for an element satisfying a predicate. *)

  val for_all : t -> f:(elt -> Q.t -> bool) -> bool
  (** Test whether all elements satisfy a predicate. *)

  val fold : t -> f:(elt -> Q.t -> 's -> 's) -> init:'s -> 's
  (** Fold over the elements in ascending order. *)
end
