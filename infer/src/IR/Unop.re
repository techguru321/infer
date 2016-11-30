/*
 * vim: set ft=rust:
 * vim: set ft=reason:
 *
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */
open! Utils;


/** The Smallfoot Intermediate Language: Unary Operators */
let module L = Logging;

let module F = Format;


/** Unary operations */
type t =
  | Neg /** Unary minus */
  | BNot /** Bitwise complement (~) */
  | LNot /** Logical Not (!) */
[@@deriving compare];

let equal o1 o2 => compare o1 o2 == 0;


/** String representation of unary operator. */
let str =
  fun
  | Neg => "-"
  | BNot => "~"
  | LNot => "!";
