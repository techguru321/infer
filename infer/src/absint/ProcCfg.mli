(*
 * Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

(** Control-flow graph for a single procedure (as opposed to cfg.ml, which represents a cfg for a
    file). Defines useful wrappers that allows us to do tricks like turn a forward cfg to into a
    backward one, or view a cfg as having a single instruction per block *)

module type Node = sig
  type t

  type id

  val kind : t -> Procdesc.Node.nodekind

  val id : t -> id

  val hash : t -> int

  val loc : t -> Location.t

  val underlying_node : t -> Procdesc.Node.t

  val of_underlying_node : Procdesc.Node.t -> t

  val compare_id : id -> id -> int

  val pp_id : Format.formatter -> id -> unit

  module IdMap : PrettyPrintable.PPMap with type key = id

  module IdSet : PrettyPrintable.PPSet with type elt = id
end

module type S = sig
  type t

  module Node : Node

  val instrs : Node.t -> Instrs.t
  (** get the instructions from a node *)

  val fold_succs : t -> (Node.t, Node.t, 'accum) Container.fold
  (** fold over all successors (normal and exceptional) *)

  val fold_preds : t -> (Node.t, Node.t, 'accum) Container.fold
  (** fold over all predecessors (normal and exceptional) *)

  val fold_normal_succs : t -> (Node.t, Node.t, 'accum) Container.fold
  (** fold over non-exceptional successors *)

  val fold_normal_preds : t -> (Node.t, Node.t, 'accum) Container.fold
  (** fold over non-exceptional predecessors *)

  val fold_exceptional_succs : t -> (Node.t, Node.t, 'accum) Container.fold
  (** fold over exceptional successors *)

  val fold_exceptional_preds : t -> (Node.t, Node.t, 'accum) Container.fold
  (** fold over exceptional predescessors *)

  val start_node : t -> Node.t

  val exit_node : t -> Node.t

  val proc_desc : t -> Procdesc.t

  val fold_nodes : (t, Node.t, 'accum) Container.fold

  val from_pdesc : Procdesc.t -> t

  val is_loop_head : Procdesc.t -> Node.t -> bool
end

module DefaultNode : Node with type t = Procdesc.Node.t and type id = Procdesc.Node.id

module InstrNode : sig
  type instr_index

  include Node
          with type t = Procdesc.Node.t * instr_index
           and type id = Procdesc.Node.id * instr_index
end

(** Forward CFG with no exceptional control-flow *)
module Normal : S with type t = Procdesc.t and module Node = DefaultNode

(** Forward CFG with exceptional control-flow *)
module Exceptional :
  S with type t = Procdesc.t * DefaultNode.t list Procdesc.IdMap.t and module Node = DefaultNode

(** Wrapper that reverses the direction of the CFG *)
module Backward (Base : S) : S with type t = Base.t and module Node = Base.Node

module OneInstrPerNode (Base : S with module Node = DefaultNode) :
  S with type t = Base.t and module Node = InstrNode

module NormalOneInstrPerNode : module type of OneInstrPerNode (Normal)
