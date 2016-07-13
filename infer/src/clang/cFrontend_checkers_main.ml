(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

let rec do_frontend_checks_stmt cfg cg method_decl stmt =
  CFrontend_errors.run_frontend_checkers_on_stmt cfg cg method_decl stmt;
  let _, stmts = Clang_ast_proj.get_stmt_tuple stmt in
  IList.iter (do_frontend_checks_stmt cfg cg method_decl) stmts

let rec do_frontend_checks_decl cfg cg decl =
  let open Clang_ast_t in
  let info = Clang_ast_proj.get_decl_tuple decl in
  CLocation.update_curr_file info;
  (match decl with
   | FunctionDecl(_, _, _, fdi)
   | CXXMethodDecl (_, _, _, fdi, _)
   | CXXConstructorDecl (_, _, _, fdi, _)
   | CXXConversionDecl (_, _, _, fdi, _)
   | CXXDestructorDecl (_, _, _, fdi, _) ->
       (match fdi.Clang_ast_t.fdi_body with
        | Some stmt -> do_frontend_checks_stmt cfg cg decl stmt
        | None -> ())
   | ObjCMethodDecl (_, _, mdi) ->
       (match mdi.Clang_ast_t.omdi_body with
        | Some stmt -> do_frontend_checks_stmt cfg cg decl stmt
        | None -> ())
   | _ -> ());
  CFrontend_errors.run_frontend_checkers_on_decl cfg cg decl;
  match Clang_ast_proj.get_decl_context_tuple decl with
  | Some (decls, _) -> IList.iter (do_frontend_checks_decl cfg cg) decls
  | None -> ()

let do_frontend_checks cfg cg ast =
  match ast with
  | Clang_ast_t.TranslationUnitDecl(_, decl_list, _, _) ->
      IList.iter (do_frontend_checks_decl cfg cg) decl_list
  | _ -> assert false (* NOTE: Assumes that an AST alsways starts with a TranslationUnitDecl *)
