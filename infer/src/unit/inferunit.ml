(*
 * Copyright (c) 2015 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** module for running OCaml unit tests *)

module L = Logging

let () =
  let open OUnit2 in
  let tests = [] in
  let test_suite = "all" >::: tests in
  OUnit2.run_test_tt_main test_suite
