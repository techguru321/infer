(*
 * Copyright (c) 2018 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)
open! IStd
module F = Format
module L = Logging

let debug fmt = L.(debug Analysis Verbose fmt)

let is_java_static pname =
  match pname with
  | Typ.Procname.Java java_pname ->
      Typ.Procname.Java.is_static java_pname
  | _ ->
      false


let is_countdownlatch_await pn =
  match pn with
  | Typ.Procname.Java java_pname ->
      let classname = Typ.Procname.Java.get_class_name java_pname in
      let mthd = Typ.Procname.Java.get_method java_pname in
      String.equal classname "java.util.concurrent.CountDownLatch" && String.equal mthd "await"
  | _ ->
      false


(* an IBinder.transact call is an RPC.  If the 4th argument (5th counting `this` as the first)
   is int-zero then a reply is expected and returned from the remote process, thus potentially
   blocking.  If the 4th argument is anything else, we assume a one-way call which doesn't block.
*)
let is_two_way_binder_transact tenv actuals pn =
  match pn with
  | Typ.Procname.Java java_pname ->
      let classname = Typ.Procname.Java.get_class_type_name java_pname in
      let mthd = Typ.Procname.Java.get_method java_pname in
      String.equal mthd "transact"
      && PatternMatch.is_subtype_of_str tenv classname "android.os.IBinder"
      && List.nth actuals 4 |> Option.value_map ~default:false ~f:HilExp.is_int_zero
  | _ ->
      false


let is_on_main_thread pn =
  RacerDConfig.(match Models.get_thread pn with Models.MainThread -> true | _ -> false)


module Summary = Summary.Make (struct
  type payload = StarvationDomain.summary

  let update_payload post (summary: Specs.summary) =
    {summary with payload= {summary.payload with starvation= Some post}}


  let read_payload (summary: Specs.summary) = summary.payload.starvation
end)

(* using an indentifier for a class object, create an access path representing that lock;
   this is for synchronizing on class objects only *)
let lock_of_class class_id =
  let ident = Ident.create_normal class_id 0 in
  let type_name = Typ.Name.Java.from_string "java.lang.Class" in
  let typ = Typ.mk (Typ.Tstruct type_name) in
  let typ' = Typ.mk (Typ.Tptr (typ, Typ.Pk_pointer)) in
  AccessPath.of_id ident typ'


module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = StarvationDomain

  type extras = FormalMap.t

  let exec_instr (astate: Domain.astate) {ProcData.pdesc; tenv; extras} _ (instr: HilInstr.t) =
    let open RacerDConfig in
    let is_formal base = FormalMap.is_formal base extras in
    let get_path actuals =
      match actuals with
      | HilExp.AccessExpression access_exp :: _ -> (
        match AccessExpression.to_access_path access_exp with
        | (((Var.ProgramVar pvar, _) as base), _) as path
          when is_formal base || Pvar.is_global pvar ->
            Some (AccessPath.inner_class_normalize path)
        | _ ->
            (* ignore paths on local or logical variables *)
            None )
      | HilExp.Constant (Const.Cclass class_id) :: _ ->
          (* this is a synchronized/lock(CLASSNAME.class) construct *)
          Some (lock_of_class class_id)
      | _ ->
          None
    in
    match instr with
    | Call (_, Direct callee_pname, actuals, _, loc) -> (
      match Models.get_lock callee_pname actuals with
      | Lock ->
          get_path actuals |> Option.value_map ~default:astate ~f:(Domain.acquire astate loc)
      | Unlock ->
          get_path actuals |> Option.value_map ~default:astate ~f:(Domain.release astate)
      | LockedIfTrue ->
          astate
      | NoEffect ->
          if
            is_countdownlatch_await callee_pname
            || is_two_way_binder_transact tenv actuals callee_pname
          then Domain.blocking_call callee_pname loc astate
          else if is_on_main_thread callee_pname then Domain.set_on_main_thread astate
          else
            Summary.read_summary pdesc callee_pname
            |> Option.value_map ~default:astate
                 ~f:(Domain.integrate_summary astate callee_pname loc) )
    | _ ->
        astate


  let pp_session_name _node fmt = F.pp_print_string fmt "starvation"
