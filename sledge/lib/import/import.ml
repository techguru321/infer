(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Global namespace opened in each source file by the build system *)

include (
  Base :
    sig
      include
        (module type of Base
          with module Option := Base.Option
           and module List := Base.List
           and module Set := Base.Set
           and module Map := Base.Map
          (* prematurely deprecated, remove and use Stdlib instead *)
           and module Filename := Base.Filename
           and module Format := Base.Format
           and module Marshal := Base.Marshal
           and module Scanf := Base.Scanf
           and type ('ok, 'err) result := ('ok, 'err) Base.result
         [@warning "-3"])
    end )

(* undeprecate *)
external ( == ) : 'a -> 'a -> bool = "%eq"
external ( != ) : 'a -> 'a -> bool = "%noteq"

exception Not_found = Caml.Not_found

include Stdio
module Command = Core.Command
module Hash_queue = Core_kernel.Hash_queue
include Import0

(** Tuple operations *)

let fst3 (x, _, _) = x
let snd3 (_, y, _) = y
let trd3 (_, _, z) = z

(** Function combinators *)

let ( >> ) f g x = g (f x)
let ( << ) f g x = f (g x)
let ( $ ) f g x = f x ; g x
let ( $> ) x f = f x ; x
let ( <$ ) f x = f x ; x

(** Failures *)

let fail = Trace.fail

exception Unimplemented of string

let todo fmt = Trace.raisef (fun msg -> Unimplemented msg) fmt

let warn fmt =
  let fs = Format.std_formatter in
  Format.pp_open_box fs 2 ;
  Format.pp_print_string fs "Warning: " ;
  Format.kfprintf
    (fun fs () ->
      Format.pp_close_box fs () ;
      Format.pp_force_newline fs () )
    fs fmt

(** Assertions *)

let assertf cnd fmt =
  if not cnd then fail fmt
  else Format.ikfprintf (fun _ () -> ()) Format.str_formatter fmt

let checkf cnd fmt =
  if not cnd then fail fmt
  else Format.ikfprintf (fun _ () -> true) Format.str_formatter fmt

let check f x =
  assert (f x ; true) ;
  x

let violates f x =
  assert (f x ; true) ;
  assert false

type 'a or_error = ('a, exn * Caml.Printexc.raw_backtrace) result

let or_error f x () =
  try Ok (f x) with exn -> Error (exn, Caml.Printexc.get_raw_backtrace ())

(** Extensions *)

module Invariant = struct
  include Base.Invariant

  let invariant here t sexp_of_t f =
    assert (
      ( try f ()
        with exn ->
          let bt = Caml.Printexc.get_raw_backtrace () in
          let exn =
            Error.to_exn
              (Error.create_s
                 (Base.Sexp.message "invariant failed"
                    [ ("", sexp_of_exn exn)
                    ; ("", Source_code_position.sexp_of_t here)
                    ; ("", sexp_of_t t) ]))
          in
          Caml.Printexc.raise_with_backtrace exn bt ) ;
      true )
end

module Option = Option
include Option.Monad_infix
include Option.Monad_syntax
module List = List
module Vector = Vector
include Vector.Infix
module Set = Set
module Map = Map
module Qset = Qset

module Array = struct
  include Base.Array

  let pp sep pp_elt fs a = List.pp sep pp_elt fs (to_list a)
end

module String = struct
  include String

  let t_of_sexp = Sexplib.Conv.string_of_sexp
  let sexp_of_t = Sexplib.Conv.sexp_of_string

  module Map = Map.Make (String)
end

module Q = struct
  let pp = Q.pp_print
  let hash = Hashtbl.hash
  let hash_fold_t s q = Int.hash_fold_t s (hash q)
  let sexp_of_t q = Sexp.Atom (Q.to_string q)

  let t_of_sexp = function
    | Sexp.Atom s -> Q.of_string s
    | _ -> assert false

  let of_z = Q.of_bigint

  include Q
end

module Z = struct
  let pp = Z.pp_print
  let hash = [%hash: Z.t]
  let hash_fold_t s z = Int.hash_fold_t s (hash z)
  let sexp_of_t z = Sexp.Atom (Z.to_string z)

  let t_of_sexp = function
    | Sexp.Atom s -> Z.of_string s
    | _ -> assert false

  (* the signed 1-bit integers are -1 and 0 *)
  let true_ = Z.minus_one
  let false_ = Z.zero
  let of_bool = function true -> true_ | false -> false_
  let is_true = Z.equal true_
  let is_false = Z.equal false_

  include Z
end
