(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format
module L = Logging
module AbstractAddress = PulseDomain.AbstractAddress
module Attributes = PulseDomain.Attributes
module BaseStack = PulseDomain.Stack
module BaseMemory = PulseDomain.Memory

(** signature common to the "normal" [Domain], representing the post at the current program point,
    and the inverted [InvertedDomain], representing the inferred pre-condition*)
module type BaseDomain = sig
  (* private because the lattice is not the same for preconditions and postconditions so we don't
     want to confuse them *)
  type t = private PulseDomain.t

  val empty : t

  val make : BaseStack.t -> BaseMemory.t -> t

  val update : ?stack:BaseStack.t -> ?heap:BaseMemory.t -> t -> t

  include AbstractDomain.NoJoin with type t := t
end

(* just to expose the [heap] and [stack] record field names without having to type
   [PulseDomain.heap] *)
type base_domain = PulseDomain.t = {heap: BaseMemory.t; stack: BaseStack.t}

(** operations common to [Domain] and [InvertedDomain], see also the [BaseDomain] signature *)
module BaseDomainCommon = struct
  let make stack heap = {stack; heap}

  let update ?stack ?heap foot =
    let new_stack, new_heap =
      (Option.value ~default:foot.stack stack, Option.value ~default:foot.heap heap)
    in
    if phys_equal new_stack foot.stack && phys_equal new_heap foot.heap then foot
    else {stack= new_stack; heap= new_heap}
end

(** represents the post abstract state at each program point *)
module Domain : BaseDomain = struct
  include BaseDomainCommon
  include PulseDomain
end

(** represents the inferred pre-condition at each program point, biabduction style *)
module InvertedDomain : BaseDomain = struct
  include BaseDomainCommon

  type t = PulseDomain.t

  let empty = PulseDomain.empty

  let pp = PulseDomain.pp

  (** inverted lattice *)
  let ( <= ) ~lhs ~rhs = PulseDomain.( <= ) ~rhs:lhs ~lhs:rhs
end

(** biabduction-style pre/post state *)
type t =
  { post: Domain.t  (** state at the current program point*)
  ; pre: InvertedDomain.t  (** inferred pre at the current program point *) }

let pp f {post; pre} = F.fprintf f "@[<v>%a@;[%a]@]" Domain.pp post InvertedDomain.pp pre

let ( <= ) ~lhs ~rhs =
  match
    PulseDomain.isograph_map PulseDomain.empty_mapping
      ~lhs:(rhs.pre :> PulseDomain.t)
      ~rhs:(lhs.pre :> PulseDomain.t)
  with
  | NotIsomorphic ->
      false
  | IsomorphicUpTo foot_mapping ->
      PulseDomain.is_isograph foot_mapping
        ~lhs:(lhs.post :> PulseDomain.t)
        ~rhs:(rhs.post :> PulseDomain.t)


module Stack = struct
  let is_abducible astate var =
    (* HACK: formals are pre-registered in the initial state *)
    BaseStack.mem var (astate.pre :> base_domain).stack || Var.is_global var


  (** [astate] with [astate.post.stack = f astate.post.stack] *)
  let map_post_stack ~f astate =
    let new_post = Domain.update astate.post ~stack:(f (astate.post :> base_domain).stack) in
    if phys_equal new_post astate.post then astate else {astate with post= new_post}


  let eval var astate =
    match BaseStack.find_opt var (astate.post :> base_domain).stack with
    | Some addr_hist ->
        (astate, addr_hist)
    | None ->
        let addr_hist = (AbstractAddress.mk_fresh (), []) in
        let post_stack = BaseStack.add var addr_hist (astate.post :> base_domain).stack in
        let pre =
          (* do not overwrite values of variables already in the pre *)
          if (not (BaseStack.mem var (astate.pre :> base_domain).stack)) && is_abducible astate var
          then
            let foot_stack = BaseStack.add var addr_hist (astate.pre :> base_domain).stack in
            let foot_heap =
              BaseMemory.register_address (fst addr_hist) (astate.pre :> base_domain).heap
            in
            InvertedDomain.make foot_stack foot_heap
          else astate.pre
        in
        ({post= Domain.update astate.post ~stack:post_stack; pre}, addr_hist)


  let add var addr_loc_opt astate =
    map_post_stack astate ~f:(fun stack -> BaseStack.add var addr_loc_opt stack)


  let remove_vars vars astate =
    let vars_to_remove =
      let is_in_pre var astate = BaseStack.mem var (astate.pre :> base_domain).stack in
      List.filter vars ~f:(fun var -> not (is_in_pre var astate))
    in
    map_post_stack astate ~f:(fun stack ->
        BaseStack.filter (fun var _ -> not (List.mem ~equal:Var.equal vars_to_remove var)) stack )


  let fold f astate accum = BaseStack.fold f (astate.post :> base_domain).stack accum

  let find_opt var astate = BaseStack.find_opt var (astate.post :> base_domain).stack

  let mem var astate = BaseStack.mem var (astate.post :> base_domain).stack

  let exists f astate = BaseStack.exists f (astate.post :> base_domain).stack
end

module Memory = struct
  open Result.Monad_infix
  module Access = BaseMemory.Access

  (** [astate] with [astate.post.heap = f astate.post.heap] *)
  let map_post_heap ~f astate =
    let new_post = Domain.update astate.post ~heap:(f (astate.post :> base_domain).heap) in
    if phys_equal new_post astate.post then astate else {astate with post= new_post}


  (** if [address] is in [pre] and it should be valid then that fact goes in the precondition *)
  let record_must_be_valid action address (pre : InvertedDomain.t) =
    if BaseMemory.mem_edges address (pre :> base_domain).heap then
      InvertedDomain.update pre
        ~heap:
          (BaseMemory.add_attributes address
             (Attributes.singleton (MustBeValid action))
             (pre :> base_domain).heap)
    else pre


  let check_valid action addr ({post; pre} as astate) =
    BaseMemory.check_valid addr (post :> base_domain).heap
    >>| fun () ->
    let new_pre = record_must_be_valid action addr pre in
    if phys_equal new_pre pre then astate else {astate with pre= new_pre}


  let add_edge addr access new_addr_trace astate =
    map_post_heap astate ~f:(fun heap ->
        BaseMemory.add_edge addr access new_addr_trace heap
        |> BaseMemory.add_attributes addr (Attributes.singleton WrittenTo) )


  let find_edge_opt address access astate =
    BaseMemory.find_edge_opt address access (astate.post :> base_domain).heap


  let eval_edge addr access astate =
    match find_edge_opt addr access astate with
    | Some addr_trace' ->
        (astate, addr_trace')
    | None ->
        let addr_trace' = (AbstractAddress.mk_fresh (), []) in
        let post_heap =
          BaseMemory.add_edge addr access addr_trace' (astate.post :> base_domain).heap
        in
        let foot_heap =
          if BaseMemory.mem_edges addr (astate.pre :> base_domain).heap then
            BaseMemory.add_edge addr access addr_trace' (astate.pre :> base_domain).heap
            |> BaseMemory.register_address (fst addr_trace')
          else (astate.pre :> base_domain).heap
        in
        ( { post= Domain.update astate.post ~heap:post_heap
          ; pre= InvertedDomain.update astate.pre ~heap:foot_heap }
        , addr_trace' )


  let invalidate address action astate =
    map_post_heap astate ~f:(fun heap -> BaseMemory.invalidate address action heap)


  let add_attributes address attributes astate =
    map_post_heap astate ~f:(fun heap -> BaseMemory.add_attributes address attributes heap)


  let get_closure_proc_name addr astate =
    BaseMemory.get_closure_proc_name addr (astate.post :> base_domain).heap


  let std_vector_reserve addr astate =
    map_post_heap astate ~f:(fun heap -> BaseMemory.std_vector_reserve addr heap)


  let is_std_vector_reserved addr astate =
    BaseMemory.is_std_vector_reserved addr (astate.post :> base_domain).heap


  let find_opt address astate = BaseMemory.find_opt address (astate.post :> base_domain).heap

  let set_cell addr cell astate =
    map_post_heap astate ~f:(fun heap ->
        BaseMemory.set_cell addr cell heap
        |> BaseMemory.add_attributes addr (Attributes.singleton WrittenTo) )


  module Edges = BaseMemory.Edges
end

let mk_initial proc_desc =
  (* HACK: save the formals in the stacks of the pre and the post to remember which local variables
     correspond to formals *)
  let formals =
    let proc_name = Procdesc.get_proc_name proc_desc in
    let location = Procdesc.get_loc proc_desc in
    Procdesc.get_formals proc_desc
    |> List.map ~f:(fun (mangled, _) ->
           let var = Var.of_pvar (Pvar.mk mangled proc_name) in
           ( var
           , (AbstractAddress.mk_fresh (), [PulseDomain.ValueHistory.VariableDeclaration location])
           ) )
  in
  let initial_stack =
    List.fold formals ~init:(InvertedDomain.empty :> PulseDomain.t).stack
      ~f:(fun stack (formal, addr_loc) -> BaseStack.add formal addr_loc stack)
  in
  let pre =
    let initial_heap =
      List.fold formals ~init:(InvertedDomain.empty :> base_domain).heap
        ~f:(fun heap (_, (addr, _)) -> BaseMemory.register_address addr heap)
    in
    InvertedDomain.make initial_stack initial_heap
  in
  let post = Domain.update ~stack:initial_stack Domain.empty in
  {pre; post}


let discard_unreachable ({pre; post} as astate) =
  let pre_addresses = PulseDomain.reachable_addresses (pre :> PulseDomain.t) in
  let pre_old_heap = (pre :> PulseDomain.t).heap in
  let pre_new_heap =
    PulseDomain.Memory.filter
      (fun address -> PulseDomain.AbstractAddressSet.mem address pre_addresses)
      pre_old_heap
  in
  let post_addresses = PulseDomain.reachable_addresses (post :> PulseDomain.t) in
  let all_addresses = PulseDomain.AbstractAddressSet.union pre_addresses post_addresses in
  let post_old_heap = (post :> PulseDomain.t).heap in
  let post_new_heap =
    PulseDomain.Memory.filter
      (fun address -> PulseDomain.AbstractAddressSet.mem address all_addresses)
      post_old_heap
  in
  if phys_equal pre_new_heap pre_old_heap && phys_equal post_new_heap post_old_heap then astate
  else
    { pre= InvertedDomain.make (pre :> PulseDomain.t).stack pre_new_heap
    ; post= Domain.make (post :> PulseDomain.t).stack post_new_heap }


let is_local var astate = not (Var.is_return var || Stack.is_abducible astate var)

module PrePost = struct
  type domain_t = t

  type t = domain_t

  let filter_for_summary astate =
    let post_stack =
      BaseStack.filter
        (fun var _ -> not (is_local var astate))
        (astate.post :> PulseDomain.t).stack
    in
    (* deregister empty edges in pre *)
    let pre_heap =
      BaseMemory.filter_heap
        (fun _addr edges -> not (BaseMemory.Edges.is_empty edges))
        (astate.pre :> base_domain).heap
    in
    { pre= InvertedDomain.update astate.pre ~heap:pre_heap
    ; post= Domain.update ~stack:post_stack astate.post }


  let add_out_of_scope_attribute addr pvar location history heap typ =
    let action =
      PulseDomain.InterprocAction.Immediate
        {imm= PulseDomain.Invalidation.GoneOutOfScope (pvar, typ); location}
    in
    let attr = PulseDomain.Attributes.singleton (Invalid {action; history}) in
    PulseDomain.Memory.add_attributes addr attr heap


  (** invalidate local variables going out of scope *)
  let invalidate_locals pdesc astate : t =
    let heap : BaseMemory.t = (astate.post :> PulseDomain.t).heap in
    let heap' =
      PulseDomain.Memory.fold_attrs
        (fun addr attrs heap ->
          PulseDomain.Attributes.get_address_of_stack_variable attrs
          |> Option.value_map ~default:heap ~f:(fun (var, history, location) ->
                 let get_local_typ_opt pvar =
                   Procdesc.get_locals pdesc
                   |> List.find_map ~f:(fun ProcAttributes.{name; typ} ->
                          if Mangled.equal name (Pvar.get_name pvar) then Some typ else None )
                 in
                 match var with
                 | Var.ProgramVar pvar ->
                     get_local_typ_opt pvar
                     |> Option.value_map ~default:heap
                          ~f:(add_out_of_scope_attribute addr pvar location history heap)
                 | _ ->
                     heap ) )
        heap heap
    in
    if phys_equal heap heap' then astate
    else {pre= astate.pre; post= Domain.update astate.post ~heap:heap'}


  let of_post pdesc astate =
    filter_for_summary astate |> discard_unreachable |> invalidate_locals pdesc


  (* {2 machinery to apply a pre/post pair corresponding to a function's summary in a function call
     to the current state} *)

  module AddressSet = PulseDomain.AbstractAddressSet
  module AddressMap = PulseDomain.AbstractAddressMap

  (** raised when the pre/post pair and the current state disagree on the aliasing, i.e. some
     addresses that are distinct in the pre/post are aliased in the current state. Typically raised
     when calling [foo(z,z)] where the spec for [foo(x,y)] says that [x] and [y] are disjoint. *)
  exception Aliasing

  (** stuff we carry around when computing the result of applying one pre/post pair *)
  type call_state =
    { astate: t  (** caller's abstract state computed so far *)
    ; subst: AbstractAddress.t AddressMap.t
          (** translation from callee addresses to caller addresses *)
    ; rev_subst: AbstractAddress.t AddressMap.t
          (** the inverse translation from [subst] from caller addresses to callee addresses *)
    ; visited: AddressSet.t
          (** set of callee addresses that have been visited already

               NOTE: this is not always equal to the domain of [rev_subst]: when applying the post
               we visit each subgraph from each formal independently so we reset [visited] between
              the visit of each formal *)
    }

  let pp_call_state fmt {astate; subst; rev_subst; visited} =
    F.fprintf fmt
      "@[<v>{ astate=@[<hv2>%a@];@, subst=@[<hv2>%a@];@, rev_subst=@[<hv2>%a@];@, \
       visited=@[<hv2>%a@]@, }@]"
      pp astate
      (AddressMap.pp ~pp_value:AbstractAddress.pp)
      subst
      (AddressMap.pp ~pp_value:AbstractAddress.pp)
      rev_subst AddressSet.pp visited


  let fold_globals_of_stack stack call_state ~f =
    Container.fold_result ~fold:(IContainer.fold_of_pervasives_map_fold ~fold:BaseStack.fold)
      stack ~init:call_state ~f:(fun call_state (var, stack_value) ->
        match var with
        | Var.ProgramVar pvar when Pvar.is_global pvar ->
            let call_state, (addr_caller, _) =
              let astate, var_value = Stack.eval var call_state.astate in
              if phys_equal astate call_state.astate then (call_state, var_value)
              else ({call_state with astate}, var_value)
            in
            f pvar ~stack_value ~addr_caller call_state
        | _ ->
            Ok call_state )


  let visit call_state ~addr_callee ~addr_caller =
    ( match AddressMap.find_opt addr_caller call_state.rev_subst with
    | Some addr_callee' when not (AbstractAddress.equal addr_callee addr_callee') ->
        L.d_printfln "Huho, address %a in post already bound to %a, not %a@\nState=%a"
          AbstractAddress.pp addr_caller AbstractAddress.pp addr_callee' AbstractAddress.pp
          addr_callee pp_call_state call_state ;
        raise Aliasing
    | _ ->
        () ) ;
    if AddressSet.mem addr_callee call_state.visited then (`AlreadyVisited, call_state)
    else
      ( `NotAlreadyVisited
      , { call_state with
          visited= AddressSet.add addr_callee call_state.visited
        ; subst= AddressMap.add addr_callee addr_caller call_state.subst
        ; rev_subst= AddressMap.add addr_caller addr_callee call_state.rev_subst } )


  let pp f {pre; post} =
    F.fprintf f "PRE:@\n  @[%a@]@\n" PulseDomain.pp (pre :> PulseDomain.t) ;
    F.fprintf f "POST:@\n  @[%a@]@\n" PulseDomain.pp (post :> PulseDomain.t)


  (* {3 reading the pre from the current state} *)

  (** Materialize the (abstract memory) subgraph of [pre] reachable from [addr_pre] in
     [call_state.astate] starting from address [addr_caller]. Report an error if some invalid
     addresses are traversed in the process. *)
  let rec materialize_pre_from_address callee_proc_name call_location ~pre ~addr_pre ~addr_caller
      history call_state =
    let mk_action action =
      PulseDomain.InterprocAction.ViaCall
        {action; f= Call callee_proc_name; location= call_location}
    in
    match visit call_state ~addr_callee:addr_pre ~addr_caller with
    | `AlreadyVisited, call_state ->
        Ok call_state
    | `NotAlreadyVisited, call_state -> (
        (let open Option.Monad_infix in
        PulseDomain.Memory.find_opt addr_pre pre.PulseDomain.heap
        >>= fun (edges_pre, attrs_pre) ->
        PulseDomain.Attributes.get_must_be_valid attrs_pre
        >>| fun callee_action ->
        let action = mk_action callee_action in
        match Memory.check_valid action addr_caller call_state.astate with
        | Error invalidated_by ->
            Error
              (PulseDiagnostic.AccessToInvalidAddress
                 {invalidated_by; accessed_by= {action; history}})
        | Ok astate ->
            let call_state = {call_state with astate} in
            Container.fold_result
              ~fold:(IContainer.fold_of_pervasives_map_fold ~fold:Memory.Edges.fold)
              ~init:call_state edges_pre ~f:(fun call_state (access, (addr_pre_dest, _)) ->
                let astate, (addr_caller_dest, _) =
                  Memory.eval_edge addr_caller access call_state.astate
                in
                let call_state = {call_state with astate} in
                materialize_pre_from_address callee_proc_name call_location ~pre
                  ~addr_pre:addr_pre_dest ~addr_caller:addr_caller_dest history call_state ))
        |> function Some result -> result | None -> Ok call_state )


  (** materialize subgraph of [pre] rooted at the address represented by a [formal] parameter that
      has been instantiated with the corresponding [actual] into the current state
      [call_state.astate] *)
  let materialize_pre_from_actual callee_proc_name call_location ~pre ~formal ~actual call_state =
    let addr_caller, trace = actual in
    L.d_printfln "Materializing PRE from [%a <- %a]" Var.pp formal AbstractAddress.pp addr_caller ;
    (let open Option.Monad_infix in
    PulseDomain.Stack.find_opt formal pre.PulseDomain.stack
    >>= fun (addr_formal_pre, _) ->
    PulseDomain.Memory.find_edge_opt addr_formal_pre Dereference pre.PulseDomain.heap
    >>| fun (formal_pre, _) ->
    materialize_pre_from_address callee_proc_name call_location ~pre ~addr_pre:formal_pre
      ~addr_caller trace call_state)
    |> function Some result -> result | None -> Ok call_state


  let is_cell_read_only ~cell_pre_opt ~cell_post:(edges_post, attrs_post) =
    match cell_pre_opt with
    | None ->
        false
    | Some (edges_pre, _) when not (Attributes.is_modified attrs_post) ->
        let are_edges_equal =
          PulseDomain.Memory.Edges.equal
            (fun (addr_dest_pre, _) (addr_dest_post, _) ->
              (* NOTE: ignores traces

                  TODO: can the traces be leveraged here? maybe easy to detect writes by looking at
                  the post trace *)
              AbstractAddress.equal addr_dest_pre addr_dest_post )
            edges_pre edges_post
        in
        if CommandLineOption.strict_mode then assert are_edges_equal ;
        are_edges_equal
    | _ ->
        false


  let materialize_pre_for_parameters callee_proc_name call_location pre_post ~formals ~actuals
      call_state =
    (* For each [(formal, actual)] pair, resolve them to addresses in their respective states then
       call [materialize_pre_from] on them.  Give up if calling the function introduces aliasing.
       *)
    match
      IList.fold2_result formals actuals ~init:call_state ~f:(fun call_state formal (actual, _) ->
          materialize_pre_from_actual callee_proc_name call_location
            ~pre:(pre_post.pre :> PulseDomain.t)
            ~formal ~actual call_state )
    with
    | Unequal_lengths ->
        L.d_printfln "ERROR: formals have length %d but actuals have length %d"
          (List.length formals) (List.length actuals) ;
        None
    | Ok result ->
        Some result


  let materialize_pre_for_globals callee_proc_name call_location pre_post call_state =
    fold_globals_of_stack (pre_post.pre :> PulseDomain.t).stack call_state
      ~f:(fun _var ~stack_value:(addr_pre, history) ~addr_caller call_state ->
        materialize_pre_from_address callee_proc_name call_location
          ~pre:(pre_post.pre :> PulseDomain.t)
          ~addr_pre ~addr_caller history call_state )


  let materialize_pre callee_proc_name call_location pre_post ~formals ~actuals call_state =
    PerfEvent.(log (fun logger -> log_begin_event logger ~name:"pulse call pre" ())) ;
    let r =
      materialize_pre_for_parameters callee_proc_name call_location pre_post ~formals ~actuals
        call_state
      |> Option.map
           ~f:
             (Result.bind ~f:(fun call_state ->
                  materialize_pre_for_globals callee_proc_name call_location pre_post call_state ))
    in
    PerfEvent.(log (fun logger -> log_end_event logger ())) ;
    r


  (* {3 applying the post to the current state} *)

  let subst_find_or_new subst addr_callee =
    match AddressMap.find_opt addr_callee subst with
    | None ->
        let addr_fresh = AbstractAddress.mk_fresh () in
        (addr_fresh, AddressMap.add addr_callee addr_fresh subst)
    | Some addr_caller ->
        (addr_caller, subst)


  let call_state_subst_find_or_new call_state addr_callee =
    let addr_caller, new_subst = subst_find_or_new call_state.subst addr_callee in
    if phys_equal new_subst call_state.subst then (call_state, addr_caller)
    else ({call_state with subst= new_subst}, addr_caller)


  let delete_edges_in_callee_pre_from_caller ~addr_callee:_ ~cell_pre_opt ~addr_caller call_state =
    match
      PulseDomain.Memory.find_edges_opt addr_caller (call_state.astate.post :> base_domain).heap
    with
    | None ->
        PulseDomain.Memory.Edges.empty
    | Some old_post_edges -> (
      match cell_pre_opt with
      | None ->
          old_post_edges
      | Some (edges_pre, _) ->
          PulseDomain.Memory.Edges.merge
            (fun _access old_opt pre_opt ->
              (* TODO: should apply [call_state.subst] to [_access]! Actually, should rewrite the
                whole [cell_pre] beforehand so that [Edges.merge] makes sense. *)
              if Option.is_some pre_opt then
                (* delete edge if some edge for the same access exists in the pre *)
                None
              else (* keep old edge if it exists *) old_opt )
            old_post_edges edges_pre )


  let add_call_to_attr proc_name location attr =
    match (attr : PulseDomain.Attribute.t) with
    | Invalid trace ->
        PulseDomain.Attribute.Invalid
          { action=
              PulseDomain.InterprocAction.ViaCall
                {action= trace.action; f= Call proc_name; location}
          ; history= trace.history }
    | MustBeValid _
    | WrittenTo
    | AddressOfCppTemporary (_, _)
    | AddressOfStackVariable (_, _, _)
    | Closure _
    | StdVectorReserve ->
        attr


  let record_post_cell callee_proc_name call_loc ~addr_callee ~cell_pre_opt
      ~cell_post:(edges_post, attrs_post) ~addr_caller call_state =
    let post_edges_minus_pre =
      delete_edges_in_callee_pre_from_caller ~addr_callee ~cell_pre_opt ~addr_caller call_state
    in
    let heap = (call_state.astate.post :> base_domain).heap in
    let heap =
      let attrs_post_caller =
        Attributes.map ~f:(fun attr -> add_call_to_attr callee_proc_name call_loc attr) attrs_post
      in
      PulseDomain.Memory.set_attrs addr_caller attrs_post_caller heap
    in
    let subst, translated_post_edges =
      PulseDomain.Memory.Edges.fold_map ~init:call_state.subst edges_post
        ~f:(fun subst (addr_callee, trace_post) ->
          let addr_curr, subst = subst_find_or_new subst addr_callee in
          ( subst
          , ( addr_curr
            , PulseDomain.ValueHistory.Call {f= Call callee_proc_name; location= call_loc}
              :: trace_post ) ) )
    in
    let heap =
      let edges_post_caller =
        PulseDomain.Memory.Edges.union
          (fun _ _ post_cell -> Some post_cell)
          post_edges_minus_pre translated_post_edges
      in
      PulseDomain.Memory.set_edges addr_caller edges_post_caller heap
      |> PulseDomain.Memory.add_attributes addr_caller (PulseDomain.Attributes.singleton WrittenTo)
    in
    let caller_post = Domain.make (call_state.astate.post :> base_domain).stack heap in
    {call_state with subst; astate= {call_state.astate with post= caller_post}}


  let rec record_post_for_address callee_proc_name call_loc ({pre; post} as pre_post) ~addr_callee
      ~addr_caller call_state =
    L.d_printfln "%a<->%a" AbstractAddress.pp addr_callee AbstractAddress.pp addr_caller ;
    match visit call_state ~addr_callee ~addr_caller with
    | `AlreadyVisited, call_state ->
        call_state
    | `NotAlreadyVisited, call_state -> (
      match PulseDomain.Memory.find_opt addr_callee (post :> PulseDomain.t).PulseDomain.heap with
      | None ->
          call_state
      | Some ((edges_post, _attrs_post) as cell_post) ->
          let cell_pre_opt =
            PulseDomain.Memory.find_opt addr_callee (pre :> PulseDomain.t).PulseDomain.heap
          in
          let call_state_after_post =
            if is_cell_read_only ~cell_pre_opt ~cell_post then call_state
            else
              record_post_cell callee_proc_name call_loc ~addr_callee ~cell_pre_opt ~addr_caller
                ~cell_post call_state
          in
          IContainer.fold_of_pervasives_map_fold ~fold:Memory.Edges.fold
            ~init:call_state_after_post edges_post
            ~f:(fun call_state (_access, (addr_callee_dest, _)) ->
              let call_state, addr_curr_dest =
                call_state_subst_find_or_new call_state addr_callee_dest
              in
              record_post_for_address callee_proc_name call_loc pre_post
                ~addr_callee:addr_callee_dest ~addr_caller:addr_curr_dest call_state ) )


  let record_post_for_actual callee_proc_name call_loc pre_post ~formal ~actual call_state =
    let addr_caller, _ = actual in
    L.d_printfln_escaped "Recording POST from [%a] <-> %a" Var.pp formal AbstractAddress.pp
      addr_caller ;
    match
      let open Option.Monad_infix in
      PulseDomain.Stack.find_opt formal (pre_post.pre :> PulseDomain.t).PulseDomain.stack
      >>= fun (addr_formal_pre, _) ->
      PulseDomain.Memory.find_edge_opt addr_formal_pre Dereference
        (pre_post.pre :> PulseDomain.t).PulseDomain.heap
      >>| fun (formal_pre, _) ->
      record_post_for_address callee_proc_name call_loc pre_post ~addr_callee:formal_pre
        ~addr_caller call_state
    with
    | Some call_state ->
        call_state
    | None ->
        call_state


  let record_post_for_return callee_proc_name call_loc pre_post call_state =
    let return_var = Var.of_pvar (Pvar.get_ret_pvar callee_proc_name) in
    match PulseDomain.Stack.find_opt return_var (pre_post.post :> PulseDomain.t).stack with
    | None ->
        (call_state, None)
    | Some (addr_return, _) -> (
      match
        PulseDomain.Memory.find_edge_opt addr_return Dereference
          (pre_post.post :> PulseDomain.t).PulseDomain.heap
      with
      | None ->
          (call_state, None)
      | Some (return_callee, _) ->
          let return_caller =
            match AddressMap.find_opt return_callee call_state.subst with
            | Some return_caller ->
                return_caller
            | None ->
                AbstractAddress.mk_fresh ()
          in
          let call_state =
            record_post_for_address callee_proc_name call_loc pre_post ~addr_callee:return_callee
              ~addr_caller:return_caller call_state
          in
          (call_state, Some return_caller) )


  let apply_post_for_parameters callee_proc_name call_location pre_post ~formals ~actuals
      call_state =
    (* for each [(formal_i, actual_i)] pair, do [post_i = post union subst(graph reachable from
       formal_i in post)], deleting previous info when comparing pre and post shows a difference
       (TODO: record in the pre when a location is written to instead of just comparing values
       between pre and post since it's unreliable, eg replace value read in pre with same value in
       post but nuke other fields in the meantime? is that possible?).  *)
    match
      List.fold2 formals actuals ~init:call_state ~f:(fun call_state formal (actual, _) ->
          record_post_for_actual callee_proc_name call_location pre_post ~formal ~actual call_state
      )
    with
    | Unequal_lengths ->
        (* should have been checked before by [materialize_pre] *)
        assert false
    | Ok call_state ->
        call_state


  let apply_post_for_globals callee_proc_name call_location pre_post call_state =
    match
      fold_globals_of_stack (pre_post.pre :> PulseDomain.t).stack call_state
        ~f:(fun _var ~stack_value:(addr_callee, _) ~addr_caller call_state ->
          Ok
            (record_post_for_address callee_proc_name call_location pre_post ~addr_callee
               ~addr_caller call_state) )
    with
    | Error _ ->
        (* always return [Ok _] above *) assert false
    | Ok call_state ->
        call_state


  let record_post_remaining_attributes callee_proc_name call_loc pre_post call_state =
    let heap0 = (call_state.astate.post :> base_domain).heap in
    let heap =
      PulseDomain.Memory.fold_attrs
        (fun addr_callee attrs heap ->
          if AddressSet.mem addr_callee call_state.visited then
            (* already recorded the attributes when we were walking the edges map *) heap
          else
            match AddressMap.find_opt addr_callee call_state.subst with
            | None ->
                (* callee address has no meaning for the caller *) heap
            | Some addr_caller ->
                let attrs' =
                  Attributes.map
                    ~f:(fun attr -> add_call_to_attr callee_proc_name call_loc attr)
                    attrs
                in
                PulseDomain.Memory.set_attrs addr_caller attrs' heap )
        (pre_post.post :> PulseDomain.t).heap heap0
    in
    if phys_equal heap heap0 then call_state
    else
      let post = Domain.make (call_state.astate.post :> PulseDomain.t).stack heap in
      {call_state with astate= {call_state.astate with post}}


  let apply_post callee_proc_name call_location pre_post ~formals ~actuals call_state =
    PerfEvent.(log (fun logger -> log_begin_event logger ~name:"pulse call post" ())) ;
    let r =
      apply_post_for_parameters callee_proc_name call_location pre_post ~formals ~actuals
        call_state
      |> apply_post_for_globals callee_proc_name call_location pre_post
      |> record_post_for_return callee_proc_name call_location pre_post
      |> fun (call_state, return_caller) ->
      ( record_post_remaining_attributes callee_proc_name call_location pre_post call_state
      , return_caller )
      |> fun ({astate}, return_caller) -> (astate, return_caller)
    in
    PerfEvent.(log (fun logger -> log_end_event logger ())) ;
    r


  (* - read all the pre, assert validity of addresses and materializes *everything* (to throw stuff
       in the *current* pre as appropriate so that callers of the current procedure will also know
       about the deeper reads)

     - for each actual, write the post for that actual

     - if aliasing is introduced at any time then give up

     questions:

     - what if some preconditions raise lifetime issues but others don't? Have to be careful with
     the noise that this will introduce since we don't care about values. For instance, if the pre
     is for a path where [formal != 0] and we pass [0] then it will be an FP. Maybe the solution is
     to bake in some value analysis.  *)
  let apply callee_proc_name call_location pre_post ~formals ~actuals astate =
    L.d_printfln "Applying pre/post for %a(%a):@\n%a" Typ.Procname.pp callee_proc_name
      (Pp.seq ~sep:"," Var.pp) formals pp pre_post ;
    let empty_call_state =
      {astate; subst= AddressMap.empty; rev_subst= AddressMap.empty; visited= AddressSet.empty}
    in
    (* read the precondition *)
    match
      materialize_pre callee_proc_name call_location pre_post ~formals ~actuals empty_call_state
    with
    | exception Aliasing ->
        (* can't make sense of the pre-condition in the current context: give up on that particular
           pre/post pair *)
        Ok (astate, None)
    | None ->
        (* couldn't apply the pre for some technical reason (as in: not by the fault of the
           programmer as far as we know) *)
        Ok (astate, None)
    | Some (Error _ as error) ->
        (* error: the function call requires to read some state known to be invalid *)
        error
    | Some (Ok call_state) ->
        (* reset [visited] *)
        let call_state = {call_state with visited= AddressSet.empty} in
        (* apply the postcondition *)
        Ok (apply_post callee_proc_name call_location pre_post ~formals ~actuals call_state)
end
