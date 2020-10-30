(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

type violation = {lhs: AnnotatedNullability.t; rhs: InferredNullability.t} [@@deriving compare]

module ProvisionalViolation = struct
  type t =
    { fix_annotation: ProvisionalAnnotation.t option
    ; offending_annotations: ProvisionalAnnotation.t list }

  let offending_annotations {offending_annotations} = offending_annotations

  let fix_annotation {fix_annotation} = fix_annotation

  let from {lhs; rhs} =
    let offending_annotations = InferredNullability.get_provisional_annotations rhs in
    if List.is_empty offending_annotations then None
    else
      let fix_annotation =
        match lhs with
        | AnnotatedNullability.ProvisionallyNullable annotation ->
            Some annotation
        | _ ->
            None
      in
      Some {offending_annotations; fix_annotation}
end

module ReportableViolation = struct
  type t = {nullsafe_mode: NullsafeMode.t; violation: violation}

  type assignment_type =
    | PassingParamToFunction of function_info
    | AssigningToField of Fieldname.t
    | ReturningFromFunction of Procname.Java.t
  [@@deriving compare]

  and function_info =
    { param_signature: AnnotatedSignature.param_signature
    ; actual_param_expression: string
    ; param_position: int
    ; annotated_signature: AnnotatedSignature.t
    ; procname: Procname.Java.t }

  let from nullsafe_mode ({lhs; rhs} as violation) =
    let falls_under_optimistic_third_party =
      Config.nullsafe_optimistic_third_party_params_in_non_strict
      && NullsafeMode.equal nullsafe_mode Default
      && Nullability.equal (AnnotatedNullability.get_nullability lhs) ThirdPartyNonnull
    in
    let is_non_reportable =
      falls_under_optimistic_third_party
      || (* In certain modes, we trust rhs to be non-nullable and don't report violation *)
      Nullability.is_considered_nonnull ~nullsafe_mode (InferredNullability.get_nullability rhs)
    in
    if is_non_reportable then None else Some {nullsafe_mode; violation}


  let get_origin_opt assignment_type origin =
    let should_show_origin =
      match assignment_type with
      | PassingParamToFunction {actual_param_expression} ->
          not
            (ErrorRenderingUtils.is_object_nullability_self_explanatory
               ~object_expression:actual_param_expression origin)
      | AssigningToField _ | ReturningFromFunction _ ->
          true
    in
    if should_show_origin then Some origin else None


  let pp_param_name fmt mangled =
    let name = Mangled.to_string mangled in
    if String.is_substring name ~substring:"_arg_" then
      (* The real name was not fetched for whatever reason, this is an autogenerated name *)
      Format.fprintf fmt ""
    else Format.fprintf fmt "(%a)" MarkupFormatter.pp_monospaced name


  (* A slight adapter over [NullsafeIssue.make]: the same signature but additionally accepts an alternative method *)
  let make_issue_with_recommendation ~description ~rhs_origin ~issue_type ~loc ~severity =
    (* If there is an alternative method to propose, tell about it at the end of the description *)
    let alternative_method =
      ErrorRenderingUtils.find_alternative_nonnull_method_description rhs_origin
    in
    let alternative_recommendation =
      Option.value_map alternative_method
        ~f:
          (Format.asprintf " If you don't expect null, use %a instead."
             MarkupFormatter.pp_monospaced)
        ~default:""
    in
    let full_description = Format.sprintf "%s%s" description alternative_recommendation in
    let nullable_methods =
      match rhs_origin with TypeOrigin.MethodCall origin -> [origin] | _ -> []
    in
    NullsafeIssue.make ~description:full_description ~issue_type ~loc ~severity
    |> NullsafeIssue.with_nullable_methods nullable_methods


  let mk_issue_for_bad_param_passed
      {annotated_signature; param_signature; actual_param_expression; param_position; procname}
      ~param_nullability_kind ~nullability_evidence
      ~(make_issue_factory : description:string -> issue_type:IssueType.t -> NullsafeIssue.t) =
    let nullability_evidence_as_suffix =
      Option.value_map nullability_evidence ~f:(fun evidence -> ": " ^ evidence) ~default:""
    in
    let annotated_param_nullability = param_signature.param_annotated_type.nullability in
    let module MF = MarkupFormatter in
    let argument_description =
      if String.equal actual_param_expression "null" then "is `null`"
      else
        let nullability_descr =
          match param_nullability_kind with
          | ErrorRenderingUtils.UserFriendlyNullable.Null ->
              "`null`"
          | ErrorRenderingUtils.UserFriendlyNullable.Nullable ->
              "nullable"
        in
        Format.asprintf "%a is %s" MF.pp_monospaced actual_param_expression nullability_descr
    in
    let issue_type = IssueType.eradicate_parameter_not_nullable in
    match AnnotatedNullability.get_nullability annotated_param_nullability with
    | Nullability.Null ->
        Logging.die Logging.InternalError "Unexpected param nullability: Null"
    | Nullability.Nullable ->
        Logging.die Logging.InternalError "Passing anything to a nullable param should be allowed"
    | Nullability.ThirdPartyNonnull ->
        (* This is a special case. While for FB codebase we can assume "not annotated hence not nullable" rule for all_whitelisted signatures,
           This is not the case for third party functions, which can have different conventions,
           So we can not just say "param is declared as non-nullable" like we say for FB-internal or modelled case:
           param can be nullable according to API but it was just not annotated.
           So we phrase it differently to remain truthful, but as specific as possible.
        *)
        let suggested_third_party_sig_file =
          ThirdPartyAnnotationInfo.lookup_related_sig_file_for_proc
            (ThirdPartyAnnotationGlobalRepo.get_repo ())
            procname
        in
        let where_to_add_signature =
          Option.value_map suggested_third_party_sig_file
            ~f:(fun sig_file_name ->
              ThirdPartyAnnotationGlobalRepo.get_user_friendly_third_party_sig_file_name
                ~filename:sig_file_name )
              (* this can happen when third party is registered in a deprecated way (not in third party repository) *)
            ~default:"the third party signature storage"
        in
        let procname_str = Procname.Java.to_simplified_string ~withclass:true procname in
        let description =
          Format.asprintf
            "Third-party %a is missing a signature that would allow passing a nullable to param \
             #%d%a. Actual argument %s%s. Consider adding the correct signature of %a to %s."
            MF.pp_monospaced procname_str param_position pp_param_name param_signature.mangled
            argument_description nullability_evidence_as_suffix MF.pp_monospaced procname_str
            where_to_add_signature
        in
        make_issue_factory ~description ~issue_type
        |> NullsafeIssue.with_third_party_dependent_methods [(procname, annotated_signature)]
    (* Equivalent to non-null from user point of view *)
    | Nullability.ProvisionallyNullable
    | Nullability.LocallyCheckedNonnull
    | Nullability.LocallyTrustedNonnull
    | Nullability.UncheckedNonnull
    | Nullability.StrictNonnull ->
        let nonnull_evidence =
          match annotated_signature.kind with
          | FirstParty | ThirdParty Unregistered ->
              ""
          | ThirdParty ModelledInternally ->
              " (according to nullsafe internal models)"
          | ThirdParty (InThirdPartyRepo {filename; line_number}) ->
              Format.sprintf " (see %s at line %d)"
                (ThirdPartyAnnotationGlobalRepo.get_user_friendly_third_party_sig_file_name
                   ~filename)
                line_number
        in
        let description =
          Format.asprintf "%a: parameter #%d%a is declared non-nullable%s but the argument %s%s."
            MF.pp_monospaced
            (Procname.Java.to_simplified_string ~withclass:true procname)
            param_position pp_param_name param_signature.mangled nonnull_evidence
            argument_description nullability_evidence_as_suffix
        in
        make_issue_factory ~description ~issue_type


  let mk_nullsafe_issue_for_explicitly_nullable_values ~assignment_type ~rhs_origin ~nullsafe_mode
      ~explicit_rhs_nullable_kind ~assignment_location =
    let nullability_evidence =
      get_origin_opt assignment_type rhs_origin
      |> Option.bind ~f:(fun origin -> TypeOrigin.get_description origin)
    in
    let nullability_evidence_as_suffix =
      Option.value_map nullability_evidence ~f:(fun evidence -> ": " ^ evidence) ~default:""
    in
    (* A "factory" - a high-order function for creating the nullsafe issue: fill in what is already known at this point.
       The rest to be filled by the client *)
    let make_issue_factory =
      make_issue_with_recommendation ~rhs_origin
        ~severity:(NullsafeMode.severity nullsafe_mode)
        ~loc:assignment_location
    in
    match assignment_type with
    | PassingParamToFunction function_info ->
        mk_issue_for_bad_param_passed function_info ~nullability_evidence
          ~param_nullability_kind:explicit_rhs_nullable_kind ~make_issue_factory
    | AssigningToField field_name ->
        let rhs_description =
          match explicit_rhs_nullable_kind with
          | ErrorRenderingUtils.UserFriendlyNullable.Null ->
              "`null`"
          | ErrorRenderingUtils.UserFriendlyNullable.Nullable ->
              "a nullable"
        in
        let description =
          Format.asprintf "%a is declared non-nullable but is assigned %s%s."
            MarkupFormatter.pp_monospaced
            (Fieldname.get_field_name field_name)
            rhs_description nullability_evidence_as_suffix
        in
        make_issue_factory ~description ~issue_type:IssueType.eradicate_field_not_nullable
    | ReturningFromFunction function_proc_name ->
        let return_description =
          match explicit_rhs_nullable_kind with
          | ErrorRenderingUtils.UserFriendlyNullable.Null ->
              (* Return `null` in all_whitelisted branches *)
              "`null`"
          | ErrorRenderingUtils.UserFriendlyNullable.Nullable ->
              "a nullable value"
        in
        let description =
          Format.asprintf "%a: return type is declared non-nullable but the method returns %s%s."
            MarkupFormatter.pp_monospaced
            (Procname.Java.to_simplified_string ~withclass:false function_proc_name)
            return_description nullability_evidence_as_suffix
        in
        make_issue_factory ~description ~issue_type:IssueType.eradicate_return_not_nullable


  let make_nullsafe_issue ~assignment_location assignment_type {nullsafe_mode; violation= {rhs}} =
    let rhs_origin = InferredNullability.get_simple_origin rhs in
    let user_friendly_nullable =
      ErrorRenderingUtils.UserFriendlyNullable.from_nullability
        (InferredNullability.get_nullability rhs)
      |> IOption.if_none_eval ~f:(fun () ->
             Logging.die InternalError
               "get_description:: Assignment violation should not be possible for non-nullable \
                values on right hand side" )
    in
    match user_friendly_nullable with
    | ErrorRenderingUtils.UserFriendlyNullable.UntrustedNonnull untrusted_kind ->
        (* Attempt to assigning a value which is not explictly declared as nullable,
           but still can not be trusted in this particular mode.
        *)
        ErrorRenderingUtils.mk_nullsafe_issue_for_untrusted_values ~nullsafe_mode ~untrusted_kind
          ~bad_usage_location:assignment_location rhs_origin
    | ErrorRenderingUtils.UserFriendlyNullable.ExplainablyNullable explicit_kind ->
        (* Attempt to assigning a value that can be explained to the user as nullable. *)
        mk_nullsafe_issue_for_explicitly_nullable_values ~assignment_type ~rhs_origin ~nullsafe_mode
          ~explicit_rhs_nullable_kind:explicit_kind ~assignment_location
end

let check ~lhs ~rhs =
  let is_subtype =
    Nullability.is_subtype
      ~supertype:(AnnotatedNullability.get_nullability lhs)
      ~subtype:(InferredNullability.get_nullability rhs)
  in
  Result.ok_if_true is_subtype ~error:{lhs; rhs}
