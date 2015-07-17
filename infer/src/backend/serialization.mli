(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(** Serialization of data stuctures *)

open Utils

(** Generic serializer *)
type 'a serializer

(** Serialization key, used to distinguish versions of serializers and avoid assert faults *)
type key

(** current key for tenv *)
val tenv_key : key

(** current key for a procedure summary *)
val summary_key : key

(** current key for a cfg *)
val cfg_key : key

(** current key for an error trace *)
val trace_key : key

(** current key for a call graph *)
val cg_key : key

(** current key for a cluster *)
val cluster_key : key

(** current key for an analysis results value *)
val analysis_results_key : key

(** create a serializer from a file name, given an integer key used as double-check of the file type *)
val create_serializer : key -> 'a serializer

(** extract a from_string function from a serializer *)
val from_string : 'a serializer -> string -> 'a option

(** extract a from_file function from a serializer *)
val from_file : 'a serializer -> DB.filename -> 'a option

(** extract a to_file function from a serializer *)
val to_file : 'a serializer -> DB.filename -> 'a -> unit
