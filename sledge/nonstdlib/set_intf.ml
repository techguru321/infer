(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open NS0

module type S = sig
  type elt

  module Elt : sig
    type t = elt

    include Comparator.S with type t := t
  end

  include Core_kernel.Set_intf.Make_S_plain_tree(Elt).S

  val hash_fold_t : elt Hash.folder -> t Hash.folder

  val pp :
       ?pre:(unit, unit) fmt
    -> ?suf:(unit, unit) fmt
    -> ?sep:(unit, unit) fmt
    -> elt pp
    -> t pp

  val pp_diff : elt pp -> (t * t) pp
  val of_ : elt -> t
  val of_option : elt option -> t
  val of_iarray : elt IArray.t -> t
  val add_option : elt option -> t -> t
  val add_list : elt list -> t -> t
  val diff_inter : t -> t -> t * t
  val disjoint : t -> t -> bool

  val pop_exn : t -> elt * t
  (** Find and remove an unspecified element. [O(1)]. *)

  val pop : t -> (elt * t) option
  (** Find and remove an unspecified element. [O(1)]. *)
end
