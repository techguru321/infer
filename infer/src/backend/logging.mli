(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

open Utils

(** log messages at different levels of verbosity *)

type colour

val black : colour
val red : colour
val green : colour
val yellow : colour
val blue : colour
val magenta : colour
val cyan : colour

(** Return the next "coloured" (i.e. not black) colour *)
val next_colour : unit -> colour

(** Print escape code to change the terminal's colour *)
val change_terminal_colour : colour -> unit

(** type of printable elements *)
type print_type =
  | PTatom
  | PTdecrease_indent
  | PTexp
  | PTexp_list
  | PThpred
  | PTincrease_indent
  | PTinstr
  | PTinstr_list
  | PTjprop_list
  | PTjprop_short
  | PTloc
  | PTnode_instrs
  | PToff
  | PToff_list
  | PTpath
  | PTprop
  | PTproplist
  | PTprop_list_with_typ
  | PTprop_with_typ
  | PTpvar
  | PTspec
  | PTstr
  | PTstr_color
  | PTstrln
  | PTstrln_color
  | PTpathset
  | PTpi
  | PTsexp
  | PTsexp_list
  | PTsigma
  | PTtexp_full
  | PTsub
  | PTtyp_full
  | PTtyp_list
  | PTwarning
  | PTerror
  | PTinfo

(** delayable print action *)
type print_action =
  print_type * Obj.t (** data to be printed *)

(** hook for the current printer of delayed print actions *)
val printer_hook : (Format.formatter -> print_action -> unit) ref

(** extend he current print log *)
val add_print_action : print_action -> unit

(** return the delayed print actions *)
val get_delayed_prints : unit -> print_action list

(** reset the delayed print actions *)
val reset_delayed_prints : unit -> unit

(** Set the colours of the printer *)
val set_colour : colour -> unit

(** print to the current out stream *)
val out : ('a, Format.formatter, unit) format -> 'a

(** print to the current err stream *)
val err : ('a, Format.formatter, unit) format -> 'a

(** print immediately to standard error *)
val stderr : ('a, Format.formatter, unit) format -> 'a

(** print immediately to standard output *)
val stdout : ('a, Format.formatter, unit) format -> 'a

(** Get the current out formatter *)
val get_out_formatter : unit -> Format.formatter

(** Get the current err formatter *)
val get_err_formatter : unit -> Format.formatter

(** Set the current out formatter *)
val set_out_formatter : Format.formatter -> unit

(** Set the current err formatter *)
val set_err_formatter : Format.formatter -> unit

(** Flush the current streams *)
val flush_streams : unit -> unit

(** print a warning with information of the position in the ml source where it oririnated.
use as: warning_position "description" (try assert false with Assert_failure x -> x); *)
val warning_position: string -> ml_location -> unit

(** dump a string *)
val d_str : string -> unit

(** dump a string with the given color *)
val d_str_color : color -> string -> unit

(** dump a string plus newline *)
val d_strln : string -> unit

(** dump a string plus newline with the given color *)
val d_strln_color : color -> string -> unit

(** dump a newline *)
val d_ln : unit -> unit

(** dump an error string *)
val d_error : string -> unit

(** dump a warning string *)
val d_warning : string -> unit

(** dump an info string *)
val d_info : string -> unit

(** dump an indentation *)
val d_indent : int -> unit

(** dump command to increase the indentation level *)
val d_increase_indent : int -> unit

(** dump command to decrease the indentation level *)
val d_decrease_indent : int -> unit
