(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

val in_profiler_data_map : Typ.Procname.t -> bool

val make_void_signature_procname : string -> string -> Typ.Procname.t
