(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

let log_issue ?proc_name ~issue_log ~loc ~severity ~nullsafe_extra issue_type error_message =
  let extras =
    Jsonbug_t.{nullsafe_extra= Some nullsafe_extra; cost_polynomial= None; cost_degree= None}
  in
  let proc_name = Option.value proc_name ~default:Procname.Linters_dummy_method in
  let trace = [Errlog.make_trace_element 0 loc error_message []] in
  Reporting.log_issue_external proc_name severity ~issue_log ~loc ~extras ~ltr:trace issue_type
    error_message


(* If the issue is related to violation of nullability type system rules *)
let is_typing_rules_violation = function
  | TypeErr.Condition_redundant _ | TypeErr.Over_annotation _ ->
      (* Those are not nullability type system violations per se *)
      false
  | TypeErr.Inconsistent_subclass _
  | TypeErr.Nullable_dereference _
  | TypeErr.Field_not_initialized _
  | TypeErr.Bad_assignment _ ->
      true


(* Yes, if the issue is a) "type violation" issue b) reportable to the user in a given mode *)
let is_reportable_typing_rules_violation ~nullsafe_mode issue =
  is_typing_rules_violation issue && TypeErr.is_reportable ~nullsafe_mode issue


let get_reportable_typing_rules_violations ~nullsafe_mode issues =
  List.filter issues ~f:(is_reportable_typing_rules_violation ~nullsafe_mode)


type meta_issue =
  { issue_type: IssueType.t
  ; description: string
  ; severity: Exceptions.severity
  ; meta_issue_info: Jsonbug_t.nullsafe_meta_issue_info }