end

module Analyzer = LowerHil.MakeAbstractInterpreter (ProcCfg.Normal) (TransferFunctions)

(* To allow on-demand reporting for deadlocks, we look for order pairs of the form (A,B)
   where A belongs to the current class and B is potentially another class.  To avoid
   quadratic/double reporting (ie when we actually analyse B), we allow the check
   only if the current class is ordered greater or equal to the callee class.  *)
let should_skip_during_deadlock_reporting _ _ = false

(* currently short-circuited until non-determinism in reporting is dealt with *)
(* Typ.Name.compare current_class eventually_class < 0 *)
(* let false_if_none a ~f = Option.value_map a ~default:false ~f *)
(* if same class, report only if the locks order in one of the possible ways *)
let should_report_if_same_class _ = true

(* currently short-circuited until non-determinism in reporting is dealt with *)
(* StarvationDomain.(
    LockOrder.get_pair caller_elem
    |> false_if_none ~f:(fun (b, a) ->
           let b_class_opt, a_class_opt = (LockEvent.owner_class b, LockEvent.owner_class a) in
           false_if_none b_class_opt ~f:(fun first_class ->
               false_if_none a_class_opt ~f:(fun eventually_class ->
                   not (Typ.Name.equal first_class eventually_class) || LockEvent.compare b a >= 0
               ) ) )) *)

let make_trace_with_header ?(header= "") elem start_loc pname =
  let trace = StarvationDomain.LockOrder.make_loc_trace elem in
  let first_step = List.hd_exn trace in
  if Location.equal first_step.Errlog.lt_loc start_loc then
    let trace_descr = header ^ first_step.Errlog.lt_description in
    Errlog.make_trace_element 0 start_loc trace_descr [] :: List.tl_exn trace
  else
    let trace_descr = Format.asprintf "%sMethod start: %a" header Typ.Procname.pp pname in
    Errlog.make_trace_element 0 start_loc trace_descr [] :: trace


let make_loc_trace pname trace_id start_loc elem =
  let header = Printf.sprintf "[Trace %d] " trace_id in
  make_trace_with_header ~header elem start_loc pname


let get_summary caller_pdesc callee_pdesc =
  Summary.read_summary caller_pdesc (Procdesc.get_proc_name callee_pdesc)
  |> Option.map ~f:(fun summary -> (callee_pdesc, summary))


let get_class_of_pname = function
  | Typ.Procname.Java java_pname ->
      Some (Typ.Procname.Java.get_class_type_name java_pname)
  | _ ->
      None


let report_deadlocks get_proc_desc tenv pdesc (summary, _) =
  let open StarvationDomain in
  let process_callee_elem caller_pdesc caller_elem callee_pdesc elem =
    if LockOrder.may_deadlock caller_elem elem && should_report_if_same_class caller_elem then (
      debug "Possible deadlock:@.%a@.%a@." LockOrder.pp caller_elem LockOrder.pp elem ;
      let caller_loc = Procdesc.get_loc caller_pdesc in
      let callee_loc = Procdesc.get_loc callee_pdesc in
      let caller_pname = Procdesc.get_proc_name caller_pdesc in
      let callee_pname = Procdesc.get_proc_name callee_pdesc in
      match
        ( caller_elem.LockOrder.eventually.LockEvent.event
        , elem.LockOrder.eventually.LockEvent.event )
      with
      | LockEvent.LockAcquire lock, LockEvent.LockAcquire lock' ->
          let error_message =
            Format.asprintf "Potential deadlock (%a ; %a)" LockIdentity.pp lock LockIdentity.pp
              lock'
          in
          let exn =
            Exceptions.Checkers (IssueType.starvation, Localise.verbatim_desc error_message)
          in
          let first_trace = List.rev (make_loc_trace caller_pname 1 caller_loc caller_elem) in
          let second_trace = make_loc_trace callee_pname 2 callee_loc elem in
          let ltr = List.rev_append first_trace second_trace in
          Specs.get_summary caller_pname
          |> Option.iter ~f:(fun summary -> Reporting.log_error summary ~loc:caller_loc ~ltr exn)
      | _, _ ->
          () )
  in
  let report_pair current_class elem =
    LockOrder.get_pair elem
    |> Option.iter ~f:(fun (_, eventually) ->
           LockEvent.owner_class eventually
           |> Option.iter ~f:(fun eventually_class ->
                  if should_skip_during_deadlock_reporting current_class eventually_class then ()
                  else
                    (* get the class of the root variable of the lock in the endpoint event
                       and retrieve all the summaries of the methods of that class *)
                    let class_of_eventual_lock =
                      LockEvent.owner_class eventually |> Option.bind ~f:(Tenv.lookup tenv)
                    in
                    let methods =
                      Option.value_map class_of_eventual_lock ~default:[] ~f:(fun tstruct ->
                          tstruct.Typ.Struct.methods )
                    in
                    let proc_descs = List.rev_filter_map methods ~f:get_proc_desc in
                    let summaries = List.rev_filter_map proc_descs ~f:(get_summary pdesc) in
                    (* for each summary related to the endpoint, analyse and report on its pairs *)
                    List.iter summaries ~f:(fun (callee_pdesc, (summary, _)) ->
                        LockOrderDomain.iter (process_callee_elem pdesc elem callee_pdesc) summary
                    ) ) )
  in
  Procdesc.get_proc_name pdesc |> get_class_of_pname
  |> Option.iter ~f:(fun curr_class -> LockOrderDomain.iter (report_pair curr_class) summary)


