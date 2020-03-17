(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
open IResult.Let_syntax
open PulseBasicInterface
open PulseDomainInterface

type arg_payload = AbstractValue.t * ValueHistory.t

type exec_fun =
     caller_summary:Summary.t
  -> Location.t
  -> ret:Ident.t * Typ.t
  -> PulseAbductiveDomain.t
  -> PulseAbductiveDomain.t list PulseOperations.access_result

type model = exec_fun

module Misc = struct
  let shallow_copy model_desc dest_pointer_hist src_pointer_hist : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model model_desc; location; in_call= []} in
    let* astate, obj = PulseOperations.eval_access location src_pointer_hist Dereference astate in
    let* astate, obj_copy = PulseOperations.shallow_copy location obj astate in
    let+ astate =
      PulseOperations.write_deref location ~ref:dest_pointer_hist
        ~obj:(fst obj_copy, event :: snd obj_copy)
        astate
    in
    [PulseOperations.havoc_id ret_id [event] astate]


  let early_exit : model = fun ~caller_summary:_ _ ~ret:_ _ -> Ok []

  let return_int : Int64.t -> model =
   fun i64 ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let ret_addr = AbstractValue.mk_fresh () in
    let astate =
      let i = IntLit.of_int64 i64 in
      AddressAttributes.add_one ret_addr (BoItv (Itv.ItvPure.of_int_lit i)) astate
      |> AddressAttributes.add_one ret_addr
           (CItv (CItv.equal_to i, Immediate {location; history= []}))
    in
    Ok [PulseOperations.write_id ret_id (ret_addr, []) astate]


  let return_unknown_size : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let ret_addr = AbstractValue.mk_fresh () in
    let astate =
      AddressAttributes.add_one ret_addr (BoItv Itv.ItvPure.nat) astate
      |> AddressAttributes.add_one ret_addr
           (CItv (CItv.zero_inf, Immediate {location; history= []}))
    in
    Ok [PulseOperations.write_id ret_id (ret_addr, []) astate]


  let skip : model = fun ~caller_summary:_ _ ~ret:_ astate -> Ok [astate]

  let nondet ~fn_name : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model fn_name; location; in_call= []} in
    Ok [PulseOperations.havoc_id ret_id [event] astate]


  let id_first_arg arg_access_hist : model =
   fun ~caller_summary:_ _ ~ret astate ->
    Ok [PulseOperations.write_id (fst ret) arg_access_hist astate]
end

module C = struct
  let free deleted_access : model =
   fun ~caller_summary:_ location ~ret:_ astate ->
    (* NOTE: we could introduce a case-split explicitly on =0 vs ≠0 but instead only act on what we
       currently know about the value. This is purely to avoid contributing to path explosion. *)
    let is_known_zero =
      ( AddressAttributes.get_citv (fst deleted_access) astate
      |> function Some (arith, _) -> CItv.is_equal_to_zero arith | None -> false )
      || Itv.ItvPure.is_zero (AddressAttributes.get_bo_itv (fst deleted_access) astate)
    in
    if is_known_zero then (* freeing 0 is a no-op *)
      Ok [astate]
    else
      let+ astate = PulseOperations.invalidate location Invalidation.CFree deleted_access astate in
      [astate]


  let malloc access : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let astate = PulseOperations.allocate location access astate in
    Ok [PulseOperations.write_id ret_id access astate]
end

module Cplusplus = struct
  let delete deleted_access : model =
   fun ~caller_summary:_ location ~ret:_ astate ->
    PulseOperations.invalidate location Invalidation.CppDelete deleted_access astate >>| List.return


  let placement_new actuals : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model "<placement new>()"; location; in_call= []} in
    match List.rev actuals with
    | ProcnameDispatcher.Call.FuncArg.{arg_payload= address, hist} :: _ ->
        Ok [PulseOperations.write_id ret_id (address, event :: hist) astate]
    | _ ->
        Ok [PulseOperations.havoc_id ret_id [event] astate]
end

