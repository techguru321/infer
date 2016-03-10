(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** Module for on-demand analysis. *)

(** Optional set of source dirs to analyze in on-demand mode. *)
val dirs_to_analyze : StringSet.t option Lazy.t

type analyze_ondemand = Cfg.Procdesc.t -> unit

type get_cfg = Procname.t -> Cfg.cfg option

type get_proc_desc = Procname.t -> Cfg.Procdesc.t option

type callbacks =
  {
    analyze_ondemand : analyze_ondemand;
    get_cfg : get_cfg;
    get_proc_desc : get_proc_desc;
  }

(** Find a cfg for the procedure, perhaps loading it from disk. *)
val get_cfg : get_cfg

(** analyze_proc_desc curr_pdesc callee_pdesc
    performs an on-demand analysis of callee_pdesc
    triggered during the analysis of curr_pdesc. *)
val analyze_proc_desc : propagate_exceptions:bool -> Cfg.Procdesc.t -> Cfg.Procdesc.t -> unit

(** analyze_proc_name curr_pdesc proc_name
    performs an on-demand analysis of proc_name
    triggered during the analysis of curr_pdesc. *)
val analyze_proc_name : propagate_exceptions:bool -> Cfg.Procdesc.t -> Procname.t -> unit

(** Check if the procedure called needs to be analyzed. *)
val procedure_should_be_analyzed : Procname.t -> bool

(** Set the callbacks used to perform on-demand analysis. *)
val set_callbacks : callbacks -> unit

(** Unset the callbacks used to perform on-demand analysis. *)
val unset_callbacks : unit -> unit
