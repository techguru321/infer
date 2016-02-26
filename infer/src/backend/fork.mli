(*
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** Implementation of the Interprocedural Footprint Analysis Algorithm *)

val procs_become_done : Cg.t -> Procname.t -> Procname.t list

val post_process_procs : Exe_env.t -> Procname.t list -> unit

(** Return the list of procedures which should perform a phase
    transition from [FOOTPRINT] to [RE_EXECUTION] *)
val should_perform_transition : Cg.t -> Procname.t -> Procname.t list

(** Perform the transition from [FOOTPRINT] to [RE_EXECUTION] in spec table *)
val transition_footprint_re_exe : Procname.t -> Prop.normal Specs.Jprop.t list -> unit

(** Update the specs of the current proc after the execution of one phase *)
val update_specs :
  Procname.t -> Specs.phase -> Specs.NormSpec.t list -> Specs.NormSpec.t list * bool

type analyze_proc = Exe_env.t -> Procname.t -> Specs.summary

type process_result = Exe_env.t -> (Procname.t * Cg.in_out_calls) -> Specs.summary -> unit

(** Execute [analyze_proc] respecting dependencies between procedures,
    and apply [process_result] to the result of the analysis. *)
val interprocedural_algorithm : Exe_env.t -> analyze_proc -> process_result -> unit
