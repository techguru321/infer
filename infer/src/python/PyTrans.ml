(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module L = Logging
module T = Textual
module PyBuiltins = PyCommon.Builtins

(* In Python, everything is an object, and the interpreter maintains a stack of references to
   such objects. Pushing and popping on the stack are always references to objets that leave in a
   heap. There is no need to model this heap, but the data stack is quite important. *)
module DataStack = struct
  type cell =
    | Const of int  (** index in [co_consts] *)
    | Name of int  (** reference to a global name, stored in [co_names] *)
    | VarName of int  (** reference to a local name, stored in [co_varnames] *)
    | Temp of T.Ident.t  (** SSA variable *)
    | Fun of string  (** top level user-defined function name *)
  [@@deriving show]

  let as_code FFI.Code.{co_consts} = function
    | Const n ->
        let code = co_consts.(n) in
        FFI.Constant.as_code code
    | Name _ | Temp _ | Fun _ | VarName _ ->
        None


  let show_cell_kind = function
    | Const _ ->
        "DataStack.Const"
    | Name _ ->
        "DataStack.Name"
    | VarName _ ->
        "DataStack.VarName"
    | Temp _ ->
        "DataStack.Temp"
    | Fun _ ->
        "DataStack.Fun"


  type t = cell list

  let push stack cell = cell :: stack

  let pop = function [] -> None | hd :: stack -> Some (stack, hd)
end

module Env = struct
  module Labels = Caml.Map.Make (Int)

  (** Part of the environment shared by most structures. It gathers information like which builtin
      has been spotted, or what idents and labels have been generated so far. *)
  type shared =
    { idents: T.Ident.Set.t
    ; globals: T.VarName.Set.t
    ; builtins: PyBuiltins.t
    ; next_label: int
    ; forward_labels: (string * T.Exp.t option) Labels.t
          (** Map from offset of labels the code might eventually jump to, to the label name and the
              Textual expression that might need pruning. They are kept around to correctly split
              code unit into Textual nodes. *) }

  (* TODO(vsiles): revisit the data stack status once generators are in the mix *)

  (** State of the capture while processing a single node: each node has a dedicated data stack, and
      generates its own set of instructions. *)
  type node = {stack: DataStack.t; instructions: T.Instr.t list; last_line: int option}

  let empty_node = {stack= []; instructions= []; last_line= None}

  type t = {shared: shared; node: node}

  let empty =
    { idents= T.Ident.Set.empty
    ; globals= T.VarName.Set.empty
    ; builtins= PyBuiltins.empty
    ; next_label= 0
    ; forward_labels= Labels.empty }


  (** Reset the [node] part of an environment, and all of its [idents], to prepare it to process a
      new code unit *)
  let reset_for_proc shared =
    let shared = {shared with idents= T.Ident.Set.empty; next_label= 0} in
    {shared; node= empty_node}


  (** Reset the [instructions] field of a [node] to prepare the env to deal with a new set of
      instructions. *)
  let reset_for_node ({node} as env) =
    let reset_for_node env = {env with instructions= []} in
    let node = reset_for_node node in
    {env with node}


  (** Update the [last_line] field of an env, if new information is availbe. *)
  let update_last_line ({node} as env) last_line =
    let update_last_line node last_line =
      if Option.is_some last_line then {node with last_line} else node
    in
    {env with node= update_last_line node last_line}


  (** Return the last recorded line information from the Python code-unit, if any. *)
  let loc {node} =
    let loc {last_line} =
      last_line
      |> Option.map ~f:(fun line -> T.Location.known ~line ~col:0)
      |> Option.value ~default:T.Location.Unknown
    in
    loc node


  (** Push a new [DataStack.cell] on the datastack *)
  let push ({node} as env) cell =
    let push ({stack} as env) cell =
      let stack = DataStack.push stack cell in
      {env with stack}
    in
    let node = push node cell in
    {env with node}


  (** Pop a [DataStack.cell] from the datastack, if any is available *)
  let pop ({node} as env) =
    let pop ({stack} as env) =
      DataStack.pop stack |> Option.map ~f:(fun (stack, cell) -> ({env with stack}, cell))
    in
    pop node |> Option.map ~f:(fun (node, cell) -> ({env with node}, cell))


  (** Generate a fresh temporary name *)
  let temp ({shared} as env) =
    let temp ({idents} as env) =
      let fresh = T.Ident.fresh idents in
      let idents = T.Ident.Set.add fresh idents in
      ({env with idents}, fresh)
    in
    let shared, fresh = temp shared in
    ({env with shared}, fresh)


  (** Record a new instruction for the current code unit *)
  let push_instr ({node} as env) instr =
    let push_instr ({instructions} as env) instr = {env with instructions= instr :: instructions} in
    {env with node= push_instr node instr}


  (** Generate a fresh label name *)
  let label ({shared} as env) =
    let label ({next_label} as env) =
      let fresh_label = sprintf "b%d" next_label in
      let env = {env with next_label= next_label + 1} in
      (env, fresh_label)
    in
    let shared, fresh_label = label shared in
    let env = {env with shared} in
    (env, fresh_label)


  (** Register the fact that a [label] must be inserted before the instruction at [offset] *)
  let register_label offset label pruned ({shared} as env) =
    let register_label offset label pruned ({forward_labels} as env) =
      let forward_labels = Labels.add offset (label, pruned) forward_labels in
      {env with forward_labels}
    in
    let shared = register_label offset label pruned shared in
    {env with shared}


  (** Check if the instruction is a possible jump location, and return the label information found
      there, if any. The entry is removed from the set to avoid infinite recursion in the main
      [nodes] function. *)
  let label_of_offset ({shared} as env) offset =
    let label_of_offset ({forward_labels} as env) offset =
      let res = Labels.find_opt offset forward_labels in
      let env =
        if Option.is_some res then
          let forward_labels = Labels.remove offset forward_labels in
          {env with forward_labels}
        else env
      in
      (env, res)
    in
    let shared, res = label_of_offset shared offset in
    ({env with shared}, res)


  (** Returns the list of all instructions recorded for the current code unit *)
  let get_instructions {node} =
    let get_instructions {instructions} = List.rev instructions in
    get_instructions node


  (** Register a global name (function, variable, ...). Since Python allows "toplevel" code, they
      are encoded within a specially named function that behaves as a toplevel scope, and global
      identifiers are scope accordingly. That way, there is no mixing them with locals with the same
      name. *)
  let register_global ({shared} as env) name =
    let register_global ({globals} as env) name =
      {env with globals= T.VarName.Set.add name globals}
    in
    {env with shared= register_global shared name}


  (** Register a known builtin, so they are correctly scoped, and add the relevant Textual
      declarations for them. *)
  let register_builtin ({shared} as env) name =
    let register_builtin ({builtins} as env) name =
      {env with builtins= PyBuiltins.register builtins name}
    in
    {env with shared= register_builtin shared name}
end

module Debug = struct
  (* Custom verbose flag, while I'm still building this front end.
     I'll move to Logging once it's done. *)
  let debug = false

  (* Inspired by PulseFormula.Debug. Check there for plugging it into Logging too *)
  let dummy_formatter = F.make_formatter (fun _ _ _ -> ()) (fun () -> ())

  let p fmt =
    if debug then F.kasprintf (fun s -> F.printf "%s" s) fmt else F.ifprintf dummy_formatter fmt
end

let var_name ?(loc = T.Location.Unknown) value = T.VarName.{value; loc}

let node_name ?(loc = T.Location.Unknown) value = T.NodeName.{value; loc}

let proc_name ?(loc = T.Location.Unknown) value = T.ProcName.{value; loc}

(* TODO: only deal with toplevel functions for now *)
let qualified_procname name : T.qualified_procname = {enclosing_class= TopLevel; name}

let global name = sprintf "$globals::%s" name

(* Until there is support for python types, everything is a [*object] *)
let pyObject = PyCommon.pyObject

(** Try to load the data referenced by a [DataStack.cell], into a [Textual.Exp.t] *)
let load_cell env {FFI.Code.co_consts; co_names; co_varnames} cell =
  (* Python only stores references to objects on the data stack, so when data needs to be really
     accessed, [load_cell] is used to get information from the code information ([co_consts], ...).
     These data are mapped to Textual.Exp.t values as much as possible. But it's not always
     desirable (see MAKE_FUNCTION) *)
  let loc = Env.loc env in
  match cell with
  | DataStack.Const ndx -> (
      let const = co_consts.(ndx) in
      match FFI.Constant.to_exp const with
      | None ->
          (env, `Error "[load_cell] Constant contains code objects")
      | Some exp_ty ->
          (env, `Ok exp_ty) )
  | DataStack.Name ndx ->
      let name = global co_names.(ndx) in
      let env, id = Env.temp env in
      let exp = T.Exp.Lvar (var_name ~loc name) in
      let loc = Env.loc env in
      let instr = T.Instr.Load {id; exp; typ= pyObject; loc} in
      let env = Env.push_instr env instr in
      (* TODO: try to trace the type of names ? *)
      (env, `Ok (T.Exp.Var id, PyCommon.pyObject))
  | DataStack.VarName ndx ->
      let name = co_varnames.(ndx) in
      let env, id = Env.temp env in
      let exp = T.Exp.Lvar (var_name ~loc name) in
      let loc = Env.loc env in
      let instr = T.Instr.Load {id; exp; typ= pyObject; loc} in
      let env = Env.push_instr env instr in
      (* TODO: try to trace the type of names ? *)
      (env, `Ok (T.Exp.Var id, PyCommon.pyObject))
  | DataStack.Temp id ->
      (* TODO: try to trace the type of ids ? *)
      (env, `Ok (T.Exp.Var id, PyCommon.pyObject))
  | DataStack.Fun f ->
      (env, `Fun f)


(** Pop the top of the datastack. Fails with an [InternalError] if the stack is empty. *)
let pop_tos opname env =
  match Env.pop env with
  | None ->
      L.die ExternalError "[%s] stack is empty" opname
  | Some (env, cell) ->
      (env, cell)


(* Python opcodes support. Most of the documentation directly comes from the official python
   documentation and is only altered to improve readability.

   https://docs.python.org/3.8/library/dis.html *)

module LOAD = struct
  type kind =
    | CONST  (** {v LOAD_CONST(consti) v}

                 Pushes [co_consts\[consti\]] onto the stack. *)
    | FAST
        (** {v LOAD_FAST(var_num) v}

            Pushes a reference to the local [co_varnames\[var_num\]] onto the stack. *)
    | GLOBAL
        (** {v LOAD_GLOBAL(namei) v}

            Loads the global named [co_names\[namei\]] onto the stack. *)
    | NAME
        (** {v LOAD_NAME(namei) v}

            Pushes the value associated with [co_names\[namei\]] onto the stack. *)

  let run kind env code {FFI.Instruction.opname; arg} =
    let pp {FFI.Code.co_names; co_varnames; co_consts} fmt = function
      | CONST ->
          FFI.Constant.pp fmt co_consts.(arg)
      | FAST ->
          F.fprintf fmt "%s" co_varnames.(arg)
      | NAME | GLOBAL ->
          F.fprintf fmt "%s" co_names.(arg)
    in
    let cell =
      match kind with
      | CONST ->
          DataStack.Const arg
      | FAST ->
          DataStack.VarName arg
      | NAME | GLOBAL ->
          DataStack.Name arg
    in
    Debug.p "[%s] arg = %a\n" opname (pp code) kind ;
    (Env.push env cell, None)
end

module STORE = struct
  type kind =
    | FAST
        (** {v STORE_FAST(var_num) v}

            Stores top-of-stack into the local [co_varnames\[var_num\]]. *)
    | NAME
        (** {v STORE_NAME(namei) v}

            Implements name = top-of-stack. namei is the index of name in the attribute co_names of
            the code object. The compiler tries to use [STORE_FAST] or [STORE_GLOBAL] if possible.

            Notes: this should only happen in global nodes, to update global variables from the
            global scope.

            In a function, local varialbes are updated using [STORE_FAST], and global variables are
            updated using [STORE_GLOBAL]. *)
    | GLOBAL
        (** {v STORE_GLOBAL(namei) v}

            Works as [STORE_NAME], but stores the name as a global.

            Since there is a special namespace for global varialbes, this is in fact the same as
            [STORE_NAME], but only called from within a function/method. *)

  let run kind env ({FFI.Code.co_names; co_varnames} as code) {FFI.Instruction.opname; arg} =
    let name, is_global =
      match kind with
      | FAST ->
          (co_varnames.(arg), false)
      | NAME | GLOBAL ->
          (global co_names.(arg), true)
    in
    Debug.p "[%s] name = %s\n" opname name ;
    let loc = Env.loc env in
    let var_name = var_name ~loc name in
    let env, cell = pop_tos opname env in
    let env, exp_ty = load_cell env code cell in
    match exp_ty with
    | `Ok (exp, typ) ->
        let env = if is_global then Env.register_global env var_name else env in
        let instr = T.Instr.Store {exp1= Lvar var_name; typ; exp2= exp; loc} in
        (Env.push_instr env instr, None)
    | `Error s ->
        L.die InternalError "[%s] %s" opname s
    | `Fun f ->
        if is_global then (
          Debug.p "  top-level function defined: %s\n" f ;
          (env, None) )
        else L.die InternalError "[%s] no support for closure at the moment: %s" opname f
end

module RETURN_VALUE = struct
  (** {v RETURN_VALUE v}

      Returns the top-of-stack *)
  let run env code {FFI.Instruction.opname} =
    Debug.p "[%s]\n" opname ;
    let env, cell = pop_tos opname env in
    let env, exp_ty = load_cell env code cell in
    match exp_ty with
    | `Ok (exp, _) ->
        let term = T.Terminator.Ret exp in
        (env, Some (`Return term))
    | `Error s ->
        L.die InternalError "[%s] %s" opname s
    | `Fun f ->
        L.die InternalError "[%s] can't support returning closure: %s" opname f
end

module POP_TOP = struct
  (** {v POP_TOP v}

      Pop the top-of-stack and discard it *)
  let run env {FFI.Instruction.opname} =
    Debug.p "[%s]\n" opname ;
    let env, _cell = pop_tos opname env in
    (env, None)
end

module CALL_FUNCTION = struct
  (** {v CALL_FUNCTION(argc) v}

      Calls a callable object with positional arguments. [argc] indicates the number of positional
      arguments. The top of the stack contains positional arguments, with the right-most argument on
      top. Below the arguments is a callable object to call. This opcode pushes a fresh result on
      the top of the stack.

      Before: [ argN | ... | arg1 | arg0 | code-object | rest-of-the-stack ]

      After: [ result | rest-of-the-stack v} ] *)

  let pop_n_tos opname code =
    let rec pop env n acc =
      if n > 0 then (
        let env, cell = pop_tos opname env in
        Debug.p "  popped %s\n" (DataStack.show_cell cell) ;
        let env, exp_ty = load_cell env code cell in
        match exp_ty with
        | `Ok (exp, _) ->
            pop env (n - 1) (exp :: acc)
        | `Fun f ->
            L.die InternalError "[%s] failed to get closure as function argument: %s" opname f
        | `Error s ->
            L.die UserError "[%s] failed to fetch from the stack: %s" opname s )
      else (env, acc)
    in
    Debug.p "[pop_n_tos]\n" ;
    pop


  let run env ({FFI.Code.co_names} as code) {FFI.Instruction.opname; arg} =
    Debug.p "[%s] argc = %d\n" opname arg ;
    let env, args = pop_n_tos opname code env arg [] in
    Debug.p "  #args = %d\n" (List.length args) ;
    let env, fname = pop_tos opname env in
    Debug.p "  fname = %s\n" (DataStack.show_cell fname) ;
    let fname =
      match fname with
      | DataStack.Name ndx ->
          co_names.(ndx)
      | VarName _ | Fun _ | Const _ | Temp _ ->
          L.die UserError "[%s] invalid function on the stack: %s" opname
            (DataStack.show_cell_kind fname)
    in
    let env, id = Env.temp env in
    let loc = Env.loc env in
    let env, proc =
      if PyBuiltins.is_builtin fname then
        let env = Env.register_builtin env fname in
        (env, PyCommon.builtin_name fname)
      else (env, qualified_procname @@ proc_name ~loc fname)
    in
    let call = T.Exp.Call {proc; args; kind= NonVirtual} in
    let let_instr = T.Instr.Let {id; exp= call; loc} in
    let env = Env.push_instr env let_instr in
    let env = Env.push env (DataStack.Temp id) in
    (env, None)
end

module BINARY_ADD = struct
  (** {v BINARY_ADD v}

      Implements top-of-stack = top-of-stack1 + top-of-stack.

      Before: [ TOS (rhs) | TOS1 (lhs) | rest-of-stack ]

      After: [ TOS1 + TOS (lhs + rhs) | rest-of-stack ]

      Since Python is using runtime types to know which [+] to do (addition, string concatenation,
      custom operator, ...), we'll need to write a model for this one. *)
  let run env code {FFI.Instruction.opname} =
    Debug.p "[%s]\n" opname ;
    let env, tos = pop_tos opname env in
    let env, tos1 = pop_tos opname env in
    let env, lhs = load_cell env code tos1 in
    let lhs =
      match lhs with
      | `Ok (lhs, _) ->
          lhs
      | `Error s ->
          L.die InternalError "[%s] %s" opname s
      | `Fun f ->
          L.die InternalError "[%s] Can't add function %s" opname f
    in
    let env, rhs = load_cell env code tos in
    let rhs =
      match rhs with
      | `Ok (rhs, _) ->
          rhs
      | `Error s ->
          L.die InternalError "[%s] %s" opname s
      | `Fun f ->
          L.die InternalError "[%s] Can't add function %s" opname f
    in
    let fname = "binary_add" in
    let env = Env.register_builtin env fname in
    let env, id = Env.temp env in
    let proc = PyCommon.builtin_name fname in
    (* Even if the call can be considered as virtual because, it's logic is not symetric. Based
       on what I gathered, like in [0], I think the best course of action is to write a model for
       it and leave it non virtual. TODO: ask David.

       [0]:
       https://stackoverflow.com/questions/58828522/is-radd-called-if-add-raises-notimplementederror
    *)
    let exp = T.Exp.Call {proc; args= [lhs; rhs]; kind= T.Exp.NonVirtual} in
    let loc = Env.loc env in
    let let_instr = T.Instr.Let {id; exp; loc} in
    let env = Env.push_instr env let_instr in
    let env = Env.push env (DataStack.Temp id) in
    (env, None)
end

module MAKE_FUNCTION = struct
  (** {v MAKE_FUNCTION(flags) v}

      Pushes a new function object on the stack. From bottom to top, the consumed stack must consist
      of values if the argument carries a specified flag value

      - [0x01] a tuple of default values for positional-only and positional-or-keyword parameters in
        positional order
      - [0x02] a dictionary of keyword-only parameters’ default values
      - [0x04] an annotation dictionary
      - [0x08] a tuple containing cells for free variables, making a closure
      - the code associated with the function (at TOS1)
      - the qualified name of the function (at TOS)

      In this first version, only support for [flags = 0x00] is implemented. Also there is no
      support for closures or nested functions *)
  let run env ({FFI.Code.co_consts} as code) {FFI.Instruction.opname; arg} =
    Debug.p "[%s] flags = 0x%x\n" opname arg ;
    if arg <> 0 then L.die InternalError "%s: support for flag 0x%x is not implemented" opname arg ;
    let env, qual = pop_tos opname env in
    (* don't care about the content of the code object, but check it is indeed code *)
    let env, body = pop_tos opname env in
    let body =
      match DataStack.as_code code body with
      | None ->
          L.die InternalError "%s: payload is not code: %s" opname (DataStack.show_cell_kind body)
      | Some body ->
          body
    in
    if FFI.Code.is_closure body then L.die InternalError "%s: can't create closure" opname ;
    let qual =
      match qual with
      | DataStack.(VarName _ | Name _ | Temp _ | Fun _) ->
          L.die InternalError "%s: invalid function name: %s" opname (DataStack.show_cell_kind qual)
      | DataStack.Const ndx -> (
          let const = co_consts.(ndx) in
          match FFI.Constant.as_name const with
          | Some name ->
              name
          | None ->
              L.die InternalError "%s: can't read qualified name from stack: %s" opname
                (FFI.Constant.show const) )
    in
    let env = Env.push env (DataStack.Fun qual) in
    (env, None)
end

module JUMP = struct
  module POP_IF = struct
    (** {v POP_JUMP_IF_TRUE(target) v}

        If top-of-stack is true, sets the bytecode counter to target. top-of-stack is popped.

        {v POP_JUMP_IF_FALSE(target) v}

        If top-of-stack is false, sets the bytecode counter to target. top-of-steack is popped. *)
    let run ~next_is_true env code {FFI.Instruction.opname; arg} =
      Debug.p "[%s] target = %d\n" opname arg ;
      let env, tos = pop_tos opname env in
      let env, cell = load_cell env code tos in
      let cond =
        match cell with
        | `Ok (cond, _) ->
            cond
        | `Error s ->
            L.die InternalError "[%s] %s" opname s
        | `Fun f ->
            L.die InternalError "[%s] Can't evaluate jump condition based on a function: %s" opname
              f
      in
      (env, Some (`TwoWay (next_is_true, arg, cond)))
  end
end

(** Main opcode dispatch function. *)
let run_instruction env code ({FFI.Instruction.opname; starts_line} as instr) =
  let env = Env.update_last_line env starts_line in
  (* TODO: there are < 256 opcodes, could setup an array of callbacks instead *)
  let env, maybe_term =
    match opname with
    | "LOAD_CONST" ->
        LOAD.(run CONST env code instr)
    | "LOAD_FAST" ->
        LOAD.(run FAST env code instr)
    | "LOAD_GLOBAL" ->
        LOAD.(run GLOBAL env code instr)
    | "LOAD_NAME" ->
        LOAD.(run NAME env code instr)
    | "STORE_FAST" ->
        STORE.(run FAST env code instr)
    | "STORE_GLOBAL" ->
        STORE.(run GLOBAL env code instr)
    | "STORE_NAME" ->
        STORE.(run NAME env code instr)
    | "RETURN_VALUE" ->
        RETURN_VALUE.run env code instr
    | "POP_TOP" ->
        POP_TOP.run env instr
    | "CALL_FUNCTION" ->
        CALL_FUNCTION.run env code instr
    | "BINARY_ADD" ->
        BINARY_ADD.run env code instr
    | "MAKE_FUNCTION" ->
        MAKE_FUNCTION.run env code instr
    | "POP_JUMP_IF_TRUE" ->
        JUMP.POP_IF.run ~next_is_true:false env code instr
    | "POP_JUMP_IF_FALSE" ->
        JUMP.POP_IF.run ~next_is_true:true env code instr
    | _ ->
        L.die InternalError "Unsupported opcode: %s" opname
  in
  (env, maybe_term)


(** Helper function to check if the next instructions has a label attached to it *)
let has_jump_target env instructions =
  match List.hd instructions with
  | None ->
      (env, None)
  | Some {FFI.Instruction.offset; is_jump_target} ->
      (* Python provides us with jump target info too, so we can do a sanity check. *)
      let env, maybe_label = Env.label_of_offset env offset in
      if Option.is_some maybe_label then
        if not is_jump_target then
          L.die InternalError "Label at offset %d is not a jump target" offset ;
      (env, maybe_label)


(** Iterator on [run_instruction]: this function will interpret instructions as long as terminator
    is not reached. *)
let rec run env code instructions =
  match instructions with
  | [] ->
      (env, None, [])
  | instr :: rest ->
      let env, maybe_term = run_instruction env code instr in
      if Option.is_some maybe_term then (env, maybe_term, rest) else run env code rest


(** Return the location of the first available instruction, if any *)
let first_loc_of_code instructions =
  match instructions with
  | {FFI.Instruction.starts_line= Some line} :: _ ->
      T.Location.known ~line ~col:0
  | _ ->
      T.Location.Unknown


let mk_jump loc labels =
  let nodes =
    List.map
      ~f:(fun value ->
        let label = {T.NodeName.value; loc} in
        {T.Terminator.label; ssa_args= []} )
      labels
  in
  T.Terminator.Jump nodes


(** Process the instructions of a code object up to the point where a terminator is reached. It will
    return the remaining instructions, new allocated node, along with any label that should be used
    to start the next node, if any (and prunning information).

    If the terminator is [`Return], just return the single node describing all the instruction that
    have been recorded so far, and the remaining instructions, on the side.

    If the terminator is [`TwoWay], record the current node, and register two fresh labels for the
    two possible jump locations. One is always the follow-up instruction, the "next" instruction,
    and the "other" might be located further away in case of nested "if/then/else" scenarios.*)
let until_terminator env label_name pruned code instructions =
  Debug.p "[until_terminator] %s\n" label_name ;
  let label_loc = first_loc_of_code instructions in
  let label = {T.NodeName.value= label_name; loc= label_loc} in
  (* Prune necessary expressions *)
  let env =
    match pruned with
    | None ->
        env
    | Some exp ->
        let instr = T.Instr.Prune {exp; loc= label_loc} in
        Env.push_instr env instr
  in
  let env, maybe_term, rest = run env code instructions in
  let last_loc = Env.loc env in
  match maybe_term with
  | None ->
      L.die InternalError "Reached the end of code without spotting a terminator"
  | Some (`Return last) ->
      let node =
        T.Node.
          { label
          ; ssa_parameters= []
          ; exn_succs= []
          ; last
          ; instrs= Env.get_instructions env
          ; last_loc
          ; label_loc }
      in
      (env, rest, node, None)
  | Some (`TwoWay (next_is_true, other_offset, cond)) ->
      (* The current node ended up with a two-way jump. Either continue to the "next"
         (fall-through) part of the code, or jump to the "other" section of the code. For this
         purpose, register a fresh label for the jump. *)
      let jump_loc = Env.loc env in
      let env, next_label = Env.label env in
      let env, other_label = Env.label env in
      (* Compute the relevant pruning expressions *)
      let condT = PyCommon.mk_is_true cond in
      let condF = PyCommon.mk_is_true (T.Exp.not cond) in
      let next_prune = if next_is_true then condT else condF in
      let other_prune = if next_is_true then condF else condT in
      (* Register the jump target *)
      let env = Env.register_label other_offset other_label (Some other_prune) env in
      let jump = mk_jump jump_loc [next_label; other_label] in
      let node =
        T.Node.
          { label
          ; ssa_parameters= []
          ; exn_succs= []
          ; last= jump
          ; instrs= Env.get_instructions env
          ; last_loc
          ; label_loc }
      in
      (env, rest, node, Some (next_label, Some next_prune))


(** Process a sequence of instructions until there is no more left to process. *)
let rec nodes env label_name pruned code instructions =
  let env, instructions, textual_node, forward_label =
    until_terminator env label_name pruned code instructions
  in
  if List.is_empty instructions then (env, [textual_node])
  else
    let env = Env.reset_for_node env in
    let env, label_name, pruned =
      (* If the previous node provides the name of the next label, take it.
         Otherwise, check if execution reached a jump location, and use it.
         Otherwise pick up a fresh label. *)
      match forward_label with
      | Some (name, pruned) ->
          (env, name, pruned)
      | None -> (
          let env, jump_target = has_jump_target env instructions in
          match jump_target with
          | Some (name, pruned) ->
              (env, name, pruned)
          | None ->
              let env, name = Env.label env in
              (env, name, None) )
    in
    let env, more_textual_nodes = nodes env label_name pruned code instructions in
    (env, textual_node :: more_textual_nodes)


(** Process a single code unit (toplevel code, function body, ...) *)
let to_proc_desc env name ({FFI.Code.co_argcount; co_varnames; instructions} as code) =
  Debug.p "[to_proc_desc] %s\n" name.T.ProcName.value ;
  let qualified_name = qualified_procname name in
  let pyObject = T.Typ.{typ= pyObject; attributes= []} in
  let loc = name.T.ProcName.loc in
  let nr_varnames = Array.length co_varnames in
  let params = Array.sub co_varnames ~pos:0 ~len:co_argcount in
  let locals = Array.sub co_varnames ~pos:co_argcount ~len:(nr_varnames - co_argcount) in
  let params = Array.map ~f:(var_name ~loc) params |> Array.to_list in
  let locals = Array.map ~f:(fun name -> (var_name ~loc name, pyObject)) locals |> Array.to_list in
  let procdecl =
    { T.ProcDecl.qualified_name
    ; formals_types= List.map ~f:(fun _ -> pyObject) params
    ; are_formal_types_fully_declared= true
    ; result_type= pyObject
    ; attributes= [] }
  in
  (* Create the original environment for this code unit *)
  let env = Env.reset_for_proc env in
  let env, entry_label = Env.label env in
  let label = node_name ~loc entry_label in
  (* Now that a full unit has been processed, discard all the local information (local variable
     names, labels, ...) and only keep the [shared] part of the environment *)
  let {Env.shared= env}, nodes = nodes env entry_label None code instructions in
  (env, {Textual.ProcDesc.procdecl; nodes; start= label; params; locals; exit_loc= Unknown})


(* TODO: No support for nested functions/methods at the moment *)

(** Process multiple [code] objects. Usually called by the toplevel function. *)
let to_proc_descs env codes =
  Array.fold codes ~init:(env, []) ~f:(fun (env, decls) const ->
      match FFI.Constant.as_code const with
      | None ->
          (env, decls)
      | Some ({FFI.Code.co_name; instructions} as code) ->
          let loc = first_loc_of_code instructions in
          let name = proc_name ~loc co_name in
          let env, decl = to_proc_desc env name code in
          (env, T.Module.Proc decl :: decls) )


let python_attribute = Textual.Attr.mk_source_language Textual.Lang.Python

(** Entry point of the module: process a whole Python file / compilation unit into Textual *)
let to_module ~sourcefile module_name ({FFI.Code.co_consts; instructions} as code) =
  Debug.p "[to_module] %s\n" module_name ;
  let env = Env.empty in
  (* First, process any code body that is in code.co_consts *)
  let env, decls = to_proc_descs env co_consts in
  (* Process top level module *)
  let loc = first_loc_of_code instructions in
  let name = proc_name ~loc module_name in
  let env, decl = to_proc_desc env name code in
  (* Translate globals to Textual *)
  let globals =
    T.VarName.Set.fold
      (fun name acc ->
        let global = T.Global.{name; typ= pyObject; attributes= []} in
        T.Module.Global global :: acc )
      env.Env.globals []
  in
  (* Gather everything into a Textual module *)
  let decls = ((T.Module.Proc decl :: decls) @ globals) @ PyBuiltins.to_textual env.Env.builtins in
  {T.Module.attrs= [python_attribute]; decls; sourcefile}