let report_direct_blocks_on_main_thread proc_desc summary =
  let open StarvationDomain in
  let report_pair ({LockOrder.eventually} as elem) =
    match eventually with
    | {LockEvent.event= LockEvent.MayBlock _} ->
        let caller_loc = Procdesc.get_loc proc_desc in
        let caller_pname = Procdesc.get_proc_name proc_desc in
        let error_message =
          Format.asprintf "May block while on main thread. Eventually: %a" LockEvent.pp_event
            eventually.LockEvent.event
        in
        let exn =
          Exceptions.Checkers (IssueType.starvation, Localise.verbatim_desc error_message)
        in
        let ltr = make_trace_with_header elem caller_loc caller_pname in
        Specs.get_summary caller_pname
        |> Option.iter ~f:(fun summary -> Reporting.log_error summary ~loc:caller_loc ~ltr exn)
    | _ ->
        ()
  in
  LockOrderDomain.iter report_pair summary


let analyze_procedure {Callbacks.proc_desc; get_proc_desc; tenv; summary} =
  let pname = Procdesc.get_proc_name proc_desc in
  let formals = FormalMap.make proc_desc in
  let proc_data = ProcData.make proc_desc tenv formals in
  let initial =
    if not (Procdesc.is_java_synchronized proc_desc) then StarvationDomain.empty
    else
      let loc = Procdesc.get_loc proc_desc in
      let lock =
        if is_java_static pname then
          (* this is crafted so as to match synchronized(CLASSNAME.class) constructs *)
          get_class_of_pname pname
          |> Option.map ~f:(fun tn -> Typ.Name.name tn |> Ident.string_to_name |> lock_of_class)
        else FormalMap.get_formal_base 0 formals |> Option.map ~f:(fun base -> (base, []))
      in
      Option.value_map lock ~default:StarvationDomain.empty
        ~f:(StarvationDomain.acquire StarvationDomain.empty loc)
  in
  let initial =
    if RacerDConfig.Models.runs_on_ui_thread proc_desc then
      StarvationDomain.set_on_main_thread initial
    else initial
  in
  match Analyzer.compute_post proc_data ~initial with
  | None ->
      summary
  | Some lock_state ->
      let lock_order = StarvationDomain.to_summary lock_state in
      let updated_summary = Summary.update_summary lock_order summary in
      Option.iter updated_summary.Specs.payload.starvation
        ~f:(report_deadlocks get_proc_desc tenv proc_desc) ;
      Option.iter updated_summary.Specs.payload.starvation ~f:(fun (sum, main) ->
          if main then report_direct_blocks_on_main_thread proc_desc sum ) ;
      updated_summary
