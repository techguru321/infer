(*
* Copyright (c) 2014 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

module L = Logging
module F = Format
open Utils

let checkers_repeated_calls_name = "CHECKERS_REPEATED_CALLS"

(* activate the check for repeated calls *)
let checkers_repeated_calls = Config.from_env_variable checkers_repeated_calls_name


(** Extension for the repeated calls check. *)
module RepeatedCallsExtension : Eradicate.ExtensionT =
struct
  module InstrSet =
    Set.Make(struct
      type t = Sil.instr
      let compare i1 i2 = match i1, i2 with
        | Sil.Call (ret1, e1, etl1, loc1, cf1), Sil.Call (ret2, e2, etl2, loc2, cf2) ->
        (* ignore return ids and call flags *)
            let n = Sil.exp_compare e1 e2 in
            if n <> 0 then n else let n = list_compare Sil.exp_typ_compare etl1 etl2 in
              if n <> 0 then n else Sil.call_flags_compare cf1 cf2
        | _ -> Sil.instr_compare i1 i2
    end)

  type extension = InstrSet.t

  let empty = InstrSet.empty

  let join calls1 calls2 =
    InstrSet.inter calls1 calls2

  let pp fmt calls =
    let pp_call instr = F.fprintf fmt "  %a@\n" (Sil.pp_instr pe_text) instr in
    if not (InstrSet.is_empty calls) then
      begin
        F.fprintf fmt "Calls:@\n";
        InstrSet.iter pp_call calls;
      end

  let get_old_call instr calls =
    try
      Some (InstrSet.find instr calls)
    with Not_found -> None

  let add_call instr calls =
    if InstrSet.mem instr calls then calls
    else InstrSet.add instr calls

  type paths =
    | AllPaths (** Check on all paths *)
    | SomePath (** Check if some path exists *)

  (** Check if the procedure performs an allocation operation.
  If [paths] is AllPaths, check if an allocation happens on all paths.
  If [paths] is SomePath, check if a path with an allocation exists. *)
  let proc_performs_allocation pdesc paths : Sil.location option =

    let node_allocates node : Sil.location option =
      let found = ref None in
      let proc_is_new pn =
        Procname.equal pn SymExec.ModelBuiltins.__new ||
        Procname.equal pn SymExec.ModelBuiltins.__new_array in
      let do_instr instr =
        match instr with
        | Sil.Call (_, Sil.Const (Sil.Cfun pn), _, loc, _) when proc_is_new pn ->
            found := Some loc
        | _ -> () in
      list_iter do_instr (Cfg.Node.get_instrs node);
      !found in

    let module DFAllocCheck = Dataflow.MakeDF(struct
        type t = Sil.location option
        let equal = opt_equal Sil.loc_equal
        let _join _paths l1o l2o = (* join with left priority *)
          match l1o, l2o with
          | None, None ->
              None
          | Some loc, None
          | None, Some loc ->
              if _paths = AllPaths then None else Some loc
          | Some loc1, Some loc2 ->
              Some loc1 (* left priority *)
        let join = _join paths
        let do_node node lo1 =
          let lo2 = node_allocates node in
          let lo' = (* use left priority join to implement transfer function *)
            _join SomePath lo1 lo2 in
          [lo'], [lo']
        let proc_throws pn = Dataflow.DontKnow
      end) in

    if Cfg.Procdesc.is_defined pdesc then
      let transitions = DFAllocCheck.run pdesc None in
      match transitions (Cfg.Procdesc.get_exit_node pdesc) with
      | DFAllocCheck.Transition (loc, _, _) -> loc
      | DFAllocCheck.Dead_state -> None
    else None

  (** Check repeated calls to the same procedure. *)
  let check_instr get_proc_desc curr_pname curr_pdesc node extension instr normalized_etl =

    (** Arguments are not temporary variables. *)
    let arguments_not_temp args =
      let filter_arg (e, t) = match e with
        | Sil.Lvar pvar ->
        (* same temporary variable does not imply same value *)
            not (Errdesc.pvar_is_frontend_tmp pvar)
        | _ -> true in
      list_for_all filter_arg args in

    match instr with
    | Sil.Call (ret_ids, Sil.Const (Sil.Cfun callee_pname), _, loc, call_flags)
    when ret_ids <> [] && arguments_not_temp normalized_etl ->
        let instr_normalized_args = Sil.Call (
            ret_ids,
            Sil.Const (Sil.Cfun callee_pname),
            normalized_etl,
            loc,
            call_flags) in
        let report callee_pdesc =
          match get_old_call instr_normalized_args extension with
          | Some (Sil.Call (_, _, _, loc_old, _)) ->
              begin
                match proc_performs_allocation callee_pdesc AllPaths with
                | Some alloc_loc ->
                    let description =
                      Printf.sprintf "call to %s seen before on line %d (may allocate at %s:%n)"
                        (Procname.to_simplified_string callee_pname)
                        loc_old.Sil.line
                        (DB.source_file_to_string alloc_loc.Sil.file)
                        alloc_loc.Sil.line in
                    Checkers.ST.report_error
                      curr_pname curr_pdesc checkers_repeated_calls_name loc description
                | None -> ()
              end
          | _ -> () in

        let () = match get_proc_desc callee_pname with
          | None -> ()
          | Some callee_pdesc -> report callee_pdesc in
        add_call instr_normalized_args extension
    | _ -> extension

  let ext =
    {
      TypeState.empty = empty;
      check_instr = check_instr;
      join = join;
      pp = pp;
    }

  let mkpayload typestate = Specs.TypeState None
end (* CheckRepeatedCalls *)

module MainRepeatedCalls =
  Eradicate.Build(RepeatedCallsExtension)

let callback_check_repeated_calls all_procs get_proc_desc idenv tenv proc_name proc_desc =
  let checks =
    {
      TypeCheck.eradicate = false;
      check_extension = checkers_repeated_calls;
      check_ret_type = [];
    } in
  MainRepeatedCalls.callback checks all_procs get_proc_desc idenv tenv proc_name proc_desc
