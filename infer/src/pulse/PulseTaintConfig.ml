(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module L = Logging

module Kind = struct
  type t = string [@@deriving compare, equal, hash]

  type kind_info = {name: string; is_data_flow_only: bool}

  (** Taint "kinds" are user-configurable and thus represented as strings. This hash table ensures
      we only store one copy of each kind. It also identifies which kinds are designated for data
      flow reporting only. *)
  let all_kinds = Hashtbl.create (module String)

  let of_string name =
    (* use [all_kinds] to do a weak hashconsing and try to keep only one version of each string
       around. This does not ensure we always get the same representative for each string because
       kinds get marshalled in and out of summaries, which does not maintain physical equality
       between equal kinds *)
    (Hashtbl.find_or_add all_kinds name ~default:(fun () -> {name; is_data_flow_only= false})).name


  let hash kind = String.hash kind

  let sexp_of_t kind = String.sexp_of_t kind

  let mark_data_flow_only name =
    Hashtbl.update all_kinds name ~f:(fun _ -> {name; is_data_flow_only= true})


  let is_data_flow_only name =
    Hashtbl.find all_kinds name |> Option.exists ~f:(fun {is_data_flow_only} -> is_data_flow_only)


  let pp fmt kind =
    F.fprintf fmt "`%s`%s" kind (if is_data_flow_only kind then " (data flow only)" else "")


  let simple_kind = of_string "Simple"

  let kinds_of_strings_opt = function
    | None ->
        [simple_kind]
    | Some kinds ->
        List.map kinds ~f:of_string
end

module Target = struct
  type procedure_target =
    | ReturnValue
    | AllArguments
    | ArgumentPositions of int list
    | AllArgumentsButPositions of int list
    | ArgumentsMatchingTypes of string list
    | InstanceReference
    | FieldsOfValue of (string * procedure_target) list

  type field_target = GetField | SetField

  type t = ProcedureTarget of procedure_target | FieldTarget of field_target

  let rec pp_procedure_target f procedure_target =
    match procedure_target with
    | ReturnValue ->
        F.pp_print_string f "ReturnValue"
    | AllArguments ->
        F.pp_print_string f "AllArguments"
    | ArgumentPositions positions ->
        F.fprintf f "ArgumentPositions %a" (Pp.comma_seq Int.pp) positions
    | AllArgumentsButPositions positions ->
        F.fprintf f "AllArgumentsButPositions %a" (Pp.comma_seq Int.pp) positions
    | ArgumentsMatchingTypes types ->
        F.fprintf f "ArgumentsMatchingTypes %a" (Pp.comma_seq String.pp) types
    | InstanceReference ->
        F.pp_print_string f "InstanceReference"
    | FieldsOfValue targets ->
        F.fprintf f "Fields %a"
          (Pp.comma_seq (Pp.pair ~fst:String.pp ~snd:pp_procedure_target))
          targets


  let pp_field_target f field_target =
    match field_target with
    | GetField ->
        F.pp_print_string f "GetField"
    | SetField ->
        F.pp_print_string f "SetField"


  let pp f target =
    match target with
    | ProcedureTarget target ->
        pp_procedure_target f target
    | FieldTarget target ->
        pp_field_target f target


  let rec target_of_gen_target (gen_target : Pulse_config_t.taint_target) =
    match gen_target with
    | `ReturnValue ->
        ProcedureTarget ReturnValue
    | `AllArguments ->
        ProcedureTarget AllArguments
    | `ArgumentPositions l ->
        ProcedureTarget (ArgumentPositions l)
    | `AllArgumentsButPositions l ->
        ProcedureTarget (AllArgumentsButPositions l)
    | `ArgumentsMatchingTypes l ->
        ProcedureTarget (ArgumentsMatchingTypes l)
    | `InstanceReference ->
        ProcedureTarget InstanceReference
    | `FieldsOfValue l ->
        let fields_targets =
          List.map l ~f:(fun (field, target) ->
              match target_of_gen_target target with
              | ProcedureTarget procedure_target ->
                  (field, procedure_target)
              | FieldTarget field_target ->
                  L.die UserError
                    "Only procedure targets are allowed within FieldsOfValue target, but found %a"
                    pp_field_target field_target )
        in
        ProcedureTarget (FieldsOfValue fields_targets)
    | `GetField ->
        FieldTarget GetField
    | `SetField ->
        FieldTarget SetField
end

module Unit = struct
  type procedure_matcher =
    | ProcedureName of {name: string}
    | ProcedureNameRegex of {name_regex: Str.regexp; exclude_in: string list option}
    | ClassNameRegex of {name_regex: Str.regexp; exclude_in: string list option}
    | ClassAndMethodNames of {class_names: string list; method_names: string list}
    | ClassAndMethodReturnTypeNames of
        {class_names: string list; method_return_type_names: string list}
    | OverridesOfClassWithAnnotation of {annotation: string}
    | MethodWithAnnotation of {annotation: string; annotation_values: string list option}
    | Block of {name: string}
    | BlockNameRegex of {name_regex: Str.regexp; exclude_in: string list option}
    | Allocation of {class_name: string}

  let pp_procedure_matcher f procedure_matcher =
    match procedure_matcher with
    | ProcedureName {name} ->
        F.fprintf f "Procedure %s" name
    | ProcedureNameRegex _ ->
        F.pp_print_string f "Procedure name regex"
    | ClassNameRegex _ ->
        F.pp_print_string f "Class Name regex"
    | ClassAndMethodNames {class_names; method_names} ->
        F.fprintf f "class_names=%a, method_names=%a" (Pp.comma_seq String.pp) class_names
          (Pp.comma_seq String.pp) method_names
    | ClassAndMethodReturnTypeNames {class_names; method_return_type_names} ->
        F.fprintf f "class_names=%a, method_return_type_names=%a" (Pp.comma_seq String.pp)
          class_names (Pp.comma_seq String.pp) method_return_type_names
    | OverridesOfClassWithAnnotation {annotation} ->
        F.fprintf f "overrides of class with annotation=%s" annotation
    | MethodWithAnnotation {annotation; annotation_values: string list option} ->
        F.fprintf f "method with annotation=%s and annotation_values=%a" annotation
          (Pp.option (Pp.comma_seq String.pp))
          annotation_values
    | Block {name} ->
        F.fprintf f "Block %s" name
    | BlockNameRegex _ ->
        F.fprintf f "Block regex"
    | Allocation {class_name} ->
        F.fprintf f "allocation %s" class_name


  type field_matcher =
    | FieldRegex of {name_regex: Str.regexp; exclude_in: string list option}
    | ClassAndFieldNames of {class_names: string list; field_names: string list}
    | FieldWithAnnotation of {annotation: string}

  let pp_field_matcher f field_matcher =
    match field_matcher with
    | FieldRegex _ ->
        F.pp_print_string f "Field name regex"
    | ClassAndFieldNames {class_names; field_names} ->
        F.fprintf f "class_names=%a, field_names=%a" (Pp.comma_seq String.pp) class_names
          (Pp.comma_seq String.pp) field_names
    | FieldWithAnnotation {annotation} ->
        F.fprintf f "field with annotation=%s" annotation


  type procedure_unit =
    { procedure_matcher: procedure_matcher
    ; arguments: Pulse_config_t.argument_constraint list
    ; kinds: Kind.t list
    ; procedure_target: Target.procedure_target }

  let pp_arguments f arguments =
    F.pp_print_string f (Pulse_config_j.string_of_argument_constraint arguments)


  let pp_procedure_unit f unit =
    F.fprintf f "procedure_matcher=%a, arguments=%a, kinds=%a, target=%a" pp_procedure_matcher
      unit.procedure_matcher (Pp.comma_seq pp_arguments) unit.arguments (Pp.comma_seq Kind.pp)
      unit.kinds Target.pp_procedure_target unit.procedure_target


  type field_unit =
    { field_matcher: field_matcher
    ; kinds: Kind.t list
    ; field_target: Target.field_target
    ; sanitized_in: string list option }

  let pp_field_unit f unit =
    F.fprintf f "field_matcher=%a, kinds=%a, field_target=%a, sanitized_in=%a" pp_field_matcher
      unit.field_matcher (Pp.comma_seq Kind.pp) unit.kinds Target.pp_field_target unit.field_target
      (Pp.option (Pp.comma_seq String.pp))
      unit.sanitized_in


  type t = ProcedureUnit of procedure_unit | FieldUnit of field_unit

  let pp_procedure_matcher_error_message f (matcher : Pulse_config_t.matcher) =
    let pp_procedure_matcher f (matcher : Pulse_config_t.matcher) =
      F.fprintf f
        "\"procedure\": %a, \n\
        \ \"procedure_regex\": %a, \n\
        \ \"class_name_regex\": %a, \n\
        \ \"class_names\": %a, \n\
        \ \"method_names\": %a, \n\
        \ \"method_return_type_names\": %a, \n\
        \ \"overrides_of_class_with_annotation\": %a,\n\
        \ \"method_with_annotation\": %a, \n\
        \ \"annotation_values\": %a, \n\
        \ \"block_passed_to\": %a, \n\
        \ \"block_passed_to_regex\": %a, \n\
        \ \"allocation\": %a" (Pp.option F.pp_print_string) matcher.procedure
        (Pp.option F.pp_print_string) matcher.procedure_regex (Pp.option F.pp_print_string)
        matcher.class_name_regex
        (Pp.option (Pp.seq ~sep:"," F.pp_print_string))
        matcher.class_names
        (Pp.option (Pp.seq ~sep:"," F.pp_print_string))
        matcher.method_names
        (Pp.option (Pp.seq ~sep:"," F.pp_print_string))
        matcher.method_return_type_names
        (Pp.option (Pp.seq ~sep:"," F.pp_print_string))
        matcher.annotation_values (Pp.option F.pp_print_string)
        matcher.overrides_of_class_with_annotation (Pp.option F.pp_print_string)
        matcher.method_with_annotation (Pp.option F.pp_print_string) matcher.block_passed_to
        (Pp.option F.pp_print_string) matcher.block_passed_to_regex (Pp.option F.pp_print_string)
        matcher.allocation
    in
    F.fprintf f
      "To build a procedure matcher, exactly one of \n\
      \ \"procedure\", \n\
      \ \"procedure_regex\", \n\
      \ \"class_name_regex\", \n\
      \ \"block_passed_to\", \n\
      \ \"block_passed_to_regex\", \n\
      \ \"method_with_annotation\", \n\
      \ \"allocation\" or \n\
      \ \"overrides_of_class_with_annotation\" must be provided, \n\
       or else \"class_names\" and \"method_names\" must be provided, \n\
       or else \"class_names\" and \"method_return_type_names\" must be provided, \n\
       or else \"method_with_annotation\" and \"annotation_values\" must be provided, \n\
       but got \n\
      \ %a." pp_procedure_matcher matcher


  let pp_field_matcher_error_message f (matcher : Pulse_config_t.matcher) =
    let pp_field_matcher f (matcher : Pulse_config_t.matcher) =
      F.fprintf f
        "\"field_regex\": %a, \n\
        \ \"class_names\": %a, \n\
        \ \"field_names\": %a, \n\
        \ \"field_with_annotation\": %a" (Pp.option F.pp_print_string) matcher.field_regex
        (Pp.option (Pp.seq ~sep:"," F.pp_print_string))
        matcher.class_names
        (Pp.option (Pp.seq ~sep:"," F.pp_print_string))
        matcher.field_names (Pp.option F.pp_print_string) matcher.field_with_annotation
    in
    F.fprintf f
      "To build a field matcher, exactly one of \n\
      \ \"field_regex\", \n\
      \ \"field_with_annotation\", \n\
       or else \"class_names\" and \"field_names\" must be provided, \n\
       but got \n\
      \ %a" pp_field_matcher matcher


  let procedure_matcher_of_config ~default_taint_target ~option_name
      (matcher : Pulse_config_t.matcher) =
    let procedure_matcher =
      match matcher with
      | { procedure= Some name
        ; procedure_regex= None
        ; class_name_regex= None
        ; class_names= None
        ; method_names= None
        ; method_return_type_names= None
        ; overrides_of_class_with_annotation= None
        ; method_with_annotation= None
        ; annotation_values= None
        ; block_passed_to= None
        ; allocation= None } ->
          ProcedureName {name}
      | { procedure= None
        ; procedure_regex= Some name_regex
        ; class_name_regex= None
        ; class_names= None
        ; method_names= None
        ; method_return_type_names= None
        ; annotation_values= None
        ; overrides_of_class_with_annotation= None
        ; method_with_annotation= None
        ; block_passed_to= None
        ; allocation= None } ->
          ProcedureNameRegex
            {name_regex= Str.regexp name_regex; exclude_in= matcher.exclude_from_regex_in}
      | { procedure= None
        ; procedure_regex= None
        ; class_name_regex= Some name_regex
        ; class_names= None
        ; method_names= None
        ; overrides_of_class_with_annotation= None
        ; method_with_annotation= None
        ; annotation_values= None
        ; block_passed_to= None
        ; allocation= None } ->
          ClassNameRegex
            {name_regex= Str.regexp name_regex; exclude_in= matcher.exclude_from_regex_in}
      | { procedure= None
        ; procedure_regex= None
        ; class_name_regex= None
        ; class_names= Some class_names
        ; method_names= Some method_names
        ; method_return_type_names= None
        ; overrides_of_class_with_annotation= None
        ; method_with_annotation= None
        ; annotation_values= None
        ; block_passed_to= None
        ; allocation= None } ->
          ClassAndMethodNames {class_names; method_names}
      | { procedure= None
        ; procedure_regex= None
        ; class_name_regex= None
        ; class_names= Some class_names
        ; method_names= None
        ; method_return_type_names= Some method_return_type_names
        ; overrides_of_class_with_annotation= None
        ; method_with_annotation= None
        ; annotation_values= None
        ; allocation= None } ->
          ClassAndMethodReturnTypeNames {class_names; method_return_type_names}
      | { procedure= None
        ; procedure_regex= None
        ; class_names= None
        ; method_names= None
        ; method_return_type_names= None
        ; overrides_of_class_with_annotation= Some annotation
        ; method_with_annotation= None
        ; allocation= None } ->
          OverridesOfClassWithAnnotation {annotation}
      | { procedure= None
        ; procedure_regex= None
        ; class_name_regex= None
        ; class_names= None
        ; method_names= None
        ; method_return_type_names= None
        ; overrides_of_class_with_annotation= None
        ; method_with_annotation= Some annotation
        ; annotation_values
        ; block_passed_to= None
        ; allocation= None } ->
          MethodWithAnnotation {annotation; annotation_values}
      | { procedure= None
        ; procedure_regex= None
        ; class_name_regex= None
        ; class_names= None
        ; method_names= None
        ; method_return_type_names= None
        ; overrides_of_class_with_annotation= None
        ; method_with_annotation= None
        ; annotation_values= None
        ; block_passed_to= None
        ; allocation= Some class_name } ->
          Allocation {class_name}
      | { procedure= None
        ; procedure_regex= None
        ; class_name_regex= None
        ; class_names= None
        ; method_names= None
        ; overrides_of_class_with_annotation= None
        ; method_with_annotation= None
        ; annotation_values= None
        ; block_passed_to= Some s
        ; allocation= None } ->
          Block {name= s}
      | { procedure= None
        ; procedure_regex= None
        ; class_name_regex= None
        ; class_names= None
        ; method_names= None
        ; overrides_of_class_with_annotation= None
        ; method_with_annotation= None
        ; annotation_values= None
        ; block_passed_to_regex= Some name_regex
        ; allocation= None } ->
          BlockNameRegex
            {name_regex= Str.regexp name_regex; exclude_in= matcher.exclude_from_regex_in}
      | _ ->
          L.die UserError "When parsing option %s: Unexpected JSON format: %a \n %a" option_name
            pp_procedure_matcher_error_message matcher pp_field_matcher_error_message matcher
    in
    let taint_target =
      Target.target_of_gen_target (Option.value ~default:default_taint_target matcher.taint_target)
    in
    match taint_target with
    | ProcedureTarget procedure_target ->
        { procedure_matcher
        ; arguments= matcher.argument_constraints
        ; kinds= Kind.kinds_of_strings_opt matcher.kinds
        ; procedure_target }
    | FieldTarget _ ->
        L.die UserError
          "Target %a found but one of the following targets must be provided:\n\
          \         ReturnValue, AllArguments, ArgumentPositions, AllArgumentsButPositions, \
           ArgumentsMatchingTypes, InstanceReference, FieldsOfValue"
          Target.pp taint_target


  let field_matcher_of_config ~default_taint_target ~option_name (matcher : Pulse_config_t.matcher)
      =
    let field_matcher =
      match matcher with
      | { field_regex= Some name_regex
        ; class_names= None
        ; field_names= None
        ; field_with_annotation= None } ->
          FieldRegex {name_regex= Str.regexp name_regex; exclude_in= matcher.exclude_from_regex_in}
      | { field_regex= None
        ; class_names= Some class_names
        ; field_names= Some field_names
        ; field_with_annotation= None } ->
          ClassAndFieldNames {class_names; field_names}
      | { field_regex= None
        ; class_names= None
        ; field_names= None
        ; field_with_annotation= Some annotation } ->
          FieldWithAnnotation {annotation}
      | _ ->
          L.die UserError "When parsing option %s: Unexpected JSON format: %a %a" option_name
            pp_field_matcher_error_message matcher pp_procedure_matcher_error_message matcher
    in
    let taint_target =
      Target.target_of_gen_target (Option.value ~default:default_taint_target matcher.taint_target)
    in
    match taint_target with
    | FieldTarget field_target ->
        { field_matcher
        ; kinds= Kind.kinds_of_strings_opt matcher.kinds
        ; field_target
        ; sanitized_in= matcher.Pulse_config_t.sanitized_in }
    | ProcedureTarget _ ->
        L.die UserError
          "Target %a found but one of the following targets must be provided: GetField or SetField"
          Target.pp taint_target


  let is_field_matcher (matcher : Pulse_config_t.matcher) =
    Option.is_some matcher.field_regex
    || Option.is_some matcher.field_names
    || Option.is_some matcher.field_with_annotation


  let of_config ~default_taint_target ~option_name (matchers : Pulse_config_t.matcher list) =
    List.map matchers ~f:(fun (matcher : Pulse_config_t.matcher) ->
        if is_field_matcher matcher then
          FieldUnit (field_matcher_of_config ~default_taint_target ~option_name matcher)
        else ProcedureUnit (procedure_matcher_of_config ~default_taint_target ~option_name matcher) )
end

module SinkPolicy = struct
  type t =
    { source_kinds: Kind.t list [@ignore]
    ; sanitizer_kinds: Kind.t list [@ignore]
    ; description: string [@ignore]
    ; policy_id: int
    ; privacy_effect: string option [@ignore]
    ; exclude_in: string list option [@ignore] }
  [@@deriving equal]

  let pp f policy =
    F.fprintf f
      "source_kinds=%a, description=%a, sanitizer_kinds=%a, policy_id=%d, privacy_effect=%a, \
       exclude_in=%a"
      (Pp.comma_seq Kind.pp) policy.source_kinds F.pp_print_string policy.description
      (Pp.comma_seq Kind.pp) policy.sanitizer_kinds policy.policy_id (Pp.option String.pp)
      policy.privacy_effect
      (Pp.option (Pp.comma_seq String.pp))
      policy.exclude_in


  let next_policy_id =
    let policy_id_counter = ref 0 in
    fun () ->
      incr policy_id_counter ;
      !policy_id_counter


  let sink_policies : (Kind.t, t list) Base.Hashtbl.t = Hashtbl.create (module Kind)

  let pp_sink_policies f sink_policies =
    Hashtbl.iteri sink_policies ~f:(fun ~key:kind ~data:policies_by_kind ->
        F.fprintf f "%a -> %a@\n" Kind.pp kind (Pp.comma_seq pp) policies_by_kind )
end
