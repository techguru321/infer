(*
* Copyright (c) 2014 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

open Utils
module L = Logging
module F = Format

(** Module for type checking. *)

let remove_temps = true (* remove temp ids from typestates *)

(* print debug info when errors are found *)
let debug = Config.from_env_variable "ERADICATE_DEBUG"


(** Module to treat selected complex expressions as constants. *)
module ComplexExpressions = struct
  (** What complex expressions are considered constant, each case includes the previous ones.
  Boolean checks (e.g. null check) and assignments on expressions considered constant are
  retained across the control flow assuming there are no modifications in between. *)
  type expressions_constant =
    | FL_NO (* none *)
    | FL_PARAMETER_STATIC (* parameter.field and static fields *)
    | FL_ALL_NESTED_FIELDS (* all forms of var.field1. ... .fieldn *)
    | FUNCTIONS_IDEMPOTENT (* the above plus function calls are considered idempotent *)

  let complex_expressions_flag = FUNCTIONS_IDEMPOTENT

  let parameter_and_static_field () =
    complex_expressions_flag >= FL_PARAMETER_STATIC

  let all_nested_fields () =
    complex_expressions_flag >= FL_ALL_NESTED_FIELDS

  let functions_idempotent () =
    complex_expressions_flag >= FUNCTIONS_IDEMPOTENT


  let procname_optional_isPresent = Models.is_optional_isPresent
  let procname_instanceof = Procname.equal SymExec.ModelBuiltins.__instanceof
  let procname_containsKey = Models.is_containsKey

  (** Recognize *all* the procedures treated specially in conditionals *)
  let procname_used_in_condition pn =
    procname_optional_isPresent pn ||
    procname_instanceof pn ||
    procname_containsKey pn ||
    SymExec.function_is_builtin pn


  exception Not_handled

  (* Convert an expression to a unique string. *)
  (* This is used to turn complex expressions into pvar's.*)
  (* Arbitrary function parameters and field access are allowed *)
  (* when the relevant options are active. *)
  let exp_to_string_map_dexp map_dexp node' exp =

    let rec dexp_to_string dexp =
      let case_not_handled () =
        raise Not_handled in

      match dexp with
      | Sil.Darray (de1, de2) ->
          dexp_to_string de1 ^ "[" ^ dexp_to_string de2 ^ "]"
      | Sil.Darrow (de, f)
      | Sil.Ddot (de, f) ->
          dexp_to_string de ^ "." ^ Ident.fieldname_to_string f
      | Sil.Dbinop (op, de1, de2) ->
          "(" ^ dexp_to_string de1 ^ (Sil.str_binop pe_text op) ^ dexp_to_string de2 ^ ")"
      | Sil.Dconst (Sil.Cfun pn) ->
          Procname.to_unique_id pn
      | Sil.Dconst c ->
          pp_to_string (Sil.pp_const pe_text) c
      | Sil.Dderef de ->
          dexp_to_string de
      | Sil.Dfcall (fun_dexp, args, loc, { Sil.cf_virtual = isvirtual })
      | Sil.Dretcall (fun_dexp, args, loc, { Sil.cf_virtual = isvirtual })
      when functions_idempotent () ->
          let pp_arg fmt de = F.fprintf fmt "%s" (dexp_to_string de) in
          let pp_args fmt des = (pp_comma_seq) pp_arg fmt des in
          let pp fmt () =
            let virt = if isvirtual then "V" else "" in
            F.fprintf fmt "%a(%a)%s" pp_arg fun_dexp pp_args args virt in
          pp_to_string pp ()
      | Sil.Dfcall _
      | Sil.Dretcall _ ->
          case_not_handled ()
      | Sil.Dpvar pv
      | Sil.Dpvaraddr pv when not (Errdesc.pvar_is_frontend_tmp pv) ->
          Sil.pvar_to_string pv
      | Sil.Dpvar pv
      | Sil.Dpvaraddr pv (* front-end variable -- this should not happen) *) ->
          case_not_handled ()
      | Sil.Dunop (op, de) ->
          Sil.str_unop op ^ dexp_to_string de

      | Sil.Dsizeof (typ, sub) ->
          case_not_handled ()
      | Sil.Dunknown ->
          case_not_handled () in

    match map_dexp (Errdesc.exp_rv_dexp node' exp) with
    | Some de ->
        begin
          try Some (dexp_to_string de)
          with Not_handled -> None
        end
    | None -> None

  let exp_to_string node' exp =
    let map_dexp de_opt = de_opt in
    exp_to_string_map_dexp map_dexp node' exp

end (* ComplexExpressions *)

type check_return_type =
  Procname.t -> Cfg.Procdesc.t -> Sil.typ -> Sil.typ option -> Sil.location -> unit

type find_canonical_duplicate = Cfg.Node.t -> Cfg.Node.t

type get_proc_desc = TypeState.get_proc_desc

type checks =
  {
    eradicate : bool;
    check_extension : bool;
    check_ret_type : check_return_type list;
  }

(** Typecheck an expression. *)
let rec typecheck_expr
    find_canonical_duplicate visited checks node instr_ref curr_pname
    typestate e tr_default loc : TypeState.range = match e with
  | Sil.Lvar pvar ->
      (match TypeState.lookup_pvar pvar typestate with
        | Some tr -> TypeState.range_add_locs tr [loc]
        | None -> tr_default)
  | Sil.Var id ->
      (match TypeState.lookup_id id typestate with
        | Some tr -> TypeState.range_add_locs tr [loc]
        | None -> tr_default)
  | Sil.Const (Sil.Cint i) when Sil.Int.iszero i ->
      let (typ, _, locs) = tr_default in
      if PatternMatch.type_is_class typ
      then (typ, TypeAnnotation.const Annotations.Nullable true (TypeOrigin.Const loc), locs)
      else
        let t, ta, ll = tr_default in
        (t, TypeAnnotation.with_origin ta (TypeOrigin.Const loc), ll)
  | Sil.Const (Sil.Cexn e1) ->
      typecheck_expr
        find_canonical_duplicate visited checks
        node instr_ref curr_pname
        typestate e1 tr_default loc
  | Sil.Const c ->
      let (typ, _, locs) = tr_default in
      (typ, TypeAnnotation.const Annotations.Nullable false (TypeOrigin.Const loc), locs)
  | Sil.Lfield (exp, fn, typ) ->
      let _, _, locs = tr_default in
      let (_, ta, locs') =
        typecheck_expr
          find_canonical_duplicate visited checks node instr_ref curr_pname typestate exp
          (typ, TypeAnnotation.const Annotations.Nullable false TypeOrigin.ONone, locs) loc in
      let tr_new = match EradicateChecks.get_field_annotation fn typ with
        | Some (t, ia) ->
            (
              t,
              TypeAnnotation.from_item_annotation ia (TypeOrigin.Field (fn, loc)),
              locs'
            )
        | None -> tr_default in
      if checks.eradicate then
        EradicateChecks.check_field_access
          find_canonical_duplicate curr_pname node instr_ref exp fn ta loc;
      tr_new
  | Sil.Lindex (array_exp, index_exp) ->
      let (_, ta, _) =
        typecheck_expr
          find_canonical_duplicate
          visited
          checks
          node
          instr_ref
          curr_pname
          typestate
          array_exp
          tr_default
          loc in
      let index =
        match EradicateChecks.explain_expr node index_exp with
        | Some s -> Format.sprintf "%s" s
        | None -> "?" in
      let fname = Ident.create_fieldname
          (Mangled.from_string index)
          0 in
      if checks.eradicate then
        EradicateChecks.check_array_access
          find_canonical_duplicate
          curr_pname
          node
          instr_ref
          array_exp
          fname
          ta
          loc
          true;
      tr_default
  | _ -> tr_default

(** Typecheck an instruction. *)
let typecheck_instr ext calls_this checks (node: Cfg.Node.t) idenv get_proc_desc curr_pname
    curr_pdesc find_canonical_duplicate annotated_signature instr_ref linereader typestate instr =
  let print_current_state () =
    L.stdout "Current Typestate in node %a@\n%a@."
      Cfg.Node.pp (TypeErr.InstrRef.get_node instr_ref)
      (TypeState.pp ext) typestate;
    L.stdout "  %a@." (Sil.pp_instr pe_text) instr in

  (** Handle the case where a field access X.f happens via a temporary variable $Txxx.
  This has been observed in assignments this.f = exp when exp contains an ifthenelse.
  Reconstuct the original expression knowing: the origin of $Txxx is 'this'. *)
  let handle_field_access_via_temporary typestate exp loc =
    let name_is_temporary name =
      let prefix = "$T" in
      Utils.string_is_prefix prefix name in
    let pvar_get_origin pvar =
      match TypeState.lookup_pvar pvar typestate with
      | Some (_, ta, _) ->
          Some (TypeAnnotation.get_origin ta)
      | None -> None in
    let handle_temporary e = match Idenv.expand_expr idenv e with
      | Sil.Lvar pvar when name_is_temporary (Sil.pvar_to_string pvar) ->
          begin
            match pvar_get_origin pvar with
            | Some (TypeOrigin.Formal s) ->
                let pvar' = Sil.mk_pvar (Mangled.from_string s) curr_pname in
                Some (Sil.Lvar pvar')
            | _ -> None
          end
      | _ -> None in
    match exp with
    | Sil.Lfield (e, fn, typ) ->
        let exp' = match handle_temporary e with
          | Some e' ->
              Sil.Lfield (e', fn, typ)
          | None -> exp in
        exp'
    | _ -> exp in

  (** Convert a complex expressions into a pvar.
  When [is_assigment] is true, update the relevant annotations for the pvar. *)
  let convert_complex_exp_to_pvar node' is_assignment _exp typestate loc =
    let exp =
      handle_field_access_via_temporary
        typestate
        (Idenv.expand_expr idenv _exp)
        loc in
    let default = exp, typestate in

    (* If this is an assignment, update the typestate for a field access pvar. *)
    let update_typestate_fld pvar fn typ =
      match TypeState.lookup_pvar pvar typestate with
      | Some _ when not is_assignment -> typestate
      | _ ->
          (match EradicateChecks.get_field_annotation fn typ with
            | Some (t, ia) ->
                let range =
                  (
                    t,
                    TypeAnnotation.from_item_annotation ia (TypeOrigin.Field (fn, loc)),
                    [loc]
                  ) in
                TypeState.add_pvar pvar range typestate
            | None -> typestate) in

    (* Convert a function call to a pvar. *)
    let handle_function_call call_node id =
      match Errdesc.find_normal_variable_funcall call_node id with
      | Some (Sil.Const (Sil.Cfun pn), _, _, _)
      when not (ComplexExpressions.procname_used_in_condition pn) ->
          begin
            match ComplexExpressions.exp_to_string node' exp with
            | None -> default
            | Some exp_str ->
                let pvar = Sil.mk_pvar (Mangled.from_string exp_str) curr_pname in
                let already_in_typestate = TypeState.lookup_pvar pvar typestate <> None in

                if is_assignment && already_in_typestate
                then default (* Don't overwrite pvar representing result of function call. *)
                else Sil.Lvar pvar, typestate
          end
      | _ -> default in

    match exp with
    | Sil.Var id when
    ComplexExpressions.functions_idempotent () &&
    Errdesc.find_normal_variable_funcall node' id <> None ->
        handle_function_call node' id
    | Sil.Lvar pvar when
    ComplexExpressions.functions_idempotent () &&
    Errdesc.pvar_is_frontend_tmp pvar ->
        let frontend_variable_assignment =
          Errdesc.find_program_variable_assignment node pvar in
        begin
          match frontend_variable_assignment with
          | Some (call_node, id) ->
              handle_function_call call_node id

          | _ -> default
        end

    | Sil.Lvar pvar ->
        default
    | Sil.Lfield (_exp, fn, typ) when ComplexExpressions.parameter_and_static_field () ->
        let exp' = Idenv.expand_expr_temps idenv node _exp in

        let is_parameter_field pvar = (* parameter.field *)
          let name = Sil.pvar_to_string pvar in
          let filter (s, ia, typ) = string_equal s name in
          list_exists filter annotated_signature.Annotations.params in

        let is_static_field pvar = (* static field *)
          Sil.pvar_is_global pvar in

        let pvar_to_str pvar =
          if Sil.exp_is_this (Sil.Lvar pvar) then ""
          else Sil.pvar_to_string pvar ^ "_" in

        let res = match exp' with
          | Sil.Lvar pv when is_parameter_field pv || is_static_field pv ->
              let fld_name = pvar_to_str pv ^ Ident.fieldname_to_string fn in
              let pvar = Sil.mk_pvar (Mangled.from_string fld_name) curr_pname in
              let typestate' = update_typestate_fld pvar fn typ in
              (Sil.Lvar pvar, typestate')
          | Sil.Lfield (_exp', fn', typ') when Ident.java_fieldname_is_outer_instance fn' ->
          (** handle double dereference when accessing a field from an outer class *)
              let fld_name = Ident.fieldname_to_string fn' ^ "_" ^ Ident.fieldname_to_string fn in
              let pvar = Sil.mk_pvar (Mangled.from_string fld_name) curr_pname in
              let typestate' = update_typestate_fld pvar fn typ in
              (Sil.Lvar pvar, typestate')
          | Sil.Lvar _ | Sil.Lfield _ when ComplexExpressions.all_nested_fields () ->
          (** treat var.field1. ... .fieldn as a constant *)
              begin
                match ComplexExpressions.exp_to_string node' exp with
                | Some exp_str ->
                    let pvar = Sil.mk_pvar (Mangled.from_string exp_str) curr_pname in
                    let typestate' = update_typestate_fld pvar fn typ in
                    (Sil.Lvar pvar, typestate')
                | None ->
                    default
              end
          | _ ->
              default in
        res
    | _ -> default in

  let constructor_check_calls_this calls_this pn =
    if Procname.java_get_class curr_pname = Procname.java_get_class pn
    then calls_this := true in

  (* Drops hidden and synthetic parameters which we do not check in a call. *)
  let drop_unchecked_params calls_this pdesc pname params =
    if Procname.is_constructor pname then
      match PatternMatch.get_this_type pdesc with
      | Some this_type ->
          begin
            constructor_check_calls_this calls_this pname;

            (* Drop reference parameters to this and outer objects. *)
            let is_hidden_parameter (n, t) =
              string_equal n "this" ||
              Str.string_match (Str.regexp "$bcvar[0-9]+") n 0 in
            let rec drop_n_args ntl = match ntl with
              | fp:: tail when is_hidden_parameter fp -> 1 + drop_n_args tail
              | _ -> 0 in
            let n = drop_n_args (Cfg.Procdesc.get_formals pdesc) in
            let visible_params = list_drop_first n params in

            (* Drop the trailing hidden parameter if the constructor is synthetic. *)
            if (Cfg.Procdesc.get_attributes pdesc).Sil.is_synthetic_method then
              list_drop_last 1 visible_params
            else
              visible_params
          end
      | None -> params
    else
      params in

  (* Drop parameters from the signature which we do not check in a call. *)
  let drop_unchecked_signature_params pdesc pname annotated_signature =
    if Procname.is_constructor pname &&
    (Cfg.Procdesc.get_attributes pdesc).Sil.is_synthetic_method then
      list_drop_last 1 annotated_signature.Annotations.params
    else
      annotated_signature.Annotations.params in

  let pvar_is_return pvar =
    let pdesc = Cfg.Node.get_proc_desc node in
    let ret_pvar = Cfg.Procdesc.get_ret_var pdesc in
    Sil.pvar_equal pvar ret_pvar in

  (* Apply a function to a pvar and its associated content if front-end generated. *)
  let pvar_apply loc handle_pvar typestate pvar =
    let typestate' = handle_pvar typestate pvar in
    let curr_node = TypeErr.InstrRef.get_node instr_ref in
    let frontent_variable_assignment =
      if Errdesc.pvar_is_frontend_tmp pvar
      then Errdesc.find_program_variable_assignment curr_node pvar
      else None in
    match frontent_variable_assignment with
    | None ->
        typestate'
    | Some (node', id) ->
    (* handle the case where pvar is a frontend-generated program variable *)
        let exp = Idenv.expand_expr idenv (Sil.Var id) in
        begin
          match convert_complex_exp_to_pvar node' false exp typestate' loc with
          | Sil.Lvar pvar', _ -> handle_pvar typestate' pvar'
          | _ -> typestate'
        end in


  (* typecheck_expr with fewer parameters, using a common template for typestate range  *)
  let typecheck_expr_simple typestate1 exp1 typ1 origin1 loc1 =
    typecheck_expr
      find_canonical_duplicate calls_this checks node instr_ref
      curr_pname typestate1 exp1
      (typ1, TypeAnnotation.const Annotations.Nullable false origin1, [loc1])
      loc1 in

  (* check if there are errors in exp1 *)
  let typecheck_expr_for_errors typestate1 exp1 loc1 : unit =
    ignore (typecheck_expr_simple typestate1 exp1 Sil.Tvoid TypeOrigin.Undef loc1) in

  match instr with
  | Sil.Remove_temps (idl, loc) ->
      if remove_temps then list_fold_right TypeState.remove_id idl typestate
      else typestate
  | Sil.Declare_locals _
  | Sil.Abstract _
  | Sil.Nullify _ -> typestate
  | Sil.Letderef (id, e, typ, loc) ->
      typecheck_expr_for_errors typestate e loc;
      let e', typestate' = convert_complex_exp_to_pvar node false e typestate loc in
      TypeState.add_id id
        (typecheck_expr_simple typestate' e' typ TypeOrigin.Undef loc)
        typestate'
  | Sil.Set (Sil.Lvar pvar, typ, Sil.Const (Sil.Cexn _), loc) when pvar_is_return pvar ->
  (* skip assignment to return variable where it is an artifact of a throw instruction *)
      typestate
  | Sil.Set (e1, typ, e2, loc) ->
      typecheck_expr_for_errors typestate e1 loc;
      let e1', typestate1 = convert_complex_exp_to_pvar node true e1 typestate loc in
      let check_field_assign () = match e1 with
        | Sil.Lfield (_, fn, f_typ) ->
            let t_ia_opt = EradicateChecks.get_field_annotation fn f_typ in
            if checks.eradicate then
              EradicateChecks.check_field_assignment
                find_canonical_duplicate curr_pname node
                instr_ref typestate1 e1' e2 typ loc fn t_ia_opt
                (typecheck_expr find_canonical_duplicate calls_this checks)
                print_current_state
        | _ -> () in
      let typestate2 =
        match e1' with
        | Sil.Lvar pvar ->
            TypeState.add_pvar
              pvar
              (typecheck_expr_simple typestate1 e2 typ TypeOrigin.Undef loc)
              typestate1
        | Sil.Lfield (_, fn, styp) ->
            typestate1
        | _ ->
            typestate1 in
      check_field_assign ();
      typestate2
  | Sil.Call ([id], Sil.Const (Sil.Cfun pn), [(_, typ)], loc, _)
  when Procname.equal pn SymExec.ModelBuiltins.__new ||
  Procname.equal pn SymExec.ModelBuiltins.__new_array ->
      TypeState.add_id
        id
        (typ, TypeAnnotation.const Annotations.Nullable false TypeOrigin.New, [loc])
        typestate (* new never returns null *)
  | Sil.Call ([id], Sil.Const (Sil.Cfun pn), (e, typ):: _, loc, _)
  when Procname.equal pn SymExec.ModelBuiltins.__cast ->
      typecheck_expr_for_errors typestate e loc;
      let e', typestate' =
        convert_complex_exp_to_pvar node false e typestate loc in
      (* cast copies the type of the first argument *)
      TypeState.add_id id
        (typecheck_expr_simple typestate' e' typ TypeOrigin.ONone loc)
        typestate'
  | Sil.Call ([id], Sil.Const (Sil.Cfun pn), [(array_exp, t)], loc, _)
  when Procname.equal pn SymExec.ModelBuiltins.__get_array_size ->
      let (_, ta, _) = typecheck_expr
          find_canonical_duplicate
          calls_this
          checks
          node
          instr_ref
          curr_pname
          typestate
          array_exp
          (t, TypeAnnotation.const Annotations.Nullable false TypeOrigin.ONone, [loc])
          loc in
      if checks.eradicate then
        EradicateChecks.check_array_access
          find_canonical_duplicate
          curr_pname
          node
          instr_ref
          array_exp
          (Ident.create_fieldname (Mangled.from_string "length") 0)
          ta
          loc
          false;
      TypeState.add_id
        id
        (
          Sil.Tint (Sil.IInt),
          TypeAnnotation.const Annotations.Nullable false TypeOrigin.New,
          [loc]
        )
        typestate
  | Sil.Call (_, Sil.Const (Sil.Cfun pn), _, _, _) when SymExec.function_is_builtin pn ->
      typestate (* skip othe builtins *)
  | Sil.Call (ret_ids, Sil.Const (Sil.Cfun callee_pname), _etl, loc, cflags)
  when get_proc_desc callee_pname <> None ->
      let callee_pdesc = match get_proc_desc callee_pname with
        | Some callee_pdesc -> callee_pdesc
        | None -> assert false in
      let callee_loc = Cfg.Procdesc.get_loc callee_pdesc in

      let etl = drop_unchecked_params calls_this callee_pdesc callee_pname _etl in
      let call_params, typestate1 =
        let handle_et (e1, t1) (etl1, typestate1) =
          typecheck_expr_for_errors typestate e1 loc;
          let e2, typestate2 = convert_complex_exp_to_pvar node false e1 typestate1 loc in
          (((e1, e2), t1) :: etl1), typestate2 in
        list_fold_right handle_et etl ([], typestate) in

      let annotated_signature = Models.get_annotated_signature callee_pdesc callee_pname in
      let signature_params = drop_unchecked_signature_params
          callee_pdesc
          callee_pname
          annotated_signature in

      let is_anonymous_inner_class_constructor =
        Procname.java_is_anonymous_inner_class_constructor callee_pname in

      let do_return loc' typestate' =
        match ret_ids with
        | [] -> typestate'
        | [id] ->
            let (ia, ret_typ) = annotated_signature.Annotations.ret in
            let is_library = Specs.proc_is_library callee_pname callee_pdesc in
            let origin = TypeOrigin.Proc (callee_pname, loc', annotated_signature, is_library) in
            TypeState.add_id
              id
              (
                ret_typ,
                TypeAnnotation.from_item_annotation ia origin,
                [loc']
              )
              typestate'
        | _ :: _ :: _ -> assert false in

      (** Handle Preconditions.checkNotNull. *)
      let do_preconditions_check_not_null parameter_num is_vararg typestate' =
        (* clear the nullable flag of the first parameter of the procedure *)
        let clear_nullable_flag typestate'' pvar =
          (* remove the nullable flag for the given pvar *)
          match TypeState.lookup_pvar pvar typestate'' with
          | Some (t, ta, locs) ->
              let should_report =
                EradicateChecks.activate_condition_redundant &&
                TypeAnnotation.get_value Annotations.Nullable ta = false &&
                not (TypeAnnotation.origin_is_fun_library ta) in
              if checks.eradicate && should_report then
                begin
                  let cond = Sil.BinOp (Sil.Ne, Sil.Lvar pvar, Sil.exp_null) in
                  EradicateChecks.report_error
                    find_canonical_duplicate
                    node
                    (TypeErr.Condition_redundant
                      (true, EradicateChecks.explain_expr node cond, false))
                    (Some instr_ref)
                    loc curr_pname
                end;
              TypeState.add_pvar
                pvar
                (t, TypeAnnotation.const Annotations.Nullable false TypeOrigin.ONone, [loc])
                typestate''
          | None ->
              typestate' in
        let rec find_parameter n eetl1 = match n, eetl1 with
          | n, _ :: eetl2 when n > 1 -> find_parameter (n -1) eetl2
          | 1, ((_, Sil.Lvar pvar), typ):: _ -> Some (pvar, typ)
          | _ -> None in

        match find_parameter parameter_num call_params with
        | Some (pvar, typ) ->
            if is_vararg
            then
              let do_vararg_value e ts = match Idenv.expand_expr idenv e with
                | Sil.Lvar pvar1 ->
                    pvar_apply loc clear_nullable_flag ts pvar1
                | _ -> ts in
              let vararg_values = PatternMatch.java_get_vararg_values node pvar idenv curr_pdesc in
              Utils.list_fold_right do_vararg_value vararg_values typestate'
            else
              pvar_apply loc clear_nullable_flag typestate' pvar
        | None -> typestate' in


      (** Handle Preconditions.checkState for &&-separated conditions x!=null. *)
      let do_preconditions_check_state typestate' =
        let handle_pvar ann b typestate1 pvar = (* handle the annotation flag for pvar *)
          match TypeState.lookup_pvar pvar typestate1 with
          | Some (t, _, _) ->
              TypeState.add_pvar
                pvar
                (t, TypeAnnotation.const ann b TypeOrigin.ONone, [loc])
                typestate1
          | None ->
              typestate1 in

        let res_typestate = ref typestate' in

        let set_flag pvar ann b = (* set the annotation flag for pvar *)
          res_typestate := pvar_apply loc (handle_pvar ann b) !res_typestate pvar in

        let handle_negated_condition cond_node =
          let do_instr = function
            | Sil.Prune (Sil.BinOp (Sil.Eq, _cond_e, Sil.Const (Sil.Cint i)), _, _, _)
            | Sil.Prune (Sil.BinOp (Sil.Eq, Sil.Const (Sil.Cint i), _cond_e), _, _, _)
            when Sil.Int.iszero i ->
                let cond_e = Idenv.expand_expr_temps idenv cond_node _cond_e in
                begin
                  match convert_complex_exp_to_pvar cond_node false cond_e typestate' loc with
                  | Sil.Lvar pvar', _ ->
                      set_flag pvar' Annotations.Nullable false
                  | _ -> ()
                end
            | _ -> () in
          list_iter do_instr (Cfg.Node.get_instrs cond_node) in
        let handle_optional_isPresent node' e =
          match convert_complex_exp_to_pvar node' false e typestate' loc with
          | Sil.Lvar pvar', _ ->
              set_flag pvar' Annotations.Present true
          | _ -> () in
        match call_params with
        | ((_, Sil.Lvar pvar), typ):: _ ->
        (* temporary variable for the value of the boolean condition *)
            begin
              let curr_node = TypeErr.InstrRef.get_node instr_ref in
              let branch = false in
              match Errdesc.find_boolean_assignment curr_node pvar branch with
              (* In foo(cond1 && cond2), the node that sets the result to false
              has all the negated conditions as parents. *)
              | Some boolean_assignment_node ->
                  list_iter handle_negated_condition (Cfg.Node.get_preds boolean_assignment_node);
                  !res_typestate
              | None ->
                  begin
                    match Errdesc.find_program_variable_assignment curr_node pvar with
                    | None ->
                        ()
                    | Some (node', id) ->
                        let () = match Errdesc.find_normal_variable_funcall node' id with
                          | Some (Sil.Const (Sil.Cfun pn), [e], loc, call_flags)
                          when ComplexExpressions.procname_optional_isPresent pn ->
                              handle_optional_isPresent node' e
                          | _ -> () in
                        ()
                  end;
                  !res_typestate
            end
        | _ -> typestate' in


      let typestate2 =
        if not is_anonymous_inner_class_constructor then
          begin
            if debug then
              begin
                let unique_id = Procname.to_unique_id callee_pname in
                let classification =
                  EradicateChecks.classify_procedure callee_pname callee_pdesc in
                L.stdout "  %s unique id: %s@." classification unique_id
              end;
            if cflags.Sil.cf_virtual && checks.eradicate then
              EradicateChecks.check_call_receiver
                find_canonical_duplicate
                curr_pname
                node
                typestate1
                call_params
                callee_pname
                callee_loc
                instr_ref
                loc
                (typecheck_expr find_canonical_duplicate calls_this checks)
                print_current_state;
            if checks.eradicate then
              EradicateChecks.check_call_parameters
                find_canonical_duplicate
                curr_pname
                node
                typestate1
                callee_pname
                callee_pdesc
                signature_params
                call_params
                loc
                annotated_signature
                instr_ref
                (typecheck_expr find_canonical_duplicate calls_this checks)
                print_current_state;
            let typestate2 =
              if checks.check_extension then
                let etl' = list_map (fun ((_, e), t) -> (e, t)) call_params in
                let extension = TypeState.get_extension typestate1 in
                let extension' =
                  ext.TypeState.check_instr
                    get_proc_desc curr_pname curr_pdesc node
                    extension instr etl' in
                TypeState.set_extension typestate1 extension'
              else typestate1 in
            if Models.is_check_not_null callee_pname then
              do_preconditions_check_not_null
                (Models.get_check_not_null_parameter callee_pname)
                false (* is_vararg *)
                typestate2
            else
            if Procname.java_get_method callee_pname = "checkNotNull"
            && Procname.java_is_vararg callee_pname
            then
              let last_parameter = list_length call_params in
              do_preconditions_check_not_null
                last_parameter
                true (* is_vararg *)
                typestate2
            else if Models.is_check_state callee_pname ||
            Models.is_check_argument callee_pname then
              do_preconditions_check_state typestate2
            else typestate2
          end
        else typestate1 in
      do_return loc typestate2
  | Sil.Call _ ->
      typestate
  | Sil.Prune (cond, loc, true_branch, ik) ->
      let rec check_condition node' c : _ TypeState.t =
        (* check if the expression is coming from a call, and return the argument *)
        let from_call filter_callee e : Sil.exp option =
          match e with
          | Sil.Var id ->
              begin
                match Errdesc.find_normal_variable_funcall node' id with
                | Some (Sil.Const (Sil.Cfun pn), e1:: _, loc, call_flags) when
                filter_callee pn ->
                    Some e1
                | _ -> None
              end
          | _ -> None in

        (* check if the expression is coming from instanceof *)
        let from_instanceof e : Sil.exp option =
          from_call ComplexExpressions.procname_instanceof e in

        (* check if the expression is coming from Optional.isPresent *)
        let from_optional_isPresent e : Sil.exp option =
          from_call ComplexExpressions.procname_optional_isPresent e in

        (* check if the expression is coming from Map.containsKey *)
        let from_containsKey e : Sil.exp option =
          from_call ComplexExpressions.procname_containsKey e in

        (* Turn x.containsKey(e) into the pvar for x.get(e) *)
        (* which is then treated as a normal condition != null. *)
        let handle_containsKey e =
          let map_dexp = function
            | Some (Sil.Dretcall (Sil.Dconst (Sil.Cfun pname), args, loc, call_flags)) ->
                let pname' =
                  let object_t = (Some "java.lang", "Object") in
                  Procname.java_replace_return_type
                    (Procname.java_replace_method pname "get")
                    object_t in
                let fun_dexp = Sil.Dconst (Sil.Cfun pname') in
                Some (Sil.Dretcall (fun_dexp, args, loc, call_flags))
            | _ -> None in
          begin
            match ComplexExpressions.exp_to_string_map_dexp map_dexp node' e with
            | Some e_str ->
                let pvar =
                  Sil.mk_pvar (Mangled.from_string e_str) curr_pname in
                let e1 = Sil.Lvar pvar in
                let (typ, ta, _) =
                  typecheck_expr_simple typestate e1 Sil.Tvoid TypeOrigin.ONone loc in
                let range = (typ, ta, [loc]) in
                let typestate1 = TypeState.add_pvar pvar range typestate in
                typestate1, e1, EradicateChecks.From_containsKey
            | None ->
                typestate, e, EradicateChecks.From_condition
          end in


        match c with
        | Sil.BinOp (Sil.Eq, Sil.Const (Sil.Cint i), e)
        | Sil.BinOp (Sil.Eq, e, Sil.Const (Sil.Cint i)) when Sil.Int.iszero i ->
            typecheck_expr_for_errors typestate e loc;
            let e', typestate' = convert_complex_exp_to_pvar node' false e typestate loc in
            let (typ, ta, _) =
              typecheck_expr_simple typestate' e' Sil.Tvoid TypeOrigin.ONone loc in
            if checks.eradicate then
              EradicateChecks.check_zero
                find_canonical_duplicate get_proc_desc curr_pname
                node' e' typ
                ta true_branch EradicateChecks.From_condition
                idenv linereader loc instr_ref;
            typestate'
        | Sil.BinOp (Sil.Ne, Sil.Const (Sil.Cint i), e)
        | Sil.BinOp (Sil.Ne, e, Sil.Const (Sil.Cint i)) when Sil.Int.iszero i ->
            let typestate1, e1, from_call = match from_instanceof e with
              | Some e1 -> (* (e1 instanceof C) implies (e1 != null) *)
                  typestate, e1, EradicateChecks.From_instanceof
              | None ->
                  begin
                    match from_optional_isPresent e with
                    | Some e1 ->
                        typestate, e1, EradicateChecks.From_optional_isPresent
                    | None ->
                        begin
                          match from_containsKey e with
                          | Some e1 when ComplexExpressions.functions_idempotent () ->
                              handle_containsKey e
                          | _ ->
                              typestate, e, EradicateChecks.From_condition
                        end
                  end in
            typecheck_expr_for_errors typestate1 e1 loc;
            let e', typestate2 = convert_complex_exp_to_pvar node' false e1 typestate1 loc in
            let (typ, ta, _) =
              typecheck_expr_simple typestate2 e' Sil.Tvoid TypeOrigin.ONone loc in

            let set_flag e' ann b = (* add constraint on e' for annotation ann *)
              let handle_pvar typestate' pvar =
                match TypeState.lookup_pvar pvar typestate' with
                | Some (t, ta1, locs) ->
                    if TypeAnnotation.get_value ann ta1 <> b then
                      let origin = TypeAnnotation.get_origin ta1 in
                      let ta2 = TypeAnnotation.const ann b origin in
                      TypeState.add_pvar pvar (t, ta2, locs) typestate'
                    else typestate'
                | None -> typestate' in
              match e' with
              | Sil.Lvar pvar ->
                  pvar_apply loc handle_pvar typestate2 pvar
              | _ -> typestate2 in

            if checks.eradicate then
              EradicateChecks.check_nonzero find_canonical_duplicate get_proc_desc curr_pname
                node e' typ ta true_branch from_call idenv linereader loc instr_ref;
            begin
              match from_call with
              | EradicateChecks.From_optional_isPresent ->
                  if TypeAnnotation.get_value Annotations.Present ta = false
                  then set_flag e' Annotations.Present true
                  else typestate2
              | EradicateChecks.From_condition
              | EradicateChecks.From_instanceof
              | EradicateChecks.From_containsKey ->
                  if TypeAnnotation.get_value Annotations.Nullable ta then
                    set_flag e' Annotations.Nullable false
                  else typestate2
            end

        | Sil.UnOp (Sil.LNot, (Sil.BinOp (Sil.Eq, e1, e2)), _) ->
            check_condition node' (Sil.BinOp (Sil.Ne, e1, e2))
        | Sil.UnOp (Sil.LNot, (Sil.BinOp (Sil.Ne, e1, e2)), _) ->
            check_condition node' (Sil.BinOp (Sil.Eq, e1, e2))
        | _ -> typestate in

      (** Handle assigment fron a temp pvar in a condition.
      This recognizes the handling of temp variables in ((x = ...) != null) *)
      let handle_assignment_in_condition pvar =
        match Cfg.Node.get_preds node with
        | [prev_node] ->
            let found = ref None in
            let do_instr i = match i with
              | Sil.Set (e, _, e', _)
              when Sil.exp_equal (Sil.Lvar pvar) (Idenv.expand_expr idenv e') ->
                  found := Some e
              | _ -> () in
            list_iter do_instr (Cfg.Node.get_instrs prev_node);
            !found
        | _ -> None in

      (** Normalize the condition by resolving temp variables. *)
      let rec normalize_cond _node _cond = match _cond with
        | Sil.UnOp (Sil.LNot, c, top) ->
            let node', c' = normalize_cond _node c in
            node', Sil.UnOp (Sil.LNot, c', top)
        | Sil.BinOp (bop, c1, c2) ->
            let node', c1' = normalize_cond _node c1 in
            let node'', c2' = normalize_cond node' c2 in
            node'', Sil.BinOp (bop, c1', c2')
        | Sil.Var id ->
            let c' = Idenv.expand_expr idenv _cond in
            if not (Sil.exp_equal c' _cond) then normalize_cond _node c'
            else _node, c'
        | Sil.Lvar pvar when Errdesc.pvar_is_frontend_tmp pvar ->
            (match handle_assignment_in_condition pvar with
              | None ->
                  (match Errdesc.find_program_variable_assignment _node pvar with
                    | Some (node', id) -> node', Sil.Var id
                    | None -> _node, _cond)
              | Some e2 -> _node, e2)
        | c -> _node, c in

      let node', ncond = normalize_cond node cond in
      check_condition node' ncond
  | Sil.Stackop _ ->
      typestate
  | Sil.Goto_node _ ->
      typestate

(** Typecheck the instructions in a cfg node. *)
let typecheck_node
    ext calls_this checks idenv get_proc_desc curr_pname curr_pdesc
    find_canonical_duplicate annotated_signature typestate node linereader =

  let instrs = Cfg.Node.get_instrs node in
  let instr_ref_gen = TypeErr.InstrRef.create_generator node in

  let typestates_exn = ref [] in
  let handle_exceptions typestate instr = match instr with
    | Sil.Call (_, Sil.Const (Sil.Cfun callee_pname), _, _, _) ->
    (* check if the call might throw an exception *)
        let exceptions =
          match get_proc_desc callee_pname with
          | Some callee_pdesc ->
              (Specs.proc_get_attributes callee_pname callee_pdesc).Sil.exceptions
          | None -> [] in
        if exceptions <> [] then
          typestates_exn := typestate :: !typestates_exn
    | Sil.Set (Sil.Lvar pv, _, _, _) when
    Sil.pvar_is_return pv &&
    Cfg.Node.get_kind node = Cfg.Node.throw_kind ->
    (* throw instruction *)
        typestates_exn := typestate :: !typestates_exn
    | _ -> () in

  let canonical_node = find_canonical_duplicate node in

  let do_instruction ext typestate instr =
    let instr_ref = (* keep unique instruction reference per-node *)
      TypeErr.InstrRef.gen instr_ref_gen in
    let instr' =
      typecheck_instr ext calls_this checks node idenv get_proc_desc curr_pname curr_pdesc
        find_canonical_duplicate annotated_signature instr_ref linereader typestate instr in
    handle_exceptions typestate instr;
    instr' in

  (* Reset 'always' field for forall errors to false. *)
  (* This is used to track if it is set to true for all visit to the node. *)
  TypeErr.node_reset_forall canonical_node;

  let typestate_succ = list_fold_left (do_instruction ext) typestate instrs in
  if Cfg.Node.get_kind node = Cfg.Node.exn_sink_kind
  then [], [] (* don't propagate exceptions to exit node *)
  else [typestate_succ], !typestates_exn
