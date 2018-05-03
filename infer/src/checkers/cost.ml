(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
module F = Format
module L = Logging

module Summary = Summary.Make (struct
  type payload = CostDomain.summary

  let update_payload sum (summary: Specs.summary) =
    {summary with payload= {summary.payload with cost= Some sum}}


  let read_payload (summary: Specs.summary) = summary.payload.cost
end)

(* We use this treshold to give error if the cost is above it.
   Currently it's set randomly to 200. *)
let expensive_threshold = Itv.Bound.of_int 200

(* CFG modules used in several other modules  *)
module InstrCFG = ProcCfg.NormalOneInstrPerNode
module NodeCFG = ProcCfg.Normal
module InstrCFGScheduler = Scheduler.ReversePostorder (InstrCFG)

module Node = struct
  include ProcCfg.DefaultNode

  let equal_id = [%compare.equal : id]
end

module NodesBasicCostDomain = CostDomain.NodeInstructionToCostMap

(* Compute a map (node,instruction) -> basic_cost, where basic_cost is the
   cost known for a certain operation. For example for basic operation we
   set it to 1 and for function call we take it from the spec of the function.
   The nodes in the domain of the map are those in the path reaching the current node.
*)
module TransferFunctionsNodesBasicCost = struct
  module CFG = InstrCFG
  module Domain = NodesBasicCostDomain

  type extras = BufferOverrunChecker.invariant_map

  let cost_atomic_instruction = Itv.Bound.one

  let instantiate_cost ~tenv ~caller_pdesc ~inferbo_caller_mem ~callee_pname ~params ~callee_cost =
    match Ondemand.get_proc_desc callee_pname with
    | None ->
        L.(die InternalError)
          "Can't instantiate symbolic cost %a from call to %a (can't get procdesc)" Itv.Bound.pp
          callee_cost Typ.Procname.pp callee_pname
    | Some callee_pdesc ->
      match BufferOverrunChecker.Summary.read_summary caller_pdesc callee_pname with
      | None ->
          L.(die InternalError)
            "Can't instantiate symbolic cost %a from call to %a (can't get summary)" Itv.Bound.pp
            callee_cost Typ.Procname.pp callee_pname
      | Some inferbo_summary ->
          let inferbo_caller_mem = Option.value_exn inferbo_caller_mem in
          let callee_entry_mem = BufferOverrunDomain.Summary.get_input inferbo_summary in
          let callee_exit_mem = BufferOverrunDomain.Summary.get_output inferbo_summary in
          let callee_ret_alias = BufferOverrunDomain.Mem.find_ret_alias callee_exit_mem in
          let (subst_map, _), _ =
            BufferOverrunSemantics.get_subst_map tenv callee_pdesc params inferbo_caller_mem
              callee_entry_mem ~callee_ret_alias
          in
          match Itv.Bound.subst_ub callee_cost subst_map with
          | Bottom ->
              L.(die InternalError)
                "Instantiation of cost %a from call to %a returned Bottom" Itv.Bound.pp callee_cost
                Typ.Procname.pp callee_pname
          | NonBottom callee_cost ->
              callee_cost


  let exec_instr_cost inferbo_mem (astate: CostDomain.NodeInstructionToCostMap.astate)
      {ProcData.pdesc; tenv} (node: CFG.node) instr : CostDomain.NodeInstructionToCostMap.astate =
    let key = CFG.id node in
    let astate' =
      match instr with
      | Sil.Call (_, Exp.Const (Const.Cfun callee_pname), params, _, _) ->
          let callee_cost =
            match Summary.read_summary pdesc callee_pname with
            | Some {post= callee_cost} ->
                if Itv.Bound.is_symbolic callee_cost then
                  instantiate_cost ~tenv ~caller_pdesc:pdesc ~inferbo_caller_mem:inferbo_mem
                    ~callee_pname ~params ~callee_cost
                else callee_cost
            | None ->
                cost_atomic_instruction
          in
          CostDomain.NodeInstructionToCostMap.add key callee_cost astate
      | Sil.Load _ | Sil.Store _ | Sil.Call _ | Sil.Prune _ ->
          CostDomain.NodeInstructionToCostMap.add key cost_atomic_instruction astate
      | _ ->
          astate
    in
    L.(debug Analysis Medium)
      "@\n>>>Instr: %a   Cost: %a@\n" (Sil.pp_instr Pp.text) instr
      CostDomain.NodeInstructionToCostMap.pp astate' ;
    astate'


  let exec_instr costmap ({ProcData.extras= inferbo_invariant_map} as pdata) node instr =
    let inferbo_mem = BufferOverrunChecker.extract_pre (CFG.id node) inferbo_invariant_map in
    let costmap = exec_instr_cost inferbo_mem costmap pdata node instr in
    costmap


  let pp_session_name node fmt = F.fprintf fmt "cost(basic) %a" CFG.pp_id (CFG.id node)
end

module AnalyzerNodesBasicCost =
  AbstractInterpreter.MakeNoCFG (InstrCFGScheduler) (TransferFunctionsNodesBasicCost)

(* Map associating to each node a bound on the number of times it can be executed.
   This bound is computed using environments (map: val -> values), using the following
   observation: the number of environments associated with a program point is an upperbound
   of the number of times the program point can be executed in any execution.
   The size of an environment env is computed as:
     |env| = |env(v1)| * ... * |env(n_k)|

   where |env(v)| is the size of the interval associated to v by env.

    Reference: see Stefan Bygde PhD thesis, 2010

*)
module BoundMap = struct
  type t = Itv.Bound.t Node.IdMap.t

  let print_upper_bound_map bound_map =
    L.(debug Analysis Medium) "@\n\n******* Bound Map ITV **** @\n" ;
    Node.IdMap.iter
      (fun nid b ->
        L.(debug Analysis Medium) "@\n node: %a --> bound = %a @\n" Node.pp_id nid Itv.Bound.pp b
        )
      bound_map ;
    L.(debug Analysis Medium) "@\n******* END Bound Map ITV **** @\n\n"


  let filter_loc formal_pvars vars_to_keep = function
    | AbsLoc.Loc.Var (Var.LogicalVar _) ->
        false
    | AbsLoc.Loc.Var (Var.ProgramVar pvar) when List.mem formal_pvars pvar ~equal:Pvar.equal ->
        false
    | AbsLoc.Loc.Var var when Control.VarSet.mem var vars_to_keep ->
        true
    | _ ->
        false


  let compute_upperbound_map node_cfg inferbo_invariant_map data_invariant_map
      control_invariant_map =
    let pname = Procdesc.get_proc_name node_cfg in
    let formal_pvars =
      Procdesc.get_formals node_cfg |> List.map ~f:(fun (m, _) -> Pvar.mk m pname)
    in
    let compute_node_upper_bound bound_map node =
      let node_id = NodeCFG.id node in
      match Procdesc.Node.get_kind node with
      | Procdesc.Node.Exit_node _ ->
          Node.IdMap.add node_id Itv.Bound.one bound_map
      | _ ->
          let entry_state_opt =
            let instr_node_id = InstrCFG.of_underlying_node node |> InstrCFG.id in
            BufferOverrunChecker.extract_pre instr_node_id inferbo_invariant_map
          in
          match entry_state_opt with
          | Some entry_mem ->
              (* compute all the dependencies, i.e. set of variables that affect the control flow upto the node *)
              let all_deps =
                Control.compute_all_deps data_invariant_map control_invariant_map node
              in
              L.(debug Analysis Medium)
                "@\n>>> All dependencies for node = %a : %a  @\n\n" Procdesc.Node.pp node
                Control.VarSet.pp all_deps ;
              (* bound = env(v1) *... * env(vn) *)
              let bound =
                match entry_mem with
                | Bottom ->
                    L.internal_error
                      "@\n\
                       [COST ANALYSIS INTERNAL WARNING:] No 'env' found. This location is \
                       unreachable returning cost 0 \n" ;
                    Itv.Bound.zero
                | NonBottom mem ->
                    BufferOverrunDomain.MemReach.heap_range
                      ~filter_loc:(filter_loc formal_pvars all_deps)
                      mem
              in
              L.(debug Analysis Medium)
                "@\n>>>Setting bound for node = %a  to %a@\n\n" Node.pp_id node_id Itv.Bound.pp
                bound ;
              Node.IdMap.add node_id bound bound_map
          | _ ->
              Node.IdMap.add node_id Itv.Bound.zero bound_map
    in
    let bound_map =
      List.fold (NodeCFG.nodes node_cfg) ~f:compute_node_upper_bound ~init:Node.IdMap.empty
    in
    print_upper_bound_map bound_map ; bound_map


  let upperbound bound_map nid =
    match Node.IdMap.find_opt nid bound_map with
    | Some bound ->
        bound
    | None ->
        L.(debug Analysis Medium)
          "@\n\n[WARNING] Bound not found for node %a, returning Top @\n" Node.pp_id nid ;
        Itv.Bound.pinf
end

(* Structural Constraints are expressions of the kind:
     n <= n1 +...+ nk

   The informal meaning is: the number of times node n can be executed is less or
   equal to the sum of the number of times nodes n1,..., nk can be executed.
*)
module StructuralConstraints = struct
  type rhs = Single of Node.id | Sum of Node.IdSet.t

  type t = {lhs: Node.id; rhs: rhs}

  let is_single ~lhs:expected_lhs = function
    | {lhs; rhs= Single single} when Node.equal_id lhs expected_lhs ->
        Some single
    | _ ->
        None


  let is_sum ~lhs:expected_lhs = function
    | {lhs; rhs= Sum sum} when Node.equal_id lhs expected_lhs ->
        Some sum
    | _ ->
        None


  let pp_rhs fmt = function
    | Single nid ->
        Node.pp_id fmt nid
    | Sum nidset ->
        Pp.seq ~sep:" + " Node.pp_id fmt (Node.IdSet.elements nidset)


  let pp fmt {lhs; rhs} = F.fprintf fmt "%a <= %a" Node.pp_id lhs pp_rhs rhs

  let print_constraint_list constraints =
    L.(debug Analysis Medium) "@\n\n******* Structural Constraints **** @\n" ;
    List.iter ~f:(fun c -> L.(debug Analysis Medium) "@\n    %a   @\n" pp c) constraints ;
    L.(debug Analysis Medium) "@\n******* END Structural Constraints **** @\n\n"


  (*  for each program point return a set of contraints of the kind

     i<=Sum_{j \in Predecessors(i) } j
     i<=Sum_{j \in Successors(i)} j
*)
  let compute_structural_constraints node_cfg =
    let compute_node_constraints acc node =
      let constraints_append node get_nodes tail =
        match get_nodes node with
        | [] ->
            tail
        | [single] ->
            {lhs= NodeCFG.id node; rhs= Single (NodeCFG.id single)} :: tail
        | nodes ->
            let sum =
              List.fold nodes ~init:Node.IdSet.empty ~f:(fun idset node ->
                  Node.IdSet.add (NodeCFG.id node) idset )
            in
            {lhs= NodeCFG.id node; rhs= Sum sum} :: tail
      in
      acc |> constraints_append node Procdesc.Node.get_preds
      |> constraints_append node Procdesc.Node.get_succs
    in
    let constraints = List.fold (NodeCFG.nodes node_cfg) ~f:compute_node_constraints ~init:[] in
    print_constraint_list constraints ; constraints
end

(* MinTree is used to compute:

    \max (\Sum_{n \in Nodes} c_n * x_n )

   given a set of contraints on x_n. The constraints involve the contro flow
    of the program.

*)
module MinTree = struct
  type mt_node = Leaf of (Node.id * Itv.Bound.t) | Min of mt_node list | Plus of mt_node list

  let add_leaf node nid leaf =
    let leaf' = Leaf (nid, leaf) in
    match node with Min l -> Min (leaf' :: l) | Plus l -> Plus (leaf' :: l) | _ -> assert false


  let plus_seq pp f l = Pp.seq ~sep:" + " pp f l

  let rec pp fmt node =
    match node with
    | Leaf (nid, c) ->
        F.fprintf fmt "%a:%a" Node.pp_id nid Itv.Bound.pp c
    | Min l ->
        F.fprintf fmt "Min(%a)" (Pp.comma_seq pp) l
    | Plus l ->
        F.fprintf fmt "(%a)" (plus_seq pp) l


  let add_child node child =
    match child with
    | Plus [] | Min [] ->
        node (* if it's a dummy child, don't add it *)
    | _ ->
      match node with Plus l -> Plus (child :: l) | Min l -> Min (child :: l) | _ -> assert false


  (* finds the subset of constraints of the form x_k <= x_j *)
  let get_k_single_constraints constraints k =
    List.filter_map constraints ~f:(StructuralConstraints.is_single ~lhs:k)


  (* finds the subset of constraints of the form x_k <= x_j1 +...+ x_jn and
return the addends of the sum x_j1+x_j2+..+x_j_n*)
  let get_k_sum_constraints constraints k =
    List.filter_map constraints ~f:(StructuralConstraints.is_sum ~lhs:k)


  let rec evaluate_tree t =
    match t with
    | Leaf (_, c) ->
        c
    | Min l ->
        evaluate_operator Itv.Bound.min_u l
    | Plus l ->
        evaluate_operator Itv.Bound.plus_u l


  and evaluate_operator op l =
    match l with
    | [] ->
        assert false
    | [c] ->
        evaluate_tree c
    | c :: l' ->
        let res_c = evaluate_tree c in
        let res_l' = evaluate_operator op l' in
        op res_c res_l'


  (*  a plus node is well formed if has at least two addends *)
  let is_well_formed_plus_node plus_node =
    match plus_node with Plus (_ :: _ :: _) -> true | _ -> false


  module SetOfSetsOfNodes = Caml.Set.Make (Node.IdSet)

  module BuiltTreeMap = Caml.Map.Make (struct
    type t = Node.id * Node.IdSet.t [@@deriving compare]
  end)

  let minimum_propagation (bound_map: BoundMap.t) (constraints: StructuralConstraints.t list) self
      ((q, visited): Node.id * Node.IdSet.t) =
    let rec build_min node branch visited_acc worklist =
      match worklist with
      | [] ->
          (node, branch, visited_acc)
      | k :: rest ->
          if Node.IdSet.mem k visited_acc then build_min node branch visited_acc rest
          else
            let visited_acc' = Node.IdSet.add k visited_acc in
            let node = add_leaf node k (BoundMap.upperbound bound_map k) in
            let k_constraints_upperbound = get_k_single_constraints constraints k in
            let worklist' =
              List.fold k_constraints_upperbound ~init:rest ~f:(fun acc ub_id ->
                  if Node.IdSet.mem ub_id visited_acc' then acc else ub_id :: acc )
            in
            let k_sum_constraints = get_k_sum_constraints constraints k in
            let branch =
              List.fold_left
                ~f:(fun branch set_addend ->
                  if Node.IdSet.is_empty (Node.IdSet.inter set_addend visited_acc') then
                    SetOfSetsOfNodes.add set_addend branch
                  else branch )
                ~init:branch k_sum_constraints
            in
            build_min node branch visited_acc' worklist'
    in
    let node, branch, visited_res = build_min (Min []) SetOfSetsOfNodes.empty visited [q] in
    SetOfSetsOfNodes.fold
      (fun addend i_node ->
        if Node.IdSet.cardinal addend < 2 then assert false
        else (
          L.(debug Analysis Medium) "@\n\n|Set addends| = %i  {" (Node.IdSet.cardinal addend) ;
          Node.IdSet.iter (fun e -> L.(debug Analysis Medium) " %a, " Node.pp_id e) addend ;
          L.(debug Analysis Medium) " }@\n " ) ;
        let plus_node =
          Node.IdSet.fold
            (fun n acc ->
              let child = self (n, visited_res) in
              add_child acc child )
            addend (Plus [])
        in
        (* without this check it would add plus node with just one child, and give wrong results *)
        if is_well_formed_plus_node plus_node then add_child i_node plus_node else i_node )
      branch node


  let with_cache f =
    (* a map used for bookkeeping of the min trees that we have already built *)
    let global_built_tree_map : mt_node BuiltTreeMap.t ref = ref BuiltTreeMap.empty in
    let rec f_with_cache x =
      match BuiltTreeMap.find_opt x !global_built_tree_map with
      | Some v ->
          v
      | None ->
          let v = f f_with_cache x in
          global_built_tree_map := BuiltTreeMap.add x v !global_built_tree_map ;
          v
    in
    Staged.stage f_with_cache


  let compute_trees_from_contraints bound_map node_cfg constraints =
    let minimum_propagation =
      with_cache (minimum_propagation bound_map constraints) |> Staged.unstage
    in
    let min_trees =
      List.fold
        ~f:(fun acc node ->
          let nid = Node.id node in
          let tree = minimum_propagation (nid, Node.IdSet.empty) in
          (nid, tree) :: acc )
        ~init:[] (NodeCFG.nodes node_cfg)
    in
    List.iter
      ~f:(fun (nid, t) -> L.(debug Analysis Medium) "@\n node %a = %a @\n" Node.pp_id nid pp t)
      min_trees ;
    min_trees
end

module ReportedOnNodes = AbstractDomain.FiniteSetOfPPSet (Node.IdSet)

type extras_TransferFunctionsWCET =
  { basic_cost_map: AnalyzerNodesBasicCost.invariant_map
  ; min_trees_map: Itv.Bound.t Node.IdMap.t
  ; summary: Specs.summary }

(* Calculate the final Worst Case Execution Time predicted for each node.
   It uses the basic cost of the nodes (computed previously by AnalyzerNodesBasicCost)
   and MinTrees which give an upperbound on the number of times a node can be executed
*)
module TransferFunctionsWCET = struct
  module CFG = InstrCFG
  module Domain = AbstractDomain.Pair (Itv.Bound) (ReportedOnNodes)

  type extras = extras_TransferFunctionsWCET

  let should_report_on_instr = function
    | Sil.Call _ | Sil.Load _ | Sil.Prune _ | Sil.Store _ ->
        true
    | Sil.Abstract _ | Sil.Declare_locals _ | Sil.Nullify _ | Sil.Remove_temps _ ->
        false


  (* We don't report when the cost is Top as it corresponds to subsequent 'don't know's.
   Instead, we report Top cost only at the top level per function when `report_infinity` is set to true *)
  let should_report_cost cost =
    Itv.Bound.is_not_infty cost && not (Itv.Bound.le cost expensive_threshold)


  let do_report summary loc cost =
    let ltr =
      let cost_desc = F.asprintf "with estimated cost %a" Itv.Bound.pp cost in
      [Errlog.make_trace_element 0 loc cost_desc []]
    in
    let exn =
      let message =
        F.asprintf
          "The execution time from the beginning of the function up to this program point is \
           likely above the acceptable threshold of %a (estimated cost %a)"
          Itv.Bound.pp expensive_threshold Itv.Bound.pp cost
      in
      Exceptions.Checkers (IssueType.expensive_execution_time_call, Localise.verbatim_desc message)
    in
    Reporting.log_error summary ~loc ~ltr exn


  (* get a list of nodes and check if we have already reported for at
     least one of them. In that case no need to report again. *)
  let should_report_on_node preds reported_so_far =
    List.for_all
      ~f:(fun node ->
        let nid = Procdesc.Node.get_id node in
        not (ReportedOnNodes.mem nid reported_so_far) )
      preds


  let map_cost trees m : Itv.Bound.t =
    CostDomain.NodeInstructionToCostMap.fold
      (fun ((node_id, _) as instr_node_id) c acc ->
        let t = Node.IdMap.find node_id trees in
        let c_node = Itv.Bound.mult c t in
        let c_node' = Itv.Bound.plus_u acc c_node in
        L.(debug Analysis Medium)
          "@\n  [AnalyzerWCET] Adding cost: (%a) --> c =%a  t = %a @\n" InstrCFG.pp_id
          instr_node_id Itv.Bound.pp c Itv.Bound.pp t ;
        L.(debug Analysis Medium)
          "@\n  [AnalyzerWCET] Adding cost: (%a) --> c_node=%a  cost = %a @\n" InstrCFG.pp_id
          instr_node_id Itv.Bound.pp c_node Itv.Bound.pp c_node' ;
        c_node' )
      m Itv.Bound.zero


  let exec_instr ((_, reported_so_far): Domain.astate) {ProcData.extras} (node: CFG.node) instr
      : Domain.astate =
    let {basic_cost_map= invariant_map_cost; min_trees_map= trees; summary} = extras in
    let cost_node =
      let instr_node_id = CFG.id node in
      match AnalyzerNodesBasicCost.extract_post instr_node_id invariant_map_cost with
      | Some node_map ->
          L.(debug Analysis Medium)
            "@\n AnalyzerWCET] Final map for node: %a @\n" CFG.pp_id instr_node_id ;
          map_cost trees node_map
      | _ ->
          assert false
    in
    L.(debug Analysis Medium)
      "@\n>>>AnalyzerWCET] Instr: %a   Cost: %a@\n" (Sil.pp_instr Pp.text) instr Itv.Bound.pp
      cost_node ;
    let astate' =
      let und_node = CFG.underlying_node node in
      let preds = Procdesc.Node.get_preds und_node in
      let reported_so_far =
        if
          should_report_on_instr instr && should_report_on_node (und_node :: preds) reported_so_far
          && should_report_cost cost_node
        then (
          do_report summary (Sil.instr_get_loc instr) cost_node ;
          let nid = Procdesc.Node.get_id und_node in
          ReportedOnNodes.add nid reported_so_far )
        else reported_so_far
      in
      (cost_node, reported_so_far)
    in
    astate'


  let pp_session_name _node fmt = F.pp_print_string fmt "cost(wcet)"
end

module AnalyzerWCET = AbstractInterpreter.MakeNoCFG (InstrCFGScheduler) (TransferFunctionsWCET)

let check_and_report_infinity cost proc_desc summary =
  if not (Itv.Bound.is_not_infty cost) then
    let loc = Procdesc.get_start_node proc_desc |> Procdesc.Node.get_loc in
    let message =
      F.asprintf "The execution time of the function %a cannot be computed" Typ.Procname.pp
        (Procdesc.get_proc_name proc_desc)
    in
    let exn =
      Exceptions.Checkers (IssueType.infinite_execution_time_call, Localise.verbatim_desc message)
    in
    Reporting.log_error ~loc summary exn


let checker ({Callbacks.tenv; proc_desc} as callback_args) : Specs.summary =
  let inferbo_invariant_map, summary =
    BufferOverrunChecker.compute_invariant_map_and_check callback_args
  in
  let proc_data = ProcData.make_default proc_desc tenv in
  let node_cfg = NodeCFG.from_pdesc proc_desc in
  (* computes the data dependencies: node -> (var -> var set) *)
  let data_dep_invariant_map =
    Control.DataDepAnalyzer.exec_cfg node_cfg proc_data ~initial:Control.DataDepMap.empty
      ~debug:true
  in
  (* computes the control dependencies: node -> var set *)
  let control_dep_invariant_map =
    Control.ControlDepAnalyzer.exec_cfg node_cfg proc_data ~initial:Control.ControlDepSet.empty
      ~debug:true
  in
  let instr_cfg = InstrCFG.from_pdesc proc_desc in
  let invariant_map_NodesBasicCost =
    let proc_data = ProcData.make proc_desc tenv inferbo_invariant_map in
    (*compute_WCET cfg invariant_map min_trees in *)
    AnalyzerNodesBasicCost.exec_cfg instr_cfg proc_data ~initial:NodesBasicCostDomain.empty
      ~debug:true
  in
  (* given the semantics computes the upper bound on the number of times a node could be executed *)
  let bound_map =
    BoundMap.compute_upperbound_map node_cfg inferbo_invariant_map data_dep_invariant_map
      control_dep_invariant_map
  in
  let constraints = StructuralConstraints.compute_structural_constraints node_cfg in
  L.internal_error "@\n[COST ANALYSIS] PROCESSING MIN_TREE for PROCEDURE '%a' |CFG| = %i "
    Typ.Procname.pp
    (Procdesc.get_proc_name proc_desc)
    (List.length (NodeCFG.nodes node_cfg)) ;
  let min_trees = MinTree.compute_trees_from_contraints bound_map node_cfg constraints in
  let trees_valuation =
    List.fold
      ~f:(fun acc (nid, t) ->
        let res = MinTree.evaluate_tree t in
        L.(debug Analysis Medium) "@\n   Tree %a eval to %a @\n" Node.pp_id nid Itv.Bound.pp res ;
        Node.IdMap.add nid res acc )
      ~init:Node.IdMap.empty min_trees
  in
  let initWCET = (Itv.Bound.zero, ReportedOnNodes.empty) in
  match
    AnalyzerWCET.compute_post
      (ProcData.make proc_desc tenv
         {basic_cost_map= invariant_map_NodesBasicCost; min_trees_map= trees_valuation; summary})
      ~debug:true ~initial:initWCET
  with
  | Some (exit_cost, _) ->
      L.internal_error "  PROCEDURE COST = %a @\n" Itv.Bound.pp exit_cost ;
      check_and_report_infinity exit_cost proc_desc summary ;
      Summary.update_summary {post= exit_cost} summary
  | None ->
      if Procdesc.Node.get_succs (Procdesc.get_start_node proc_desc) <> [] then (
        L.internal_error "Failed to compute final cost for function %a" Typ.Procname.pp
          (Procdesc.get_proc_name proc_desc) ;
        summary )
      else summary