let mode_to_json mode =
  let open NullsafeMode in
  match mode with
  | Default ->
      `Default
  | Local Trust.All ->
      `LocalTrustAll
  | Local (Trust.Only trust_list) when Trust.is_trust_none trust_list ->
      `LocalTrustNone
  | Local (Trust.Only _) ->
      `LocalTrustSome
  | Strict ->
      `Strict


let is_clean_in_mode nullsafe_mode all_issues =
  get_reportable_typing_rules_violations ~nullsafe_mode all_issues |> List.is_empty


(* Return the maximum mode where we still have zero issues, or None if no such mode exists.
*)
let calc_strictest_mode_with_zero_issues all_issues =
  let modes_to_try = NullsafeMode.[Strict; Local Trust.none; Local Trust.All; Default] in
  List.find modes_to_try ~f:(fun mode -> is_clean_in_mode mode all_issues)


(* The maximum strict mode this mode can be promoted to with still having zero issues, if exists *)
let calc_mode_to_promote_to curr_mode all_issues =
  let open IOption.Let_syntax in
  let* strictest_mode = calc_strictest_mode_with_zero_issues all_issues in
  if NullsafeMode.is_stricter_than ~stricter:strictest_mode ~weaker:curr_mode then
    Some strictest_mode
  else None


(* analyze all issues for the current class and classify them into one meta-issue.
 *)
let make_meta_issue all_issues current_mode class_name =
  let issue_count_in_curr_mode =
    get_reportable_typing_rules_violations ~nullsafe_mode:current_mode all_issues |> List.length
  in
  List.iter (get_reportable_typing_rules_violations ~nullsafe_mode:current_mode all_issues)
    ~f:(fun issue -> Logging.debug Analysis Medium "Issue: %a@\n" TypeErr.pp_err_instance issue) ;
  let mode_to_promote_to = calc_mode_to_promote_to current_mode all_issues in
  let meta_issue_info =
    Jsonbug_t.
      { num_issues= issue_count_in_curr_mode
      ; curr_nullsafe_mode= mode_to_json current_mode
      ; can_be_promoted_to= Option.map mode_to_promote_to ~f:mode_to_json }
  in
  let issue_type, description, severity =
    if NullsafeMode.equal current_mode Default then
      match mode_to_promote_to with
      | Some mode_to_promote_to ->
          (* This class is not @Nullsafe yet, but can become such! *)
          let trust_none_mode =
            "`@Nullsafe(value = Nullsafe.Mode.LOCAL, trustOnly = @Nullsafe.TrustList({}))`"
          in
          let trust_all_mode = "`@Nullsafe(Nullsafe.Mode.LOCAL)`" in
          let promo_recommendation =
            match mode_to_promote_to with
            | NullsafeMode.Local NullsafeMode.Trust.All ->
                trust_all_mode
            | NullsafeMode.Local (NullsafeMode.Trust.Only trust_list)
              when NullsafeMode.Trust.is_trust_none trust_list ->
                trust_none_mode
            | NullsafeMode.Strict
            (* We don't recommend "strict" for now as it is harder to keep a class in strict mode than it "trust none" mode.
               Trust none is almost as safe alternative, but adding a dependency will require just updating trust list,
               without need to strictify it first. *) ->
                trust_none_mode
            | NullsafeMode.Default | NullsafeMode.Local (NullsafeMode.Trust.Only _) ->
                Logging.die InternalError "Unexpected promotion mode"
          in
          ( IssueType.eradicate_meta_class_can_be_nullsafe
          , Format.asprintf
              "Congrats! `%s` is free of nullability issues. Mark it %s to prevent regressions."
              (JavaClassName.classname class_name)
              promo_recommendation
          , Exceptions.Advice )
      | None ->
          (* This class can not be made @Nullsafe without extra work *)
          let issue_count_to_make_nullsafe =
            get_reportable_typing_rules_violations
              ~nullsafe_mode:(NullsafeMode.Local NullsafeMode.Trust.All) all_issues
            |> List.length
          in
          ( IssueType.eradicate_meta_class_needs_improvement
          , Format.asprintf "`%s` needs %d issues to be fixed in order to be marked @Nullsafe."
              (JavaClassName.classname class_name)
              issue_count_to_make_nullsafe
          , Exceptions.Info )
    else if issue_count_in_curr_mode > 0 then
      (* This class is already nullsafe *)
      ( IssueType.eradicate_meta_class_needs_improvement
      , Format.asprintf
          "@Nullsafe classes should have exactly zero nullability issues. `%s` has %d."
          (JavaClassName.classname class_name)
          issue_count_in_curr_mode
      , Exceptions.Info )
    else
      ( IssueType.eradicate_meta_class_is_nullsafe
      , Format.asprintf "Class %a is free of nullability issues." JavaClassName.pp class_name
      , Exceptions.Info )
  in
  {issue_type; description; severity; meta_issue_info}


let get_class_loc source_file Struct.{java_class_info} =
  match java_class_info with
  | Some {loc} ->
      (* In rare cases location is not present, fall back to the first line of the file *)
      Option.value loc ~default:Location.{file= source_file; line= 1; col= 0}
  | None ->
      Logging.die InternalError "java_class_info should be present for Java classes"


(* Meta issues are those related to null-safety of the class in general, not concrete nullability violations *)
let report_meta_issues tenv source_file class_name class_struct class_info issue_log =
  (* For purposes of aggregation, we consider all nested anonymous summaries as belonging to this class *)
  let current_mode = NullsafeMode.of_class tenv class_name in
  let summaries = AggregatedSummaries.ClassInfo.get_all_summaries class_info in
  let class_loc = get_class_loc source_file class_struct in
  let all_issues =
    List.map summaries ~f:(fun Summary.{payloads= {nullsafe}} ->
        Option.value_map nullsafe ~f:(fun NullsafeSummary.{issues} -> issues) ~default:[] )
    |> List.fold ~init:[] ~f:( @ )
  in
  let {issue_type; description; severity; meta_issue_info} =
    make_meta_issue all_issues current_mode class_name
  in
  let package = JavaClassName.package class_name in
  let class_name = JavaClassName.classname class_name in
  let nullsafe_extra = Jsonbug_t.{class_name; package; meta_issue_info= Some meta_issue_info} in
  log_issue ~issue_log ~loc:class_loc ~severity ~nullsafe_extra issue_type description


(* Optimization - if issues are disabled, don't bother analyzing them *)
let should_analyze_meta_issues () =
  (not Config.filtering) || IssueType.eradicate_meta_class_can_be_nullsafe.enabled
  || IssueType.eradicate_meta_class_needs_improvement.enabled
  || IssueType.eradicate_meta_class_is_nullsafe.enabled


let analyze_meta_issues tenv source_file class_name class_struct class_info issue_log =
  if should_analyze_meta_issues () then
    report_meta_issues tenv source_file class_name class_struct class_info issue_log
  else issue_log


let analyze_nullsafe_annotations tenv source_file class_name class_struct issue_log =
  let loc = get_class_loc source_file class_struct in
  let nullsafe_extra =
    let package = JavaClassName.package class_name in
    let class_name = JavaClassName.classname class_name in
    Jsonbug_t.{class_name; package; meta_issue_info= None}
  in
  match NullsafeMode.check_problematic_class_annotation tenv class_name with
  | Ok () ->
      issue_log
  | Error NullsafeMode.RedundantNestedClassAnnotation ->
      let description =
        Format.sprintf
          "`%s`: the same @Nullsafe mode is already specified in the outer class, so this \
           annotation can be removed."
          (JavaClassName.classname class_name)
      in
      log_issue ~issue_log ~loc ~nullsafe_extra ~severity:Exceptions.Advice
        IssueType.eradicate_redundant_nested_class_annotation description
  | Error (NullsafeMode.NestedModeIsWeaker (ExtraTrustClass wrongly_trusted_classes)) ->
      (* The list can not be empty *)
      let example_of_wrongly_trusted_class = List.nth_exn wrongly_trusted_classes 0 in
      let description =
        Format.sprintf
          "Nested classes cannot add classes to trust list if they are not in the outer class \
           trust list. Remove `%s` from trust list."
          (JavaClassName.classname example_of_wrongly_trusted_class)
      in
      log_issue ~issue_log ~loc ~nullsafe_extra ~severity:Exceptions.Warning
        IssueType.eradicate_bad_nested_class_annotation description
  | Error (NullsafeMode.NestedModeIsWeaker Other) ->
      let description =
        Format.sprintf
          "`%s`: nested classes are disallowed to weaken @Nullsafe mode specified in the outer \
           class. This annotation will be ignored."
          (JavaClassName.classname class_name)
      in
      log_issue ~issue_log ~loc ~nullsafe_extra ~severity:Exceptions.Warning
        IssueType.eradicate_bad_nested_class_annotation description


let analyze_class_impl tenv source_file class_name class_struct class_info issue_log =
  issue_log
  |> analyze_meta_issues tenv source_file class_name class_struct class_info
  |> analyze_nullsafe_annotations tenv source_file class_name class_struct


let analyze_class tenv source_file class_name class_info issue_log =
  match Tenv.lookup tenv (Typ.JavaClass class_name) with
  | Some class_struct ->
      analyze_class_impl tenv source_file class_name class_struct class_info issue_log
  | None ->
      Logging.debug Analysis Medium
        "%a: could not load class info in environment: skipping class analysis@\n" JavaClassName.pp
        class_name ;
      issue_log
