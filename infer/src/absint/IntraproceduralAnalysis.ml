(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

type t = {proc_desc: Procdesc.t; tenv: Tenv.t; err_log: Errlog.t; exe_env: Exe_env.t}
