(*
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

(** Database of analysis results *)

(** {2 Filename} *)

(** generic file name *)
type filename [@@deriving compare]

module FilenameSet : Set.S with type elt = filename
module FilenameMap : Map.S with type key = filename

val filename_from_string : string -> filename
val filename_to_string : filename -> string
val chop_extension : filename -> filename
val filename_concat : filename -> string -> filename
val filename_add_suffix : filename -> string -> filename
val file_exists : filename -> bool
val file_remove : filename -> unit

(** Return the time when a file was last modified. The file must exist. *)
val file_modified_time : ?symlink:bool -> filename -> float

(** Mark a file as updated by changing its timestamps to be one second in the future.
    This guarantees that it appears updated after start. *)
val mark_file_updated : string -> unit

(** Return whether filename was updated after analysis started. File doesn't have to exist *)
val file_was_updated_after_start : filename -> bool

type source_file [@@deriving compare]

(** equality of source files *)
val equal_source_file : source_file -> source_file -> bool

(** {2 Results Directory} *)

module Results_dir : sig
  (** path expressed as a list of strings *)
  type path = string list

  (** kind of path: specifies how to interpret a path *)
  type path_kind =
    | Abs_root
    (** absolute path implicitly rooted at the root of the results dir *)
    | Abs_source_dir of source_file
    (** absolute path implicitly rooted at the source directory for the file *)
    | Rel
    (** relative path *)

  (** convert a path to a filename *)
  val path_to_filename : path_kind -> path -> filename

  (** directory of spec files *)
  val specs_dir : filename

  (** Initialize the results directory *)
  val init : source_file -> unit

  (** Clean up specs directory *)
  val clean_specs_dir : unit -> unit

  (** create a file at the given path, creating any missing directories *)
  val create_file : path_kind -> path -> Unix.file_descr
end

(** origin of a analysis artifact: current results dir, a spec library, or models *)
type origin =
  | Res_dir
  | Spec_lib
  | Models

(** {2 Source Files} *)

(** Maps from source_file *)
module SourceFileMap : Map.S with type key = source_file

(** Set of source files *)
module SourceFileSet : Set.S with type elt = source_file

(** compute line count of a source file *)
val source_file_line_count : source_file -> int

(** empty source file *)
val source_file_empty : source_file

(** create source file from absolute path *)
val source_file_from_abs_path : string -> source_file

(** string encoding of a source file (including path) as a single filename *)
val source_file_encoding : source_file -> string

(** convert a source file to a string
    WARNING: result may not be valid file path, do not use this function to perform operations
             on filenames *)
val source_file_to_string : source_file -> string

(** pretty print source_file *)
val source_file_pp : Format.formatter -> source_file -> unit

(** get the full path of a source file *)
val source_file_to_abs_path : source_file -> string

(** get the relative path of a source file *)
val source_file_to_rel_path : source_file -> string

val source_file_is_infer_model : source_file -> bool

(** Returns true if the file is a C++ model *)
val source_file_is_cpp_model : source_file -> bool

(** Returns true if the file is in project root *)
val source_file_is_under_project_root : source_file -> bool

(** Return approximate source file corresponding to the parameter if it's header file and
    file exists. returns None otherwise *)
val source_file_of_header : source_file -> source_file option

(** Set of files read from --changed-files-index file, None if option not specified
    NOTE: it may include extra source_files if --changed-files-index contains paths to
          header files *)
val changed_source_files_set : SourceFileSet.t option

(** {2 Source Dirs} *)

(** source directory: the directory inside the results dir corresponding to a source file *)
type source_dir [@@deriving compare]

(** expose the source dir as a string *)
val source_dir_to_string : source_dir -> string

(** get the path to an internal file with the given extention (.cfg, .cg, .tenv) *)
val source_dir_get_internal_file : source_dir -> string -> filename

(** get the source directory corresponding to a source file *)
val source_dir_from_source_file : source_file -> source_dir

(** directory where the results of the capture phase are stored *)
val captured_dir : filename

(** create the directory containing the file bane *)
val filename_create_dir : filename -> unit

(** Find the source directories in the current results dir *)
val find_source_dirs : unit -> source_dir list

(** Read a file using a lock to allow write attempts in parallel. *)
val read_file_with_lock : string -> string -> bytes option

(** Update the file contents with the update function provided.
    If the directory does not exist, it is created.
    If the file does not exist, it is created, and update is given the empty string.
    A lock is used to allow write attempts in parallel. *)
val update_file_with_lock : string -> string -> (bytes -> bytes) -> unit

(** get the path of the global type environment (only used in Java) *)
val global_tenv_fname : filename

(** Check if a path is a Java, C, C++ or Objectve C source file according to the file extention *)
val is_source_file: string -> bool

(** Fold over all file paths recursively under [dir] which match [p]. *)
val fold_paths_matching :
  dir:filename -> p:(filename -> bool) -> init:'a -> f:(filename -> 'a -> 'a) -> 'a

(** Return all file paths recursively under the given directory which match the given predicate *)
val paths_matching : string -> (string -> bool) -> string list