module StdAtomicInteger = struct
  let internal_int =
    Fieldname.make
      (Typ.CStruct (QualifiedCppName.of_list ["std"; "atomic"]))
      "__infer_model_backing_int"


  let load_backing_int location this astate =
    let* astate, obj = PulseOperations.eval_access location this Dereference astate in
    let* astate, int_addr =
      PulseOperations.eval_access location obj (FieldAccess internal_int) astate
    in
    let+ astate, int_val = PulseOperations.eval_access location int_addr Dereference astate in
    (astate, int_addr, int_val)


  let constructor this_address init_value : model =
   fun ~caller_summary:_ location ~ret:_ astate ->
    let event = ValueHistory.Call {f= Model "std::atomic::atomic()"; location; in_call= []} in
    let this = (AbstractValue.mk_fresh (), [event]) in
    let* astate, int_field =
      PulseOperations.eval_access location this (FieldAccess internal_int) astate
    in
    let* astate = PulseOperations.write_deref location ~ref:int_field ~obj:init_value astate in
    let+ astate = PulseOperations.write_deref location ~ref:this_address ~obj:this astate in
    [astate]


  let arith_bop prepost location event ret_id bop this operand astate =
    let* astate, int_addr, (old_int, old_int_hist) = load_backing_int location this astate in
    let astate, (new_int, hist) =
      PulseOperations.eval_binop location bop (AbstractValueOperand old_int) operand old_int_hist
        astate
    in
    let+ astate =
      PulseOperations.write_deref location ~ref:int_addr ~obj:(new_int, event :: hist) astate
    in
    let ret_int = match prepost with `Pre -> new_int | `Post -> old_int in
    PulseOperations.write_id ret_id (ret_int, event :: hist) astate


  let fetch_add this (increment, _) _memory_ordering : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model "std::atomic::fetch_add()"; location; in_call= []} in
    let+ astate =
      arith_bop `Post location event ret_id (PlusA None) this (AbstractValueOperand increment)
        astate
    in
    [astate]


  let fetch_sub this (increment, _) _memory_ordering : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model "std::atomic::fetch_sub()"; location; in_call= []} in
    let+ astate =
      arith_bop `Post location event ret_id (MinusA None) this (AbstractValueOperand increment)
        astate
    in
    [astate]


  let operator_plus_plus_pre this : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model "std::atomic::operator++()"; location; in_call= []} in
    let+ astate =
      arith_bop `Pre location event ret_id (PlusA None) this (LiteralOperand IntLit.one) astate
    in
    [astate]


  let operator_plus_plus_post this _int : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event =
      ValueHistory.Call {f= Model "std::atomic<T>::operator++(T)"; location; in_call= []}
    in
    let+ astate =
      arith_bop `Post location event ret_id (PlusA None) this (LiteralOperand IntLit.one) astate
    in
    [astate]


  let operator_minus_minus_pre this : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model "std::atomic::operator--()"; location; in_call= []} in
    let+ astate =
      arith_bop `Pre location event ret_id (MinusA None) this (LiteralOperand IntLit.one) astate
    in
    [astate]


  let operator_minus_minus_post this _int : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event =
      ValueHistory.Call {f= Model "std::atomic<T>::operator--(T)"; location; in_call= []}
    in
    let+ astate =
      arith_bop `Post location event ret_id (MinusA None) this (LiteralOperand IntLit.one) astate
    in
    [astate]


  let load_instr model_desc this _memory_ordering_opt : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model model_desc; location; in_call= []} in
    let+ astate, _int_addr, (int, hist) = load_backing_int location this astate in
    [PulseOperations.write_id ret_id (int, event :: hist) astate]


  let load = load_instr "std::atomic<T>::load()"

  let operator_t = load_instr "std::atomic<T>::operator_T()"

  let store_backing_int location this_address new_value astate =
    let* astate, this = PulseOperations.eval_access location this_address Dereference astate in
    let* astate, int_field =
      PulseOperations.eval_access location this (FieldAccess internal_int) astate
    in
    PulseOperations.write_deref location ~ref:int_field ~obj:new_value astate


  let store this_address (new_value, new_hist) _memory_ordering : model =
   fun ~caller_summary:_ location ~ret:_ astate ->
    let event = ValueHistory.Call {f= Model "std::atomic::store()"; location; in_call= []} in
    let+ astate = store_backing_int location this_address (new_value, event :: new_hist) astate in
    [astate]


  let exchange this_address (new_value, new_hist) _memory_ordering : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model "std::atomic::exchange()"; location; in_call= []} in
    let* astate, _int_addr, (old_int, old_hist) = load_backing_int location this_address astate in
    let+ astate = store_backing_int location this_address (new_value, event :: new_hist) astate in
    [PulseOperations.write_id ret_id (old_int, event :: old_hist) astate]
