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

(** Control Flow Graph for Interprocedural Analysis *)

(** A control-flow graph is a collection of all the CFGs for the procedure names in a file *)
type t = Procdesc.t Typ.Procname.Hash.t

val load : SourceFile.t -> t option
(** Load the cfgs of the procedures of a source file *)

val store : SourceFile.t -> t -> unit
(** Save a cfg into the database *)

val get_all_proc_names : t -> Typ.Procname.t list
(** get all the keys from the hashtable *)

(** {2 Functions for manipulating an interprocedural CFG} *)

val create : unit -> t
(** create a new empty cfg *)

val create_proc_desc : t -> ProcAttributes.t -> Procdesc.t
(** Create a new procdesc and add it to the cfg *)

val iter_all_nodes : ?sorted:bool -> (Procdesc.t -> Procdesc.Node.t -> unit) -> t -> unit
(** Iterate over all the nodes in the cfg *)

val check_cfg_connectedness : t -> unit
(** checks whether a cfg is connected or not *)

val pp_proc_signatures : Format.formatter -> t -> unit
