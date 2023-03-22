(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

(** ['a state_store] is a piece of global state of type ['a] encapsulated via the interface offered
    by the functions in the record *)
type 'a state_store = {init: Procname.t -> unit; save: unit -> 'a; restore: 'a -> unit}

(** a GADT to hold pieces of global state with heterogenous types in a list *)
type sealed_state_store = StateManager : 'a state_store -> sealed_state_store

(** list of all the pieces of global state we know about *)
let stores : sealed_state_store list ref = ref []

let register_with_proc_name ~init ~save ~restore =
  stores := StateManager {init; save; restore} :: !stores


let register ~init ~save ~restore =
  register_with_proc_name ~save ~restore ~init:(fun _proc_name -> init ())


let register_ref ~init ref_ =
  stores :=
    StateManager
      {save= (fun () -> !ref_); restore= (fun x -> ref_ := x); init= (fun _ -> ref_ := init ())}
    :: !stores


(** intermediate datatype to hold saved pieces of state in a heterogenously-typed list, see [save] *)
type saved_state = Saved : 'a * ('a -> unit) -> saved_state

(** for the .mli *)
type t = saved_state list

let save () =
  List.map !stores ~f:(function StateManager {save; restore} ->
      (* more GADT trickery: each element of the list is the saved state + the function to call to
         restore that piece of global state in [restore] below *)
      Saved (save (), restore) )


let restore saved_states = List.iter saved_states ~f:(function Saved (x, restore) -> restore x)

let initialize proc_name = List.iter !stores ~f:(function StateManager {init} -> init proc_name)
