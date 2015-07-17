(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(** Interprocedural Analysis *)

module L = Logging
module F = Format
open Utils (* No abbreviation for Utils, as every module can depend on it *)

type visitednode =
  { node: Cfg.Node.t; visits: int }

(** Set of nodes with number of visits *)
module NodeVisitSet =
  Set.Make(struct
    type t = visitednode
    let compare_ids n1 n2 = Cfg.Node.compare n2 n1 (* higher id is better *)
    let compare_distance_to_exit { node = n1 } { node = n2 } = (* smaller means higher priority *)
      let n = match Cfg.Node.get_distance_to_exit n1, Cfg.Node.get_distance_to_exit n2 with
        | None, None -> 0
        | None, Some _ -> 1
        | Some _, None -> - 1
        | Some d1, Some d2 -> int_compare d1 d2 (* shorter distance to exit is better *) in
      if n <> 0 then n else compare_ids n1 n2
    let compare_number_of_visits x1 x2 =
      let n = int_compare x1.visits x2.visits in (* visited fewer times is better *)
      if n <> 0 then n else compare_distance_to_exit x1 x2
    let compare x1 x2 =
      if !Config.footprint then
        match !Config.worklist_mode with
        | 0 -> compare_ids x1.node x2.node
        | 1 -> compare_distance_to_exit x1 x2
        | _ -> compare_number_of_visits x1 x2
      else compare_ids x1.node x2.node
  end)

(* =============== START of module Worklist =============== *)
module Worklist = struct
  module NodeMap = Map.Make(Cfg.Node)
  let worklist : NodeVisitSet.t ref = ref NodeVisitSet.empty
  let map : int NodeMap.t ref = ref NodeMap.empty

  let reset pdesc =
    worklist := NodeVisitSet.empty;
    map := NodeMap.empty;
    Cfg.Procdesc.compute_distance_to_exit_node pdesc

  let is_empty () : bool =
    NodeVisitSet.is_empty !worklist

  let add (node : Cfg.node) : unit =
    let visits = try NodeMap.find node !map with Not_found -> 0 in
    worklist := NodeVisitSet.add { node = node; visits = visits } !worklist

  (** remove the minimum element from the worklist, and increase its number of visits *)
  let remove () : Cfg.Node.t =
    try
      let min = NodeVisitSet.min_elt !worklist in
      worklist := NodeVisitSet.remove min !worklist;
      map := NodeMap.add min.node (min.visits + 1) !map; (* increase the visits *)
      min.node
    with Not_found -> begin
          L.out "@\n...Work list is empty! Impossible to remove edge...@\n";
          assert false
        end
end
(* =============== END of module Worklist =============== *)

module Join_table : sig
  val reset : unit -> unit
  val find : int -> Paths.PathSet.t
  val put : int -> Paths.PathSet.t -> unit
end = struct
  let table : (int, Paths.PathSet.t) Hashtbl.t = Hashtbl.create 1024
  let reset () = Hashtbl.clear table
  let find i =
    try Hashtbl.find table i with Not_found -> Paths.PathSet.empty
  let put i dset = Hashtbl.replace table i dset
end

let path_set_visited : (int, Paths.PathSet.t) Hashtbl.t = Hashtbl.create 1024

let path_set_todo : (int, Paths.PathSet.t) Hashtbl.t = Hashtbl.create 1024

let path_set_worklist_reset pdesc =
  State.reset ();
  Hashtbl.clear path_set_visited;
  Hashtbl.clear path_set_todo;
  Join_table.reset ();
  Worklist.reset pdesc

let htable_retrieve (htable : (int, Paths.PathSet.t) Hashtbl.t) (key : int) : Paths.PathSet.t =
  try
    Hashtbl.find htable key
  with Not_found ->
      Hashtbl.replace htable key Paths.PathSet.empty;
      Paths.PathSet.empty

let path_set_get_visited (sid: int) : Paths.PathSet.t =
  htable_retrieve path_set_visited sid

(** Add [d] to the pathset todo at [node] returning true if changed *)
let path_set_put_todo (node: Cfg.node) (d: Paths.PathSet.t) : bool =
  let changed =
    if Paths.PathSet.is_empty d then false
    else
      let sid = Cfg.Node.get_id node in
      let old_todo = htable_retrieve path_set_todo sid in
      let old_visited = htable_retrieve path_set_visited sid in
      let d' = Paths.PathSet.diff d old_visited in (* differential fixpoint *)
      let todo_new = Paths.PathSet.union old_todo d' in
      Hashtbl.replace path_set_todo sid todo_new;
      not (Paths.PathSet.equal old_todo todo_new) in
  changed

let path_set_checkout_todo (node: Cfg.node) : Paths.PathSet.t =
  try
    let sid = Cfg.Node.get_id node in
    let todo = Hashtbl.find path_set_todo sid in
    Hashtbl.replace path_set_todo sid Paths.PathSet.empty;
    let visited = Hashtbl.find path_set_visited sid in
    let new_visited = Paths.PathSet.union visited todo in
    Hashtbl.replace path_set_visited sid new_visited;
    todo
  with Not_found ->
      L.out "@.@.ERROR: could not find todo for node %a@.@." Cfg.Node.pp node;
      assert false

(* =============== END of the edge_set object =============== *)

(* =============== START: Print a complete path in a dotty file =============== *)

let pp_path_dotty f path =
  let get_node_id_from_path p =
    let node = Paths.Path.curr_node p in
    Cfg.Node.get_id node in
  let count = ref 0 in
  let prev_n_id = ref 0 in
  let curr_n_id = ref 0 in
  prev_n_id:=- 1;
  let g level p session exn_opt =
    let curr_node = Paths.Path.curr_node p in
    let curr_path_set = htable_retrieve path_set_visited (Cfg.Node.get_id curr_node) in
    let plist = Paths.PathSet.filter_path p curr_path_set in
    incr count;
    curr_n_id:= (get_node_id_from_path p);
    Dotty.pp_dotty_prop_list_in_path f plist !prev_n_id !curr_n_id;
    L.out "@.Path #%d: %a@." !count Paths.Path.pp p;
    prev_n_id:=!curr_n_id in
  L.out "@.@.Printing Path: %a to file error_path.dot@." Paths.Path.pp path;
  Dotty.reset_proposition_counter ();
  Dotty.reset_dotty_spec_counter ();
  F.fprintf f "@\n@\n@\ndigraph main { \nnode [shape=box]; @\n";
  F.fprintf f "@\n compound = true; @\n";
  (*  F.fprintf f "@\n size=\"12,7\"; ratio=fill; @\n"; *)
  Paths.Path.iter_longest_sequence g None path;
  F.fprintf f "@\n}"

let pp_complete_path_dotty_file =
  let counter = ref 0 in
  fun path ->
      incr counter;
      let outc = open_out ("error_path" ^ string_of_int !counter ^ ".dot") in
      let fmt = F.formatter_of_out_channel outc in
      F.fprintf fmt "#### Dotty version:  ####@.%a@.@." pp_path_dotty path;
      close_out outc

(* =============== END: Print a complete path in a dotty file =============== *)

let collect_do_abstract_pre pname tenv (pset : Propset.t) : Propset.t =
  if !Config.footprint then begin
    Config.footprint := false;
    let pset' = Abs.lifted_abstract pname tenv pset in
    Config.footprint := true;
    pset'
  end
  else Abs.lifted_abstract pname tenv pset

let collect_do_abstract_post pname tenv (pathset : Paths.PathSet.t) : Paths.PathSet.t =
  let abs_option p =
    if Prover.check_inconsistency p then None
    else Some (Abs.abstract pname tenv p) in
  if !Config.footprint then begin
    Config.footprint := false;
    let pathset' = Paths.PathSet.map_option abs_option pathset in
    Config.footprint := true;
    pathset'
  end
  else Paths.PathSet.map_option abs_option pathset

let do_join_pre plist =
  Dom.proplist_collapse_pre plist

let do_join_post pname tenv (pset: Paths.PathSet.t) =
  if !Config.spec_abs_level <= 0 then
    Dom.pathset_collapse pset
  else
    Dom.pathset_collapse (Dom.pathset_collapse_impl pname tenv pset)

let do_meet_pre pset =
  if !Config.meet_level > 0 then
    Dom.propset_meet_generate_pre pset
  else
    Propset.to_proplist pset

(** Find the preconditions in the current spec table, apply meet then join, and return the joined preconditions *)
let collect_preconditions pname tenv proc_name : Prop.normal Specs.Jprop.t list =
  let collect_do_abstract_one tenv prop =
    if !Config.footprint then begin
      Config.footprint := false;
      let prop' = Abs.abstract_no_symop tenv prop in
      Config.footprint := true;
      prop' end
    else Abs.abstract_no_symop tenv prop in
  let pres = list_map (fun spec -> Specs.Jprop.to_prop spec.Specs.pre) (Specs.get_specs proc_name) in
  let pset = Propset.from_proplist pres in
  let pset' =
    let f p = Prop.prop_normal_vars_to_primed_vars p in
    Propset.map f pset in

  L.d_strln ("#### Extracted footprint of " ^ Procname.to_string proc_name ^ ":  ####");
  L.d_increase_indent 1; Propset.d Prop.prop_emp pset'; L.d_decrease_indent 1; L.d_ln ();
  L.d_ln ();
  let pset'' = collect_do_abstract_pre pname tenv pset' in
  let plist_meet = do_meet_pre pset'' in
  L.d_strln ("#### Footprint of " ^ Procname.to_string proc_name ^ " after Meet  ####");
  L.d_increase_indent 1; Propgraph.d_proplist Prop.prop_emp plist_meet; L.d_decrease_indent 1; L.d_ln ();
  L.d_ln ();
  L.d_increase_indent 2; (* Indent for the join output *)
  let jplist = do_join_pre plist_meet in
  L.d_decrease_indent 2; L.d_ln ();
  L.d_strln ("#### Footprint of " ^ Procname.to_string proc_name ^ " after Join  ####");
  L.d_increase_indent 1; Specs.Jprop.d_list false jplist; L.d_decrease_indent 1; L.d_ln ();
  let jplist' = list_map (Specs.Jprop.map Prop.prop_rename_primed_footprint_vars) jplist in
  L.d_strln ("#### Renamed footprint of " ^ Procname.to_string proc_name ^ ":  ####");
  L.d_increase_indent 1; Specs.Jprop.d_list false jplist'; L.d_decrease_indent 1; L.d_ln ();
  let jplist'' =
    let f p = Prop.prop_primed_vars_to_normal_vars (collect_do_abstract_one pname tenv p) in
    list_map (Specs.Jprop.map f) jplist' in
  L.d_strln ("#### Abstracted footprint of " ^ Procname.to_string proc_name ^ ":  ####");
  L.d_increase_indent 1; Specs.Jprop.d_list false jplist''; L.d_decrease_indent 1; L.d_ln();
  jplist''

(* =============== START of symbolic execution =============== *)

(* propagate a set of results to the given node *)
let propagate pname is_exception (pset: Paths.PathSet.t) (curr_node: Cfg.node) =
  let edgeset_todo =
    let f prop path edgeset_curr = (** prop must be a renamed prop by the invariant preserved by PropSet *)
      let exn_opt =
        if is_exception then Some (Tabulation.prop_get_exn_name pname prop)
        else None in
      Paths.PathSet.add_renamed_prop prop (Paths.Path.extend curr_node exn_opt (State.get_session ()) path) edgeset_curr in
    Paths.PathSet.fold f pset Paths.PathSet.empty in
  let changed = path_set_put_todo curr_node edgeset_todo in
  if changed then (Worklist.add curr_node)

(* propagate a set of results, including exceptions and divergence *)
let propagate_nodes_divergence
    tenv (pdesc: Cfg.Procdesc.t) (pset: Paths.PathSet.t)
    (path: Paths.Path.t) (kind_curr_node : Cfg.Node.nodekind) (_succ_nodes: Cfg.node list)
    (exn_nodes: Cfg.node list) =
  let pname = Cfg.Procdesc.get_proc_name pdesc in
  let pset_exn, pset_ok = Paths.PathSet.partition (Tabulation.prop_is_exn pname) pset in
  let succ_nodes = match State.get_goto_node () with (* handle Sil.Goto_node target, if any *)
    | Some node_id ->
        list_filter (fun n -> Cfg.Node.get_id n = node_id) _succ_nodes
    | None -> _succ_nodes in
  if !Config.footprint && not (Paths.PathSet.is_empty (State.get_diverging_states_node ())) then
    begin
      if !Config.developer_mode then Errdesc.warning_err (State.get_loc ()) "Propagating Divergence@.";
      let exit_node = Cfg.Procdesc.get_exit_node pdesc in
      let diverging_states = State.get_diverging_states_node () in
      let prop_incons =
        let mk_incons prop =
          let p_abs = Abs.abstract pname tenv prop in
          let p_zero = Prop.replace_sigma [] (Prop.replace_sub Sil.sub_empty p_abs) in
          Prop.normalize (Prop.replace_pi [Sil.Aneq (Sil.exp_zero, Sil.exp_zero)] p_zero) in
        Paths.PathSet.map mk_incons diverging_states in
      (L.d_strln_color Orange) "Propagating Divergence -- diverging states:";
      Propgraph.d_proplist Prop.prop_emp (Paths.PathSet.to_proplist prop_incons); L.d_ln ();
      propagate pname false prop_incons exit_node
    end;
  list_iter (propagate pname false pset_ok) succ_nodes;
  list_iter (propagate pname true pset_exn) exn_nodes

(* ===================== END of symbolic execution ===================== *)

(* =============== START of forward_tabulate =============== *)

(** Symbolic execution for a Join node *)
let do_symexec_join pname tenv curr_node (edgeset_todo : Paths.PathSet.t) =
  let curr_pdesc = Cfg.Node.get_proc_desc curr_node in
  let curr_pname = Cfg.Procdesc.get_proc_name curr_pdesc in
  let curr_id = Cfg.Node.get_id curr_node in
  let succ_nodes = Cfg.Node.get_succs curr_node in
  let new_dset = edgeset_todo in
  let old_dset = Join_table.find curr_id in
  let old_dset', new_dset' = Dom.pathset_join curr_pname tenv old_dset new_dset in
  Join_table.put curr_id (Paths.PathSet.union old_dset' new_dset');
  list_iter (fun node ->
          Paths.PathSet.iter (fun prop path ->
                  State.set_path path None;
                  propagate pname false (Paths.PathSet.from_renamed_list [(prop, path)]) node)
            new_dset') succ_nodes

let prop_max_size = ref (0, Prop.prop_emp)
let prop_max_chain_size = ref (0, Prop.prop_emp)

(* Check if the prop exceeds the current max *)
let check_prop_size p path =
  let size = Prop.Metrics.prop_size p in
  if size > fst !prop_max_size then
    (prop_max_size := (size, p);
      L.d_strln ("Prop with new max size " ^ string_of_int size ^ ":");
      Prop.d_prop p;
      L.d_ln ())

(* Check prop size and filter out possible unabstracted lists *)
let check_prop_size edgeset_todo =
  if !Config.monitor_prop_size then Paths.PathSet.iter check_prop_size edgeset_todo

let reset_prop_metrics () =
  prop_max_size := (0, Prop.prop_emp);
  prop_max_chain_size := (0, Prop.prop_emp)

(** dump a path *)
let d_path (path, pos_opt) =
  let step = ref 0 in
  let prop_last_step = ref Prop.prop_emp in (* if the last step had a singleton prop, store it here *)
  let f level p session exn_opt =
    let curr_node = Paths.Path.curr_node p in
    let curr_path_set = htable_retrieve path_set_visited (Cfg.Node.get_id curr_node) in
    let plist = Paths.PathSet.filter_path p curr_path_set in
    incr step;
    (* Propset.pp_proplist_dotty_file ("path" ^ (string_of_int !count) ^ ".dot") plist; *)
    L.d_strln ("Path Step #" ^ string_of_int !step ^
        " node " ^ string_of_int (Cfg.Node.get_id curr_node) ^
        " session " ^ string_of_int session ^ ":");
    Propset.d !prop_last_step (Propset.from_proplist plist); L.d_ln ();
    Cfg.Node.d_instrs true None curr_node; L.d_ln (); L.d_ln ();
    prop_last_step := (match plist with | [prop] -> prop | _ -> Prop.prop_emp) in
  L.d_str "Path: "; Paths.Path.d_stats path; L.d_ln ();
  Paths.Path.d path; L.d_ln ();
  (* pp_complete_path_dotty_file path; *)
  (* if !Config.write_dotty then Dotty.print_icfg_dotty (list_rev (get_edges path)) *)
  Paths.Path.iter_longest_sequence f pos_opt path

exception RE_EXE_ERROR

let do_before_node session node =
  let loc = Cfg.Node.get_loc node in
  let proc_desc = Cfg.Node.get_proc_desc node in
  let proc_name = Cfg.Procdesc.get_proc_name proc_desc in
  State.set_node node;
  State.set_session session;
  L.reset_delayed_prints ();
  Printer.start_session node loc proc_name session

let do_after_node node = Printer.finish_session node

(** Return the list of normal ids occurring in the instructions *)
let instrs_get_normal_vars instrs =
  let fav = Sil.fav_new () in
  let do_instr instr =
    let do_e e = Sil.exp_fav_add fav e in
    let exps = Sil.instr_get_exps instr in
    list_iter do_e exps in
  list_iter do_instr instrs;
  Sil.fav_filter_ident fav Ident.is_normal;
  Sil.fav_to_list fav

(* checks that boolean conditions on a conditional are assignment *)
(* The check is done as follows: we check that the successors or a node that make an *)
(* set instruction are prune nodes, they are all at the same location and the condition on*)
(* which they prune is the variable (or the negation) which was set in the set instruction *)
(* we exclude function calls: if (g(x,y)) ....*)
(* we check that prune nodes have simple guards: a var or its negation*)
let check_assignement_guard node =
  let pdesc = Cfg.Node.get_proc_desc node in
  let pname = Cfg.Procdesc.get_proc_name pdesc in
  let verbose = false in
  let node_contains_call n =
    let instrs = Cfg.Node.get_instrs n in
    let is_call = function
      | Sil.Call _ -> true
      | _ -> false in
    list_exists is_call instrs in
  let is_set_instr i =
    match i with
    | Sil.Set _ -> true
    | _ -> false in
  let is_prune_instr i =
    match i with
    | Sil.Prune _ -> true
    | _ -> false in
  let is_letderef_instr i =
    match i with
    | Sil.Letderef _ -> true
    | _ -> false in
  let is_cil_tmp e =
    match e with
    | Sil.Lvar pv ->
        Errdesc.pvar_is_cil_tmp pv
    | _ -> false in
  let is_edg_tmp e =
    match e with
    | Sil.Lvar pv ->
        Errdesc.pvar_is_edg_tmp pv
    | _ -> false in
  let succs = Cfg.Node.get_succs node in
  let l_node = Cfg.Node.get_last_loc node in
  (* e is prune if in all successors prune nodes we have for some temp n$1: *)
  (* n$1=*&e;Prune(n$1) or n$1=*&e;Prune(!n$1) *)
  let is_prune_exp e =
    let prune_var n =
      let ins = Cfg.Node.get_instrs n in
      let pi = list_filter is_prune_instr ins in
      let leti = list_filter is_letderef_instr ins in
      match pi, leti with
      | [Sil.Prune (Sil.Var(e1), _, _, _)], [Sil.Letderef(e2, e', _, _)]
      | [Sil.Prune (Sil.UnOp(Sil.LNot, Sil.Var(e1), _), _, _, _)], [Sil.Letderef(e2, e', _, _)] when (Ident.equal e1 e2) ->
          if verbose then L.d_strln ("Found "^(Sil.exp_to_string e')^" as prune var");
          [e']
      | _ -> [] in
    let prune_vars = list_flatten(list_map (fun n -> prune_var n) succs) in
    list_for_all (fun e' -> Sil.exp_equal e' e) prune_vars in
  let succs_loc = list_map (fun n -> Cfg.Node.get_loc n) succs in
  let succs_are_all_prune_nodes () =
    list_for_all (fun n -> match Cfg.Node.get_kind n with
            | Cfg.Node.Prune_node(_) -> true
            | _ -> false) succs in
  let succs_same_loc_as_node () =
    if verbose then (L.d_str ("LOCATION NODE: line: "^(string_of_int l_node.Sil.line)^" nLOC: "^(string_of_int l_node.Sil.nLOC)); L.d_strln " ");
    list_for_all (fun l ->
            if verbose then (L.d_str ("LOCATION l: line: "^(string_of_int l.Sil.line)^" nLOC: "^(string_of_int l.Sil.nLOC)); L.d_strln " ");
            Sil.loc_equal l l_node) succs_loc in
  let succs_have_simple_guards () = (* check that the guards of the succs are a var or its negation *)
    let check_instr = function
      | Sil.Prune (Sil.Var _, _, _, _) -> true
      | Sil.Prune (Sil.UnOp(Sil.LNot, Sil.Var _, _), _, _, _) -> true
      | Sil.Prune _ -> false
      | _ -> true in
    let check_guard n =
      list_for_all check_instr (Cfg.Node.get_instrs n) in
    list_for_all check_guard succs in
  if !Sil.curr_language = Sil.C_CPP && succs_are_all_prune_nodes () && succs_same_loc_as_node () && succs_have_simple_guards () then
    (let instr = Cfg.Node.get_instrs node in
      match succs_loc with
      | loc_succ:: _ -> (* at this point all successors are at the same location, so we can take the first*)
          let set_instr_at_succs_loc = list_filter (fun i -> (Sil.loc_equal (Sil.instr_get_loc i) loc_succ) && is_set_instr i) instr in
          (match set_instr_at_succs_loc with
            | [Sil.Set(e, _, _, _)] -> (* we now check if e is the same expression used to prune*)
                if (is_prune_exp e) && not ((node_contains_call node) && (is_cil_tmp e)) && not (is_edg_tmp e) then (
                  let desc = Errdesc.explain_condition_is_assignment l_node in
                  let exn = Exceptions.Condition_is_assignment (desc, try assert false with Assert_failure x -> x) in
                  let pre_opt = State.get_normalized_pre (Abs.abstract_no_symop pname) in
                  Reporting.log_warning pname ~loc: (Some l_node) ~pre: pre_opt exn
                )
                else ()
            | _ -> ())
      | _ -> if verbose then L.d_strln "NOT FOUND loc_succ"
    ) else ()

(** Perform symbolic execution for a node starting from an initial prop *)
let do_symbolic_execution handle_exn cfg tenv
    (node : Cfg.node) (prop: Prop.normal Prop.t) (path : Paths.Path.t) =
  let pdesc = Cfg.Node.get_proc_desc node in
  State.mark_execution_start node;
  State.set_const_map (ConstantPropagation.build_const_map pdesc); (* build the const map lazily *)
  check_assignement_guard node;
  let instrs = Cfg.Node.get_instrs node in
  Ident.update_name_generator (instrs_get_normal_vars instrs); (* fresh normal vars must be fresh w.r.t. instructions *)
  let pset =
    SymExec.lifted_sym_exec handle_exn cfg tenv pdesc
      (Paths.PathSet.from_renamed_list [(prop, path)]) node instrs in
  L.d_strln ".... After Symbolic Execution ....";
  Propset.d prop (Paths.PathSet.to_propset pset);
  L.d_ln (); L.d_ln();
  State.mark_execution_end node;
  pset

let mark_visited summary node =
  let id = Cfg.Node.get_id node in
  let stats = summary.Specs.stats in
  if !Config.footprint
  then stats.Specs.nodes_visited_fp <- IntSet.add id stats.Specs.nodes_visited_fp
  else stats.Specs.nodes_visited_re <- IntSet.add id stats.Specs.nodes_visited_re

let forward_tabulate cfg tenv =
  let handled_some_exception = ref false in
  let handle_exn curr_node exn =
    let curr_pdesc = Cfg.Node.get_proc_desc curr_node in
    let curr_pname = Cfg.Procdesc.get_proc_name curr_pdesc in
    Exceptions.print_exception_html "Failure of symbolic execution: " exn;
    let pre_opt = (* precondition leading to error, if any *)
      State.get_normalized_pre (Abs.abstract_no_symop curr_pname) in
    (match pre_opt with
      | Some pre ->
          L.d_strln "Precondition:"; Prop.d_prop pre; L.d_ln ()
      | None -> ());
    L.d_strln "SIL INSTR:";
    Cfg.Node.d_instrs ~sub_instrs: true (State.get_instr ()) curr_node; L.d_ln ();
    Reporting.log_error ~pre: pre_opt curr_pname exn;
    State.mark_instr_fail pre_opt exn;
    handled_some_exception := true in

  while not (Worklist.is_empty ()) do
    let curr_node = Worklist.remove () in
    let kind_curr_node = Cfg.Node.get_kind curr_node in
    let sid_curr_node = Cfg.Node.get_id curr_node in
    let proc_desc = Cfg.Node.get_proc_desc curr_node in
    let proc_name = Cfg.Procdesc.get_proc_name proc_desc in
    let summary = Specs.get_summary_unsafe proc_name in
    mark_visited summary curr_node; (* mark nodes visited in fp and re phases *)
    let session =
      incr summary.Specs.sessions;
      !(summary.Specs.sessions) in
    do_before_node session curr_node;
    let pathset_todo = path_set_checkout_todo curr_node in
    let succ_nodes = Cfg.Node.get_succs curr_node in
    let exn_nodes = Cfg.Node.get_exn curr_node in
    let exe_iter f pathset =
      let ps_size = Paths.PathSet.size pathset in
      let cnt = ref 0 in
      let exe prop path =
        State.set_path path None;
        incr cnt;
        f prop path !cnt ps_size in
      Paths.PathSet.iter exe pathset in
    let log_string proc_name =
      let phase_string = (if Specs.get_phase proc_name == Specs.FOOTPRINT then "FP" else "RE") in
      let summary = Specs.get_summary_unsafe proc_name in
      let timestamp = Specs.get_timestamp summary in
      F.sprintf "[%s:%d] %s" phase_string timestamp (Procname.to_string proc_name) in
    let doit () =
      handled_some_exception := false;
      check_prop_size pathset_todo;
      L.d_strln ("**** " ^ (log_string proc_name) ^ " " ^
          "Node: " ^ string_of_int sid_curr_node ^ ", " ^
          "Procedure: " ^ Procname.to_string proc_name ^ ", " ^
          "Session: " ^ string_of_int session ^ ", " ^
          "Todo: " ^ string_of_int (Paths.PathSet.size pathset_todo) ^ " ****");
      L.d_increase_indent 1;
      Propset.d Prop.prop_emp (Paths.PathSet.to_propset pathset_todo);
      L.d_strln ".... Instructions: .... ";
      Cfg.Node.d_instrs ~sub_instrs: true (State.get_instr ()) curr_node;
      L.d_ln (); L.d_ln ();

      match kind_curr_node with
      | Cfg.Node.Join_node -> do_symexec_join proc_name tenv curr_node pathset_todo
      | Cfg.Node.Stmt_node _
      | Cfg.Node.Prune_node _
      | Cfg.Node.Exit_node _
      | Cfg.Node.Skip_node _
      | Cfg.Node.Start_node _ ->
          exe_iter
            (fun prop path cnt num_paths ->
                  try
                    L.d_strln ("Processing prop " ^ string_of_int cnt ^ "/" ^ string_of_int num_paths);
                    L.d_increase_indent 1;
                    State.reset_diverging_states_goto_node ();
                    let pset =
                      do_symbolic_execution (handle_exn curr_node) cfg tenv curr_node prop path in
                    L.d_decrease_indent 1; L.d_ln();
                    propagate_nodes_divergence tenv proc_desc pset path kind_curr_node succ_nodes exn_nodes;
                  with exn when Exceptions.handle_exception exn && !Config.footprint ->
                      handle_exn curr_node exn;
                      if !Config.nonstop then propagate_nodes_divergence tenv proc_desc (Paths.PathSet.from_renamed_list [(prop, path)]) path kind_curr_node succ_nodes exn_nodes;
                      L.d_decrease_indent 1; L.d_ln ())
            pathset_todo in
    try begin
        doit();
        if !handled_some_exception then Printer.force_delayed_prints ();
        do_after_node curr_node
      end
    with
    | exn when Exceptions.handle_exception exn ->
        handle_exn curr_node exn;
        Printer.force_delayed_prints ();
        do_after_node curr_node;
        if not !Config.footprint then raise RE_EXE_ERROR
  done;
  L.d_strln ".... Work list empty. Stop ...."; L.d_ln ()

(** remove locals and formals, and check if the address of a stack variable is left in the result *)
let remove_locals_formals_and_check pdesc p =
  let pname = Cfg.Procdesc.get_proc_name pdesc in
  let pvars, p' = Cfg.remove_locals_formals pdesc p in
  let check_pvar pvar =
    let loc = Cfg.Node.get_loc (Cfg.Procdesc.get_exit_node pdesc) in
    let dexp_opt, _ = Errdesc.vpath_find p (Sil.Lvar pvar) in
    let desc = Errdesc.explain_stack_variable_address_escape loc pvar dexp_opt in
    let exn = Exceptions.Stack_variable_address_escape (desc, try assert false with Assert_failure x -> x) in
    Reporting.log_warning pname exn in
  list_iter check_pvar pvars;
  p'

(* Collect the analysis results for the exit node *)
let collect_analysis_result pdesc : Paths.PathSet.t =
  let exit_node = Cfg.Procdesc.get_exit_node pdesc in
  let exit_sid = Cfg.Node.get_id exit_node in
  let pathset = path_set_get_visited exit_sid in
  Paths.PathSet.map (remove_locals_formals_and_check pdesc) pathset

module Pmap = Map.Make (struct type t = Prop.normal Prop.t let compare = Prop.prop_compare end)

let vset_ref_add_path vset_ref path =
  Paths.Path.iter_all_nodes_nocalls (fun n -> vset_ref := Cfg.NodeSet.add n !vset_ref) path

let vset_ref_add_pathset vset_ref pathset =
  Paths.PathSet.iter (fun p path -> vset_ref_add_path vset_ref path) pathset

let compute_visited vset =
  let res = ref Specs.Visitedset.empty in
  let node_get_all_lines n =
    let node_loc = Cfg.Node.get_loc n in
    let instrs_loc = list_map Sil.instr_get_loc (Cfg.Node.get_instrs n) in
    let lines = list_map (fun loc -> loc.Sil.line) (node_loc :: instrs_loc) in
    list_remove_duplicates int_compare (list_sort int_compare lines) in
  let do_node n = res := Specs.Visitedset.add (Cfg.Node.get_id n, node_get_all_lines n) !res in
  Cfg.NodeSet.iter do_node vset;
  !res

(** Extract specs from a pathset *)
let extract_specs tenv pdesc pathset : Prop.normal Specs.spec list =
  let pname = Cfg.Procdesc.get_proc_name pdesc in
  let sub =
    let fav = Sil.fav_new () in
    Paths.PathSet.iter (fun prop path -> Prop.prop_fav_add fav prop) pathset;
    let sub_list = list_map (fun id -> (id, Sil.Var (Ident.create_fresh (Ident.knormal)))) (Sil.fav_to_list fav) in
    Sil.sub_of_list sub_list in
  let pre_post_visited_list =
    let pplist = Paths.PathSet.elements pathset in
    let f (prop, path) =
      let _, prop' = Cfg.remove_locals_formals pdesc prop in
      (* let () = L.out "@.BEFORE abs:@.$%a@." (Prop.pp_prop Utils.pe_text)  prop' in *)
      let prop'' = Abs.abstract pname tenv prop' in
      (* let () = L.out "@.AFTER abs:@.$%a@." (Prop.pp_prop Utils.pe_text) prop'' in *)
      let pre, post = Prop.extract_spec prop'' in
      let pre' = Prop.normalize (Prop.prop_sub sub pre) in
      let post' =
        if Prover.check_inconsistency_base prop then None
        else Some (Prop.normalize (Prop.prop_sub sub post), path) in
      let visited =
        let vset_ref = ref Cfg.NodeSet.empty in
        vset_ref_add_path vset_ref path;
        compute_visited !vset_ref in
      (pre', post', visited) in
    list_map f pplist in
  let pre_post_map =
    let add map (pre, post, visited) =
      let current_posts, current_visited = try Pmap.find pre map with Not_found -> (Paths.PathSet.empty, Specs.Visitedset.empty) in
      let new_posts = match post with
        | None -> current_posts
        | Some (post, path) -> Paths.PathSet.add_renamed_prop post path current_posts in
      let new_visited = Specs.Visitedset.union visited current_visited in
      Pmap.add pre (new_posts, new_visited) map in
    list_fold_left add Pmap.empty pre_post_visited_list in
  let specs = ref [] in
  let add_spec pre ((posts : Paths.PathSet.t), visited) =
    let posts' =
      list_map
        (fun (p, path) -> (Cfg.remove_seed_vars p, path))
        (Paths.PathSet.elements (do_join_post pname tenv posts)) in
    let spec =
      { Specs.pre = Specs.Jprop.Prop (1, pre);
        Specs.posts = posts';
        Specs.visited = visited } in
    specs := spec :: !specs in
  Pmap.iter add_spec pre_post_map;
  !specs

let collect_postconditions tenv pdesc : Paths.PathSet.t * Specs.Visitedset.t =
  let pname = Cfg.Procdesc.get_proc_name pdesc in
  let pathset = collect_analysis_result pdesc in
  L.d_strln ("#### [FUNCTION " ^ Procname.to_string pname ^ "] Analysis result ####");
  Propset.d Prop.prop_emp (Paths.PathSet.to_propset pathset);
  L.d_ln ();
  let res =
    try
      let pathset = collect_do_abstract_post pname tenv pathset in
      let pathset_diverging = State.get_diverging_states_proc () in
      let visited =
        let vset_ref = ref Cfg.NodeSet.empty in
        vset_ref_add_pathset vset_ref pathset;
        vset_ref_add_pathset vset_ref pathset_diverging; (* nodes from diverging states were also visited *)
        compute_visited !vset_ref in
      do_join_post pname tenv pathset, visited with
    | exn when (match exn with Exceptions.Leak _ -> true | _ -> false) ->
        raise (Failure "Leak in post collecion") in
  L.d_strln ("#### [FUNCTION " ^ Procname.to_string pname ^ "] Postconditions after join ####");
  L.d_increase_indent 1; Propset.d Prop.prop_emp (Paths.PathSet.to_propset (fst res)); L.d_decrease_indent 1;
  L.d_ln ();
  res

let create_seed_vars sigma =
  let hpred_add_seed sigma = function
    | Sil.Hpointsto (Sil.Lvar pv, se, typ) when not (Sil.pvar_is_abducted pv) ->
        Sil.Hpointsto(Sil.Lvar (Sil.pvar_to_seed pv), se, typ) :: sigma
    | _ -> sigma in
  list_fold_left hpred_add_seed [] sigma

(** Initialize proposition for execution given formal and global
parameters. The footprint is initialized according to the
execution mode. The prop is not necessarily emp, so it
should be incorporated when the footprint is constructed. *)
let prop_init_formals_seed tenv new_formals (prop : 'a Prop.t) : Prop.exposed Prop.t =
  let sigma_new_formals =
    let do_formal (pv, typ) =
      let texp = match !Sil.curr_language with
        | Sil.C_CPP -> Sil.Sizeof (typ, Sil.Subtype.exact)
        | Sil.Java -> Sil.Sizeof (typ, Sil.Subtype.subtypes) in
      Prop.mk_ptsto_lvar (Some tenv) Prop.Fld_init Sil.inst_formal (pv, texp, None) in
    list_map do_formal new_formals in
  let sigma_seed =
    create_seed_vars (Prop.get_sigma prop @ sigma_new_formals) (* formals already there plus new ones *) in
  let sigma = sigma_seed @ sigma_new_formals in
  let new_pi =
    let pi = Prop.get_pi prop in
    pi
  (* inactive until it becomes necessary, as it pollutes props
  let fav_ids = Sil.fav_to_list (Prop.sigma_fav sigma_locals) in
  let mk_undef_atom id = Prop.mk_neq (Sil.Var id) (Sil.Const (Sil.Cattribute (Sil.Aundef "UNINITIALIZED"))) in
  let pi_undef = list_map mk_undef_atom fav_ids in
  pi_undef @ pi *) in
  let prop' =
    Prop.replace_pi new_pi (Prop.prop_sigma_star prop sigma) in
  Prop.replace_sigma_footprint (Prop.get_sigma_footprint prop' @ sigma_new_formals) prop'

(** Construct an initial prop by extending [prop] with locals, and formals if [add_formals] is true
as well as seed variables *)
let initial_prop tenv (curr_f: Cfg.Procdesc.t) (prop : 'a Prop.t) add_formals : Prop.normal Prop.t =
  let construct_decl (x, typ) =
    (Sil.mk_pvar (Mangled.from_string x) (Cfg.Procdesc.get_proc_name curr_f), typ) in
  let new_formals =
    if add_formals
    then list_map construct_decl (Cfg.Procdesc.get_formals curr_f)
    else [] in (** no new formals added *)
  let prop1 = Prop.prop_reset_inst (fun inst_old -> Sil.update_inst inst_old Sil.inst_formal) prop in
  let prop2 = prop_init_formals_seed tenv new_formals prop1 in
  Prop.prop_rename_primed_footprint_vars (Prop.normalize prop2)

(** Construct an initial prop from the empty prop *)
let initial_prop_from_emp tenv curr_f =
  initial_prop tenv curr_f Prop.prop_emp true

(** Construct an initial prop from an existing pre with formals *)
let initial_prop_from_pre tenv curr_f pre =
  if !Config.footprint then
    let vars = Sil.fav_to_list (Prop.prop_fav pre) in
    let sub_list = list_map (fun id -> (id, Sil.Var (Ident.create_fresh (Ident.kfootprint)))) vars in
    let sub = Sil.sub_of_list sub_list in
    let pre2 = Prop.prop_sub sub pre in
    let pre3 = Prop.replace_sigma_footprint (Prop.get_sigma pre2) (Prop.replace_pi_footprint (Prop.get_pure pre2) pre2) in
    initial_prop tenv curr_f pre3 false
  else
    initial_prop tenv curr_f pre false

(** Re-execute one precondition and return some spec if there was no re-execution error. *)
let execute_filter_prop cfg tenv pdesc init_node (precondition : Prop.normal Specs.Jprop.t)
: Prop.normal Specs.spec option =
  let proc_name = Cfg.Procdesc.get_proc_name pdesc in
  do_before_node 0 init_node;
  L.d_strln ("#### Start: RE-execution for " ^ Procname.to_string proc_name ^ " ####");
  L.d_indent 1;
  L.d_strln "Precond:"; Specs.Jprop.d_shallow precondition;
  L.d_ln (); L.d_ln ();
  let init_prop = initial_prop_from_pre tenv pdesc (Specs.Jprop.to_prop precondition) in
  let init_edgeset = Paths.PathSet.add_renamed_prop init_prop (Paths.Path.start init_node) Paths.PathSet.empty in
  do_after_node init_node;
  try
    path_set_worklist_reset pdesc;
    Worklist.add init_node;
    ignore (path_set_put_todo init_node init_edgeset);
    forward_tabulate cfg tenv;
    do_before_node 0 init_node;
    L.d_strln_color Green ("#### Finished: RE-execution for " ^ Procname.to_string proc_name ^ " ####");
    L.d_increase_indent 1;
    L.d_strln "Precond:"; Prop.d_prop (Specs.Jprop.to_prop precondition);
    L.d_ln ();
    let posts, visited =
      let pset, visited = collect_postconditions tenv pdesc in
      let plist = list_map (fun (p, path) -> (Cfg.remove_seed_vars p, path)) (Paths.PathSet.elements pset) in
      plist, visited in
    let pre =
      let p = Cfg.remove_locals_ret pdesc (Specs.Jprop.to_prop precondition) in
      match precondition with
      | Specs.Jprop.Prop (n, _) -> Specs.Jprop.Prop (n, p)
      | Specs.Jprop.Joined (n, _, jp1, jp2) -> Specs.Jprop.Joined (n, p, jp1, jp2) in
    let spec = { Specs.pre = pre; Specs.posts = posts; Specs.visited = visited } in
    L.d_decrease_indent 1;
    do_after_node init_node;
    Some spec
  with RE_EXE_ERROR ->
      do_before_node 0 init_node;
      Printer.force_delayed_prints ();
      L.d_strln_color Red ("#### [FUNCTION " ^ Procname.to_string proc_name ^ "] ...ERROR");
      L.d_increase_indent 1;
      L.d_strln "when starting from pre:";
      Prop.d_prop (Specs.Jprop.to_prop precondition);
      L.d_strln "This precondition is filtered out.";
      L.d_decrease_indent 1;
      do_after_node init_node;
      None

(** get all the nodes in the current call graph with their defined children *)
let get_procs_and_defined_children call_graph =
  list_map (fun (n, ns) -> (n, Procname.Set.elements ns)) (Cg.get_nodes_and_defined_children call_graph)

let pp_intra_stats cfg proc_desc fmt proc_name =
  let nstates = ref 0 in
  let nodes = Cfg.Procdesc.get_nodes proc_desc in
  list_iter (fun node -> nstates := !nstates + Paths.PathSet.size (path_set_get_visited (Cfg.Node.get_id node))) nodes;
  F.fprintf fmt "(%d nodes containing %d states)" (list_length nodes) !nstates

(** Return functions to perform one phase of the analysis for a procedure.
Given [proc_name], return [do, get_results] where [go ()] performs the analysis phase
and [get_results ()] returns the results computed.
This function is architected so that [get_results ()] can be called even after
[go ()] was interrupted by and exception. *)
let perform_analysis_phase cfg tenv (pname : Procname.t) (pdesc : Cfg.Procdesc.t)
: (unit -> unit) * (unit -> Prop.normal Specs.spec list) =
  let start_node = Cfg.Procdesc.get_start_node pdesc in

  let check_recursion_level () =
    let summary = Specs.get_summary_unsafe pname in
    let recursion_level = Specs.get_timestamp summary in
    if recursion_level > !Config.max_recursion then
      begin
        L.err "Reached maximum level of recursion, raising a Timeout@.";
        raise (Timeout_exe (TOrecursion recursion_level))
      end in

  let compute_footprint : (unit -> unit) * (unit -> Prop.normal Specs.spec list) =
    let go () =
      let init_prop = initial_prop_from_emp tenv pdesc in
      let init_props_from_pres = (* use existing pre's (in recursion some might exist) as starting points *)
        let specs = Specs.get_specs pname in
        let mk_init precondition = (* rename spec vars to footrpint vars, and copy current to footprint *)
          initial_prop_from_pre tenv pdesc (Specs.Jprop.to_prop precondition) in
        list_map (fun spec -> mk_init spec.Specs.pre) specs in
      let init_props = Propset.from_proplist (init_prop :: init_props_from_pres) in
      let init_edgeset =
        let add pset prop =
          Paths.PathSet.add_renamed_prop prop (Paths.Path.start start_node) pset in
        Propset.fold add Paths.PathSet.empty init_props in
      L.out "@.#### Start: Footprint Computation for %a ####@." Procname.pp pname;
      L.d_increase_indent 1;
      L.d_strln "initial props =";
      Propset.d Prop.prop_emp init_props; L.d_ln (); L.d_ln();
      L.d_decrease_indent 1;
      path_set_worklist_reset pdesc;
      check_recursion_level ();
      Worklist.add start_node;
      Config.arc_mode := Hashtbl.mem (Cfg.Procdesc.get_flags pdesc) Mleak_buckets.objc_arc_flag;
      ignore (path_set_put_todo start_node init_edgeset);
      forward_tabulate cfg tenv;
    in
    let get_results () =
      State.process_execution_failures Reporting.log_warning pname;
      let results = collect_analysis_result pdesc in
      L.out "#### [FUNCTION %a] ... OK #####@\n" Procname.pp pname;
      L.out "#### Finished: Footprint Computation for %a %a ####@."
        Procname.pp pname
        (pp_intra_stats cfg pdesc) pname;
      L.out "#### [FUNCTION %a] Footprint Analysis result ####@\n%a@."
        Procname.pp pname
        (Paths.PathSet.pp pe_text) results;
      let specs = try extract_specs tenv pdesc results with
        | Exceptions.Leak _ ->
            let exn =
              Exceptions.Internal_error
              (Localise.verbatim_desc "Leak_while_collecting_specs_after_footprint") in
            let pre_opt = State.get_normalized_pre (Abs.abstract_no_symop pname) in
            Reporting.log_error pname ~pre: pre_opt exn;
            [] (* retuning no specs *) in
      specs in
    go, get_results in

  let re_execution proc_name : (unit -> unit) * (unit -> Prop.normal Specs.spec list) =
    let candidate_preconditions = list_map (fun spec -> spec.Specs.pre) (Specs.get_specs proc_name) in
    let valid_specs = ref [] in
    let go () =
      L.out "@.#### Start: Re-Execution for %a ####@." Procname.pp proc_name;
      check_recursion_level ();
      let filter p =
        let speco = execute_filter_prop cfg tenv pdesc start_node p in
        let is_valid = match speco with
          | None -> false
          | Some spec ->
              valid_specs := !valid_specs @ [spec];
              true in
        let outcome = if is_valid then "pass" else "fail" in
        L.out "Finished re-execution for precondition %d %a (%s)@."
          (Specs.Jprop.to_number p)
          (pp_intra_stats cfg pdesc) proc_name
          outcome;
        speco in
      if !Config.undo_join then
        ignore (Specs.Jprop.filter filter candidate_preconditions)
      else
        ignore (list_map filter candidate_preconditions) in
    let get_results () =
      let specs = !valid_specs in
      L.out "#### [FUNCTION %a] ... OK #####@\n" Procname.pp proc_name;
      L.out "#### Finished: Re-Execution for %a ####@." Procname.pp proc_name;
      let valid_preconditions = list_map (fun spec -> spec.Specs.pre) specs in
      let filename = DB.Results_dir.path_to_filename DB.Results_dir.Abs_source_dir [(Procname.to_filename proc_name)] in
      if !Config.write_dotty then
        Dotty.pp_speclist_dotty_file filename specs;
      L.out "@.@.================================================";
      L.out "@. *** CANDIDATE PRECONDITIONS FOR %a: " Procname.pp proc_name;
      L.out "@.================================================@.";
      L.out "@.%a @.@." (Specs.Jprop.pp_list pe_text false) candidate_preconditions;
      L.out "@.@.================================================";
      L.out "@. *** VALID PRECONDITIONS FOR %a: " Procname.pp proc_name;
      L.out "@.================================================@.";
      L.out "@.%a @.@." (Specs.Jprop.pp_list pe_text true) valid_preconditions;
      specs in
    go, get_results in

  match Specs.get_phase pname with
  | Specs.FOOTPRINT ->
      compute_footprint
  | Specs.RE_EXECUTION ->
      re_execution pname

let set_current_language cfg proc_desc =
  let language = (Cfg.Procdesc.get_attributes proc_desc).Sil.language in
  Sil.curr_language := language

(** reset counters before analysing a procedure *)
let reset_global_counters cfg proc_name proc_desc =
  Ident.reset_name_generator ();
  SymOp.reset_total ();
  reset_prop_metrics ();
  Abs.abs_rules_reset ();
  set_current_language cfg proc_desc

(* Collect all pairs of the kind (precondition, exception) from a summary *)
let exception_preconditions tenv pname summary =
  let collect_exceptions pre exns (prop, path) =
    if Tabulation.prop_is_exn pname prop then
      let exn_name = Tabulation.prop_get_exn_name pname prop in
      if AndroidFramework.is_runtime_exception tenv exn_name then
        (pre, exn_name):: exns
      else exns
    else exns
  and collect_errors pre errors (prop, path) =
    match Tabulation.lookup_global_errors prop with
    | None -> errors
    | Some e -> (pre, e) :: errors in
  let collect_spec errors spec =
    match !Sil.curr_language with
    | Sil.Java ->
        list_fold_left (collect_exceptions spec.Specs.pre) errors spec.Specs.posts
    | Sil.C_CPP ->
        list_fold_left (collect_errors spec.Specs.pre) errors spec.Specs.posts in
  list_fold_left collect_spec [] (Specs.get_specs_from_payload summary)


(* Remove the constrain of the form this != null which is true for all Java virtual calls *)
let remove_this_not_null prop =
  let collect_hpred (var_option, hpreds) = function
    | Sil.Hpointsto (Sil.Lvar pvar, Sil.Eexp (Sil.Var var, _), _) when Sil.pvar_is_this pvar ->
        (Some var, hpreds)
    | hpred -> (var_option, hpred:: hpreds) in
  let collect_atom var atoms = function
    | Sil.Aneq (Sil.Var v, e)
    when Ident.equal v var && Sil.exp_equal e Sil.exp_null -> atoms
    | a -> a:: atoms in
  match list_fold_left collect_hpred (None, []) (Prop.get_sigma prop) with
  | None, _ -> prop
  | Some var, filtered_hpreds ->
      let filtered_atoms =
        list_fold_left (collect_atom var) [] (Prop.get_pi prop) in
      let prop' = Prop.replace_pi filtered_atoms Prop.prop_emp in
      let prop'' = Prop.replace_sigma filtered_hpreds prop' in
      Prop.normalize prop''


(** Detects if there are specs of the form {precondition} proc {runtime exception} and report
an error in that case, generating the trace that lead to the runtime exception if the method is
called in the context { precondition } *)
let report_runtime_exceptions tenv cfg pdesc summary =
  let pname = Specs.get_proc_name summary in
  let is_public_method =
    (Specs.get_attributes summary).Sil.access = Sil.Public in
  let is_main =
    is_public_method
    (* TODO (#4559939): add check for static method *)
    && Procname.is_java pname
    && (Procname.java_get_method pname) = "main" in
  let is_annotated =
    let annotated_signature =
      Annotations.get_annotated_signature
        Specs.proc_get_method_annotation pdesc pname in
    let ret_annotation, _ = annotated_signature.Annotations.ret in
    Annotations.ia_is_verify ret_annotation in
  let is_unavoidable pre =
    let prop = remove_this_not_null (Specs.Jprop.to_prop pre) in
    match Prop.CategorizePreconditions.categorize [prop] with
    | Prop.CategorizePreconditions.NoPres
    | Prop.CategorizePreconditions.Empty -> true
    | _ -> false in
  let should_report pre =
    is_main || is_annotated || is_unavoidable pre in
  let report (pre, runtime_exception) =
    if should_report pre then
      let pre_str =
        Utils.pp_to_string (Prop.pp_prop pe_text) (Specs.Jprop.to_prop pre) in
      let exn_desc = Localise.java_unchecked_exn_desc pname runtime_exception pre_str in
      let exn = Exceptions.Java_runtime_exception (runtime_exception, pre_str, exn_desc) in
      Reporting.log_error pname ~pre: (Some (Specs.Jprop.to_prop pre)) exn in
  list_iter report (exception_preconditions tenv pname summary)


(** update a summary after analysing a procedure *)
let update_summary prev_summary specs proc_name elapsed res =
  let normal_specs = list_map Specs.spec_normalize specs in
  let new_specs, changed = Fork.update_specs proc_name normal_specs in
  let timestamp = max 1 (prev_summary.Specs.timestamp + if changed then 1 else 0) in
  let stats_time = prev_summary.Specs.stats.Specs.stats_time +. elapsed in
  let symops = prev_summary.Specs.stats.Specs.symops + SymOp.get_total () in
  let timeout = res == None || prev_summary.Specs.stats.Specs.stats_timeout in
  let stats =
    { prev_summary.Specs.stats with
      Specs.stats_time = stats_time;
      Specs.symops = symops;
      Specs.stats_timeout = timeout } in
  { prev_summary with
    Specs.stats = stats;
    Specs.payload = Specs.PrePosts new_specs;
    Specs.timestamp = timestamp }


(** Analyze [proc_name] and return the updated summary. Use module
[Timeout] to call [perform_analysis_phase] with a time limit, and
then return the updated summary. Executed as a child process. *)
let analyze_proc exe_env (proc_name: Procname.t) : Specs.summary =
  if !Config.trace_anal then L.err "===analyze_proc@.";
  let init_time = Unix.gettimeofday () in
  let tenv = Exe_env.get_tenv exe_env proc_name in
  let cfg = Exe_env.get_cfg exe_env proc_name in
  let proc_desc = match Cfg.Procdesc.find_from_name cfg proc_name with
    | Some proc_desc -> proc_desc
    | None -> assert false in
  reset_global_counters cfg proc_name proc_desc;
  let go, get_results = perform_analysis_phase cfg tenv proc_name proc_desc in
  let res = Fork.Timeout.exe_timeout (Specs.get_iterations proc_name) go () in
  let specs = get_results () in
  let elapsed = Unix.gettimeofday () -. init_time in
  let prev_summary = Specs.get_summary_unsafe proc_name in
  let updated_summary =
    update_summary prev_summary specs proc_name elapsed res in
  if (!Sil.curr_language <> Sil.Java && Config.report_assertion_failure)
     || !Config.report_runtime_exceptions then
    report_runtime_exceptions tenv cfg proc_desc updated_summary;
  updated_summary

(** Perform phase transition from [FOOTPRINT] to [RE_EXECUTION] for
the procedures enabled after the analysis of [proc_name] *)
let perform_transition exe_env cg proc_name =
  let proc_names = Fork.should_perform_transition cg proc_name in
  let transition pname =
    let tenv = Exe_env.get_tenv exe_env pname in
    let joined_pres = (* disable exceptions for leaks and protect against any other errors *)
      let allowleak = !Config.allowleak in
      let apply_start_node f = (* apply the start node to f, and do nothing in case of exception *)
        try
          match Cfg.Procdesc.find_from_name (Exe_env.get_cfg exe_env pname) pname with
          | Some pdesc ->
              let start_node = Cfg.Procdesc.get_start_node pdesc in
              f start_node
          | None -> ()
        with exn when exn_not_timeout exn -> () in
      apply_start_node (do_before_node 0);
      try
        Config.allowleak := true;
        let res = collect_preconditions proc_name tenv pname in
        Config.allowleak := allowleak;
        apply_start_node do_after_node;
        res
      with exn when exn_not_timeout exn ->
          apply_start_node do_after_node;
          Config.allowleak := allowleak;
          L.err "Error in collect_preconditions for %a@." Procname.pp proc_name;
          let err_name, _, mloco, _, _, _, _ = Exceptions.recognize_exception exn in
          let err_str = "exception raised " ^ (Localise.to_string err_name) in
          L.err "Error: %s %a@." err_str pp_ml_location_opt mloco;
          [] in
    Fork.transition_footprint_re_exe pname joined_pres in
  list_iter transition proc_names

(** Process the result of the analysis of [proc_name]: update the
returned summary and add it to the spec table. Executed in the
parent process as soon as a child process returns a result. *)
let process_result (exe_env: Exe_env.t) (proc_name, calls) (_summ: Specs.summary) : unit =
  if !Config.trace_anal then L.err "===process_result@.";
  Ident.reset_name_generator (); (* for consistency with multi-core mode *)
  let summ = { _summ with Specs.status = Specs.INACTIVE; Specs.stats = { _summ.Specs.stats with Specs.stats_calls = calls }} in
  Specs.add_summary proc_name summ;
  let call_graph = Exe_env.get_cg exe_env in
  perform_transition exe_env call_graph proc_name;
  if !Config.only_footprint || summ.Specs.phase != Specs.FOOTPRINT then
    (try Specs.store_summary proc_name summ with
      Sys_error s ->
        L.err "@.### System Error while writing summary of procedure %a to disk: %s@." Procname.pp proc_name s);
  let procs_done = Fork.procs_become_done call_graph proc_name in
  Fork.post_process_procs exe_env procs_done

(** Return true if the analysis of [proc_name] should be
skipped. Called by the parent process before attempting to analyze a
proc. *)
let filter_out (call_graph: Cg.t) (proc_name: Procname.t) : bool =
  if !Config.trace_anal then L.err "===filter_out@.";
  let slice_out = (* filter out if slicing is active and [proc_name] not in slice *)
    (!Config.slice_fun <> "") &&
    (Procname.compare (Procname.from_string !Config.slice_fun) proc_name != 0) &&
    (Cg.node_defined call_graph proc_name) &&
    not (Cg.calls_recursively call_graph (Procname.from_string !Config.slice_fun) proc_name) in
  slice_out

let check_skipped_procs procs_and_defined_children =
  let skipped_procs = ref Procname.Set.empty in
  let proc_check_skips (pname, dep) =
    let process_skip () =
      let call_stats = (Specs.get_summary_unsafe pname).Specs.stats.Specs.call_stats in
      let do_tr_elem pn = function
        | Specs.CallStats.CR_skip, _ ->
            skipped_procs := Procname.Set.add pn !skipped_procs
        | _ -> () in
      let do_call (pn, _) (tr: Specs.CallStats.trace) = list_iter (do_tr_elem pn) tr in
      Specs.CallStats.iter do_call call_stats in
    if Specs.summary_exists pname then process_skip () in
  list_iter proc_check_skips procs_and_defined_children;
  let skipped_procs_with_summary =
    Procname.Set.filter Specs.summary_exists !skipped_procs in
  skipped_procs_with_summary

(** create a function to filter procedures which were skips but now have a .specs file *)
let filter_skipped_procs cg procs_and_defined_children =
  let skipped_procs_with_summary = check_skipped_procs procs_and_defined_children in
  let filter (pname, dep) =
    let calls_recurs pn =
      let r = try Cg.calls_recursively cg pname pn with Not_found -> false in
      L.err "calls recursively %a %a: %b@." Procname.pp pname Procname.pp pn r;
      r in
    Procname.Set.exists calls_recurs skipped_procs_with_summary in
  filter

(** create a function to filter procedures which were analyzed before but had no specs *)
let filter_nospecs (pname, dep) =
  if Specs.summary_exists pname
  then Specs.get_specs pname = []
  else false

(** Perform the analysis of an exe_env *)
let do_analysis exe_env =
  if !Config.trace_anal then L.err "do_analysis@.";
  let do_parallel = !Config.num_cores > 1 || !Config.max_num_proc > 0 in
  let cg = Exe_env.get_cg exe_env in
  let procs_and_defined_children = get_procs_and_defined_children cg in
  let get_calls caller_pdesc =
    let calls = ref [] in
    let f (callee_pname, loc) = calls := (callee_pname, loc) :: !calls in
    Cfg.Procdesc.iter_calls f caller_pdesc;
    list_rev !calls in
  let init_proc (pname, dep) =
    let cfg = Exe_env.get_cfg exe_env pname in
    let pdesc = match Cfg.Procdesc.find_from_name cfg pname with
      | Some pdesc -> pdesc
      | None -> assert false in
    let ret_type = Cfg.Procdesc.get_ret_type pdesc in
    let formals = Cfg.Procdesc.get_formals pdesc in
    let loc = Cfg.Procdesc.get_loc pdesc in
    let nodes = list_map (fun n -> Cfg.Node.get_id n) (Cfg.Procdesc.get_nodes pdesc) in
    let proc_flags = Cfg.Procdesc.get_flags pdesc in
    let static_err_log = Cfg.Procdesc.get_err_log pdesc in (** err log from translation *)
    let calls = get_calls pdesc in
    let cyclomatic = Cfg.Procdesc.get_cyclomatic pdesc in
    let attributes = Cfg.Procdesc.get_attributes pdesc in

    Callbacks.proc_inline_synthetic_methods cfg pdesc;
    Specs.init_summary
      (pname, ret_type, formals, dep, loc, nodes, proc_flags,
        static_err_log, calls, cyclomatic, None, attributes) in
  let filter =
    if !Config.only_skips then (filter_skipped_procs cg procs_and_defined_children)
    else if !Config.only_nospecs then filter_nospecs
    else (fun _ -> true) in
  list_iter (fun x -> if filter x then init_proc x) procs_and_defined_children;
  (try Fork.parallel_iter_nodes exe_env analyze_proc process_result filter_out with
    exe when do_parallel ->
      L.out "@.@. ERROR exception raised in parallel execution@.";
      raise exe)

let visited_and_total_nodes cfg =
  let all_nodes =
    let add s n = Cfg.NodeSet.add n s in
    list_fold_left add Cfg.NodeSet.empty (Cfg.Node.get_all_nodes cfg) in
  let filter_node n =
    Cfg.Procdesc.is_defined (Cfg.Node.get_proc_desc n) &&
    match Cfg.Node.get_kind n with
    | Cfg.Node.Stmt_node _ | Cfg.Node.Prune_node _
    | Cfg.Node.Start_node _ | Cfg.Node.Exit_node _ -> true
    | Cfg.Node.Skip_node _ | Cfg.Node.Join_node -> false in
  let counted_nodes = Cfg.NodeSet.filter filter_node all_nodes in
  let visited_nodes_re = Cfg.NodeSet.filter (fun node -> snd (Printer.is_visited_phase node)) counted_nodes in
  Cfg.NodeSet.elements visited_nodes_re, Cfg.NodeSet.elements counted_nodes

(** Print the stats for the given cfg; consider every defined proc unless a proc with the same name
was defined in another module, and was the one which was analyzed *)
let print_stats_cfg proc_shadowed proc_is_active cfg =
  let err_table = Errlog.create_err_table () in
  let active_procs = list_filter proc_is_active (Cfg.get_defined_procs cfg) in
  let nvisited, ntotal = visited_and_total_nodes cfg in
  let node_filter n =
    let node_procname = Cfg.Procdesc.get_proc_name (Cfg.Node.get_proc_desc n) in
    Specs.summary_exists node_procname && Specs.get_specs node_procname != [] in
  let nodes_visited = list_filter node_filter nvisited in
  let nodes_total = list_filter node_filter ntotal in
  let num_proc = ref 0 in
  let num_nospec_noerror_proc = ref 0 in
  let num_spec_noerror_proc = ref 0 in
  let num_nospec_error_proc = ref 0 in
  let num_spec_error_proc = ref 0 in
  let tot_specs = ref 0 in
  let tot_symops = ref 0 in
  let num_timeout = ref 0 in
  let compute_stats_proc proc_desc =
    let proc_name = Cfg.Procdesc.get_proc_name proc_desc in
    if proc_shadowed proc_desc then
      L.out "print_stats: ignoring function %a which is also defined in another file@." Procname.pp proc_name
    else
      let summary = Specs.get_summary_unsafe proc_name in
      let stats = summary.Specs.stats in
      incr num_proc;
      let specs = Specs.get_specs_from_payload summary in
      tot_specs := (list_length specs) + !tot_specs;
      let () =
        match specs,
        Errlog.size
          (fun ekind in_footprint -> ekind = Exceptions.Kerror && in_footprint)
          stats.Specs.err_log with
        | [], 0 -> incr num_nospec_noerror_proc
        | _, 0 -> incr num_spec_noerror_proc
        | [], _ -> incr num_nospec_error_proc
        | _, _ -> incr num_spec_error_proc in
      tot_symops := !tot_symops + stats.Specs.symops;
      if stats.Specs.stats_timeout then incr num_timeout;
      Errlog.extend_table err_table stats.Specs.err_log in
  let print_file_stats fmt () =
    let num_errors = Errlog.err_table_size_footprint Exceptions.Kerror err_table in
    let num_warnings = Errlog.err_table_size_footprint Exceptions.Kwarning err_table in
    let num_infos = Errlog.err_table_size_footprint Exceptions.Kinfo err_table in
    let num_ok_proc = !num_spec_noerror_proc + !num_spec_error_proc in
    (* F.fprintf fmt "VISITED: %a@\n" (pp_seq pp_node) nodes_visited;
    F.fprintf fmt "TOTAL: %a@\n" (pp_seq pp_node) nodes_total; *)
    F.fprintf fmt "@\n++++++++++++++++++++++++++++++++++++++++++++++++++@\n";
    F.fprintf fmt "+ FILE: %s  LOC: %n  VISITED: %d/%d SYMOPS: %d@\n" (DB.source_file_to_string !DB.current_source) !Config.nLOC (list_length nodes_visited) (list_length nodes_total) !tot_symops;
    F.fprintf fmt "+  num_procs: %d (%d ok, %d timeouts, %d errors, %d warnings, %d infos)@\n" !num_proc num_ok_proc !num_timeout num_errors num_warnings num_infos;
    F.fprintf fmt "+  detail procs:@\n";
    F.fprintf fmt "+    - No Errors and No Specs: %d@\n" !num_nospec_noerror_proc;
    F.fprintf fmt "+    - Some Errors and No Specs: %d@\n" !num_nospec_error_proc;
    F.fprintf fmt "+    - No Errors and Some Specs: %d@\n" !num_spec_noerror_proc;
    F.fprintf fmt "+    - Some Errors and Some Specs: %d@\n" !num_spec_error_proc;
    F.fprintf fmt "+  errors: %a@\n" (Errlog.pp_err_table_stats Exceptions.Kerror) err_table;
    F.fprintf fmt "+  warnings: %a@\n" (Errlog.pp_err_table_stats Exceptions.Kwarning) err_table;
    F.fprintf fmt "+  infos: %a@\n" (Errlog.pp_err_table_stats Exceptions.Kinfo) err_table;
    F.fprintf fmt "+  specs: %d@\n" !tot_specs;
    F.fprintf fmt "++++++++++++++++++++++++++++++++++++++++++++++++++@\n";
    Errlog.print_err_table_details fmt err_table in
  let save_file_stats () =
    let source_dir = DB.source_dir_from_source_file !DB.current_source in
    let stats_file = DB.source_dir_get_internal_file source_dir ".stats" in
    try
      let outc = open_out (DB.filename_to_string stats_file) in
      let fmt = F.formatter_of_out_channel outc in
      print_file_stats fmt ();
      close_out outc
    with Sys_error _ -> () in
  list_iter compute_stats_proc active_procs;
  L.out "%a" print_file_stats ();
  save_file_stats ()

(** Print the stats for all the files in the exe_env *)
let print_stats exe_env =
  let proc_is_active proc_desc =
    Exe_env.proc_is_active exe_env (Cfg.Procdesc.get_proc_name proc_desc) in
  Exe_env.iter_files (fun fname tenv cfg ->
          let proc_shadowed proc_desc =
            (** return true if a proc with the same name in another module was analyzed instead *)
            let proc_name = Cfg.Procdesc.get_proc_name proc_desc in
            Exe_env.get_source exe_env proc_name <> fname in
          print_stats_cfg proc_shadowed proc_is_active cfg) exe_env
