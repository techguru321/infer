(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

(** Module for on-demand analysis. *)

type analyze_ondemand = Summary.t -> Procdesc.t -> Summary.t

type get_proc_desc = Typ.Procname.t -> Procdesc.t option

type callbacks = {analyze_ondemand: analyze_ondemand; get_proc_desc: get_proc_desc}

val get_proc_desc : get_proc_desc
(** Find a proc desc for the procedure, perhaps loading it from disk. *)

val analyze_proc_desc : caller_pdesc:Procdesc.t -> Procdesc.t -> Summary.t option
(** [analyze_proc_desc ~caller_pdesc callee_pdesc] performs an on-demand analysis of callee_pdesc
   triggered during the analysis of caller_pdesc *)

val analyze_proc_name : ?caller_pdesc:Procdesc.t -> Typ.Procname.t -> Summary.t option
(** [analyze_proc_name ~caller_pdesc proc_name] performs an on-demand analysis of proc_name
   triggered during the analysis of caller_pdesc *)

val set_callbacks : callbacks -> unit
(** Set the callbacks used to perform on-demand analysis. *)

val unset_callbacks : unit -> unit
(** Unset the callbacks used to perform on-demand analysis. *)
