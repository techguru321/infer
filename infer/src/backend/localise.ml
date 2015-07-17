(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(** Support for localisation *)

module F = Format
open Utils

(** type of string used for localisation *)
type t = string

(** pretty print a localised string *)
let pp fmt s = Format.fprintf fmt "%s" s

(** create a localised string from an ordinary string *)
let from_string s = s

(** convert a localised string to an ordinary string *)
let to_string s = s

(** compare two localised strings *)
let compare (s1: string) (s2: string) = Pervasives.compare s1 s2

let analysis_stops = "ANALYSIS_STOPS"
let array_out_of_bounds_l1 = "ARRAY_OUT_OF_BOUNDS_L1"
let array_out_of_bounds_l2 = "ARRAY_OUT_OF_BOUNDS_L2"
let array_out_of_bounds_l3 = "ARRAY_OUT_OF_BOUNDS_L3"
let class_cast_exception = "CLASS_CAST_EXCEPTION"
let comparing_floats_for_equality = "COMPARING_FLOAT_FOR_EQUALITY"
let condition_is_assignment = "CONDITION_IS_ASSIGNMENT"
let condition_always_false = "CONDITION_ALWAYS_FALSE"
let condition_always_true = "CONDITION_ALWAYS_TRUE"
let dangling_pointer_dereference = "DANGLING_POINTER_DEREFERENCE"
let deallocate_stack_variable = "DEALLOCATE_STACK_VARIABLE"
let deallocate_static_memory = "DEALLOCATE_STATIC_MEMORY"
let deallocation_mismatch = "DEALLOCATION_MISMATCH"
let divide_by_zero = "DIVIDE_BY_ZERO"
let field_not_null_checked = "IVAR_NOT_NULL_CHECKED"
let inherently_dangerous_function = "INHERENTLY_DANGEROUS_FUNCTION"
let memory_leak = "MEMORY_LEAK"
let null_dereference = "NULL_DEREFERENCE"
let parameter_not_null_checked = "PARAMETER_NOT_NULL_CHECKED"
let null_test_after_dereference = "NULL_TEST_AFTER_DEREFERENCE"
let pointer_size_mismatch = "POINTER_SIZE_MISMATCH"
let precondition_not_found = "PRECONDITION_NOT_FOUND"
let precondition_not_met = "PRECONDITION_NOT_MET"
let premature_nil_termination = "PREMATURE_NIL_TERMINATION_ARGUMENT"
let resource_leak = "RESOURCE_LEAK"
let retain_cycle = "RETAIN_CYCLE"
let return_value_ignored = "RETURN_VALUE_IGNORED"
let return_expression_required = "RETURN_EXPRESSION_REQUIRED"
let return_statement_missing = "RETURN_STATEMENT_MISSING"
let skip_function = "SKIP_FUNCTION"
let skip_pointer_dereference = "SKIP_POINTER_DEREFERENCE"
let stack_variable_address_escape = "STACK_VARIABLE_ADDRESS_ESCAPE"
let tainted_value_reaching_sensitive_function = "TAINTED_VALUE_REACHING_SENSITIVE_FUNCTION"
let unary_minus_applied_to_unsigned_expression = "UNARY_MINUS_APPLIED_TO_UNSIGNED_EXPRESSION"
let uninitialized_value = "UNINITIALIZED_VALUE"
let use_after_free = "USE_AFTER_FREE"

(** description field of error messages: descriptions, advice and tags *)
type error_desc = string list * string option * (string * string) list

(** empty error description *)
let no_desc: error_desc = [], None, []

(** verbatim desc from a string, not to be used for user-visible descs *)
let verbatim_desc s = [s], None, []

let custom_desc s tags = [s], None, tags

let custom_desc_with_advice description advice tags =
  [description], Some advice, tags

(** pretty print an error description *)
let pp_error_desc fmt (l, _, s) =
  let pp_item fmt s = F.fprintf fmt "%s" s in
  pp_seq pp_item fmt l

(** pretty print an error advice *)
let pp_error_advice fmt (_, advice, _) =
  match advice with
  | Some advice -> F.fprintf fmt "%s" advice
  | None -> ()

(** pretty print an error description *)
let pp_error_desc fmt (l, _, _) =
  let pp_item fmt s = F.fprintf fmt "%s" s in
  pp_seq pp_item fmt l

(** get tags of error description *)
let error_desc_get_tags (_, _, tags) = tags

module Tags = struct
  let accessed_line = "accessed_line" (* line where value was last accessed *)
  let alloc_function = "alloc_function" (* allocation function used *)
  let alloc_call = "alloc_call" (* call in the current procedure which triggers the allocation *)
  let alloc_line = "alloc_line" (* line of alloc_call *)
  let array_index = "array_index" (* index of the array *)
  let array_size = "array_size" (* size of the array *)
  let assigned_line = "assigned_line" (* line where value was last assigned *)
  let bucket = "bucket" (* bucket to classify likelyhood of real bug *)
  let call_procedure = "call_procedure" (* name of the procedure called *)
  let call_line = "call_line" (* line of call_procedure *)
  let dealloc_function = "dealloc_function" (* deallocation function used *)
  let dealloc_call = "dealloc_call" (* call in the current procedure which triggers the deallocation *)
  let dealloc_line = "dealloc_line" (* line of dealloc_call *)
  let dereferenced_line = "dereferenced_line" (* line where value was dereferenced *)
  let escape_to = "escape_to" (* expression wher a value escapes to *)
  let line = "line" (* line of the error *)
  let type1 = "type1" (* 1st Java type *)
  let type2 = "type2" (* 2nd Java type *)
  let value = "value" (* string describing a C value, e.g. "x.date" *)
  let parameter_not_null_checked = "parameter_not_null_checked" (* describes a NPE that comes from parameter not nullable *)
  let field_not_null_checked = "field_not_null_checked" (* describes a NPE that comes from field not nullable *)
  let nullable_src = "nullable_src" (* @Nullable-annoted field/param/retval that causes a warning *)
  let create () = ref []
  let add tags tag value = tags := (tag, value) :: !tags
  let update tags tag value =
    let tags' = list_filter (fun (t, v) -> t <> tag) tags in
    (tag, value) :: tags'
  let get tags tag =
    try
      let (_, v) = list_find (fun (t, _) -> t = tag) tags in
      Some v
    with Not_found -> None
end

module BucketLevel = struct
  let b1 = "B1" (* highest likelyhood *)
  let b2 = "B2"
  let b3 = "B3"
  let b4 = "B4"
  let b5 = "B5" (* lowest likelyhood *)
end

(** takes in input a tag to extract from the given error_desc
and returns its value *)
let error_desc_extract_tag_value (_, _, tags) tag_to_extract =
  let find_value tag v =
    match v with
    | (t, _) when t = tag -> true
    | _ -> false in
  try
    let _, s = list_find (find_value tag_to_extract) tags in
    s
  with Not_found -> ""

let error_desc_to_tag_value_pairs (_, _, tags) = tags

(** returns the content of the value tag of the error_desc *)
let error_desc_get_tag_value error_desc = error_desc_extract_tag_value error_desc Tags.value

(** returns the content of the call_procedure tag of the error_desc *)
let error_desc_get_tag_call_procedure error_desc = error_desc_extract_tag_value error_desc Tags.call_procedure

(** get the bucket value of an error_desc, if any *)
let error_desc_get_bucket (_, _, tags) =
  Tags.get tags Tags.bucket

(** set the bucket value of an error_desc; the boolean indicates where the bucket should be shown in the message *)
let error_desc_set_bucket (l, advice, tags) bucket show_in_message =
  let tags' = Tags.update tags Tags.bucket bucket in
  let l' =
    if show_in_message = false then l
    else ("[" ^ bucket ^ "]") :: l in
  (l', advice, tags')

(** get the value tag, if any *)
let get_value_line_tag tags =
  try
    let value = snd (list_find (fun (_tag, value) -> _tag = Tags.value) tags) in
    let line = snd (list_find (fun (_tag, value) -> _tag = Tags.line) tags) in
    Some [value; line]
  with Not_found -> None

(** extract from desc a value on which to apply polymorphic hash and equality *)
let desc_get_comparable (sl, advice, tags) =
  match get_value_line_tag tags with
  | Some sl' -> sl'
  | None -> sl

(** hash function for error_desc *)
let error_desc_hash desc =
  Hashtbl.hash (desc_get_comparable desc)

(** equality for error_desc *)
let error_desc_equal desc1 desc2 = (desc_get_comparable desc1) = (desc_get_comparable desc2)

let _line_tag tags tag loc =
  let line_str = string_of_int loc.Sil.line in
  Tags.add tags tag line_str;
  let s = "line " ^ line_str in
  if (loc.Sil.col != -1) then
    let col_str = string_of_int loc.Sil.col in
    s ^ ", column " ^ col_str
  else s

let at_line_tag tags tag loc =
  "at " ^ _line_tag tags tag loc

let _line tags loc =
  _line_tag tags Tags.line loc

let at_line tags loc =
  at_line_tag tags Tags.line loc

let call_to tags proc_name =
  let proc_name_str = Procname.to_simplified_string proc_name in
  Tags.add tags Tags.call_procedure proc_name_str;
  "call to " ^ proc_name_str

let call_to_at_line tags proc_name loc =
  (call_to tags proc_name) ^ " " ^ at_line_tag tags Tags.call_line loc

let by_call_to tags proc_name =
  "by " ^ call_to tags proc_name

let by_call_to_ra tags ra =
  "by " ^ call_to_at_line tags ra.Sil.ra_pname ra.Sil.ra_loc

let mem_dyn_allocated = "memory dynamically allocated"
let res_acquired = "resource acquired"
let lock_acquired = "lock acquired"
let released = "released"
let reachable = "reachable"

(** dereference strings used to explain a dereference action in an error message *)
type deref_str =
  { tags : (string * string) list ref; (** tags for the error description *)
    value_pre: string option; (** string printed before the value being dereferenced *)
    value_post: string option; (** string printed after the value being dereferenced *)
    problem_str: string; (** description of the problem *) }

let pointer_or_object () =
  if !Sil.curr_language = Sil.Java then "object" else "pointer"

let _deref_str_null proc_name_opt _problem_str tags =
  let problem_str = match proc_name_opt with
    | Some proc_name ->
        _problem_str ^ " " ^ by_call_to tags proc_name
    | None -> _problem_str in
  { tags = tags;
    value_pre = Some (pointer_or_object ());
    value_post = None;
    problem_str = problem_str; }

(** dereference strings for null dereference *)
let deref_str_null proc_name_opt =
  let problem_str = "could be null and is dereferenced" in
  _deref_str_null proc_name_opt problem_str (Tags.create ())

(** dereference strings for null dereference due to Nullable annotation *)
let deref_str_nullable proc_name_opt nullable_obj_str =
  let tags = Tags.create () in
  Tags.add tags Tags.nullable_src nullable_obj_str;
  (* to be completed once we know if the deref'd expression is directly or transitively @Nullable*)
  let problem_str = "" in
  _deref_str_null proc_name_opt problem_str tags

(** dereference strings for nonterminal nil arguments in c/objc variadic methods *)
let deref_str_nil_argument_in_variadic_method pn total_args arg_number =
  let tags = Tags.create () in
  let function_method, nil_null =
    if Procname.is_objc pn then ("method", "nil") else ("function", "null") in
  let problem_str =
    Printf.sprintf
      "could be %s which results in a call to %s with %d arguments instead of %d \
       (%s indicates that the last argument of this variadic %s has been reached)"
      nil_null (Procname.to_simplified_string pn) arg_number (total_args - 1) nil_null function_method in
  _deref_str_null None problem_str tags

(** dereference strings for an undefined value coming from the given procedure *)
let deref_str_undef (proc_name, loc) =
  let tags = Tags.create () in
  let proc_name_str = Procname.to_simplified_string proc_name in
  Tags.add tags Tags.call_procedure proc_name_str;
  { tags = tags;
    value_pre = Some (pointer_or_object ());
    value_post = None;
    problem_str = "could be assigned by a call to skip function " ^ proc_name_str ^
      at_line_tag tags Tags.call_line loc ^ " and is dereferenced or freed"; }

(** dereference strings for a freed pointer dereference *)
let deref_str_freed ra =
  let tags = Tags.create () in
  let freed_or_closed_by_call =
    let freed_or_closed = match ra.Sil.ra_res with
      | Sil.Rmemory _ -> "freed"
      | Sil.Rfile -> "closed"
      | Sil.Rignore -> "freed"
      | Sil.Rlock -> "locked" in
    freed_or_closed ^ " " ^ by_call_to_ra tags ra in
  { tags = tags;
    value_pre = Some (pointer_or_object ());
    value_post = None;
    problem_str = "was " ^ freed_or_closed_by_call ^ " and is dereferenced or freed" }

(** dereference strings for a dangling pointer dereference *)
let deref_str_dangling dangling_kind_opt =
  let dangling_kind_prefix = match dangling_kind_opt with
    | Some Sil.DAuninit -> "uninitialized "
    | Some Sil.DAaddr_stack_var -> "deallocated stack "
    | Some Sil.DAminusone -> "-1 "
    | None -> "" in
  { tags = Tags.create ();
    value_pre = Some (dangling_kind_prefix ^ (pointer_or_object ()));
    value_post = None;
    problem_str = "could be dangling and is dereferenced or freed"; }

(** dereference strings for a pointer size mismatch *)
let deref_str_pointer_size_mismatch typ_from_instr typ_of_object =
  let str_from_typ typ =
    let pp f () = Sil.pp_typ_full pe_text f typ in
    pp_to_string pp () in
  { tags = Tags.create ();
    value_pre = Some (pointer_or_object ());
    value_post = Some ("of type " ^ str_from_typ typ_from_instr);
    problem_str = "could be used to access an object of smaller type " ^ str_from_typ typ_of_object; }

(** dereference strings for an array out of bound access *)
let deref_str_array_bound size_opt index_opt =
  let tags = Tags.create () in
  let size_str_opt = match size_opt with
    | Some n ->
        let n_str = Sil.Int.to_string n in
        Tags.add tags Tags.array_size n_str;
        Some ("of size " ^ n_str)
    | None -> None in
  let index_str = match index_opt with
    | Some n ->
        let n_str = Sil.Int.to_string n in
        Tags.add tags Tags.array_index n_str;
        "index " ^ n_str
    | None -> "an index" in
  { tags = tags;
    value_pre = Some "array";
    value_post = size_str_opt;
    problem_str = "could be accessed with " ^ index_str ^ " out of bounds"; }

(** dereference strings for an uninitialized access whose lhs has the given attribute *)
let deref_str_uninitialized alloc_att_opt =
  let tags = Tags.create () in
  let creation_str = match alloc_att_opt with
    | Some (Sil.Aresource ({ Sil.ra_kind = Sil.Racquire } as ra)) ->
        "after allocation " ^ by_call_to_ra tags ra
    | _ -> "after declaration" in
  { tags = tags;
    value_pre = Some "value";
    value_post = None;
    problem_str = "was not initialized " ^ creation_str ^ " and is used"; }

(** Java unchecked exceptions errors *)
let java_unchecked_exn_desc proc_name exn_name pre_str : error_desc =
  ([Procname.to_string proc_name;
    "can throw "^(Mangled.to_string exn_name);
    "whenever "^pre_str], None, [])

let desc_assertion_failure loc : error_desc =
  (["could be raised"; at_line (Tags.create ()) loc], None, [])

(** type of access *)
type access =
  | Last_assigned of int * bool (* line, null_case_flag *)
  | Last_accessed of int * bool (* line, is_nullable flag *)
  | Initialized_automatically
  | Returned_from_call of int

let dereference_string deref_str value_str access_opt loc =
  let tags = deref_str.tags in
  Tags.add tags Tags.value value_str;
  let is_call_access = match access_opt with
    | Some (Returned_from_call _) -> true
    | _ -> false in
  let value_desc =
    String.concat "" [
      (match deref_str.value_pre with Some s -> s ^ " " | _ -> "");
      (if is_call_access then "returned by " else "");
      value_str;
      (match deref_str.value_post with Some s -> " " ^ s | _ -> "")] in
  let access_desc = match access_opt with
    | None ->
        []
    | Some (Last_accessed (n, _)) ->
        let line_str = string_of_int n in
        Tags.add tags Tags.accessed_line line_str;
        ["last accessed on line " ^ line_str]
    | Some (Last_assigned (n, ncf)) ->
        let line_str = string_of_int n in
        Tags.add tags Tags.assigned_line line_str;
        ["last assigned on line " ^ line_str]
    | Some (Returned_from_call _) -> []
    | Some Initialized_automatically ->
        ["initialized automatically"] in
  let problem_desc =
    let problem_str =
      match Tags.get !tags Tags.nullable_src with
      | Some nullable_src ->
        if nullable_src = value_str then "is annotated with @Nullable and is dereferenced"
        else "may hold @Nullable-annotated object " ^ nullable_src ^ " and is dereferenced"
      | None -> deref_str.problem_str in
    [(problem_str ^ " " ^ at_line tags loc)] in
  value_desc:: access_desc @ problem_desc, None, !tags

let parameter_field_not_null_checked_desc desc exp =
  let parameter_not_nullable_desc var =
    let var_s = Sil.pvar_to_string var in
    let param_not_null_desc =
      "Parameter "^var_s^" is not checked for null, there could be a null pointer dereference:" in
    match desc with
    | descriptions, advice, tags ->
        param_not_null_desc:: descriptions, advice, (Tags.parameter_not_null_checked, var_s):: tags in
  let field_not_nullable_desc exp =
    let rec exp_to_string exp =
      match exp with
      | Sil.Lfield (exp', field, typ) -> (exp_to_string exp')^" -> "^(Ident.fieldname_to_string field)
      | Sil.Lvar pvar -> Mangled.to_string (Sil.pvar_get_name pvar)
      | _ -> "" in
    let var_s = exp_to_string exp in
    let field_not_null_desc =
      "Instance variable "^var_s^" is not checked for null, there could be a null pointer dereference:" in
    match desc with
    | descriptions, advice, tags ->
        field_not_null_desc:: descriptions, advice, (Tags.field_not_null_checked, var_s):: tags in
  match exp with
  | Sil.Lvar var -> parameter_not_nullable_desc var
  | Sil.Lfield _ -> field_not_nullable_desc exp
  | _ -> desc

let has_tag desc tag =
  match desc with
  | descriptions, advice, tags ->
      list_exists (fun (tag', value) -> tag = tag') tags

let is_parameter_not_null_checked_desc desc = has_tag desc Tags.parameter_not_null_checked

let is_field_not_null_checked_desc desc = has_tag desc Tags.field_not_null_checked

let is_parameter_field_not_null_checked_desc desc =
  is_parameter_not_null_checked_desc desc ||
  is_field_not_null_checked_desc desc

let desc_allocation_mismatch alloc dealloc =
  let tags = Tags.create () in
  let using is_alloc (primitive_pname, called_pname, loc) =
    let tag_fun, tag_call, tag_line =
      if is_alloc then Tags.alloc_function, Tags.alloc_call, Tags.alloc_line
      else Tags.dealloc_function, Tags.dealloc_call, Tags.dealloc_line in
    Tags.add tags tag_fun (Procname.to_simplified_string primitive_pname);
    Tags.add tags tag_call (Procname.to_simplified_string called_pname);
    Tags.add tags tag_line (string_of_int loc.Sil.line);
    let by_call =
      if Procname.equal primitive_pname called_pname then ""
      else " by call to " ^ Procname.to_simplified_string called_pname in
    "using " ^ Procname.to_simplified_string primitive_pname ^ by_call ^ " " ^ at_line (Tags.create ()) (* ignore the tag *) loc in
  let description = Format.sprintf
      "%s %s is deallocated %s"
      mem_dyn_allocated
      (using true alloc)
      (using false dealloc) in
  [description], None, !tags

let desc_comparing_floats_for_equality loc =
  let tags = Tags.create () in
  ["Comparing floats for equality " ^ at_line tags loc], None, !tags

let desc_condition_is_assignment loc =
  let tags = Tags.create () in
  ["Boolean condition is an assignment " ^ at_line tags loc], None, !tags

let desc_condition_always_true_false i cond_str_opt loc =
  let tags = Tags.create () in
  let value = match cond_str_opt with
    | None -> ""
    | Some s -> s in
  let tt_ff = if Sil.Int.iszero i then "false" else "true" in
  Tags.add tags Tags.value value;
  let description = Format.sprintf
      "Boolean condition %s is always %s %s"
      (if value = "" then "" else " " ^ value)
      tt_ff
      (at_line tags loc) in
  [description], None, !tags

let desc_deallocate_stack_variable var_str proc_name loc =
  let tags = Tags.create () in
  Tags.add tags Tags.value var_str;
  let description = Format.sprintf
      "Stack variable %s is freed by a %s"
      var_str
      (call_to_at_line tags proc_name loc) in
  [description], None, !tags

let desc_deallocate_static_memory const_str proc_name loc =
  let tags = Tags.create () in
  Tags.add tags Tags.value const_str;
  let description = Format.sprintf
      "Constant string %s is freed by a %s"
      const_str
      (call_to_at_line tags proc_name loc) in
  [description], None, !tags

let desc_class_cast_exception pname_opt typ_str1 typ_str2 exp_str_opt loc =
  let tags = Tags.create () in
  Tags.add tags Tags.type1 typ_str1;
  Tags.add tags Tags.type2 typ_str2;
  let in_expression = match exp_str_opt with
    | Some exp_str ->
        Tags.add tags Tags.value exp_str;
        " in expression " ^ exp_str ^ " "
    | None -> " " in
  let at_line' () = match pname_opt with
    | Some proc_name -> "in " ^ call_to_at_line tags proc_name loc
    | None -> at_line tags loc in
  let description = Format.sprintf
      "%s cannot be cast to %s %s %s"
      typ_str1
      typ_str2
      in_expression
      (at_line' ()) in
  [description], None, !tags

let desc_divide_by_zero expr_str loc =
  let tags = Tags.create () in
  Tags.add tags Tags.value expr_str;
  let description = Format.sprintf
      "Expression %s could be zero %s"
      expr_str
      (at_line tags loc) in
  [description], None, !tags

let desc_leak value_str_opt resource_opt resource_action_opt loc bucket_opt =
  let tags = Tags.create () in
  let () = match bucket_opt with
    | Some bucket ->
        Tags.add tags Tags.bucket bucket;
    | None -> () in
  let value_str = match value_str_opt with
    | None -> ""
    | Some s ->
        Tags.add tags Tags.value s;
        s in
  let xxx_allocated_to =
    let desc_str =
      let _to = if value_str_opt = None then "" else " to " in
      let _on = if value_str_opt = None then "" else " on " in
      match resource_opt with
      | Some Sil.Rmemory _ -> mem_dyn_allocated ^ _to ^ value_str
      | Some Sil.Rfile -> res_acquired ^ _to ^ value_str
      | Some Sil.Rlock -> lock_acquired ^ _on ^ value_str
      | Some Sil.Rignore
      | None -> if value_str_opt = None then "memory" else value_str in
    if desc_str = "" then [] else [desc_str] in
  let by_call_to = match resource_action_opt with
    | Some ra -> [(by_call_to_ra tags ra)]
    | None -> [] in
  let is_not_rxxx_after =
    let rxxx = match resource_opt with
      | Some Sil.Rmemory _ -> reachable
      | Some Sil.Rfile
      | Some Sil.Rlock -> released
      | Some Sil.Rignore
      | None -> reachable in
    [("is not " ^ rxxx ^ " after " ^ _line tags loc)] in
  let bucket_str =
    match bucket_opt with
    | Some bucket when !Config.show_ml_buckets -> bucket
    | _ -> "" in
  bucket_str :: xxx_allocated_to @ by_call_to @ is_not_rxxx_after, None, !tags

(** kind of precondition not met *)
type pnm_kind =
  | Pnm_bounds
  | Pnm_dangling

let desc_precondition_not_met kind proc_name loc =
  let tags = Tags.create () in
  let kind_str = match kind with
    | None -> []
    | Some Pnm_bounds -> ["possible array out of bounds"]
    | Some Pnm_dangling -> ["possible dangling pointer dereference"] in
  kind_str @ ["in " ^ call_to_at_line tags proc_name loc], None, !tags

let desc_null_test_after_dereference expr_str line loc =
  let tags = Tags.create () in
  Tags.add tags Tags.dereferenced_line (string_of_int line);
  Tags.add tags Tags.value expr_str;
  let description = Format.sprintf
      "Pointer %s was dereferenced at line %d and is tested for null %s"
      expr_str
      line
      (at_line tags loc) in
  [description], None, !tags

let desc_return_expression_required typ_str loc =
  let tags = Tags.create () in
  Tags.add tags Tags.value typ_str;
  let description = Format.sprintf
      "Return statement requires an expression of type %s %s"
      typ_str
      (at_line tags loc) in
  [description], None, !tags

let desc_retain_cycle prop cycle loc =
  Logging.d_strln "Proposition with retain cycle:";
  Prop.d_prop prop; Logging.d_strln "";
  let ct = ref 1 in
  let tags = Tags.create () in
  let str_cycle = ref "" in
  let remove_old s =
    match Str.split_delim (Str.regexp_string "&old_") s with
    | [_; s'] -> s'
    | _ -> s in
  let do_edge ((se,_), f, se') =
    match se with
    | Sil.Eexp(Sil.Lvar pvar, _) when Sil.pvar_equal pvar Sil.block_pvar ->
        str_cycle:=!str_cycle^" ("^(string_of_int !ct)^") a block capturing "^(Ident.fieldname_to_string f)^"; ";
        ct:=!ct +1;
    | Sil.Eexp(Sil.Lvar pvar as e, _) ->
        let e_str = Sil.exp_to_string e in
        let e_str = if Sil.pvar_is_seed pvar then
            remove_old e_str
          else e_str in
        str_cycle:=!str_cycle^" ("^(string_of_int !ct)^") object "^e_str^" retaining "^e_str^"."^(Ident.fieldname_to_string f)^", ";
        ct:=!ct +1
    | Sil.Eexp(Sil.Sizeof(typ, _), _) ->
        str_cycle:=!str_cycle^" ("^(string_of_int !ct)^") an object of "^(Sil.typ_to_string typ)^" retaining another object via instance variable "^(Ident.fieldname_to_string f)^", ";
        ct:=!ct +1
    | _ -> () in
  list_iter do_edge cycle;
  let desc = Format.sprintf "Retain cycle involving the following objects: %s  %s"
      !str_cycle (at_line tags loc) in
  [desc], None, !tags

let desc_return_statement_missing loc =
  let tags = Tags.create () in
  ["Return statement missing " ^ at_line tags loc], None, !tags

let desc_return_value_ignored proc_name loc =
  let tags = Tags.create () in
  ["after " ^ call_to_at_line tags proc_name loc], None, !tags

let desc_unary_minus_applied_to_unsigned_expression expr_str_opt typ_str loc =
  let tags = Tags.create () in
  let expression = match expr_str_opt with
    | Some s ->
        Tags.add tags Tags.value s;
        "expression " ^ s
    | None -> "an expression" in
  let description = Format.sprintf
      "A unary minus is applied to %s of type %s %s"
      expression
      typ_str
      (at_line tags loc) in
  [description], None, !tags

let desc_skip_function proc_name =
  let tags = Tags.create () in
  let proc_name_str = Procname.to_string proc_name in
  Tags.add tags Tags.value proc_name_str;
  [proc_name_str], None, !tags

let desc_inherently_dangerous_function proc_name =
  let proc_name_str = Procname.to_string proc_name in
  let tags = Tags.create () in
  Tags.add tags Tags.value proc_name_str;
  [proc_name_str], None, !tags

let desc_stack_variable_address_escape expr_str addr_dexp_str loc =
  let tags = Tags.create () in
  Tags.add tags Tags.value expr_str;
  let escape_to_str = match addr_dexp_str with
    | Some s ->
        Tags.add tags Tags.escape_to s;
        "to " ^ s ^ " "
    | None -> "" in
  let description = Format.sprintf
      "Address of stack variable %s escapes %s%s"
      expr_str
      escape_to_str
      (at_line tags loc) in
  [description], None, !tags

let desc_tainted_value_reaching_sensitive_function expr_str loc =
  let tags = Tags.create () in
  Tags.add tags Tags.value expr_str;
  let description = Format.sprintf
      "Value %s can be tainted and is reaching sensitive function %s"
      expr_str
      (at_line tags loc) in
  [description], None, !tags
