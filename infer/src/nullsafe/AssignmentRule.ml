(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

type violation = {is_strict_mode: bool; lhs: Nullability.t; rhs: Nullability.t} [@@deriving compare]

type assignment_type =
  | PassingParamToFunction of function_info
  | AssigningToField of Typ.Fieldname.t
  | ReturningFromFunction of Typ.Procname.t
[@@deriving compare]

and function_info =
  { param_signature: AnnotatedSignature.param_signature
  ; model_source: AnnotatedSignature.model_source option
  ; actual_param_expression: string
  ; param_position: int
  ; function_procname: Typ.Procname.t }

let is_whitelisted_assignment ~is_strict_mode ~lhs ~rhs =
  match (is_strict_mode, lhs, rhs) with
  | false, Nullability.Nonnull, Nullability.DeclaredNonnull ->
      (* We allow DeclaredNonnull -> Nonnull conversion outside of strict mode for better adoption.
         Otherwise using strictified classes in non-strict context becomes a pain because
         of extra warnings.
      *)
      true
  | _ ->
      false


let check ~is_strict_mode ~lhs ~rhs =
  let is_allowed_assignment =
    Nullability.is_subtype ~subtype:rhs ~supertype:lhs
    || is_whitelisted_assignment ~is_strict_mode ~lhs ~rhs
  in
  Result.ok_if_true is_allowed_assignment ~error:{is_strict_mode; lhs; rhs}


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


let bad_param_description
    {model_source; param_signature; actual_param_expression; param_position; function_procname}
    nullability_evidence =
  let nullability_evidence_as_suffix =
    Option.value_map nullability_evidence ~f:(fun evidence -> ": " ^ evidence) ~default:""
  in
  let module MF = MarkupFormatter in
  let argument_description =
    if String.equal "null" actual_param_expression then "is `null`"
    else Format.asprintf "%a is nullable" MF.pp_monospaced actual_param_expression
  in
  let suggested_file_to_add_third_party =
    (* If the function is modelled, this is the different case:
       suggestion to add third party is irrelevant
    *)
    Option.bind model_source ~f:(fun _ ->
        ThirdPartyAnnotationInfo.lookup_related_sig_file_by_package
          (ThirdPartyAnnotationGlobalRepo.get_repo ())
          function_procname )
  in
  match suggested_file_to_add_third_party with
  | Some sig_file_name ->
      (* This is a special case. While for FB codebase we can assume "not annotated hence not nullable" rule for all signatures,
         This is not the case for third party functions, which can have different conventions,
         So we can not just say "param is declared as non-nullable" like we say for FB-internal or modelled case:
         param can be nullable according to API but it was just not annotated.
         So we phrase it differently to remain truthful, but as specific as possible.
      *)
      let procname_str = Typ.Procname.to_simplified_string ~withclass:true function_procname in
      Format.asprintf
        "Third-party %a is missing a signature that would allow passing a nullable to param #%d%a. \
         Actual argument %s%s. Consider adding the correct signature of %a to %s."
        MF.pp_monospaced procname_str param_position pp_param_name param_signature.mangled
        argument_description nullability_evidence_as_suffix MF.pp_monospaced procname_str
        (ThirdPartyAnnotationGlobalRepo.get_user_friendly_third_party_sig_file_name
           ~filename:sig_file_name)
  | None ->
      let nonnull_evidence =
        match model_source with
        | None ->
            ""
        | Some InternalModel ->
            " (according to nullsafe internal models)"
        | Some (ThirdPartyRepo {filename; line_number}) ->
            Format.sprintf " (see %s at line %d)"
              (ThirdPartyAnnotationGlobalRepo.get_user_friendly_third_party_sig_file_name ~filename)
              line_number
      in
      Format.asprintf "%a: parameter #%d%a is declared non-nullable%s but the argument %s%s."
        MF.pp_monospaced
        (Typ.Procname.to_simplified_string ~withclass:true function_procname)
        param_position pp_param_name param_signature.mangled nonnull_evidence argument_description
        nullability_evidence_as_suffix


let is_declared_nonnull_to_nonnull ~lhs ~rhs =
  match (lhs, rhs) with Nullability.Nonnull, Nullability.DeclaredNonnull -> true | _ -> false


let get_issue_type = function
  | PassingParamToFunction _ ->
      IssueType.eradicate_parameter_not_nullable
  | AssigningToField _ ->
      IssueType.eradicate_field_not_nullable
  | ReturningFromFunction _ ->
      IssueType.eradicate_return_not_nullable


let violation_description {is_strict_mode; lhs; rhs} ~assignment_location assignment_type
    ~rhs_origin =
  if is_declared_nonnull_to_nonnull ~lhs ~rhs then (
    if not is_strict_mode then
      Logging.die InternalError "Unexpected situation: should not be a violation not in strict mode" ;
    (* This type of violation is more subtle than the normal case because, so it should be rendered in a special way *)
    ErrorRenderingUtils.get_strict_mode_violation_issue ~bad_usage_location:assignment_location
      rhs_origin )
  else
    let nullability_evidence =
      get_origin_opt assignment_type rhs_origin
      |> Option.bind ~f:(fun origin -> TypeOrigin.get_description origin)
    in
    let nullability_evidence_as_suffix =
      Option.value_map nullability_evidence ~f:(fun evidence -> ": " ^ evidence) ~default:""
    in
    let module MF = MarkupFormatter in
    let error_message =
      match assignment_type with
      | PassingParamToFunction function_info ->
          bad_param_description function_info nullability_evidence
      | AssigningToField field_name ->
          Format.asprintf "%a is declared non-nullable but is assigned a nullable%s."
            MF.pp_monospaced
            (Typ.Fieldname.to_flat_string field_name)
            nullability_evidence_as_suffix
      | ReturningFromFunction function_proc_name ->
          Format.asprintf
            "%a: return type is declared non-nullable but the method returns a nullable value%s."
            MF.pp_monospaced
            (Typ.Procname.to_simplified_string ~withclass:false function_proc_name)
            nullability_evidence_as_suffix
    in
    let issue_type = get_issue_type assignment_type in
    (error_message, issue_type, assignment_location)
