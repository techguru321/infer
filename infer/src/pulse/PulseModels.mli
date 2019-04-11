(*
 * Copyright (c) 2018-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

type exec_fun =
     Location.t
  -> ret:Var.t * Typ.t
  -> actuals:HilExp.t list
  -> PulseAbductiveDomain.t
  -> PulseAbductiveDomain.t PulseOperations.access_result

type model = exec_fun

val dispatch : Typ.Procname.t -> CallFlags.t -> model option
