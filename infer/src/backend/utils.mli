(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(** General utility functions *)

(** {2 Generic Utility Functions} *)

(** Compare police: generic compare disabled. *)
val compare : unit

(** Comparison for booleans *)
val bool_compare : bool -> bool -> int

(** Equality for booleans *)
val bool_equal : bool -> bool -> bool

(** Efficient comparison for integers *)
val int_compare : int -> int -> int

(** Equality for integers *)
val int_equal : int -> int -> bool

(** Extend and equality function to an option type. *)
val opt_equal : ('a -> 'a -> bool) -> 'a option -> 'a option -> bool

(** Generic comparison of pairs given a compare function for each element of the pair. *)
val pair_compare : ('a -> 'b -> int) -> ('c -> 'd -> int) -> ('a * 'c) -> ('b * 'd) -> int

(** Generic comparison of pairs given a compare function for each element of the triple. *)
val triple_compare : ('a -> 'b -> int) -> ('c -> 'd -> int) -> ('e -> 'f -> int) -> ('a * 'c * 'e) -> ('b * 'd * 'f) -> int

(** Generic comparison of lists given a compare function for the elements of the list *)
val list_compare : ('a -> 'b -> int) -> 'a list -> 'b list -> int

(** Comparison for strings *)
val string_compare : string -> string -> int

(** Equality for strings *)
val string_equal : string -> string -> bool

(** Comparison for floats *)
val float_compare : float -> float -> int

(** tail-recursive variant of List.append *)
val list_append : 'a list -> 'a list -> 'a list

(** tail-recursive variant of List.combine *)
val list_combine : 'a list -> 'b list -> ('a * 'b) list

val list_exists : ('a -> bool) -> 'a list -> bool
val list_filter : ('a -> bool) -> 'a list -> 'a list

(** tail-recursive variant of List.flatten *)
val list_flatten : 'a list list -> 'a list

(** Remove all None elements from the list. *)
val list_flatten_options : ('a option) list -> 'a list

val list_find : ('a -> bool) -> 'a list -> 'a
val list_fold_left : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a
val list_fold_left2 : ('a -> 'b -> 'c -> 'a) -> 'a -> 'b list -> 'c list -> 'a
val list_for_all : ('a -> bool) -> 'a list -> bool
val list_for_all2 : ('a -> 'b -> bool) -> 'a list -> 'b list -> bool
val list_hd : 'a list -> 'a
val list_iter : ('a -> unit) -> 'a list -> unit
val list_iter2 : ('a -> 'b -> unit) -> 'a list -> 'b list -> unit
val list_length : 'a list -> int

(** tail-recursive variant of List.fold_right *)
val list_fold_right : ('a -> 'b -> 'b) -> 'a list -> 'b -> 'b

(** tail-recursive variant of List.map *)
val list_map : ('a -> 'b) -> 'a list -> 'b list

(** Like List.mem but without builtin equality *)
val list_mem : ('a -> 'b -> bool) -> 'a -> 'b list -> bool

val list_nth : 'a list -> int -> 'a
val list_partition : ('a -> bool) -> 'a list -> 'a list * 'a list
val list_rev : 'a list -> 'a list
val list_rev_append : 'a list -> 'a list -> 'a list
val list_rev_map : ('a -> 'b) -> 'a list -> 'b list
val list_sort : ('a -> 'a -> int) -> 'a list -> 'a list

(** tail-recursive variant of List.split *)
val list_split : ('a * 'b) list -> 'a list * 'b list

val list_stable_sort : ('a -> 'a -> int) -> 'a list -> 'a list
val list_tl : 'a list -> 'a list

(* Drops the first n elements from a list. *)
val list_drop_first : int -> 'a list -> 'a list

(* Drops the last n elements from a list. *)
val list_drop_last : int -> 'a list -> 'a list

(** List police: don't use the list module to avoid non-tail-recursive functions and builtin equality *)
module List : sig end

(** Returns (reverse input_list)[@]acc *)
val list_rev_with_acc : 'a list -> 'a list -> 'a list

(** Remove consecutive equal elements from a list (according to the given comparison functions) *)
val list_remove_duplicates : ('a -> 'a -> int) -> 'a list -> 'a list

(** Remove consecutive equal irrelevant elements from a list (according to the given comparison and relevance functions) *)
val list_remove_irrelevant_duplicates : ('a -> 'a -> int) -> ('a -> bool) -> 'a list -> 'a list

(** The function works on sorted lists without duplicates *)
val list_merge_sorted_nodup : ('a -> 'a -> int) -> 'a list -> 'a list -> 'a list -> 'a list

(** Returns whether there is an intersection in the elements of the two lists.
The compare function is required to sort the lists. *)
val list_intersect : ('a -> 'a -> int) -> 'a list -> 'a list -> bool

exception Fail

(** Apply [f] to pairs of elements; raise [Fail] if the two lists have different lenghts. *)
val list_map2 : ('a -> 'b -> 'c) -> 'a list -> 'b list -> 'c list

val list_to_string : ('a -> string) -> 'a list -> string

(** {2 Useful Modules} *)

(** Set of integers *)
module IntSet : Set.S with type elt = int

(** Set of strings *)
module StringSet : Set.S with type elt = string

(** Pretty print a set of strings *)
val pp_stringset : Format.formatter -> StringSet.t -> unit

(** Maps from strings *)
module StringMap : Map.S with type key = string

(** {2 Printing} *)

(** Type of location in ml source: file,line,column *)
type ml_location = string * int * int

(** Turn an ml location into a string *)
val ml_location_string : ml_location -> string

(** Pretty print a location of ml source *)
val pp_ml_location_opt : Format.formatter -> ml_location option -> unit

(** Colors supported in printing *)
type color = Black | Blue | Green | Orange | Red

(** map subexpressions (as Obj.t element compared by physical equality) to colors *)
type colormap = Obj.t -> color

(** Kind of simple printing: default or with full types *)
type pp_simple_kind = PP_SIM_DEFAULT | PP_SIM_WITH_TYP

(** Kind of printing *)
type printkind = PP_TEXT | PP_LATEX | PP_HTML

(** Print environment threaded through all the printing functions *)
type printenv = {
  pe_opt : pp_simple_kind; (** Current option for simple printing *)
  pe_kind : printkind; (** Current kind of printing *)
  pe_cmap_norm : colormap; (** Current colormap for the normal part *)
  pe_cmap_foot : colormap; (** Current colormap for the footprint part *)
  pe_color : color; (** Current color *)
  pe_obj_sub : (Obj.t -> Obj.t) option (** generic object substitution *)
}

(** Reset the object substitution, so that no substitution takes place *)
val pe_reset_obj_sub : printenv -> printenv

(** Set the object substitution, which is supposed to preserve the type.
Currently only used for a map from (identifier) expressions to the program var containing them *)
val pe_set_obj_sub : printenv -> ('a -> 'a) -> printenv

(** standard colormap: black *)
val colormap_black : colormap

(** red colormap *)
val colormap_red : colormap

(** Extend the normal colormap for the given object with the given color *)
val pe_extend_colormap : printenv -> Obj.t -> color -> printenv

(** Default text print environment *)
val pe_text : printenv

(** Default html print environment *)
val pe_html : color -> printenv

(** Default latex print environment *)
val pe_latex : color -> printenv

(** string representation of colors *)
val color_string : color -> string

(** Pretty print a space-separated sequence *)
val pp_seq : (Format.formatter -> 'a -> unit) -> Format.formatter -> 'a list -> unit

(** Pretty print a comma-separated sequence *)
val pp_comma_seq : (Format.formatter -> 'a -> unit) -> Format.formatter -> 'a list -> unit

(** Pretty print a ;-separated sequence *)
val pp_semicolon_seq : printenv -> (Format.formatter -> 'a -> unit) -> Format.formatter -> 'a list -> unit

(** Pretty print a ;-separated sequence on one line *)
val pp_semicolon_seq_oneline : printenv -> (Format.formatter -> 'a -> unit) -> Format.formatter -> 'a list -> unit

(** Pretty print a or-separated sequence *)
val pp_or_seq : printenv -> (Format.formatter -> 'a -> unit) -> Format.formatter -> 'a list -> unit

(** Produce a string from a 1-argument pretty printer function *)
val pp_to_string : (Format.formatter -> 'a -> unit) -> 'a -> string

(** Print the current time and date in a format similar to the "date" command *)
val pp_current_time : Format.formatter -> unit -> unit

(** Print the time in seconds elapsed since the beginning of the execution of the current command. *)
val pp_elapsed_time : Format.formatter -> unit -> unit

(** {2 SymOp and Timeouts: units of symbolic execution} *)

(** initial time of the analysis, i.e. when this module is loaded, gotten from Unix.time *)
val initial_analysis_time : float

(** number of symops to multiply by the number of iterations, after which there is a timeout *)
val symops_per_iteration : int ref

(** number of seconds to multiply by the number of iterations, after which there is a timeout *)
val seconds_per_iteration : int ref

(** timeout value from the -iterations command line option *)
val iterations_cmdline : int ref

(** Timeout in seconds for each function *)
val get_timeout_seconds : unit -> int

(** Set the timeout values in seconds and symops, computed as a multiple of the integer parameter *)
val set_iterations : int -> unit

type timeout_kind =
  | TOtime (* max time exceeded *)
  | TOsymops of int (* max symop's exceeded *)
  | TOrecursion of int (* max recursion level exceeded *)

(** Timeout exception *)
exception Timeout_exe of timeout_kind

(** check that the exception is not a timeout exception *)
val exn_not_timeout : exn -> bool

(** Count the number of symbolic operations *)
module SymOp : sig
(** Count one symop *)
  val pay : unit -> unit

  (** Reset the counter and activate the alarm *)
  val set_alarm : unit -> unit

  (** De-activate the alarm *)
  val unset_alarm : unit -> unit

  (** set the handler for the wallclock timeout *)
  val set_wallclock_timeout_handler : (unit -> unit) -> unit

  (** Set the wallclock alarm checked at every pay() *)
  val set_wallclock_alarm : int -> unit

  (** Unset the wallclock alarm checked at every pay() *)
  val unset_wallclock_alarm : unit -> unit

  (** if the wallclock alarm has expired, raise a timeout exception *)
  val check_wallclock_alarm : unit -> unit

  (** Return the total number of symop's since the beginning *)
  val get_total : unit -> int

  (** Reset the total number of symop's *)
  val reset_total : unit -> unit

  (** Report the stats since the last reset *)
  val report : Format.formatter -> unit -> unit

  (** Report the stats since the loading of this module *)
  val report_total : Format.formatter -> unit -> unit
end

(** Modified version of Arg module from the ocaml distribution *)
module Arg2 : sig
  type spec = Arg.spec

  type key = string
  type doc = string
  type usage_msg = string
  type anon_fun = (string -> unit)

  val current : int ref

  (** type of aligned commend-line options *)
  type aligned

  val align : (key * spec * doc) list -> aligned list

  val parse : aligned list -> anon_fun -> usage_msg -> unit

  val usage : aligned list -> usage_msg -> unit

  val to_arg_desc : aligned -> (key * spec * doc)
  val from_arg_desc : (key * spec * doc) -> aligned

  (** [create_options_desc double_minus unsorted_desc title] creates a group of sorted command-line arguments.
  [double_minus] is a booleand indicating whether the [-- option = nn] format or [- option n] format is to be used.
  [title] is the title of this group of options.
  It expects a list [opname, desc, param_opt, text] where
  [opname] is the name of the option
  [desc] is the Arg.spec
  [param_opt] is the optional parameter to [opname]
  [text] is the description of the option *)
  val create_options_desc : bool -> string -> (string * Arg.spec * string option * string) list -> aligned list

end

(** Check if the lhs is a substring of the rhs. *)
val string_is_prefix : string -> string -> bool

(** Check if the lhs is a suffix of the rhs. *)
val string_is_suffix : string -> string -> bool

(** Check if the lhs is contained in the rhs. *)
val string_contains : string -> string -> bool

(** Split a string across the given character, if given. (e.g. split first.second with '.').*)
val string_split_character : string -> char -> string option * string

(** The value of a string option or the empty string.: *)
val string_value_or_empty_string : string option -> string

(** copy a source file, return the number of lines, or None in case of error *)
val copy_file : string -> string -> int option

(** read a source file and return a list of lines, or None in case of error *)
val read_file : string -> string list option

(** Convert a filename to an absolute one if it is relative, and normalize "." and ".." *)
val filename_to_absolute : string -> string

(** Convert an absolute filename to one relative to a root directory *)
val filename_to_relative : string -> string -> string

module FileLOC : (** count lines of code of files and keep processed results in a cache *)
sig
  val reset: unit -> unit (** reset the cache *)
  val file_get_loc : string -> int (** get the LOC of the file *)
end

(** type for files used for printing *)
type outfile =
  { fname : string; (** name of the file *)
    out_c : out_channel; (** output channel *)
    fmt : Format.formatter (** formatter for printing *) }

(** create an outfile for the command line, the boolean indicates whether to do demangling when closing the file *)
val create_outfile : string -> outfile option

(** operate on an outfile reference if it is not None *)
val do_outf : outfile option ref -> (outfile -> unit) -> unit

(** close an outfile *)
val close_outf : outfile -> unit

(** Basic command-line arguments *)
val base_arg_desc : (string * Arg.spec * string option * string) list

(** Reserved command-line arguments *)
val reserved_arg_desc : (string * Arg.spec * string option * string) list

(** Escape a string for use in a CSV or XML file: replace reserved characters with escape sequences *)
module Escape : sig
(** escape a string specifying the per character escaping function *)
  val escape_map : (char -> string option) -> string -> string
  val escape_dotty : string -> string (** escape a string to be used in a dotty file *)
  val escape_csv : string -> string (** escape a string to be used in a csv file *)
  val escape_path : string -> string (** escape a path replacing the directory separator with an underscore *)
  val escape_xml : string -> string (** escape a string to be used in an xml file *)
end


(** flags for a procedure, these can be set programmatically by __infer_set_flag: see frontend.ml *)
type proc_flags = (string, string) Hashtbl.t

(** keys for proc_flags *)
val proc_flag_iterations : string (** key to specify procedure-specific iterations *)
val proc_flag_skip : string (** key to specify that a function should be treated as a skip function *)
val proc_flag_ignore_return : string (** key to specify that it is OK to ignore the return value *)

(** empty proc flags *)
val proc_flags_empty : unit -> proc_flags

(** add a key value pair to a proc flags *)
val proc_flags_add : proc_flags -> string -> string -> unit

(** find a value for a key in the proc flags *)
val proc_flags_find : proc_flags -> string -> string

(** [join_strings sep parts] contatenates the elements of [parts] using [sep] as separator *)
val join_strings : string -> string list -> string

(** [next compare] transforms the comparison function [compare] to another function taking
the outcome of another comparison as last parameter and only performs this comparison if this value
is different from 0. Useful to combine comparison functions using the operator |>. The outcome of
the expression [Int.compare x y |> next Set.compare s t] is: [Int.compare x y] if this value is
not [0], skipping the evaluation of [Set.compare s t] in such case; or [Set.compare s t] in case
[Int.compare x y] is [0] *)
val next : ('a -> 'a -> int) -> ('a -> 'a -> int -> int)

(** Functional fold function over all the file of a directory *)
val directory_fold : ('a -> string -> 'a) -> 'a -> string -> 'a

(** Functional iter function over all the file of a directory *)
val directory_iter : (string -> unit) -> string -> unit

(** Various kind of analyzers *)
type analyzer = Infer | Eradicate | Checkers | Tracing

(** List of analyzers *)
val analyzers: analyzer list

val string_of_analyzer: analyzer -> string

val analyzer_of_string: string -> analyzer
