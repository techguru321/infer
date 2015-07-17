(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(** Specifications and spec table *)

open Utils

(** {2 Spec Tables} *)

(** Module for joined props: the result of joining together propositions repeatedly *)
module Jprop : sig
(** Remember when a prop is obtained as the join of two other props; the first parameter is an id *)
  type 'a t =
    | Prop of int * 'a Prop.t
    | Joined of int * 'a Prop.t * 'a t * 'a t

  (** Comparison for joined_prop *)
  val compare : 'a t -> 'a t -> int

  (** Dump the toplevel prop *)
  val d_shallow : Prop.normal t -> unit

  (** dump a joined prop list, the boolean indicates whether to print toplevel props only *)
  val d_list : bool -> Prop.normal t list -> unit

  (** Return true if the two join_prop's are equal *)
  val equal : 'a t -> 'a t -> bool

  (** Add fav to a jprop *)
  val fav_add : Sil.fav -> 'a t -> unit

  (** [jprop_filter filter joinedprops] applies [filter] to the elements
  of [joindeprops] and applies it to the subparts if the result is
  [None]. Returns the most absract results which pass [filter]. *)
  val filter : ('a t -> 'b option) -> 'a t list -> 'b list

  (** apply a substitution to a jprop *)
  val jprop_sub : Sil.subst -> Prop.normal t -> Prop.exposed t

  (** map the function to each prop in the jprop, pointwise *)
  val map : ('a Prop.t -> 'b Prop.t) -> 'a t -> 'b t

  (** Print a list of joined props, the boolean indicates whether to print subcomponents of joined props *)
  val pp_list : printenv -> bool -> Format.formatter -> Prop.normal t list -> unit

  (** Print the toplevel prop *)
  val pp_short : printenv -> Format.formatter -> Prop.normal t -> unit

  (** Extract the number associated to the toplevel jprop of a prop *)
  val to_number : 'a t -> int

  (** Extract the toplevel jprop of a prop *)
  val to_prop : 'a t -> 'a Prop.t
end

(** set of visited nodes: node id and list of lines of all the instructions *)
module Visitedset : Set.S with type elt = int * int list

(** convert a Visitedset to a string *)
val visited_str : Visitedset.t -> string

(** A spec consists of:
pre: a joined prop
posts: a list of props with path
visited: a list of pairs (node_id, line) for the visited nodes *)
type 'a spec = { pre: 'a Jprop.t; posts: ('a Prop.t * Paths.Path.t) list; visited : Visitedset.t }

module NormSpec : sig (* encapsulate type for normalized specs *)
  type t
end

module CallStats : (** module for tracing stats of function calls *)
sig
  type t

  type call_result = (** kind of result of a procedure call *)
    | CR_success (** successful call *)
    | CR_not_met (** precondition not met *)
    | CR_not_found (** the callee has no specs *)
    | CR_skip (** the callee was skipped *)

  (** trace of an occurrence of function call *)
  type trace = (call_result * bool) list

  (** iterate over results of procedure calls *)
  val iter : (Procname.t * Sil.location -> trace -> unit) -> t -> unit

  (** trace a procedure call *)
  val trace : t -> Procname.t -> Sil.location -> call_result -> bool -> unit

  (** pretty print a call trace *)
  val pp_trace : Format.formatter -> trace -> unit
end

(** Execution statistics *)
type stats =
  { stats_time: float; (** Analysis time for the procedure *)
    stats_timeout: bool; (** Flag to indicate whether a timeout occurred *)
    stats_calls: Cg.in_out_calls; (** num of procs calling, and called *)
    symops: int; (** Number of SymOp's throughout the whole analysis of the function *)
    err_log: Errlog.t; (** Error log for the procedure *)
    mutable nodes_visited_fp : IntSet.t; (** Nodes visited during the footprint phase *)
    mutable nodes_visited_re : IntSet.t; (** Nodes visited during the re-execution phase *)
    call_stats : CallStats.t;
    cyclomatic : int;
  }

type status = ACTIVE | INACTIVE

type phase = FOOTPRINT | RE_EXECUTION

type dependency_map_t = int Procname.Map.t

(** Payload: results of some analysis *)
type payload =
  | PrePosts of NormSpec.t list (** list of specs *)
  | TypeState of unit TypeState.t option (** final typestate *)

(** Procedure summary *)
type summary =
  { dependency_map: dependency_map_t;  (** maps children procs to timestamp as last seen at the start of an analysys phase for this proc *)
    loc: Sil.location; (** original file and line number *)
    nodes: int list; (** ids of cfg nodes of the procedure *)
    ret_type : Sil.typ; (** type of the return parameter *)
    formals : (string * Sil.typ) list; (** name and type of the formal parameters of the procedure *)
    phase: phase; (** in FOOTPRINT phase or in RE_EXECUTION PHASE *)
    proc_name : Procname.t; (** name of the procedure *)
    proc_flags : proc_flags; (** flags of the procedure *)
    payload: payload;  (** payload containing the result of some analysis *)
    sessions: int ref; (** Session number: how many nodes went trough symbolic execution *)
    stats: stats;  (** statistics: execution time and list of errors *)
    status: status; (** ACTIVE when the proc is being analyzed *)
    timestamp: int; (** Timestamp of the specs, >= 0, increased every time the specs change *)
    attributes : Sil.proc_attributes; (** Attributes of the procedure *)
  }

(** origin of a summary: current results dir, a spec library, or models *)
type origin =
  | Res_dir
  | Spec_lib
  | Models

(** Add the summary to the table for the given function *)
val add_summary : Procname.t -> summary -> unit

(** Check if a summary for a given procedure exists in the results directory *)
val summary_exists : Procname.t -> bool

(** Check if a summary for a given procedure exists in the models directory *)
val summary_exists_in_models : Procname.t -> bool

(** remove all the elements from the spec table *)
val clear_spec_tbl : unit -> unit

(** Dump a spec *)
val d_spec : 'a spec -> unit

(** Get the procedure name *)
val get_proc_name : summary -> Procname.t

(** Get the attributes of the procedure. *)
val get_attributes : summary -> Sil.proc_attributes

(** Get the return type of the procedure *)
val get_ret_type : summary -> Sil.typ

(** Get the formal paramters of the procedure *)
val get_formals : summary -> (string * Sil.typ) list

(** Get the flag with the given key for the procedure, if any *)
val get_flag : Procname.t -> string -> string option

(** Get the iterations associated to the procedure if any, or the default timeout from the command line *)
val get_iterations : Procname.t -> int

(** Return the current phase for the proc *)
val get_phase : Procname.t -> phase

(** Return the origin of the spec file *)
val get_origin: Procname.t -> origin

(** Return the signature of a procedure declaration as a string *)
val get_signature : summary -> string

(** Return the specs for the proc in the spec table *)
val get_specs : Procname.t -> Prop.normal spec list

(** Return the specs and formal parameters for the proc in the spec table *)
val get_specs_formals : Procname.t -> Prop.normal spec list * (string * Sil.typ) list

(** Get the specs from the payload of the summary. *)
val get_specs_from_payload : summary -> Prop.normal spec list

(** Return the summary option for the procedure name *)
val get_summary : Procname.t -> summary option

(** @deprecated Return the summary for the procedure name. Raises an exception when not found. *)
val get_summary_unsafe : Procname.t -> summary

(** Return the current timestamp for the summary *)
val get_timestamp : summary -> int

(** Return the status (active v.s. inactive) of a procedure summary *)
val get_status : summary -> status

(** Check if the procedure is active *)
val is_active : Procname.t -> bool

(** Check if the procedure is active *)
val is_inactive : Procname.t -> bool

(** Initialize the summary for [proc_name] given dependent procs in list [depend_list].
Do nothing if a summary exists already. *)
val init_summary :
(Procname.t * (** proc_name *)
Sil.typ * (** ret type *)
(string * Sil.typ) list * (** formals *)
Procname.t list * (** depend list *)
Sil.location * (** loc *)
int list * (** nodes *)
proc_flags * (** procedure flags *)
Errlog.t * (** initial error log *)
(Procname.t * Sil.location) list * (** calls *)
int * (** cyclomatic *)
(Cg.in_out_calls option) * (** in and out calls *)
Sil.proc_attributes) (** attributes of the procedure *)
-> unit

val reset_summary : Cg.t -> Procname.t -> Sil.location -> unit

(** Load procedure summary from the given file *)
val load_summary : DB.filename -> summary option

(** Check if a procedure summary exists for the given procedure name *)
val summary_exists : Procname.t -> bool

(** Cast a list of normalized specs to a list of specs *)
val normalized_specs_to_specs : NormSpec.t list -> Prop.normal spec list

(** Print the spec *)
val pp_spec : printenv -> (int * int) option -> Format.formatter -> Prop.normal spec -> unit

(** Print the spec table, the bool indicates whether to print whole seconds only *)
val pp_spec_table : printenv -> bool -> Format.formatter -> unit -> unit

(** Print the specs *)
val pp_specs : printenv -> Format.formatter -> Prop.normal spec list -> unit

(** Print the summary, the bool indicates whether to print whole seconds only *)
val pp_summary : printenv -> bool -> Format.formatter -> summary -> unit

(** Get the attributes of a procedure, looking first in the procdesc and then in the .specs file. *)
val proc_get_attributes : Procname.t -> Cfg.Procdesc.t -> Sil.proc_attributes

val proc_get_method_annotation : Procname.t -> Cfg.Procdesc.t -> Sil.method_annotation

(** Check if the procedure is from a library:
It's not defined in the current proc desc, and there is no spec file for it. *)
val proc_is_library : Procname.t -> Cfg.Procdesc.t -> bool

(** Re-initialize a dependency map *)
val re_initialize_dependency_map : dependency_map_t -> dependency_map_t

(** Set the current status for the proc *)
val set_status : Procname.t -> status -> unit

(** Convert spec into normal form w.r.t. variable renaming *)
val spec_normalize : Prop.normal spec -> NormSpec.t

(** path to the .specs file for the given procedure in the current results dir *)
val res_dir_specs_filename : Procname.t -> DB.filename

(** Save summary for the procedure into the spec database *)
val store_summary : Procname.t -> summary -> unit

(** Return a compact representation of the summary *)
val summary_compact : Sil.sharing_env -> summary -> summary

(** Update the dependency map of [proc_name] with the current
timestamps of the dependents *)
val update_dependency_map : Procname.t -> unit
