(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

open CFrontend_utils

(* This module defines a language to define checkers. These checkers
   are intepreted over the AST of the program. A checker is defined by a
   CTL formula which express a condition saying when the checker should
    report a problem *)


(* Transition labels used for example to switch from decl to stmt *)
type transitions =
  | Body (* decl to stmt *)
  | InitExpr (* decl to stmt *)
  | Super (* decl to decl *)
  | Cond

(* In formulas below prefix
   "E" means "exists a path"
   "A" means "for all path" *)

type t = (* A ctl formula *)
  | True
  | False (* not really necessary but it makes it evaluation faster *)
  | Atomic of Predicates.t
  | Not of t
  | And of t * t
  | Or of t * t
  | Implies of t * t
  | InNode of string list * t
  | AX of t
  | EX of transitions option * t
  | AF of t
  | EF of transitions option * t
  | AG of t
  | EG of transitions option * t
  | AU of t * t
  | EU of transitions option * t * t
  | EH of string list * t
  | ET of string list * transitions option * t
  | ETX of string list * transitions option * t

(* the kind of AST nodes where formulas are evaluated *)
type ast_node =
  | Stmt of Clang_ast_t.stmt
  | Decl of Clang_ast_t.decl

module Debug = struct
  let pp_transition fmt trans_opt =
    let pp_aux fmt trans = match trans with
      | Body -> Format.pp_print_string fmt "Body"
      | InitExpr -> Format.pp_print_string fmt "InitExpr"
      | Super -> Format.pp_print_string fmt "Super"
      | Cond -> Format.pp_print_string fmt "Cond" in
    match trans_opt with
    | Some trans -> pp_aux fmt trans
    | None -> Format.pp_print_string fmt "_"

  (* a flag to print more or less in the dotty graph *)
  let full_print = true

  let rec pp_formula fmt phi =
    match phi with
    | True -> Format.fprintf fmt "True"
    | False -> Format.fprintf fmt "False"
    | Atomic p -> Predicates.pp_predicate fmt p
    | Not phi -> if full_print then Format.fprintf fmt "NOT(%a)" pp_formula phi
        else Format.fprintf fmt "NOT(...)"
    | And (phi1, phi2) -> if full_print then
          Format.fprintf fmt "(%a AND %a)" pp_formula phi1 pp_formula phi2
        else  Format.fprintf fmt "(... AND ...)"
    | Or (phi1, phi2) -> if full_print then
          Format.fprintf fmt "(%a OR %a)" pp_formula phi1 pp_formula phi2
        else Format.fprintf fmt "(... OR ...)"
    | Implies (phi1, phi2) -> Format.fprintf fmt "(%a ==> %a)" pp_formula phi1 pp_formula phi2
    | InNode (nl, phi) -> Format.fprintf fmt "IN-NODE %a: (%a)"
                            (Utils.pp_comma_seq Format.pp_print_string) nl
                            pp_formula phi
    | AX phi -> Format.fprintf fmt "AX(%a)" pp_formula phi
    | EX (trs, phi) -> Format.fprintf fmt "EX[->%a](%a)" pp_transition trs pp_formula phi
    | AF phi -> Format.fprintf fmt "AF(%a)" pp_formula phi
    | EF (trs, phi) -> Format.fprintf fmt "EF[->%a](%a)" pp_transition trs pp_formula phi
    | AG phi -> Format.fprintf fmt "AG(%a)" pp_formula phi
    | EG (trs, phi) -> Format.fprintf fmt "EG[->%a](%a)" pp_transition trs pp_formula phi
    | AU (phi1, phi2) -> Format.fprintf fmt "A[%a UNTIL %a]" pp_formula phi1 pp_formula phi2
    | EU (trs, phi1, phi2) -> Format.fprintf fmt "E[->%a][%a UNTIL %a]"
                                pp_transition trs pp_formula phi1 pp_formula phi2
    | EH (arglist, phi) -> Format.fprintf fmt "EH[%a](%a)"
                             (Utils.pp_comma_seq Format.pp_print_string) arglist
                             pp_formula phi
    | ET (arglist, trans, phi)
    | ETX (arglist, trans, phi)  -> Format.fprintf fmt "ETX[%a][%a](%a)"
                                      (Utils.pp_comma_seq Format.pp_print_string) arglist
                                      pp_transition trans
                                      pp_formula phi

  module EvaluationTracker = struct
    exception Empty_stack of string

    type eval_result = Eval_undefined | Eval_true | Eval_false

    type content = {
      ast_node: ast_node;
      phi: t;
      lcxt: CLintersContext.context;
      eval_result: eval_result;
    }

    type node = {
      id: int;
      content: content;
    }

    type tree = Tree of node * (tree list)

    type t = {
      next_id: int;
      eval_stack: tree Stack.t;
      forest: tree list;
    }

    let create_content ast_node phi lcxt = {ast_node; phi; eval_result = Eval_undefined; lcxt = lcxt; }

    let create () = {next_id = 0; eval_stack = Stack.create(); forest = [] }

    let eval_begin t content =
      let node = {id = t.next_id; content} in
      let create_subtree root = Tree (root, []) in
      let subtree' = create_subtree node in
      Stack.push subtree' t.eval_stack;
      {t with next_id = t.next_id + 1}

    let eval_end t result =
      let eval_result_of_bool = function
        | true -> Eval_true
        | false -> Eval_false in
      if Stack.is_empty t.eval_stack then
        raise (Empty_stack "Unbalanced number of eval_begin/eval_end invocations");
      let evaluated_tree = match Stack.pop t.eval_stack with
        | Tree ({id = _; content} as node, children) ->
            let content' = {content with eval_result = eval_result_of_bool result} in
            Tree ({node with content = content'}, children) in
      let forest' =
        if Stack.is_empty t.eval_stack then evaluated_tree :: t.forest
        else
          let parent = match Stack.pop t.eval_stack with
              Tree (node, children) -> Tree (node, evaluated_tree :: children) in
          Stack.push parent t.eval_stack;
          t.forest in
      {t with forest = forest'}

    module DottyPrinter = struct
      let dotty_of_ctl_evaluation t =
        let buffer_content buf =
          let result = Buffer.contents buf in
          Buffer.reset buf;
          result in
        let dotty_of_tree cluster_id tree =
          let get_root tree = match tree with Tree (root, _) -> root in
          let get_children tree = match tree with Tree (_, children) -> IList.rev children in
          (* shallow: emit dotty about root node and edges to its children *)
          let shallow_dotty_of_tree tree =
            let root_node = get_root tree in
            let children = get_children tree in
            let edge child_node =
              if root_node.content.ast_node = child_node.content.ast_node then
                Printf.sprintf "%d -> %d [style=dotted]" root_node.id child_node.id
              else
                Printf.sprintf "%d -> %d [style=bold]" root_node.id child_node.id in
            let color =
              match root_node.content.eval_result with
              | Eval_true -> "green"
              | Eval_false -> "red"
              | _ -> failwith "Tree is not fully evaluated" in
            let label =
              let string_of_lcxt c =
                match c.CLintersContext.et_evaluation_node with
                | Some s -> ("et_evaluation_node = "^s)
                | _ -> "et_evaluation_node = NONE" in
              let string_of_ast_node an =
                match an with
                | Stmt stmt -> Clang_ast_proj.get_stmt_kind_string stmt
                | Decl decl -> Clang_ast_proj.get_decl_kind_string decl in
              let smart_string_of_formula phi =
                let num_children = IList.length children in
                match phi with
                | And _ when num_children = 2 -> "(...) AND (...)"
                | Or _ when num_children = 2 -> "(...) OR (...)"
                | Implies _ when num_children = 2 -> "(...) ==> (...)"
                | Not _ -> "NOT(...)"
                | _ -> Utils.pp_to_string pp_formula phi in
              Format.sprintf "(%d)\\n%s\\n%s\\n%s"
                root_node.id
                (Escape.escape_dotty (string_of_ast_node root_node.content.ast_node))
                (Escape.escape_dotty (string_of_lcxt root_node.content.lcxt))
                (Escape.escape_dotty (smart_string_of_formula root_node.content.phi)) in
            let edges =
              let buf = Buffer.create 16 in
              IList.iter
                (fun subtree -> Buffer.add_string buf ((edge (get_root subtree)) ^ "\n"))
                children;
              buffer_content buf in
            Printf.sprintf "%d [label=\"%s\" shape=box color=%s]\n%s\n"
              root_node.id label color edges in
          let rec traverse buf tree =
            Buffer.add_string buf (shallow_dotty_of_tree tree);
            IList.iter (traverse buf) (get_children tree) in
          let buf = Buffer.create 16 in
          traverse buf tree;
          Printf.sprintf "subgraph cluster_%d {\n%s\n}" cluster_id (buffer_content buf) in
        let buf = Buffer.create 16 in
        IList.iteri
          (fun cluster_id tree -> Buffer.add_string buf ((dotty_of_tree cluster_id tree) ^ "\n"))
          (IList.rev t.forest);
        Printf.sprintf "digraph CTL_Evaluation {\n%s\n}\n" (buffer_content buf)
    end
  end
end

let ctl_evaluation_tracker = match Config.debug_mode with
  | true -> Some (ref (Debug.EvaluationTracker.create ()))
  | false -> None

let debug_create_payload ast_node phi lcxt =
  match ctl_evaluation_tracker with
  | Some _ -> Some (Debug.EvaluationTracker.create_content ast_node phi lcxt)
  | None -> None

let debug_eval_begin payload =
  match ctl_evaluation_tracker, payload with
  | Some tracker, Some payload ->
      tracker := Debug.EvaluationTracker.eval_begin !tracker payload
  | _ -> ()

let debug_eval_end result =
  match ctl_evaluation_tracker with
  | Some tracker ->
      tracker := Debug.EvaluationTracker.eval_end !tracker result
  | None -> ()

let save_dotty_when_in_debug_mode source_file =
  match ctl_evaluation_tracker with
  | Some tracker ->
      let dotty_dir = Config.results_dir // Config.lint_dotty_dir_name in
      create_dir dotty_dir;
      let source_file_basename = Filename.basename (DB.source_file_to_abs_path source_file) in
      let file = dotty_dir // (source_file_basename ^ ".dot") in
      let dotty = Debug.EvaluationTracker.DottyPrinter.dotty_of_ctl_evaluation !tracker in
      with_file file ~f:(fun oc -> output_string oc dotty)
  | _ -> ()

(* Helper functions *)

(* Sometimes we need to unwrap a node *)
(* NOTE: when in the language it will be possible to define
   sintactic sugar than we can remove this and define it a
   transition from BlockExpr to  BlockDecl *)
let unwrap_node an =
  match an with
  | Stmt BlockExpr(_, _, _, d) ->
      (* From BlockExpr we jump directly to its BlockDecl *)
      Decl d
  | _ -> an

let node_to_string an =
  match an with
  | Decl d -> Clang_ast_proj.get_decl_kind_string d
  | Stmt s -> Clang_ast_proj.get_stmt_kind_string s

let node_to_unique_string_id an =
  match an with
  | Decl d ->
      let di = Clang_ast_proj.get_decl_tuple d in
      (Clang_ast_proj.get_decl_kind_string d) ^ (string_of_int di.Clang_ast_t.di_pointer)
  | Stmt s ->
      let si, _ = Clang_ast_proj.get_stmt_tuple s in
      Clang_ast_proj.get_stmt_kind_string s ^ (string_of_int si.Clang_ast_t.si_pointer)

(* true iff an ast node is a node of type among the list tl *)
let node_has_type tl an =
  let an_str = node_to_string an in
  IList.mem Core.Std.String.equal an_str tl

(* given a decl returns a stmt such that decl--->stmt via label trs *)
let transition_decl_to_stmt d trs =
  let open Clang_ast_t in
  let temp_res =
    match trs, d with
    | Some Body, ObjCMethodDecl (_, _, omdi) -> omdi.omdi_body
    | Some Body, FunctionDecl (_, _, _, fdi)
    | Some Body, CXXMethodDecl (_, _, _, fdi,_ )
    | Some Body, CXXConstructorDecl (_, _, _, fdi, _)
    | Some Body, CXXConversionDecl (_, _, _, fdi, _)
    | Some Body, CXXDestructorDecl (_, _, _, fdi, _) -> fdi.fdi_body
    | Some Body, BlockDecl (_, bdi) -> bdi.bdi_body
    | Some InitExpr, VarDecl (_, _ ,_, vdi) -> vdi.vdi_init_expr
    | Some InitExpr, ObjCIvarDecl (_, _, _, fldi, _)
    | Some InitExpr, FieldDecl (_, _, _, fldi)
    | Some InitExpr, ObjCAtDefsFieldDecl (_, _, _, fldi)-> fldi.fldi_init_expr
    | Some InitExpr, CXXMethodDecl _
    | Some InitExpr, CXXConstructorDecl _
    | Some InitExpr, CXXConversionDecl _
    | Some InitExpr, CXXDestructorDecl _ ->
        assert false (* to be done. Requires extending to lists *)
    | Some InitExpr, EnumConstantDecl (_, _, _, ecdi) -> ecdi.ecdi_init_expr
    | _, _ -> None in
  match temp_res with
  | Some st -> Some (Stmt st)
  | _ -> None

let transition_decl_to_decl_via_super d =
  match Ast_utils.get_impl_decl_info d with
  | Some idi ->
      (match Ast_utils.get_super_ObjCImplementationDecl idi with
       | Some d -> Some (Decl d)
       | _ -> None)
  | None -> None

let transition_stmt_to_stmt_via_condition st =
  let open Clang_ast_t in
  match st with
  | IfStmt (_, _ :: _ :: cond :: _)
  | ConditionalOperator (_, cond:: _, _)
  | ForStmt (_, [_; _; cond; _; _])
  | WhileStmt (_, [_; cond; _]) -> Some (Stmt cond)
  | _ -> None

(* given a node an returns the node an' such that an transition to an' via label trans *)
let next_state_via_transition an trans =
  match an, trans with
  | Decl d, Some Super -> transition_decl_to_decl_via_super d
  | Decl d, Some InitExpr
  | Decl d, Some Body -> transition_decl_to_stmt d trans
  | Stmt st, Some Cond -> transition_stmt_to_stmt_via_condition st
  | _, _ -> None

(* Evaluation of formulas *)

(* evaluate an atomic formula (i.e. a predicate) on a ast node an and a
   linter context lcxt. That is:  an, lcxt |= pred_name(params) *)
let eval_Atomic pred_name args an lcxt =
  match pred_name, args, an with
  | "call_method", [m], Stmt st -> Predicates.call_method m st
  | "property_name_contains_word", [word], Decl d -> Predicates.property_name_contains_word word d
  | "is_objc_extension", [], _ -> Predicates.is_objc_extension lcxt
  | "is_global_var", [], Decl d -> Predicates.is_syntactically_global_var d
  | "is_const_var", [], Decl d ->  Predicates.is_const_expr_var d
  | "call_function_named", args, Stmt st -> Predicates.call_function_named args st
  | "is_strong_property", [], Decl d -> Predicates.is_strong_property d
  | "is_assign_property", [], Decl d -> Predicates.is_assign_property d
  | "is_property_pointer_type", [], Decl d -> Predicates.is_property_pointer_type d
  | "context_in_synchronized_block", [], _ -> Predicates.context_in_synchronized_block lcxt
  | "is_ivar_atomic", [], Stmt st -> Predicates.is_ivar_atomic st
  | "is_method_property_accessor_of_ivar", [], Stmt st ->
      Predicates.is_method_property_accessor_of_ivar st lcxt
  | "is_objc_constructor", [], _ -> Predicates.is_objc_constructor lcxt
  | "is_objc_dealloc", [], _ -> Predicates.is_objc_dealloc lcxt
  | "captures_cxx_references", [], Decl d -> Predicates.captures_cxx_references d
  | "is_binop_with_kind", [str_kind], Stmt st -> Predicates.is_binop_with_kind str_kind st
  | "is_unop_with_kind", [str_kind], Stmt st -> Predicates.is_unop_with_kind str_kind st
  | "in_node", [nodename], Stmt st -> Predicates.is_stmt nodename st
  | "in_node", [nodename], Decl d -> Predicates.is_decl nodename d
  | "isa", [classname], Stmt st -> Predicates.isa classname st
  | _ -> failwith ("ERROR: Undefined Predicate or wrong set of arguments: " ^ pred_name)

(* st, lcxt |= EF phi  <=>
   st, lcxt |= phi or exists st' in Successors(st): st', lcxt |= EF phi

   That is: a (st, lcxt) satifies EF phi if and only if
   either (st,lcxt) satifies phi or there is a child st' of the node st
   such that (st', lcxt) satifies EF phi
*)
let rec eval_EF_st phi st lcxt trans =
  let _, succs = Clang_ast_proj.get_stmt_tuple st in
  eval_formula phi (Stmt st) lcxt
  || IList.exists (fun s -> eval_EF phi (Stmt s) lcxt trans) succs


(* dec, lcxt |= EF phi  <=>
    dec, lcxt |= phi or exists dec' in Successors(dec): dec', lcxt |= EF phi

   This is as eval_EF_st but for decl.
*)
and eval_EF_decl phi dec lcxt trans =
  eval_formula phi (Decl dec) lcxt ||
  (match Clang_ast_proj.get_decl_context_tuple dec with
   | Some (decl_list, _) ->
       IList.exists (fun d -> eval_EF phi (Decl d) lcxt trans) decl_list
   | None -> false)

(* an, lcxt |= EF phi  evaluates on decl or stmt depending on an *)
and eval_EF phi an lcxt trans =
  match trans, an with
  | Some _, _ ->
      (* Using equivalence EF[->trans] phi = phi OR EX[->trans](EF[->trans] phi)*)
      let phi' = Or (phi, EX (trans, EF (trans, phi))) in
      eval_formula phi' an lcxt
  | None, Stmt st -> eval_EF_st phi st lcxt trans
  | None, Decl dec -> eval_EF_decl phi dec lcxt trans

(* st, lcxt |= EX phi  <=> exists st' in Successors(st): st', lcxt |= phi

   That is: a (st, lcxt) satifies EX phi if and only if
   there exists is a child st' of the node st
   such that (st', lcxt) satifies phi
*)
and eval_EX_st phi st lcxt =
  let _, succs = Clang_ast_proj.get_stmt_tuple st in
  IList.exists (fun s -> eval_formula phi (Stmt s) lcxt) succs

(* dec, lcxt |= EX phi  <=> exists dec' in Successors(dec): dec',lcxt|= phi

   Same as eval_EX_st but for decl.
*)
and eval_EX_decl phi dec lcxt =
  match Clang_ast_proj.get_decl_context_tuple dec with
  | Some (decl_list, _) ->
      IList.exists (fun d -> eval_formula phi (Decl d) lcxt) decl_list
  | None -> false

(* Evaluate phi on node an' such that an -l-> an'. False if an' does not exists *)
and evaluate_on_transition phi an lcxt l =
  match next_state_via_transition an l with
  | Some succ -> eval_formula phi succ lcxt
  | None -> false

(* an |= EX phi evaluates on decl/stmt depending on the ast_node an *)
and eval_EX phi an lcxt trans =
  match trans, an with
  | Some _, _ -> evaluate_on_transition phi an lcxt trans
  | None, Stmt st -> eval_EX_st phi st lcxt
  | None, Decl decl -> eval_EX_decl phi decl lcxt


(* an, lcxt |= E(phi1 U phi2) evaluated using the equivalence
   an, lcxt |= E(phi1 U phi2) <=> an, lcxt |= phi2 or (phi1 and EX(E(phi1 U phi2)))

   That is: a (an,lcxt) satifies E(phi1 U phi2) if and only if
   an,lcxt satifies the formula phi2 or (phi1 and EX(E(phi1 U phi2)))
*)
and eval_EU phi1 phi2 an lcxt trans =
  let f = Or (phi2, And (phi1, EX (trans, (EU (trans, phi1, phi2))))) in
  eval_formula f an lcxt

(* an |= A(phi1 U phi2) evaluated using the equivalence
   an |= A(phi1 U phi2) <=> an |= phi2 or (phi1 and AX(A(phi1 U phi2)))

   Same as EU but for the all path quantifier A
*)
and eval_AU phi1 phi2 an lcxt =
  let f = Or (phi2, And (phi1, AX (AU (phi1, phi2)))) in
  eval_formula f an lcxt

(* an, lcxt |= InNode[node_type_list] phi <=>
   an is a node of type in node_type_list and an satifies phi
*)
and in_node node_type_list phi an lctx =
  let holds_for_one_node n =
    match lctx.CLintersContext.et_evaluation_node with
    | Some id ->
        (Core.Std.String.equal id (node_to_unique_string_id an)) && (eval_formula phi an lctx)
    | None ->
        (node_has_type [n] an) && (eval_formula phi an lctx) in
  IList.exists holds_for_one_node node_type_list


(* Intuitive meaning: (an,lcxt) satifies EH[Classes] phi
   if the node an is among the declaration specified by the list Classes and
   there exists a super class in its hierarchy whose declaration satisfy phi.

   an, lcxt |= EH[Classes] phi <=>
   the node an is in Classes and there exists a declaration d in Hierarchy(an)
   such that d,lcxt |= phi *)
and eval_EH classes phi an lcxt =
  (* Define EH[Classes] phi = ET[Classes](EF[->Super] phi) *)
  let f = ET (classes, None, EF (Some Super, phi)) in
  eval_formula f an lcxt

(* an, lcxt |= ET[T][->l]phi <=>
   eventually we reach a node an' such that an' is among the types defined in T
   and:

   an'-l->an''
   ("an' transitions" to another node an'' via an edge labelled l)
   and an'',lcxt |= phi

   or l is unspecified and an,lcxt |= phi
*)
and eval_ET tl trs phi an lcxt =
  let f = match trs with
    | Some _ -> EF (None, (InNode (tl, EX (trs, phi))))
    | None -> EF (None, (InNode (tl, phi))) in
  eval_formula f an lcxt

and eval_ETX tl trs phi an lcxt =
  let lcxt', tl' = match lcxt.CLintersContext.et_evaluation_node, node_has_type tl an with
    | None, true ->
        let an_str = node_to_string an in
        {lcxt with CLintersContext.et_evaluation_node = Some (node_to_unique_string_id an) }, [an_str]
    | _, _ -> lcxt, tl in
  let f = match trs with
    | Some _ -> EF (None, (InNode (tl', EX (trs, phi))))
    | None -> EF (None, (InNode (tl', phi))) in
  eval_formula f an lcxt'

(* Formulas are evaluated on a AST node an and a linter context lcxt *)
and eval_formula f an lcxt =
  debug_eval_begin (debug_create_payload an f lcxt);
  let res = match f with
    | True -> true
    | False -> false
    | Atomic (name, params) -> eval_Atomic name params an lcxt
    | Not f1 -> not (eval_formula f1 an lcxt)
    | And (f1, f2) -> (eval_formula f1 an lcxt) && (eval_formula f2 an lcxt)
    | Or (f1, f2) -> (eval_formula f1 an lcxt) || (eval_formula f2 an lcxt)
    | Implies (f1, f2) ->
        not (eval_formula f1 an lcxt) || (eval_formula f2 an lcxt)
    | InNode (node_type_list, f1) ->
        let an' = unwrap_node an in
        in_node node_type_list f1 an' lcxt
    | AU (f1, f2) -> eval_AU f1 f2 an lcxt
    | EU (trans, f1, f2) -> eval_EU f1 f2 an lcxt trans
    | EF (trans, f1) -> eval_EF f1 an lcxt trans
    | AF f1 -> eval_formula (AU (True, f1)) an lcxt
    | AG f1 -> eval_formula (Not (EF (None, (Not f1)))) an lcxt
    | EX (trans, f1) -> eval_EX f1 an lcxt trans
    | AX f1 -> eval_formula (Not (EX (None, (Not f1)))) an lcxt
    | EH (cl, phi) -> eval_EH cl phi an lcxt
    | EG (trans, f1) -> (* st |= EG f1 <=> st |= f1 /\ EX EG f1 *)
        eval_formula (And (f1, EX (trans, (EG (trans, f1))))) an lcxt
    | ET (tl, sw, phi) -> eval_ET tl sw phi an lcxt
    | ETX (tl, sw, phi) -> eval_ETX tl sw phi an lcxt in
  debug_eval_end res;
  res
