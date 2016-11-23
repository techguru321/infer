(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** Returns true if the passed-in list of decls contains an
    ObjCImplementationDecl of a descendant of CKComponent or
    CKComponentController.

    Does not recurse into hierarchy. *)
val contains_ck_impl : Clang_ast_t.decl list -> bool

val mutable_local_vars_advice :
  CLintersContext.context -> CTL.ast_node -> CTL.t * CIssue.issue_desc option

val component_factory_function_advice :
  CLintersContext.context -> CTL.ast_node -> CTL.t * CIssue.issue_desc option

val component_with_unconventional_superclass_advice :
  CLintersContext.context -> CTL.ast_node -> CTL.t * CIssue.issue_desc option

val component_with_multiple_factory_methods_advice :
  CLintersContext.context -> CTL.ast_node -> CTL.t * CIssue.issue_desc option

val component_initializer_with_side_effects_advice :
  CLintersContext.context -> CTL.ast_node -> CTL.t * CIssue.issue_desc option

val component_file_line_count_info :
  CLintersContext.context -> Clang_ast_t.decl -> CIssue.issue_desc list

val component_file_cyclomatic_complexity_info :
  CLintersContext.context -> CTL.ast_node -> CTL.t * CIssue.issue_desc option