end

module JavaObject = struct
  (* naively modeled as shallow copy. *)
  let clone src_pointer_hist : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model "Object.clone"; location; in_call= []} in
    let* astate, obj = PulseOperations.eval_access location src_pointer_hist Dereference astate in
    let+ astate, obj_copy = PulseOperations.shallow_copy location obj astate in
    [PulseOperations.write_id ret_id (fst obj_copy, event :: snd obj_copy) astate]
end

module StdBasicString = struct
  let internal_string =
    Fieldname.make
      (Typ.CStruct (QualifiedCppName.of_list ["std"; "basic_string"]))
      "__infer_model_backing_string"


  let internal_string_access = HilExp.Access.FieldAccess internal_string

  let to_internal_string location bstring astate =
    PulseOperations.eval_access location bstring internal_string_access astate


  let data this_hist : model =
   fun ~caller_summary:_ location ~ret:(ret_id, _) astate ->
    let event = ValueHistory.Call {f= Model "std::basic_string::data()"; location; in_call= []} in
    let* astate, string_addr_hist = to_internal_string location this_hist astate in
    let+ astate, (string, hist) =
      PulseOperations.eval_access location string_addr_hist Dereference astate
    in
    [PulseOperations.write_id ret_id (string, event :: hist) astate]


  let destructor this_hist : model =
   fun ~caller_summary:_ location ~ret:_ astate ->
    let model = CallEvent.Model "std::basic_string::~basic_string()" in
    let call_event = ValueHistory.Call {f= model; location; in_call= []} in
    let* astate, (string_addr, string_hist) = to_internal_string location this_hist astate in
    let string_addr_hist = (string_addr, call_event :: string_hist) in
    let* astate = PulseOperations.invalidate_deref location CppDelete string_addr_hist astate in
    let+ astate = PulseOperations.invalidate location CppDelete string_addr_hist astate in
    [astate]
end

