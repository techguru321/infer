(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** Utility methods to support the translation of clang ast constructs into sil instructions.  *)

open Utils
open CFrontend_utils

module L = Logging

(* Extract the element of a singleton list. If the list is not a singleton *)
(* It stops the computation giving a warning. We use this because we       *)
(* assume in many places that a list is just a singleton. We use the       *)
(* warning if to see which assumption was not correct                      *)
let extract_item_from_singleton l warning_string failure_val =
  match l with
  | [item] -> item
  | _ -> Printing.log_err "%s" warning_string; failure_val

let dummy_exp = (Sil.exp_minus_one, Sil.Tint Sil.IInt)

(* Extract the element of a singleton list. If the list is not a singleton *)
(* Gives a warning and return -1 as standard value indicating something    *)
(* went wrong.                                                             *)
let extract_exp_from_list el warning_string =
  extract_item_from_singleton el warning_string dummy_exp

module Nodes =
struct

  let prune_kind b = Cfg.Node.Prune_node(b, Sil.Ik_bexp , ((string_of_bool b)^" Branch"))

  let is_join_node n =
    match Cfg.Node.get_kind n with
    | Cfg.Node.Join_node -> true
    | _ -> false

  let is_prune_node n =
    match Cfg.Node.get_kind n with
    | Cfg.Node.Prune_node _ -> true
    | _ -> false

  let is_true_prune_node n =
    match Cfg.Node.get_kind n with
    | Cfg.Node.Prune_node(true, _, _) -> true
    | _ -> false

  let create_node node_kind temps instrs loc context =
    let procdesc = CContext.get_procdesc context in
    Cfg.Node.create (CContext.get_cfg context) loc node_kind instrs procdesc temps

  let create_prune_node branch e_cond ids_cond instrs_cond loc ik context =
    let (e_cond', _) = extract_exp_from_list e_cond
        "\nWARNING: Missing expression for Conditional operator. Need to be fixed" in
    let e_cond'' =
      if branch then
        Sil.BinOp(Sil.Ne, e_cond', Sil.exp_zero)
      else
        Sil.BinOp(Sil.Eq, e_cond', Sil.exp_zero) in
    let instrs_cond'= instrs_cond @ [Sil.Prune(e_cond'', loc, branch, ik)] in
    create_node (prune_kind branch) ids_cond instrs_cond' loc context

  (** Check if this binary opertor requires the creation of a node in the cfg. *)
  let is_binary_assign_op boi =
    match boi.Clang_ast_t.boi_kind with
    | `Assign | `MulAssign | `DivAssign | `RemAssign | `AddAssign | `SubAssign
    | `ShlAssign | `ShrAssign | `AndAssign | `XorAssign | `OrAssign -> true
    | `PtrMemD | `PtrMemI | `Mul | `Div | `Rem | `Add | `Sub | `Shl | `Shr
    | `LT | `GT | `LE | `GE | `EQ | `NE | `And | `Xor | `Or | `LAnd | `LOr
    | `Comma -> false

  (** Check if this unary opertor requires the creation of a node in the cfg. *)
  let need_unary_op_node uoi =
    match uoi.Clang_ast_t.uoi_kind with
    | `PostInc | `PostDec | `PreInc | `PreDec | `AddrOf | `Deref | `Plus -> true
    | `Minus | `Not | `LNot | `Real | `Imag | `Extension | `Coawait -> false

end

type str_node_map = (string, Cfg.Node.t) Hashtbl.t

module GotoLabel =
struct

  (* stores goto labels local to a function, with the relative node in the cfg *)
  let goto_label_node_map : str_node_map = Hashtbl.create 17

  let reset_all_labels () = Hashtbl.reset goto_label_node_map

  let find_goto_label context label sil_loc =
    try
      Hashtbl.find goto_label_node_map label
    with Not_found ->
      let node_name = Format.sprintf "GotoLabel_%s" label in
      let new_node = Nodes.create_node (Cfg.Node.Skip_node node_name) [] [] sil_loc context in
      Hashtbl.add goto_label_node_map label new_node;
      new_node
end

type continuation = {
  break: Cfg.Node.t list;
  continue: Cfg.Node.t list;
  return_temp : bool; (* true if temps should not be removed in the node but returned to ancestors *)
}

let is_return_temp continuation =
  match continuation with
  | Some cont -> cont.return_temp
  | _ -> false

let ids_to_parent cont ids =
  if is_return_temp cont then ids else []

let ids_to_node cont ids =
  if is_return_temp cont then [] else ids

let mk_cond_continuation cont =
  match cont with
  | Some cont' -> Some { cont' with return_temp = true; }
  | None -> Some { break =[]; continue =[]; return_temp = true;}

type priority_node =
  | Free
  | Busy of string

(* A translation state. It provides the translation function with the info*)
(* it need to carry on the tranlsation. *)
type trans_state = {
  context: CContext.t; (* current context of the translation *)
  succ_nodes: Cfg.Node.t list; (* successor nodes in the cfg *)
  continuation: continuation option; (* current continuation *)
  parent_line_number: int; (* line numbeer of the parent element in the AST *)
  priority: priority_node;
}

(* A translation result. It is returned by the translation function. *)
type trans_result = {
  root_nodes: Cfg.Node.t list; (* Top cfg nodes (root) created by the translation *)
  leaf_nodes: Cfg.Node.t list; (* Bottom cfg nodes (leaf) created by the translate *)
  ids: Ident.t list; (* list of temp identifiers created that need to be removed by the caller *)
  instrs: Sil.instr list; (* list of SIL instruction that need to be placed in cfg nodes of the parent*)
  exps: (Sil.exp * Sil.typ) list; (* SIL expressions resulting from the translation of the clang stmt *)
}

(* Empty result translation *)
let empty_res_trans = { root_nodes =[]; leaf_nodes =[]; ids =[]; instrs =[]; exps =[]}

(** Collect the results of translating a list of instructions, and link up the nodes created. *)
let collect_res_trans l =
  let rec collect l rt =
    match l with
    | [] -> rt
    | rt':: l' ->
        let root_nodes =
          if rt.root_nodes <> [] then rt.root_nodes
          else rt'.root_nodes in
        let leaf_nodes =
          if rt'.leaf_nodes <> [] then rt'.leaf_nodes
          else rt.leaf_nodes in
        if rt'.root_nodes <> [] then
          IList.iter (fun n -> Cfg.Node.set_succs_exn n rt'.root_nodes []) rt.leaf_nodes;
        collect l'
          { root_nodes = root_nodes;
            leaf_nodes = leaf_nodes;
            ids = rt.ids@rt'.ids;
            instrs = rt.instrs@rt'.instrs;
            exps = rt.exps@rt'.exps } in
  collect l empty_res_trans

(* priority_node is used to enforce some kind of policy for creating nodes *)
(* in the cfg. Certain elements of the AST _must_ create nodes therefore   *)
(* there is no need for them to use priority_node. Certain elements        *)
(* instead need or need not to create a node depending of certain factors. *)
(* When an element of the latter kind wants to create a node it must claim *)
(* priority first (like taking a lock). priority can be claimes only when  *)
(* it is free. If an element of AST succedes in claiming priority its id   *)
(* (pointer) is recorded in priority. After an element has finished it     *)
(* frees the priority. In general an AST element E checks if an ancestor   *)
(* has claimed priority. If priority is already claimed E does not have to *)
(* create a node. If priority is free then it means E has to create the    *)
(* node. Then E claims priority and release it afterward.                  *)
module PriorityNode =
struct

  type t = priority_node

  let try_claim_priority_node trans_state stmt_info =
    match trans_state.priority with
    | Free ->
        Printing.log_out "Priority is free. Locking priority node in %s\n@."
          stmt_info.Clang_ast_t.si_pointer;
        { trans_state with priority = Busy stmt_info.Clang_ast_t.si_pointer }
    | _ ->
        Printing.log_out "Priority busy in %s. No claim possible\n@." stmt_info.Clang_ast_t.si_pointer;
        trans_state

  let is_priority_free trans_state =
    match trans_state.priority with
    | Free -> true
    | _ -> false

  let own_priority_node pri stmt_info =
    match pri with
    | Busy p when p = stmt_info.Clang_ast_t.si_pointer -> true
    | _ -> false

  (* Used by translation functions to handle potenatial cfg nodes. *)
  (* It connects nodes returned by translation of stmt children and *)
  (* deals with creating or not a cfg node depending of owning the *)
  (* priority_node. It returns nodes, ids, instrs that should be passed to parent *)
  let compute_results_to_parent trans_state loc nd_name stmt_info res_states_children =
    let mk_node res_state =
      let ids_node = ids_to_node trans_state.continuation res_state.ids in
      let node_kind = Cfg.Node.Stmt_node (nd_name) in
      Nodes.create_node node_kind ids_node res_state.instrs loc trans_state.context in
    (* Invariant: if leaf_nodes is empty then the params have not created a node.*)
    let res_state_param = collect_res_trans res_states_children in
    let create_node = own_priority_node trans_state.priority stmt_info && res_state_param.instrs <> [] in
    match res_state_param.leaf_nodes, create_node with
    | _, false -> (* The node is created by the parent. We just pass back nodes/leafs params *)
        { res_state_param with exps = []}
    | [], true -> (* We need to create a node and params did not create a node.*)
        let node' = mk_node res_state_param in
        let ids_parent = ids_to_parent trans_state.continuation res_state_param.ids in
        Cfg.Node.set_succs_exn node' trans_state.succ_nodes [];
        { root_nodes =[node'];
          leaf_nodes =[node'];
          ids = ids_parent;
          instrs =[];
          exps = []}
    | _, true ->
        (* We need to create a node but params also created some,*)
        (* so we need to pass back the nodes/leafs params*)
        let node' = mk_node res_state_param in
        Cfg.Node.set_succs_exn node' trans_state.succ_nodes [];
        let ids_parent = ids_to_parent trans_state.continuation res_state_param.ids in
        IList.iter (fun n' -> Cfg.Node.set_succs_exn n' [node'] []) res_state_param.leaf_nodes;
        { root_nodes = res_state_param.root_nodes;
          leaf_nodes = [node'];
          ids = ids_parent;
          instrs =[];
          exps =[]}

end

module Loops =
struct

  type loop_kind =
    | For of Clang_ast_t.stmt * Clang_ast_t.stmt * Clang_ast_t.stmt * Clang_ast_t.stmt * Clang_ast_t.stmt
    (* init, decl_stmt, condition, increment and body *)
    | While of Clang_ast_t.stmt option * Clang_ast_t.stmt * Clang_ast_t.stmt
    (* decl_stmt, condition and body *)
    | DoWhile of Clang_ast_t.stmt * Clang_ast_t.stmt  (* condition and body *)

  let loop_kind_to_if_kind loop_kind =
    match loop_kind with
    | For _ -> Sil.Ik_for
    | While _ -> Sil.Ik_while
    | DoWhile _ -> Sil.Ik_dowhile

  let get_body loop_kind =
    match loop_kind with
    | For (_, _, _, _, body) | While (_, _, body) | DoWhile (_, body) -> body

  let get_cond loop_kind =
    match loop_kind with
    | For (_, _, cond, _, _) | While (_, cond, _) | DoWhile (cond, _) -> cond
end

(** This function handles ObjC new/alloc and C++ new calls *)
let create_alloc_instrs context sil_loc function_type fname =
  let function_type, function_type_np =
    match function_type with
    | Sil.Tptr (styp, Sil.Pk_pointer)
    | Sil.Tptr (styp, Sil.Pk_objc_weak)
    | Sil.Tptr (styp, Sil.Pk_objc_unsafe_unretained)
    | Sil.Tptr (styp, Sil.Pk_objc_autoreleasing) ->
        function_type, styp
    | _ -> Sil.Tptr (function_type, Sil.Pk_pointer), function_type in
  let function_type_np = CTypes.expand_structured_type context.CContext.tenv function_type_np in
  let sizeof_exp = Sil.Sizeof (function_type_np, Sil.Subtype.exact) in
  let exp = (sizeof_exp, Sil.Tint Sil.IULong) in
  let ret_id = Ident.create_fresh Ident.knormal in
  let stmt_call = Sil.Call([ret_id], (Sil.Const (Sil.Cfun fname)), [exp], sil_loc, Sil.cf_default) in
  (function_type, ret_id, stmt_call, Sil.Var ret_id)

let alloc_trans trans_state loc stmt_info function_type is_cf_non_null_alloc =
  let fname = if is_cf_non_null_alloc then
      SymExec.ModelBuiltins.__objc_alloc_no_fail
    else
      SymExec.ModelBuiltins.__objc_alloc in
  let (function_type, ret_id, stmt_call, exp) = create_alloc_instrs trans_state.context loc function_type fname in
  let res_trans_tmp = { empty_res_trans with ids =[ret_id]; instrs =[stmt_call]} in
  let res_trans =
    let nname = "Call alloc" in
    PriorityNode.compute_results_to_parent trans_state loc nname stmt_info [res_trans_tmp] in
  { res_trans with exps =[(exp, function_type)]}

let objc_new_trans trans_state loc stmt_info cls_name function_type =
  let fname = SymExec.ModelBuiltins.__objc_alloc_no_fail in
  let (alloc_ret_type, alloc_ret_id, alloc_stmt_call, alloc_exp) =
    create_alloc_instrs trans_state.context loc function_type fname in
  let init_ret_id = Ident.create_fresh Ident.knormal in
  let is_instance = true in
  let call_flags = { Sil.cf_virtual = is_instance; Sil.cf_noreturn = false; Sil.cf_is_objc_block = false; } in
  let pname = General_utils.mk_procname_from_objc_method cls_name CFrontend_config.init Procname.Instance_objc_method in
  CMethod_trans.create_external_procdesc trans_state.context.CContext.cfg pname is_instance None;
  let args = [(Sil.Var alloc_ret_id, alloc_ret_type)] in
  let init_stmt_call = Sil.Call([init_ret_id], (Sil.Const (Sil.Cfun pname)), args, loc, call_flags) in
  let instrs = [alloc_stmt_call; init_stmt_call] in
  let ids = [alloc_ret_id; init_ret_id] in
  let res_trans_tmp = { empty_res_trans with ids = ids; instrs = instrs } in
  let res_trans =
    let nname = "Call objC new" in
    PriorityNode.compute_results_to_parent trans_state loc nname stmt_info [res_trans_tmp] in
  { res_trans with exps = [(Sil.Var init_ret_id, alloc_ret_type)]}

let new_or_alloc_trans trans_state loc stmt_info type_ptr class_name_opt selector =
  let tenv = trans_state.context.CContext.tenv in
  let function_type = CTypes_decl.type_ptr_to_sil_type tenv type_ptr in
  let class_name =
    match class_name_opt with
    | Some class_name -> class_name
    | None -> CTypes.classname_of_type function_type in
  if selector = CFrontend_config.alloc then
    alloc_trans trans_state loc stmt_info function_type true
  else if selector = CFrontend_config.new_str then
    objc_new_trans trans_state loc stmt_info class_name function_type
  else assert false

let cpp_new_trans trans_state sil_loc stmt_info function_type =
  let fname = SymExec.ModelBuiltins.__new in
  let (function_type, ret_id, stmt_call, exp) = create_alloc_instrs trans_state.context sil_loc function_type fname in
  let res_trans_tmp = { empty_res_trans with ids =[ret_id]; instrs =[stmt_call]} in
  let res_trans =
    let nname = "Call C++ new" in
    PriorityNode.compute_results_to_parent trans_state sil_loc nname stmt_info [res_trans_tmp] in
  { res_trans with exps = [(exp, function_type)] }

let create_cast_instrs context exp cast_from_typ cast_to_typ sil_loc =
  let ret_id = Ident.create_fresh Ident.knormal in
  let typ = CTypes.remove_pointer_to_typ cast_to_typ in
  let cast_typ_no_pointer = CTypes.expand_structured_type context.CContext.tenv typ in
  let sizeof_exp = Sil.Sizeof (cast_typ_no_pointer, Sil.Subtype.exact) in
  let pname = SymExec.ModelBuiltins.__objc_cast in
  let args = [(exp, cast_from_typ); (sizeof_exp, Sil.Tint Sil.IULong)] in
  let stmt_call = Sil.Call([ret_id], (Sil.Const (Sil.Cfun pname)), args, sil_loc, Sil.cf_default) in
  (ret_id, stmt_call, Sil.Var ret_id)

let cast_trans context exps sil_loc callee_pname_opt function_type =
  if CTrans_models.is_toll_free_bridging callee_pname_opt then
    match exps with
    | [exp, typ] ->
        Some (create_cast_instrs context exp typ function_type sil_loc)
    | _ -> assert false
  else None

let builtin_trans trans_state loc stmt_info function_type callee_pname_opt =
  if CTrans_models.is_cf_non_null_alloc callee_pname_opt ||
     CTrans_models.is_alloc_model function_type callee_pname_opt then
    Some (alloc_trans trans_state loc stmt_info function_type true)
  else if CTrans_models.is_alloc callee_pname_opt then
    Some (alloc_trans trans_state loc stmt_info function_type false)
  else None

let dereference_var_sil (exp, typ) sil_loc =
  let id = Ident.create_fresh Ident.knormal in
  let sil_instr = Sil.Letderef (id, exp, typ, sil_loc) in
  ([id], [sil_instr], Sil.Var id)

(** Given trans_result with ONE expression, create temporary variable with *)
(** value of an expression assigned to it *)
let dereference_value_from_result sil_loc trans_result ~strip_pointer =
  let (obj_sil, class_typ) = extract_exp_from_list trans_result.exps "" in
  let cast_ids, cast_inst, cast_exp = dereference_var_sil (obj_sil, class_typ) sil_loc in
  let typ_no_ptr = match class_typ with | Sil.Tptr (typ, _) -> typ | _ -> assert false in
  let cast_typ = if strip_pointer then typ_no_ptr else class_typ in
  { trans_result with
    ids = trans_result.ids @ cast_ids;
    instrs = trans_result.instrs @ cast_inst;
    exps = [(cast_exp, cast_typ)]
  }


let cast_operation context cast_kind exps cast_typ sil_loc is_objc_bridged =
  let (exp, typ) = extract_exp_from_list exps "" in
  let exp_typ = match cast_kind with
    | `UncheckedDerivedToBase -> typ  (* This cast ignores change of type *)
    | _ -> cast_typ (* by default use the return type of cast expr *) in 
  if is_objc_bridged then
    let id, instr, exp = create_cast_instrs context exp typ cast_typ sil_loc in
    [id], [instr], (exp, exp_typ)
  else
    match cast_kind with
    | `NoOp
    | `BitCast
    | `IntegralCast
    | `DerivedToBase
    | `UncheckedDerivedToBase
    | `IntegralToBoolean -> (* This is treated as a nop by returning the same expressions exps*)
        ([], [], (exp, exp_typ))
    | `LValueToRValue ->
        (* Takes an LValue and allow it to use it as RValue. *)
        (* So we assign the LValue to a temp and we pass it to the parent.*)
        let ids, instrs, deref_exp = dereference_var_sil (exp, typ) sil_loc in
        ids, instrs, (deref_exp, exp_typ)
    | `CPointerToObjCPointerCast ->
        [], [], (Sil.Cast(typ, exp), exp_typ)
    | _ ->
        Printing.log_err
          "\nWARNING: Missing translation for Cast Kind %s. The construct has been ignored...\n"
          (Clang_ast_j.string_of_cast_kind cast_kind);
        ([],[], (exp, exp_typ))

let trans_assertion_failure sil_loc context =
  let assert_fail_builtin = Sil.Const (Sil.Cfun SymExec.ModelBuiltins.__infer_fail) in
  let args = [Sil.Const (Sil.Cstr Config.default_failure_name), Sil.Tvoid] in
  let call_instr = Sil.Call ([], assert_fail_builtin, args, sil_loc, Sil.cf_default) in
  let exit_node = Cfg.Procdesc.get_exit_node (CContext.get_procdesc context)
  and failure_node =
    Nodes.create_node (Cfg.Node.Stmt_node "Assertion failure") [] [call_instr] sil_loc context in
  Cfg.Node.set_succs_exn failure_node [exit_node] [];
  { root_nodes = [failure_node];
    leaf_nodes = [failure_node];
    ids = [];
    instrs =[];
    exps = [] }

let trans_assume_false sil_loc context succ_nodes =
  let instrs_cond = [Sil.Prune (Sil.exp_zero, sil_loc, true, Sil.Ik_land_lor)] in
  let prune_node = Nodes.create_node (Nodes.prune_kind true) [] instrs_cond sil_loc context in
  Cfg.Node.set_succs_exn prune_node succ_nodes [];
  { root_nodes = [prune_node];
    leaf_nodes = [prune_node];
    ids = [];
    instrs = [];
    exps = [] }

let define_condition_side_effects context e_cond instrs_cond sil_loc =
  let (e', typ) = extract_exp_from_list e_cond "\nWARNING: Missing expression in IfStmt. Need to be fixed\n" in
  match e' with
  | Sil.Lvar pvar ->
      let id = Ident.create_fresh Ident.knormal in
      [(Sil.Var id, typ)],
      [Sil.Letderef (id, Sil.Lvar pvar, typ, sil_loc)]
  | _ -> [(e', typ)], instrs_cond

let fix_param_exps_mismatch params_stmt exps_param =
  let diff = IList.length params_stmt - IList.length exps_param in
  let args = if diff >0 then Array.make diff dummy_exp
    else assert false in
  let exps'= exps_param @ (Array.to_list args) in
  exps'

let is_superinstance mei =
  match mei.Clang_ast_t.omei_receiver_kind with
  | `SuperInstance -> true
  | _ -> false

let get_selector_receiver obj_c_message_expr_info =
  obj_c_message_expr_info.Clang_ast_t.omei_selector, obj_c_message_expr_info.Clang_ast_t.omei_receiver_kind

(* Similar to extract_item_from_singleton but for option type *)
let extract_item_from_option op warning_string =
  match op with
  | Some item -> item
  | _ -> Printing.log_err warning_string; assert false

let is_member_exp stmt =
  match stmt with
  | Clang_ast_t.MemberExpr _ -> true
  | _ -> false

let is_enumeration_constant stmt =
  match stmt with
  | Clang_ast_t.DeclRefExpr(_, _, _, drei) ->
      (match drei.Clang_ast_t.drti_decl_ref with
       | Some d -> (match d.Clang_ast_t.dr_kind with
           | `EnumConstant -> true
           | _ -> false)
       | _ -> false)
  | _ -> false

let is_null_stmt s =
  match s with
  | Clang_ast_t.NullStmt _ -> true
  | _ -> false

let dummy_id () =
  Ident.create_normal (Ident.string_to_name "DUMMY_ID_INFER") 0

let extract_stmt_from_singleton stmt_list warning_string =
  extract_item_from_singleton stmt_list warning_string (Ast_expressions.dummy_stmt ())

let extract_id_from_singleton id_list warning_string =
  extract_item_from_singleton id_list warning_string (dummy_id ())

let rec get_type_from_exp_stmt stmt =
  let do_decl_ref_exp i =
    match i.Clang_ast_t.drti_decl_ref with
    | Some d -> (match d.Clang_ast_t.dr_type_ptr with
        | Some n -> n
        | _ -> assert false )
    | _ -> assert false in
  let open Clang_ast_t in
  match stmt with
  | CXXOperatorCallExpr(_, _, ei)
  | CallExpr(_, _, ei) -> ei.Clang_ast_t.ei_type_ptr
  | MemberExpr (_, _, ei, _) -> ei.Clang_ast_t.ei_type_ptr
  | ParenExpr (_, _, ei) -> ei.Clang_ast_t.ei_type_ptr
  | ArraySubscriptExpr(_, _, ei) -> ei.Clang_ast_t.ei_type_ptr
  | ObjCIvarRefExpr (_, _, ei, _) -> ei.Clang_ast_t.ei_type_ptr
  | ObjCMessageExpr (_, _, ei, _ ) -> ei.Clang_ast_t.ei_type_ptr
  | PseudoObjectExpr(_, _, ei) -> ei.Clang_ast_t.ei_type_ptr
  | CStyleCastExpr(_, stmt_list, _, _, _)
  | UnaryOperator(_, stmt_list, _, _)
  | ImplicitCastExpr(_, stmt_list, _, _) ->
      get_type_from_exp_stmt (extract_stmt_from_singleton stmt_list "WARNING: We expect only one stmt.")
  | DeclRefExpr(_, _, _, info) -> do_decl_ref_exp info
  | _ -> Printing.log_err "Failing with: %s \n%!" (Clang_ast_j.string_of_stmt stmt);
      Printing.print_failure_info "";
      assert false

module Self =
struct

  exception SelfClassException of string

  let add_self_parameter_for_super_instance context procname loc mei =
    if is_superinstance mei then
      let typ, self_expr, id, ins =
        let t' = CTypes.add_pointer_to_typ
            (CTypes_decl.get_type_curr_class context.CContext.tenv context.CContext.curr_class) in
        let e = Sil.Lvar (Sil.mk_pvar (Mangled.from_string CFrontend_config.self) procname) in
        let id = Ident.create_fresh Ident.knormal in
        t', Sil.Var id, [id], [Sil.Letderef (id, e, t', loc)] in
      { empty_res_trans with
        exps = [(self_expr, typ)];
        ids = id;
        instrs = ins }
    else empty_res_trans

  let is_var_self pvar is_objc_method =
    let is_self = Mangled.to_string (Sil.pvar_get_name pvar) = CFrontend_config.self in
    is_self && is_objc_method

end

(* From the manual: A selector is in a certain selector family if, ignoring any leading underscores, *)
(* the first component of the selector either consists entirely of the name of *)
(* the method family or it begins with that followed by character other than lower case letter.*)
(* For example: '__perform:with' and 'performWith:' would fall into the 'perform' family (if we had one),*)
(* but 'performing:with' would not.  *)
let is_owning_name n =
  let is_family fam s'=
    if String.length s' < String.length fam then false
    else (
      let prefix = Str.string_before s' (String.length fam) in
      let suffix = Str.string_after s' (String.length fam) in
      prefix = fam && not (Str.string_match (Str.regexp "[a-z]") suffix 0)
    ) in
  match Str.split (Str.regexp_string ":") n with
  | fst:: _ ->
      (match Str.split (Str.regexp "['_']+") fst with
       | [no_und]
       | _:: no_und:: _ ->
           is_family CFrontend_config.alloc no_und ||
           is_family CFrontend_config.copy no_und ||
           is_family CFrontend_config.new_str no_und ||
           is_family CFrontend_config.mutableCopy no_und ||
           is_family CFrontend_config.init no_und
       | _ -> assert false)
  | _ -> assert false

let rec is_owning_method s =
  match s with
  | Clang_ast_t.ObjCMessageExpr(_, _ , _, mei) ->
      is_owning_name mei.Clang_ast_t.omei_selector
  | _ -> (match snd (Clang_ast_proj.get_stmt_tuple s) with
      | [] -> false
      | s'':: _ -> is_owning_method s'')

let rec is_method_call s =
  match s with
  | Clang_ast_t.ObjCMessageExpr (_, _ , _, mei) -> true
  | _ -> (match snd (Clang_ast_proj.get_stmt_tuple s) with
      | [] -> false
      | s'':: _ -> is_method_call s'')

let get_info_from_decl_ref decl_ref =
  let name_info = match decl_ref.Clang_ast_t.dr_name with Some ni -> ni | _ -> assert false in
  let decl_ptr = decl_ref.Clang_ast_t.dr_decl_pointer in
  let type_ptr = match decl_ref.Clang_ast_t.dr_type_ptr with Some tp -> tp | _ -> assert false in
  name_info, decl_ptr, type_ptr

let rec get_decl_ref_info s parent_line_number =
  match s with
  | Clang_ast_t.DeclRefExpr (stmt_info, stmt_list, expr_info, decl_ref_expr_info) ->
      (let line_number = CLocation.get_line stmt_info parent_line_number in
       match decl_ref_expr_info.Clang_ast_t.drti_decl_ref with
       | Some decl_ref -> decl_ref, line_number
       | None -> assert false)
  | _ ->
      match Clang_ast_proj.get_stmt_tuple s with
      | stmt_info, [] -> assert false
      | stmt_info, s'':: _ ->
          let line_number = CLocation.get_line stmt_info parent_line_number in
          get_decl_ref_info s'' line_number

let rec contains_opaque_value_expr s =
  match s with
  | Clang_ast_t.OpaqueValueExpr _ -> true
  | _ -> match snd (Clang_ast_proj.get_stmt_tuple s) with
    | [] -> false
    | s'':: _ -> contains_opaque_value_expr s''

(* checks if a unary operator is a logic negation applied to integers*)
let is_logical_negation_of_int tenv ei uoi =
  match CTypes_decl.type_ptr_to_sil_type tenv ei.Clang_ast_t.ei_type_ptr, uoi.Clang_ast_t.uoi_kind with
  | Sil.Tint Sil.IInt,`LNot -> true
  | _, _ -> false

(* Checks if stmt_list is a call to a special dispatch function *)
let is_dispatch_function stmt_list =
  let open Clang_ast_t in
  match stmt_list with
  | ImplicitCastExpr(_,[DeclRefExpr(_, _, _, di)], _, _):: stmts ->
      (match di.Clang_ast_t.drti_decl_ref with
       | None -> None
       | Some d ->
           (match d.Clang_ast_t.dr_kind, d.Clang_ast_t.dr_name with
            | `Function, Some name_info ->
                let s = name_info.Clang_ast_t.ni_name in
                (match (CTrans_models.is_dispatch_function_name s) with
                 | None -> None
                 | Some (dispatch_function, block_arg_pos) ->
                     try
                       (match IList.nth stmts block_arg_pos with
                        | BlockExpr _ -> Some block_arg_pos
                        | _ -> None)
                     with Not_found -> None
                )
            | _ -> None))
  | _ -> None

let get_decl_pointer decl_ref_expr_info =
  match decl_ref_expr_info.Clang_ast_t.drti_decl_ref with
  | Some decl_ref -> decl_ref.Clang_ast_t.dr_decl_pointer
  | None -> assert false

let rec pointer_of_call_expr stmt =
  let open Clang_ast_t in
  match stmt with
  | DeclRefExpr(_, _, _, decl_ref_expr_info) ->
      Some (get_decl_pointer decl_ref_expr_info)
  | MemberExpr(_, _, _, member_expr_info) ->
      let decl_ref = member_expr_info.Clang_ast_t.mei_decl_ref in
      Some decl_ref.Clang_ast_t.dr_decl_pointer
  | CXXConstructExpr (_, _, _, cxx_construct_expr_info) ->
      let decl_ref = cxx_construct_expr_info.xcei_decl_ref in
      Some decl_ref.Clang_ast_t.dr_decl_pointer
  | _ ->
      match snd (Clang_ast_proj.get_stmt_tuple stmt) with
      | [stmt] -> pointer_of_call_expr stmt
      | _ -> None

let get_decl_from_call_expr stmt =
  match pointer_of_call_expr stmt with
  | Some pointer -> Ast_utils.get_decl pointer
  | _ -> None


let assign_default_params params_stmt call_stmt =
  let open Clang_ast_t in
  match get_decl_from_call_expr call_stmt with
  | Some FunctionDecl (_, name_info, _, fdecl_info)
  | Some CXXMethodDecl (_, name_info, _, fdecl_info, _)
  | Some CXXConstructorDecl (_, name_info, _, fdecl_info, _) ->
      (let get_param_default_val param_decl = match param_decl with
          | ParmVarDecl (_, _, _, var_decl_info) -> var_decl_info.vdi_init_expr
          | _ -> None in
       let replace_default_arg param = match param with
         | CXXDefaultArgExpr _, Some default_expr -> default_expr
         | instr, _ -> instr in
       let default_params = IList.map get_param_default_val fdecl_info.Clang_ast_t.fdi_parameters in
       try
         let param_args = IList.combine params_stmt default_params in
         IList.map replace_default_arg param_args
       with Invalid_argument _ ->
         let name = name_info.ni_name in
         (* IList.combine failed because of different list lengths *)
         Printing.log_err "Param count doesn't match %s\n" name;
         params_stmt)
  | Some _ -> params_stmt
  | None -> params_stmt


let is_block_enumerate_function mei =
  mei.Clang_ast_t.omei_selector = CFrontend_config.enumerateObjectsUsingBlock
