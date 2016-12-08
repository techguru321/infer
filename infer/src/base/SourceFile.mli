(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

type t [@@deriving compare]

(** equality of source files *)
val equal : t -> t -> bool

(** Maps from source_file *)
module Map : Map.S with type key = t

(** Set of source files *)
module Set : Set.S with type elt = t

(** compute line count of a source file *)
val line_count : t -> int

(** empty source file *)
val empty : t

(** create source file from absolute path *)
val from_abs_path : string -> t

(** string encoding of a source file (including path) as a single filename *)
val encoding : t -> string

(** convert a source file to a string
    WARNING: result may not be valid file path, do not use this function to perform operations
             on filenames *)
val to_string : t -> string

(** pretty print t *)
val pp : Format.formatter -> t -> unit

(** get the full path of a source file *)
val to_abs_path : t -> string

(** get the relative path of a source file *)
val to_rel_path : t -> string

val is_infer_model : t -> bool

(** Returns true if the file is a C++ model *)
val is_cpp_model : t -> bool

(** Returns true if the file is in project root *)
val is_under_project_root : t -> bool

(** Return approximate source file corresponding to the parameter if it's header file and
    file exists. returns None otherwise *)
val of_header : t -> t option

(** Set of files read from --changed-files-index file, None if option not specified
    NOTE: it may include extra source_files if --changed-files-index contains paths to
          header files *)
val changed_files_set : Set.t option
