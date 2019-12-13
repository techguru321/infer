(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format

module LocalAccessPath = struct
  type t = {access_path: AccessPath.t; parent: Typ.Procname.t} [@@deriving compare]

  let make access_path parent = {access_path; parent}

  let make_from_access_expression ae parent =
    make (HilExp.AccessExpression.to_access_path ae) parent


  let make_from_pvar pvar typ parent = make (AccessPath.of_pvar pvar typ) parent

  let pp fmt t = AccessPath.pp fmt t.access_path
end

module LocalAccessPathSet = PrettyPrintable.MakePPSet (LocalAccessPath)

let suffixes = String.Set.of_list ["Attr"; "Dip"; "Px"; "Res"; "Sp"]

module MethodCallPrefix = struct
  type t =
    { (* TODO: We can remove the [receiver] field after we replace the old checker *)
      receiver: LocalAccessPath.t [@compare.ignore]
    ; prefix: string
    ; procname: Typ.Procname.t [@compare.ignore]
    ; location: Location.t [@compare.ignore] }
  [@@deriving compare]

  let make receiver procname location =
    let method_name = Typ.Procname.get_method procname in
    let prefix_opt =
      String.Set.find_map suffixes ~f:(fun suffix -> String.chop_suffix method_name ~suffix)
    in
    let prefix = Option.value prefix_opt ~default:method_name in
    {receiver; prefix; procname; location}


  let pp fmt {receiver; procname} =
    F.fprintf fmt "%a.%a" LocalAccessPath.pp receiver Typ.Procname.pp procname


  let procname_to_string {procname} = Typ.Procname.get_method procname
end

module CreatedLocation = struct
  type t =
    | ByCreateMethod of {location: Location.t; typ_name: Typ.name}
    | ByParameter of LocalAccessPath.t
  [@@deriving compare]

  let pp fmt = function
    | ByCreateMethod {location; typ_name} ->
        F.fprintf fmt "Created at %a with type %a" Location.pp location Typ.Name.pp typ_name
    | ByParameter path ->
        F.fprintf fmt "Given by parameter %a" LocalAccessPath.pp path
end

module CreatedLocations = AbstractDomain.FiniteSet (CreatedLocation)

(** Map from access paths of callee parameters and return variable to caller's corresponding access
    paths *)
module SubstPathMap = struct
  include PrettyPrintable.MakePPMonoMap (LocalAccessPath) (LocalAccessPath)

  let make ~formals ~actuals ~caller_return ~callee_return =
    let map = singleton callee_return caller_return in
    match
      List.fold2 formals actuals ~init:map ~f:(fun acc formal actual ->
          Option.fold actual ~init:acc ~f:(fun acc actual -> add formal actual acc) )
    with
    | Ok map ->
        map
    | Unequal_lengths ->
        map
end

module Created = struct
  include AbstractDomain.Map (LocalAccessPath) (CreatedLocations)

  let lookup k x = Option.value (find_opt k x) ~default:CreatedLocations.empty

  let append path locations x =
    let append_created_locations = function
      | None ->
          Some locations
      | Some pre_locations ->
          Some (CreatedLocations.join pre_locations locations)
    in
    update path append_created_locations x


  let append_one path location x = append path (CreatedLocations.singleton location) x

  let subst map ~caller_return ~callee_return ~callee ~caller =
    Option.fold (find_opt callee_return callee) ~init:caller ~f:(fun acc callee_returns ->
        let accum_subst callee_return acc =
          match callee_return with
          | CreatedLocation.ByCreateMethod _ ->
              append_one caller_return callee_return acc
          | CreatedLocation.ByParameter path ->
              let caller_path = SubstPathMap.find path map in
              Option.value_map (find_opt caller_path caller) ~default:acc ~f:(fun caller_created ->
                  append caller_return caller_created acc )
        in
        CreatedLocations.fold accum_subst callee_returns acc )
end

module MethodCalls = struct
  module IsChecked = AbstractDomain.BooleanOr
  (** if the method calls are checked and reported *)

  module S = AbstractDomain.InvertedSet (MethodCallPrefix)

  type t = {is_checked: IsChecked.t; method_calls: S.t}

  let pp fmt {is_checked; method_calls} =
    F.fprintf fmt "%a%s" S.pp method_calls (if is_checked then " checked" else "")


  let leq ~lhs ~rhs =
    IsChecked.leq ~lhs:lhs.is_checked ~rhs:rhs.is_checked
    && S.leq ~lhs:lhs.method_calls ~rhs:rhs.method_calls


  let join x y =
    { is_checked= IsChecked.join x.is_checked y.is_checked
    ; method_calls= S.join x.method_calls y.method_calls }


  let widen ~prev ~next ~num_iters =
    { is_checked= IsChecked.widen ~prev:prev.is_checked ~next:next.is_checked ~num_iters
    ; method_calls= S.widen ~prev:prev.method_calls ~next:next.method_calls ~num_iters }


  let empty = {is_checked= false; method_calls= S.empty}

  let singleton e = {is_checked= false; method_calls= S.singleton e}

  let add e ({method_calls} as x) = {x with method_calls= S.add e method_calls}

  let merge x y =
    {is_checked= x.is_checked || y.is_checked; method_calls= S.union x.method_calls y.method_calls}


  let to_string_set method_calls =
    let accum_as_string method_call acc =
      String.Set.add acc (MethodCallPrefix.procname_to_string method_call)
    in
    S.fold accum_as_string method_calls String.Set.empty


  let get_call_chain method_calls =
    (* TODO: sort chain by inserted order *)
    S.elements method_calls


  let check_required_props ~check_on_string_set parent_typename ({is_checked; method_calls} as x) =
    if not is_checked then (
      let prop_set = to_string_set method_calls in
      let call_chain = get_call_chain method_calls in
      check_on_string_set parent_typename call_chain prop_set ;
      {x with is_checked= true} )
    else x
end

module MethodCalled = struct
  module Key = struct
    type t =
      { created_location: CreatedLocation.t
      ; is_build_called: bool  (** if the build method has been called on the builder object *) }
    [@@deriving compare]

    let pp fmt {created_location; is_build_called} =
      F.fprintf fmt "%a%s" CreatedLocation.pp created_location
        (if is_build_called then " with build() called" else "")


    let no_build_called created_location = {created_location; is_build_called= false}

    let build_called created_location = {created_location; is_build_called= true}
  end

  include AbstractDomain.Map (Key) (MethodCalls)

  let add_one created_location v x =
    let f = function
      | None ->
          Some (MethodCalls.singleton v)
      | Some method_calls ->
          Some (MethodCalls.add v method_calls)
    in
    update (Key.no_build_called created_location) f x


  let add_all created_locations callee x =
    CreatedLocations.fold
      (fun created_location acc -> add_one created_location callee acc)
      created_locations x


  let build_method_called_one created_location x =
    let k_no_build_called = Key.no_build_called created_location in
    let k_build_called = Key.build_called created_location in
    let method_calls =
      match (find_opt k_no_build_called x, find_opt k_build_called x) with
      | None, None ->
          MethodCalls.empty
      | Some x, None | None, Some x ->
          x
      | Some method_calls_no_build_called, Some method_calls_build_called ->
          MethodCalls.join method_calls_no_build_called method_calls_build_called
    in
    remove k_no_build_called x |> add k_build_called method_calls


  let build_method_called created_locations x =
    CreatedLocations.fold build_method_called_one created_locations x


  let check_required_props ~check_on_string_set x =
    let f {Key.created_location; is_build_called} method_calls =
      if is_build_called then
        match created_location with
        | CreatedLocation.ByCreateMethod {typ_name} ->
            MethodCalls.check_required_props ~check_on_string_set typ_name method_calls
        | CreatedLocation.ByParameter _ ->
            method_calls
      else method_calls
    in
    mapi f x


  let subst ~is_reachable map ~find_caller_created ~caller ~callee =
    let merge_method_calls ~callee_method_calls ({Key.created_location} as caller_key) acc =
      let method_calls =
        Option.value_map
          (find_opt (Key.no_build_called created_location) caller)
          ~default:callee_method_calls
          ~f:(fun caller_method_calls -> MethodCalls.merge caller_method_calls callee_method_calls)
      in
      update caller_key
        (function
          | None ->
              Some method_calls
          | Some acc_method_calls ->
              Some (MethodCalls.merge acc_method_calls method_calls) )
        acc
    in
    let merge_method_calls_on_substed ~callee_method_calls ~is_build_called caller_created acc =
      CreatedLocations.fold
        (fun created_location acc ->
          merge_method_calls ~callee_method_calls {Key.created_location; is_build_called} acc )
        caller_created acc
    in
    let accum_substed ({Key.created_location; is_build_called} as callee_key) callee_method_calls
        acc =
      match created_location with
      | CreatedLocation.ByCreateMethod _ ->
          if is_reachable created_location then
            merge_method_calls ~callee_method_calls callee_key acc
          else acc
      | CreatedLocation.ByParameter path ->
          Option.value_map (SubstPathMap.find_opt path map) ~default:acc ~f:(fun caller_path ->
              Option.value_map (find_caller_created caller_path) ~default:acc
                ~f:(fun caller_created ->
                  merge_method_calls_on_substed ~callee_method_calls ~is_build_called caller_created
                    acc ) )
    in
    let caller' = fold accum_substed callee empty in
    merge (fun _ v v' -> match v' with Some _ -> v' | None -> v) caller caller'
end

module Mem = struct
  type t = {created: Created.t; method_called: MethodCalled.t}

  let pp fmt {created; method_called} =
    F.fprintf fmt "@[<v 0>@[Created:@;%a@]@,@[MethodCalled:@;%a@]@]" Created.pp created
      MethodCalled.pp method_called


  let leq ~lhs ~rhs =
    Created.leq ~lhs:lhs.created ~rhs:rhs.created
    && MethodCalled.leq ~lhs:lhs.method_called ~rhs:rhs.method_called


  let join x y =
    { created= Created.join x.created y.created
    ; method_called= MethodCalled.join x.method_called y.method_called }


  let widen ~prev ~next ~num_iters =
    { created= Created.widen ~prev:prev.created ~next:next.created ~num_iters
    ; method_called= MethodCalled.widen ~prev:prev.method_called ~next:next.method_called ~num_iters
    }


  let contains_build {method_called} =
    MethodCalled.exists (fun MethodCalled.Key.{is_build_called} _ -> is_build_called) method_called


  let empty = {created= Created.empty; method_called= MethodCalled.empty}

  let init tenv pname formals =
    List.fold formals ~init:empty ~f:(fun ({created; method_called} as acc) (pvar, ptr_typ) ->
        match ptr_typ with
        | Typ.{desc= Tptr (typ, _)} -> (
          match Typ.name typ with
          | Some typ_name
            when PatternMatch.is_subtype_of_str tenv typ_name "com.facebook.litho.Component$Builder"
            ->
              let formal_ae = LocalAccessPath.make_from_pvar pvar ptr_typ pname in
              let created_location = CreatedLocation.ByParameter formal_ae in
              { created= Created.add formal_ae (CreatedLocations.singleton created_location) created
              ; method_called=
                  MethodCalled.add
                    (MethodCalled.Key.no_build_called created_location)
                    MethodCalls.empty method_called }
          | _ ->
              acc )
        | _ ->
            acc )


  let assign ~lhs ~rhs ({created} as x) =
    {x with created= Created.add lhs (Created.lookup rhs created) created}


  let call_create lhs typ_name location ({created} as x) =
    let created_location = CreatedLocation.ByCreateMethod {location; typ_name} in
    { created= Created.add lhs (CreatedLocations.singleton created_location) created
    ; method_called=
        MethodCalled.add
          (MethodCalled.Key.no_build_called created_location)
          MethodCalls.empty x.method_called }


  let call_builder ~ret ~receiver callee {created; method_called} =
    let created_locations = Created.lookup receiver created in
    { created= Created.add ret created_locations created
    ; method_called= MethodCalled.add_all created_locations callee method_called }


  let call_build_method ~ret ~receiver {created; method_called} =
    let created_locations = Created.lookup receiver created in
    { created= Created.add ret created_locations created
    ; method_called= MethodCalled.build_method_called created_locations method_called }


  let check_required_props ~check_on_string_set ({method_called} as x) =
    {x with method_called= MethodCalled.check_required_props ~check_on_string_set method_called}


  let subst ~formals ~actuals ~ret_id_typ:(ret_var, ret_typ) ~caller_pname ~callee_pname ~caller
      ~callee =
    let callee_return =
      LocalAccessPath.make_from_pvar (Pvar.get_ret_pvar callee_pname) ret_typ callee_pname
    in
    let caller_return = LocalAccessPath.make (AccessPath.of_var ret_var ret_typ) caller_pname in
    let formals =
      List.map formals ~f:(fun (pvar, typ) -> LocalAccessPath.make_from_pvar pvar typ callee_pname)
    in
    let actuals =
      List.map actuals ~f:(function
        | HilExp.AccessExpression actual ->
            Some (LocalAccessPath.make_from_access_expression actual caller_pname)
        | _ ->
            None )
    in
    let map = SubstPathMap.make ~formals ~actuals ~caller_return ~callee_return in
    let created =
      Created.subst map ~caller_return ~callee_return ~caller:caller.created ~callee:callee.created
    in
    let is_reachable =
      let reachable_paths =
        LocalAccessPathSet.of_list formals |> LocalAccessPathSet.add callee_return
      in
      let reachable_locations =
        let accum_reachable_location path locations acc =
          if LocalAccessPathSet.mem path reachable_paths then CreatedLocations.union acc locations
          else acc
        in
        Created.fold accum_reachable_location callee.created CreatedLocations.empty
      in
      fun created_location -> CreatedLocations.mem created_location reachable_locations
    in
    let method_called =
      let find_caller_created path = Created.find_opt path caller.created in
      MethodCalled.subst ~is_reachable map ~find_caller_created ~caller:caller.method_called
        ~callee:callee.method_called
    in
    {created; method_called}
end

type t = {no_return_called: Mem.t; return_called: Mem.t}

let pp fmt {no_return_called; return_called} =
  F.fprintf fmt "@[<v 0>@[NoReturnCalled:@;%a@]@,@[ReturnCalled:@;%a@]@]" Mem.pp no_return_called
    Mem.pp return_called


let get_summary ~is_void_func x = if is_void_func then x.no_return_called else x.return_called

let leq ~lhs ~rhs =
  Mem.leq ~lhs:lhs.no_return_called ~rhs:rhs.no_return_called
  && Mem.leq ~lhs:lhs.return_called ~rhs:rhs.return_called


let join x y =
  { no_return_called= Mem.join x.no_return_called y.no_return_called
  ; return_called= Mem.join x.return_called y.return_called }


let widen ~prev ~next ~num_iters =
  { no_return_called= Mem.widen ~prev:prev.no_return_called ~next:next.no_return_called ~num_iters
  ; return_called= Mem.widen ~prev:prev.return_called ~next:next.return_called ~num_iters }


let init tenv pname formals =
  {no_return_called= Mem.init tenv pname formals; return_called= Mem.empty}


let map_no_return_called f x = {x with no_return_called= f x.no_return_called}

let assign ~lhs ~rhs = map_no_return_called (Mem.assign ~lhs ~rhs)

let call_create lhs typ_name location = map_no_return_called (Mem.call_create lhs typ_name location)

let call_builder ~ret ~receiver callee =
  map_no_return_called (Mem.call_builder ~ret ~receiver callee)


let call_build_method ~ret ~receiver = map_no_return_called (Mem.call_build_method ~ret ~receiver)

let call_return {no_return_called; return_called} =
  {no_return_called= Mem.empty; return_called= Mem.join no_return_called return_called}


let subst ~formals ~actuals ~ret_id_typ ~caller_pname ~callee_pname ~caller ~callee =
  { caller with
    no_return_called=
      Mem.subst ~formals ~actuals ~ret_id_typ ~caller_pname ~callee_pname
        ~caller:caller.no_return_called ~callee }


type summary = Mem.t

let pp_summary fmt = F.fprintf fmt "@[<v 2>@[Litho Summary:@;%a@]@]" Mem.pp

let check_required_props ~check_on_string_set = Mem.check_required_props ~check_on_string_set
