(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

module F = Format

(** Control-flow graph for a single procedure (as opposed to cfg.ml, which represents a cfg for a
    file). Defines useful wrappers that allows us to do tricks like turn a forward cfg into a
    backward one, or view a cfg as having a single instruction per node. *)

module type Node = sig
  type t
  type id

  val instrs : t -> Sil.instr list
  val kind : t -> Cfg.Node.nodekind
  val id : t -> id
  val id_compare : id -> id -> int
  val pp_id : F.formatter -> id -> unit
end

module DefaultNode = struct
  type t = Cfg.Node.t
  type id = Cfg.Node.id

  let instrs = Cfg.Node.get_instrs
  let kind = Cfg.Node.get_kind
  let id = Cfg.Node.get_id
  let id_compare = Cfg.Node.id_compare
  let pp_id = Cfg.Node.pp_id
end

module type S = sig
  type t
  type node
  include (Node with type t := node)

  val succs : t -> node -> node list
  (** all predecessors (normal and exceptional) *)
  val preds : t -> node -> node list
  (** non-exceptional successors *)
  val normal_succs : t -> node -> node list
  (** non-exceptional predecessors *)
  val normal_preds : t -> node -> node list
  (** exceptional successors *)
  val exceptional_succs : t -> node -> node list
  (** exceptional predescessors *)
  val exceptional_preds : t -> node -> node list
  val start_node : t -> node
  val exit_node : t -> node
  val proc_desc : t -> Cfg.Procdesc.t
  val nodes : t -> node list
  val from_pdesc : Cfg.Procdesc.t -> t
end

(** Forward CFG with no exceptional control-flow *)
module Normal = struct
  type t = Cfg.Procdesc.t
  type node = DefaultNode.t
  include (DefaultNode : module type of DefaultNode with type t := node)

  let normal_succs _ n = Cfg.Node.get_succs n
  let normal_preds _ n = Cfg.Node.get_preds n
  (* prune away exceptional control flow *)
  let exceptional_succs _ _ = []
  let exceptional_preds _ _ = []
  let succs = normal_succs
  let preds = normal_preds
  let start_node = Cfg.Procdesc.get_start_node
  let exit_node = Cfg.Procdesc.get_exit_node
  let proc_desc t = t
  let nodes = Cfg.Procdesc.get_nodes
  let from_pdesc pdesc = pdesc
end

(** Forward CFG with exceptional control-flow *)
module Exceptional = struct
  type node = DefaultNode.t
  type id_node_map = node list Cfg.IdMap.t
  type t = Cfg.Procdesc.t * id_node_map
  include (DefaultNode : module type of DefaultNode with type t := node)

  let from_pdesc pdesc =
    (* map from a node to its exceptional predecessors *)
    let add_exn_preds exn_preds_acc n =
      let add_exn_pred exn_preds_acc exn_succ_node =
        let exn_succ_node_id = Cfg.Node.get_id exn_succ_node in
        let existing_exn_preds =
          try Cfg.IdMap.find exn_succ_node_id exn_preds_acc
          with Not_found -> [] in
        if not (IList.mem Cfg.Node.equal n existing_exn_preds)
        then (* don't add duplicates *)
          Cfg.IdMap.add exn_succ_node_id (n :: existing_exn_preds) exn_preds_acc
        else
          exn_preds_acc in
      IList.fold_left add_exn_pred exn_preds_acc (Cfg.Node.get_exn n) in
    let exceptional_preds =
      IList.fold_left add_exn_preds Cfg.IdMap.empty (Cfg.Procdesc.get_nodes pdesc) in
    pdesc, exceptional_preds

  let nodes (t, _) = Cfg.Procdesc.get_nodes t

  let normal_succs _ n = Cfg.Node.get_succs n

  let normal_preds _ n = Cfg.Node.get_preds n

  let exceptional_succs _ n = Cfg.Node.get_exn n

  let exceptional_preds (_, exn_pred_map) n =
    try Cfg.IdMap.find (Cfg.Node.get_id n) exn_pred_map
    with Not_found -> []

  (** get all normal and exceptional successors of [n]. *)
  let succs t n =
    let normal_succs = normal_succs t n in
    match exceptional_succs t n with
    | [] ->
        normal_succs
    | exceptional_succs ->
        normal_succs @ exceptional_succs
        |> IList.sort Cfg.Node.compare
        |> IList.remove_duplicates Cfg.Node.compare

  (** get all normal and exceptional predecessors of [n]. *)
  let preds t n =
    let normal_preds = normal_preds t n in
    match exceptional_preds t n with
    | [] ->
        normal_preds
    | exceptional_preds ->
        normal_preds @ exceptional_preds
        |> IList.sort Cfg.Node.compare
        |> IList.remove_duplicates Cfg.Node.compare

  let proc_desc (pdesc, _) = pdesc
  let start_node (pdesc, _) = Cfg.Procdesc.get_start_node pdesc
  let exit_node (pdesc, _) = Cfg.Procdesc.get_exit_node pdesc
end

(** Wrapper that reverses the direction of the CFG *)
module Backward (Base : S) = struct
  include Base
  let instrs n = IList.rev (Base.instrs n)

  let succs = Base.preds
  let preds = Base.succs
  let start_node = Base.exit_node
  let exit_node = Base.start_node
  let normal_succs = Base.normal_preds
  let normal_preds = Base.normal_succs
  let exceptional_succs = Base.exceptional_preds
  let exceptional_preds = Base.exceptional_succs
end

module NodeIdMap (CFG : S) = Map.Make(struct
    type t = CFG.id
    let compare = CFG.id_compare
  end)

module NodeIdSet (CFG : S) = Set.Make(struct
    type t = CFG.id
    let compare = CFG.id_compare
  end)
