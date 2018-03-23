(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

type t

type compilation_data =
  { directory: string
  ; executable: string
  ; escaped_arguments: string list
        (** argument list, where each argument is already escaped for the shell. This is because in
            some cases the argument list contains arguments that are actually themselves a list of
            arguments, for instance because the compilation database only contains a "command"
            entry. *)
  }

val filter_compilation_data : t -> f:(SourceFile.t -> bool) -> compilation_data list

val from_json_files : [< `Escaped of string | `Raw of string] list -> t
