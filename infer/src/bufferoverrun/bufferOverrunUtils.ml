(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
open AbsLoc
open! AbstractDomain.Types
module L = Logging
module Dom = BufferOverrunDomain
module PO = BufferOverrunProofObligations
module Trace = BufferOverrunTrace
module TraceSet = Trace.Set

module type S = sig
  module CFG : ProcCfg.S

  module Sem : module type of BufferOverrunSemantics.Make (CFG)

  type counter = unit -> int

  val counter_gen : int -> counter

  module Exec : sig
    val load_val : Ident.t -> Dom.Val.astate -> Dom.Mem.astate -> Dom.Mem.astate

    type decl_local =
      Typ.Procname.t -> CFG.node -> Location.t -> Loc.t -> Typ.t -> inst_num:int -> dimension:int
      -> Dom.Mem.astate -> Dom.Mem.astate * int

    val decl_local_array :
      decl_local:decl_local -> Typ.Procname.t -> CFG.node -> Location.t -> Loc.t -> Typ.t
      -> length:IntLit.t option -> ?stride:int -> inst_num:int -> dimension:int -> Dom.Mem.astate
      -> Dom.Mem.astate * int

    type decl_sym_val =
      Typ.Procname.t -> Tenv.t -> CFG.node -> Location.t -> depth:int -> Loc.t -> Typ.t
      -> Dom.Mem.astate -> Dom.Mem.astate

    val decl_sym_arr :
      decl_sym_val:decl_sym_val -> Typ.Procname.t -> Tenv.t -> CFG.node -> Location.t -> depth:int
      -> Loc.t -> Typ.t -> ?offset:Itv.t -> ?size:Itv.t -> inst_num:int -> new_sym_num:counter
      -> new_alloc_num:counter -> Dom.Mem.astate -> Dom.Mem.astate
  end

  module Check : sig
    val array_access :
      arr:ArrayBlk.astate -> arr_traces:TraceSet.t -> idx:Itv.astate -> idx_traces:TraceSet.t
      -> is_plus:bool -> Typ.Procname.t -> Location.t -> PO.ConditionSet.t -> PO.ConditionSet.t

    val lindex :
      array_exp:Exp.t -> index_exp:Exp.t -> Dom.Mem.astate -> Typ.Procname.t -> Location.t
      -> PO.ConditionSet.t -> PO.ConditionSet.t
  end
end

module Make (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Sem = BufferOverrunSemantics.Make (CFG)

  type counter = unit -> int

  let counter_gen init : counter =
    let num_ref = ref init in
    let get_num () =
      let v = !num_ref in
      num_ref := v + 1 ;
      v
    in
    get_num


  module Exec = struct
    let load_val id val_ mem =
      let locs = val_ |> Dom.Val.get_all_locs in
      let v = Dom.Mem.find_heap_set locs mem in
      let mem = Dom.Mem.add_stack (Loc.of_id id) v mem in
      if PowLoc.is_singleton locs then Dom.Mem.load_simple_alias id (PowLoc.min_elt locs) mem
      else mem


    type decl_local =
      Typ.Procname.t -> CFG.node -> Location.t -> Loc.t -> Typ.t -> inst_num:int -> dimension:int
      -> Dom.Mem.astate -> Dom.Mem.astate * int

    let decl_local_array
        : decl_local:decl_local -> Typ.Procname.t -> CFG.node -> Location.t -> Loc.t -> Typ.t
          -> length:IntLit.t option -> ?stride:int -> inst_num:int -> dimension:int
          -> Dom.Mem.astate -> Dom.Mem.astate * int =
      fun ~decl_local pname node location loc typ ~length ?stride ~inst_num ~dimension mem ->
        let size = Option.value_map ~default:Itv.top ~f:Itv.of_int_lit length in
        let arr =
          Sem.eval_array_alloc pname node typ Itv.zero size ?stride inst_num dimension
          |> Dom.Val.add_trace_elem (Trace.ArrDecl location)
        in
        let mem =
          if Int.equal dimension 1 then Dom.Mem.add_stack loc arr mem
          else Dom.Mem.add_heap loc arr mem
        in
        let loc = Loc.of_allocsite (Sem.get_allocsite pname node inst_num dimension) in
        let mem, _ =
          decl_local pname node location loc typ ~inst_num ~dimension:(dimension + 1) mem
        in
        (mem, inst_num + 1)


    type decl_sym_val =
      Typ.Procname.t -> Tenv.t -> CFG.node -> Location.t -> depth:int -> Loc.t -> Typ.t
      -> Dom.Mem.astate -> Dom.Mem.astate

    let decl_sym_arr
        : decl_sym_val:decl_sym_val -> Typ.Procname.t -> Tenv.t -> CFG.node -> Location.t
          -> depth:int -> Loc.t -> Typ.t -> ?offset:Itv.t -> ?size:Itv.t -> inst_num:int
          -> new_sym_num:counter -> new_alloc_num:counter -> Dom.Mem.astate -> Dom.Mem.astate =
      fun ~decl_sym_val pname tenv node location ~depth loc typ ?offset ?size ~inst_num
          ~new_sym_num ~new_alloc_num mem ->
        let option_value opt_x default_f = match opt_x with Some x -> x | None -> default_f () in
        let itv_make_sym () = Itv.make_sym pname new_sym_num in
        let offset = option_value offset itv_make_sym in
        let size = option_value size itv_make_sym in
        let alloc_num = new_alloc_num () in
        let elem = Trace.SymAssign location in
        let arr =
          Sem.eval_array_alloc pname node typ offset size inst_num alloc_num
          |> Dom.Val.add_trace_elem elem
        in
        let mem = Dom.Mem.add_heap loc arr mem in
        let deref_loc = Loc.of_allocsite (Sem.get_allocsite pname node inst_num alloc_num) in
        decl_sym_val pname tenv node location ~depth deref_loc typ mem
  end

  module Check = struct
    let array_access ~arr ~arr_traces ~idx ~idx_traces ~is_plus pname location cond_set =
      let size = ArrayBlk.sizeof arr in
      let offset = ArrayBlk.offsetof arr in
      let idx = (if is_plus then Itv.plus else Itv.minus) offset idx in
      L.(debug BufferOverrun Verbose) "@[<v 2>Add condition :@," ;
      L.(debug BufferOverrun Verbose) "array: %a@," ArrayBlk.pp arr ;
      L.(debug BufferOverrun Verbose) "  idx: %a@," Itv.pp idx ;
      L.(debug BufferOverrun Verbose) "@]@." ;
      match (size, idx) with
      | NonBottom size, NonBottom idx ->
          let traces = TraceSet.merge ~arr_traces ~idx_traces location in
          PO.ConditionSet.add_array_access pname location ~size ~idx traces cond_set
      | _ ->
          cond_set


    let lindex ~array_exp ~index_exp mem pname location cond_set =
      let locs = Sem.eval_locs array_exp mem |> Dom.Val.get_all_locs in
      let v_arr = Dom.Mem.find_set locs mem in
      let arr = Dom.Val.get_array_blk v_arr in
      let arr_traces = Dom.Val.get_traces v_arr in
      let v_idx = Sem.eval index_exp mem in
      let idx = Dom.Val.get_itv v_idx in
      let idx_traces = Dom.Val.get_traces v_idx in
      array_access ~arr ~arr_traces ~idx ~idx_traces ~is_plus:true pname location cond_set
  end
end
