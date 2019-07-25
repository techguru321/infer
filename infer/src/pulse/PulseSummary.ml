(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

type t = PulseAbductiveDomain.PrePost.t list

let of_posts pdesc posts = List.map posts ~f:(PulseAbductiveDomain.PrePost.of_post pdesc)

let pp fmt summary =
  PrettyPrintable.pp_collection ~pp_item:PulseAbductiveDomain.PrePost.pp fmt summary
