(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

val list_checkers : unit -> unit
(** print the list of all checkers *)

val list_issue_types : unit -> unit
(** print the list of all known issue types *)

val show_checkers : Checker.t list -> unit
(** show information about the given checkers *)

val show_issue_types : IssueType.t list -> unit
(** show information about the given issue_types *)

val write_website : website_root:string -> unit
(** generate files for the fbinfer.com website *)

val url_fragment_of_issue_type : string -> string
(** given an issue type unique ID, return the URL fragment relative to the website documentation,
    e.g. [url_fragment_of_issue_type "NULL_DEREFERENCE"] is ["all-issue-types#null_dereference"] *)