module StdFunction = struct
  let operator_call lambda_ptr_hist actuals : model =
   fun ~caller_summary location ~ret astate ->
    let havoc_ret (ret_id, _) astate =
      let event = ValueHistory.Call {f= Model "std::function::operator()"; location; in_call= []} in
      [PulseOperations.havoc_id ret_id [event] astate]
    in
    let* astate, (lambda, _) =
      PulseOperations.eval_access location lambda_ptr_hist Dereference astate
    in
    let* astate = PulseOperations.Closures.check_captured_addresses location lambda astate in
    match AddressAttributes.get_closure_proc_name lambda astate with
    | None ->
        (* we don't know what proc name this lambda resolves to *) Ok (havoc_ret ret astate)
    | Some callee_proc_name ->
        let actuals =
          List.map actuals ~f:(fun ProcnameDispatcher.Call.FuncArg.{arg_payload; typ} ->
              (arg_payload, typ) )
        in
        PulseOperations.call ~caller_summary location callee_proc_name ~ret ~actuals
          ~formals_opt:None astate
end

module StdVector = struct
  let internal_array =
    Fieldname.make
      (Typ.CStruct (QualifiedCppName.of_list ["std"; "vector"]))
      "__infer_model_backing_array"


  let internal_array_access = HilExp.Access.FieldAccess internal_array

  let to_internal_array location vector astate =
    PulseOperations.eval_access location vector internal_array_access astate


  let element_of_internal_array location vector index astate =
    let* astate, vector_internal_array = to_internal_array location vector astate in
    PulseOperations.eval_access location vector_internal_array
      (ArrayAccess (Typ.void, index))
      astate


  let reallocate_internal_array trace vector vector_f location astate =
    let* astate, array_address = to_internal_array location vector astate in
    PulseOperations.invalidate_array_elements location (StdVector vector_f) array_address astate
    >>= PulseOperations.invalidate_deref location (StdVector vector_f) array_address
    >>= PulseOperations.havoc_field location vector internal_array trace


  let invalidate_references vector_f vector : model =
   fun ~caller_summary:_ location ~ret:_ astate ->
    let crumb =
      ValueHistory.Call
        { f= Model (Format.asprintf "%a()" Invalidation.pp_std_vector_function vector_f)
        ; location
        ; in_call= [] }
    in
    reallocate_internal_array [crumb] vector vector_f location astate >>| List.return


  let at ~desc vector index : model =
   fun ~caller_summary:_ location ~ret astate ->
    let event = ValueHistory.Call {f= Model desc; location; in_call= []} in
    let+ astate, (addr, hist) = element_of_internal_array location vector (fst index) astate in
    [PulseOperations.write_id (fst ret) (addr, event :: hist) astate]


  let reserve vector : model =
   fun ~caller_summary:_ location ~ret:_ astate ->
    let crumb = ValueHistory.Call {f= Model "std::vector::reserve()"; location; in_call= []} in
    reallocate_internal_array [crumb] vector Reserve location astate
    >>| AddressAttributes.std_vector_reserve (fst vector)
    >>| List.return


  let push_back vector : model =
   fun ~caller_summary:_ location ~ret:_ astate ->
    let crumb = ValueHistory.Call {f= Model "std::vector::push_back()"; location; in_call= []} in
    if AddressAttributes.is_std_vector_reserved (fst vector) astate then
      (* assume that any call to [push_back] is ok after one called [reserve] on the same vector
         (a perfect analysis would also make sure we don't exceed the reserved size) *)
      Ok [astate]
    else
      (* simulate a re-allocation of the underlying array every time an element is added *)
      reallocate_internal_array [crumb] vector PushBack location astate >>| List.return
end

module JavaCollection = struct
  let set coll index new_elem : model =
   fun ~caller_summary:_ location ~ret astate ->
    let event = ValueHistory.Call {f= Model "Collection.set"; location; in_call= []} in
    let* astate, ((old_addr, old_hist) as old_elem) =
      StdVector.element_of_internal_array location coll (fst index) astate
    in
    let+ astate =
      PulseOperations.write_deref location ~ref:new_elem
        ~obj:(old_addr, ValueHistory.Assignment location :: old_hist)
        astate
      >>= PulseOperations.invalidate_deref location (StdVector Assign) old_elem
    in
    [PulseOperations.write_id (fst ret) (old_addr, event :: old_hist) astate]
end

module StringSet = Caml.Set.Make (String)

module ProcNameDispatcher = struct
  let dispatch : (Tenv.t, model, arg_payload) ProcnameDispatcher.Call.dispatcher =
    let open ProcnameDispatcher.Call in
    let match_builtin builtin _ s = String.equal s (Procname.get_method builtin) in
    let pushback_modeled =
      StringSet.of_list ["add"; "addAll"; "append"; "remove"; "replace"; "poll"; "put"; "putAll"]
    in
    make_dispatcher
      [ +match_builtin BuiltinDecl.free <>$ capt_arg_payload $--> C.free
      ; +match_builtin BuiltinDecl.malloc <>$ capt_arg_payload $--> C.malloc
      ; +match_builtin BuiltinDecl.__delete <>$ capt_arg_payload $--> Cplusplus.delete
      ; +match_builtin BuiltinDecl.__placement_new &++> Cplusplus.placement_new
      ; +match_builtin BuiltinDecl.objc_cpp_throw <>--> Misc.early_exit
      ; +match_builtin BuiltinDecl.__cast <>$ capt_arg_payload $+...$--> Misc.id_first_arg
      ; +match_builtin BuiltinDecl.abort <>--> Misc.early_exit
      ; +match_builtin BuiltinDecl.exit <>--> Misc.early_exit
      ; +match_builtin BuiltinDecl.__get_array_length <>--> Misc.return_unknown_size
      ; (* consider that all fbstrings are small strings to avoid false positives due to manual
           ref-counting *)
        -"folly" &:: "fbstring_core" &:: "category" &--> Misc.return_int Int64.zero
      ; -"folly" &:: "DelayedDestruction" &:: "destroy" &--> Misc.skip
      ; -"folly" &:: "Optional" &:: "reset" &--> Misc.skip
      ; -"folly" &:: "SocketAddress" &:: "~SocketAddress" &--> Misc.skip
      ; -"std" &:: "basic_string" &:: "data" <>$ capt_arg_payload $--> StdBasicString.data
      ; -"std" &:: "basic_string" &:: "~basic_string" <>$ capt_arg_payload
        $--> StdBasicString.destructor
      ; -"std" &:: "function" &:: "operator()" $ capt_arg_payload $++$--> StdFunction.operator_call
      ; -"std" &:: "function" &:: "operator=" $ capt_arg_payload $+ capt_arg_payload
        $--> Misc.shallow_copy "std::function::operator="
      ; +PatternMatch.implements_lang "Object" &:: "clone" $ capt_arg_payload $--> JavaObject.clone
      ; -"std" &:: "atomic" &:: "atomic" <>$ capt_arg_payload $+ capt_arg_payload
        $--> StdAtomicInteger.constructor
      ; -"std" &:: "__atomic_base" &:: "fetch_add" <>$ capt_arg_payload $+ capt_arg_payload
        $+ capt_arg_payload $--> StdAtomicInteger.fetch_add
      ; -"std" &:: "__atomic_base" &:: "fetch_sub" <>$ capt_arg_payload $+ capt_arg_payload
        $+ capt_arg_payload $--> StdAtomicInteger.fetch_sub
      ; -"std" &:: "__atomic_base" &:: "exchange" <>$ capt_arg_payload $+ capt_arg_payload
        $+ capt_arg_payload $--> StdAtomicInteger.exchange
      ; -"std" &:: "__atomic_base" &:: "load" <>$ capt_arg_payload $+? capt_arg_payload
        $--> StdAtomicInteger.load
      ; -"std" &:: "__atomic_base" &:: "store" <>$ capt_arg_payload $+ capt_arg_payload
        $+ capt_arg_payload $--> StdAtomicInteger.store
      ; -"std" &:: "__atomic_base" &:: "operator++" <>$ capt_arg_payload
        $--> StdAtomicInteger.operator_plus_plus_pre
      ; -"std" &:: "__atomic_base" &:: "operator++" <>$ capt_arg_payload $+ capt_arg_payload
        $--> StdAtomicInteger.operator_plus_plus_post
      ; -"std" &:: "__atomic_base" &:: "operator--" <>$ capt_arg_payload
        $--> StdAtomicInteger.operator_minus_minus_pre
      ; -"std" &:: "__atomic_base" &:: "operator--" <>$ capt_arg_payload $+ capt_arg_payload
        $--> StdAtomicInteger.operator_minus_minus_post
      ; -"std" &:: "__atomic_base"
        &::+ (fun _ name -> String.is_prefix ~prefix:"operator_" name)
        <>$ capt_arg_payload $+? capt_arg_payload $--> StdAtomicInteger.operator_t
      ; -"std" &:: "integral_constant" < any_typ &+ capt_int
        >::+ (fun _ name -> String.is_prefix ~prefix:"operator_" name)
        <>--> Misc.return_int
      ; -"std" &:: "vector" &:: "assign" <>$ capt_arg_payload
        $+...$--> StdVector.invalidate_references Assign
      ; -"std" &:: "vector" &:: "at" <>$ capt_arg_payload $+ capt_arg_payload
        $--> StdVector.at ~desc:"std::vector::at()"
      ; -"std" &:: "vector" &:: "clear" <>$ capt_arg_payload
        $--> StdVector.invalidate_references Clear
      ; -"std" &:: "vector" &:: "emplace" $ capt_arg_payload
        $+...$--> StdVector.invalidate_references Emplace
      ; -"std" &:: "vector" &:: "emplace_back" $ capt_arg_payload
        $+...$--> StdVector.invalidate_references EmplaceBack
      ; -"std" &:: "vector" &:: "insert" <>$ capt_arg_payload
        $+...$--> StdVector.invalidate_references Insert
      ; -"std" &:: "vector" &:: "operator[]" <>$ capt_arg_payload $+ capt_arg_payload
        $--> StdVector.at ~desc:"std::vector::at()"
      ; -"std" &:: "vector" &:: "shrink_to_fit" <>$ capt_arg_payload
        $--> StdVector.invalidate_references ShrinkToFit
      ; -"std" &:: "vector" &:: "push_back" <>$ capt_arg_payload $+...$--> StdVector.push_back
      ; +PatternMatch.implements_collection
        &::+ (fun _ str -> StringSet.mem str pushback_modeled)
        <>$ capt_arg_payload $+...$--> StdVector.push_back
      ; +PatternMatch.implements_queue
        &::+ (fun _ str -> StringSet.mem str pushback_modeled)
        <>$ capt_arg_payload $+...$--> StdVector.push_back
      ; +PatternMatch.implements_lang "StringBuilder"
        &::+ (fun _ str -> StringSet.mem str pushback_modeled)
        <>$ capt_arg_payload $+...$--> StdVector.push_back
      ; +PatternMatch.implements_lang "String"
        &::+ (fun _ str -> StringSet.mem str pushback_modeled)
        <>$ capt_arg_payload $+...$--> StdVector.push_back
      ; +PatternMatch.implements_iterator &:: "remove" <>$ capt_arg_payload
        $+...$--> StdVector.push_back
      ; +PatternMatch.implements_map &:: "put" <>$ capt_arg_payload $+...$--> StdVector.push_back
      ; +PatternMatch.implements_map &:: "putAll" <>$ capt_arg_payload $+...$--> StdVector.push_back
      ; -"std" &:: "vector" &:: "reserve" <>$ capt_arg_payload $+...$--> StdVector.reserve
      ; +PatternMatch.implements_collection
        &:: "get" <>$ capt_arg_payload $+ capt_arg_payload
        $--> StdVector.at ~desc:"Collection.get()"
      ; +PatternMatch.implements_list &:: "set" <>$ capt_arg_payload $+ capt_arg_payload
        $+ capt_arg_payload $--> JavaCollection.set
      ; +PatternMatch.implements_iterator &:: "hasNext"
        &--> Misc.nondet ~fn_name:"Iterator.hasNext()"
      ; +PatternMatch.implements_enumeration
        &:: "hasMoreElements"
        &--> Misc.nondet ~fn_name:"Enumeration.hasMoreElements()"
      ; +PatternMatch.implements_lang "Object"
        &:: "equals"
        &--> Misc.nondet ~fn_name:"Object.equals"
      ; +PatternMatch.implements_lang "Iterable"
        &:: "iterator" <>$ capt_arg_payload $+...$--> Misc.id_first_arg
      ; ( +PatternMatch.implements_iterator &:: "next" <>$ capt_arg_payload
        $!--> fun x -> StdVector.at ~desc:"Iterator.next" x (AbstractValue.mk_fresh (), []) )
      ; ( +PatternMatch.implements_enumeration
        &:: "nextElement" <>$ capt_arg_payload
        $!--> fun x -> StdVector.at ~desc:"Enumeration.nextElement" x (AbstractValue.mk_fresh (), [])
        ) ]
end

let dispatch tenv proc_name args = ProcNameDispatcher.dispatch tenv proc_name args
