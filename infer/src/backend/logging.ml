(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(** log messages at different levels of verbosity *)

module F = Format
open Utils

type colour =
    C30 | C31 | C32 | C33 | C34 | C35 | C36

let black = C30
let red = C31
let green = C32
let yellow = C33
let blue = C34
let magenta = C35
let cyan = C36

let next_c = function
  | C30 -> assert false
  | C31 -> C32
  | C32 -> C33
  | C33 -> C34
  | C34 -> C35
  | C35 -> C36
  | C36 -> C31

let current_thread_colour = ref C31

let next_colour () =
  let c = !current_thread_colour in
  current_thread_colour := next_c c;
  c

let _set_print_colour fmt = function
  | C30 -> F.fprintf fmt "\027[30m"
  | C31 -> F.fprintf fmt "\027[31m"
  | C32 -> F.fprintf fmt "\027[32m"
  | C33 -> F.fprintf fmt "\027[33m"
  | C34 -> F.fprintf fmt "\027[34m"
  | C35 -> F.fprintf fmt "\027[35m"
  | C36 -> F.fprintf fmt "\027[36m"

let change_terminal_colour c = _set_print_colour F.std_formatter c
let change_terminal_colour_err c = _set_print_colour F.err_formatter c

(** Can be applied to any number of arguments and throws them all away *)
let rec throw_away x = Obj.magic throw_away

let use_colours = ref false

(* =============== START of module MyErr =============== *)
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

let delayed_actions = ref []

(** hook for the current printer of delayed print actions *)
let printer_hook = ref (Obj.magic ())

(** Current formatter for the out stream *)
let current_out_formatter = ref F.std_formatter

(** Current formatter for the err stream *)
let current_err_formatter = ref F.err_formatter

(** Get the current out formatter *)
let get_out_formatter () = !current_out_formatter

(** Get the current err formatter *)
let get_err_formatter fmt = !current_err_formatter

(** Set the current out formatter *)
let set_out_formatter fmt =
  current_out_formatter := fmt

(** Set the current err formatter *)
let set_err_formatter fmt =
  current_err_formatter := fmt

(** Flush the current streams *)
let flush_streams () =
  F.fprintf !current_out_formatter "@?";
  F.fprintf !current_err_formatter "@?"

(** extend the current print log *)
let add_print_action pact =
  if !Config.write_html then delayed_actions := pact :: !delayed_actions
  else if not !Config.test then !printer_hook !current_out_formatter pact

(** reset the delayed print actions *)
let reset_delayed_prints () =
  delayed_actions := []

(** return the delayed print actions *)
let get_delayed_prints () =
  !delayed_actions

let current_colour = ref black

let set_colour c =
  use_colours := true;
  current_colour := c

let do_print fmt fmt_string =
  begin
    if !Config.num_cores > 1 then
      begin
        if !Config.in_child_process
        then change_terminal_colour !current_thread_colour
        else change_terminal_colour black
      end
    else if !use_colours then
      change_terminal_colour !current_colour
  end;
  F.fprintf fmt fmt_string

(** print on the out stream *)
let out fmt_string =
  do_print !current_out_formatter fmt_string

(** print on the err stream *)
let err fmt_string =
  do_print !current_err_formatter fmt_string

(** print immediately to standard error *)
let stderr fmt_string =
  do_print F.err_formatter fmt_string

(** print immediately to standard output *)
let stdout fmt_string =
  do_print F.std_formatter fmt_string

(** print a warning with information of the position in the ml source where it oririnated.
use as: warning_position "description" (try assert false with Assert_failure x -> x); *)
let warning_position (s: string) (mloc: ml_location) =
  err "WARNING: %s in %a@." s pp_ml_location_opt (Some mloc)

(** dump a string *)
let d_str (s: string) = add_print_action (PTstr, Obj.repr s)

(** dump a string with the given color *)
let d_str_color (c: color) (s: string) = add_print_action (PTstr_color, Obj.repr (s, c))

(** dump an error string *)
let d_error (s: string) = add_print_action (PTerror, Obj.repr s)

(** dump a warning string *)
let d_warning (s: string) = add_print_action (PTwarning, Obj.repr s)

(** dump an info string *)
let d_info (s: string) = add_print_action (PTinfo, Obj.repr s)

(** dump a string plus newline *)
let d_strln (s: string) = add_print_action (PTstrln, Obj.repr s)

(** dump a string plus newline with the given color *)
let d_strln_color (c: color) (s: string) = add_print_action (PTstrln_color, Obj.repr (s, c))

(** dump a newline *)
let d_ln () = add_print_action (PTstrln, Obj.repr "")

(** dump an indentation *)
let d_indent indent =
  let s = ref "" in
  for i = 1 to indent do s := "  " ^ !s done;
  if indent <> 0 then add_print_action (PTstr, Obj.repr !s)

(** dump command to increase the indentation level *)
let d_increase_indent (indent: int) =
  add_print_action (PTincrease_indent, Obj.repr indent)

(** dump command to decrease the indentation level *)
let d_decrease_indent (indent: int) =
  add_print_action (PTdecrease_indent, Obj.repr indent)
