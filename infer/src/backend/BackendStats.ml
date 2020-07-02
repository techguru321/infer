(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format
module L = Logging

include struct
  (* ignore dead modules added by @@deriving fields *)
  [@@@warning "-60"]

  type t =
    { mutable summary_file_try_load: int
    ; mutable summary_read_from_disk: int
    ; mutable summary_cache_hits: int
    ; mutable summary_cache_misses: int
    ; mutable ondemand_procs_analyzed: int
    ; mutable ondemand_local_cache_hits: int
    ; mutable ondemand_local_cache_misses: int
    ; mutable proc_locker_lock_time: ExecutionDuration.t
    ; mutable proc_locker_unlock_time: ExecutionDuration.t
    ; mutable restart_scheduler_useful_time: ExecutionDuration.t
    ; mutable restart_scheduler_total_time: ExecutionDuration.t }
  [@@deriving fields]
end

let global_stats =
  { summary_file_try_load= 0
  ; summary_read_from_disk= 0
  ; summary_cache_hits= 0
  ; summary_cache_misses= 0
  ; ondemand_procs_analyzed= 0
  ; ondemand_local_cache_hits= 0
  ; ondemand_local_cache_misses= 0
  ; proc_locker_lock_time= ExecutionDuration.zero
  ; proc_locker_unlock_time= ExecutionDuration.zero
  ; restart_scheduler_useful_time= ExecutionDuration.zero
  ; restart_scheduler_total_time= ExecutionDuration.zero }


let get () = global_stats

let update_with field ~f =
  match Field.setter field with
  | None ->
      L.die InternalError "incr on non-mutable field %s" (Field.name field)
  | Some set ->
      set global_stats (f (Field.get field global_stats))


let incr field = update_with field ~f:(( + ) 1)

let add field exe_duration = update_with field ~f:(ExecutionDuration.add exe_duration)

let incr_summary_file_try_load () = incr Fields.summary_file_try_load

let incr_summary_read_from_disk () = incr Fields.summary_read_from_disk

let incr_summary_cache_hits () = incr Fields.summary_cache_hits

let incr_summary_cache_misses () = incr Fields.summary_cache_misses

let incr_ondemand_procs_analyzed () = incr Fields.ondemand_procs_analyzed

let incr_ondemand_local_cache_hits () = incr Fields.ondemand_local_cache_hits

let incr_ondemand_local_cache_misses () = incr Fields.ondemand_local_cache_misses

let add_to_proc_locker_lock_time execution_duration =
  add Fields.proc_locker_lock_time execution_duration


let add_to_proc_locker_unlock_time execution_duration =
  add Fields.proc_locker_unlock_time execution_duration


let add_to_restart_scheduler_useful_time execution_duration =
  add Fields.restart_scheduler_useful_time execution_duration


let add_to_restart_scheduler_total_time execution_duration =
  add Fields.restart_scheduler_total_time execution_duration


let copy from ~into : unit =
  let { summary_file_try_load
      ; summary_read_from_disk
      ; summary_cache_hits
      ; summary_cache_misses
      ; ondemand_procs_analyzed
      ; ondemand_local_cache_hits
      ; ondemand_local_cache_misses
      ; proc_locker_lock_time
      ; proc_locker_unlock_time
      ; restart_scheduler_useful_time
      ; restart_scheduler_total_time } =
    from
  in
  Fields.Direct.set_all_mutable_fields into ~summary_file_try_load ~summary_read_from_disk
    ~summary_cache_hits ~summary_cache_misses ~ondemand_procs_analyzed ~ondemand_local_cache_hits
    ~ondemand_local_cache_misses ~proc_locker_lock_time ~proc_locker_unlock_time
    ~restart_scheduler_useful_time ~restart_scheduler_total_time


let merge stats1 stats2 =
  { summary_file_try_load= stats1.summary_file_try_load + stats2.summary_file_try_load
  ; summary_read_from_disk= stats1.summary_read_from_disk + stats2.summary_read_from_disk
  ; summary_cache_hits= stats1.summary_cache_hits + stats2.summary_cache_hits
  ; summary_cache_misses= stats1.summary_cache_misses + stats2.summary_cache_misses
  ; ondemand_procs_analyzed= stats1.ondemand_procs_analyzed + stats2.ondemand_procs_analyzed
  ; ondemand_local_cache_hits= stats1.ondemand_local_cache_hits + stats2.ondemand_local_cache_hits
  ; ondemand_local_cache_misses=
      stats1.ondemand_local_cache_misses + stats2.ondemand_local_cache_misses
  ; proc_locker_lock_time=
      ExecutionDuration.add stats1.proc_locker_lock_time stats2.proc_locker_lock_time
  ; proc_locker_unlock_time=
      ExecutionDuration.add stats1.proc_locker_unlock_time stats2.proc_locker_unlock_time
  ; restart_scheduler_useful_time=
      ExecutionDuration.add stats1.restart_scheduler_useful_time
        stats2.restart_scheduler_useful_time
  ; restart_scheduler_total_time=
      ExecutionDuration.add stats1.restart_scheduler_total_time stats2.restart_scheduler_total_time
  }


let initial =
  { summary_file_try_load= 0
  ; summary_read_from_disk= 0
  ; summary_cache_hits= 0
  ; summary_cache_misses= 0
  ; ondemand_procs_analyzed= 0
  ; ondemand_local_cache_hits= 0
  ; ondemand_local_cache_misses= 0
  ; proc_locker_lock_time= ExecutionDuration.zero
  ; proc_locker_unlock_time= ExecutionDuration.zero
  ; restart_scheduler_useful_time= ExecutionDuration.zero
  ; restart_scheduler_total_time= ExecutionDuration.zero }


let reset () = copy initial ~into:global_stats

let pp f stats =
  let pp_hit_percent hit miss f =
    let total = hit + miss in
    if Int.equal total 0 then F.pp_print_string f "N/A%%" else F.fprintf f "%d%%" (hit * 100 / total)
  in
  let pp_int_field stats f field =
    F.fprintf f "%s= %d@;" (Field.name field) (Field.get field stats)
  in
  let pp_execution_duration_field stats f field =
    let field_value = Field.get field stats in
    let field_name = Field.name field in
    F.fprintf f "%a@;" (ExecutionDuration.pp ~prefix:field_name) field_value
  in
  let pp_cache_hits stats cache_misses f cache_hits_field =
    let cache_hits = Field.get cache_hits_field stats in
    F.fprintf f "%s= %d (%t)@;" (Field.name cache_hits_field) cache_hits
      (pp_hit_percent cache_hits cache_misses)
  in
  let pp_stats stats f =
    Fields.iter ~summary_file_try_load:(pp_int_field stats f)
      ~summary_read_from_disk:(pp_int_field stats f)
      ~summary_cache_hits:(pp_cache_hits stats stats.summary_cache_misses f)
      ~summary_cache_misses:(pp_int_field stats f) ~ondemand_procs_analyzed:(pp_int_field stats f)
      ~ondemand_local_cache_hits:(pp_cache_hits stats stats.ondemand_local_cache_misses f)
      ~ondemand_local_cache_misses:(pp_int_field stats f)
      ~proc_locker_lock_time:(pp_execution_duration_field stats f)
      ~proc_locker_unlock_time:(pp_execution_duration_field stats f)
      ~restart_scheduler_useful_time:(pp_execution_duration_field stats f)
      ~restart_scheduler_total_time:(pp_execution_duration_field stats f)
  in
  F.fprintf f "@[Backend stats:@\n@[<v2>  %t@]@]@." (pp_stats stats)


let log_to_scuba stats =
  let create_counter field =
    [LogEntry.mk_count ~label:("backend_stats." ^ Field.name field) ~value:(Field.get field stats)]
  in
  let create_time_entry field =
    Field.get field stats
    |> ExecutionDuration.to_scuba_entries ~prefix:("backend_stats." ^ Field.name field)
  in
  let entries =
    Fields.to_list ~summary_file_try_load:create_counter ~summary_read_from_disk:create_counter
      ~summary_cache_hits:create_counter ~summary_cache_misses:create_counter
      ~ondemand_procs_analyzed:create_counter ~ondemand_local_cache_hits:create_counter
      ~ondemand_local_cache_misses:create_counter ~proc_locker_lock_time:create_time_entry
      ~proc_locker_unlock_time:create_time_entry ~restart_scheduler_useful_time:create_time_entry
      ~restart_scheduler_total_time:create_time_entry
    |> List.concat
  in
  ScubaLogging.log_many entries


let log_aggregate stats_list =
  match stats_list with
  | [] ->
      L.internal_error "Empty list of backend stats to aggregate, weird!@\n"
  | one :: rest ->
      let stats = List.fold rest ~init:one ~f:(fun aggregate one -> merge aggregate one) in
      L.debug Analysis Quiet "%a" pp stats ;
      log_to_scuba stats
