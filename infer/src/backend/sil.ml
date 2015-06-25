(*
* Copyright (c) 2009 -2013 Monoidics ltd.
* Copyright (c) 2013 - Facebook.
* All rights reserved.
*)

(** The Smallfoot Intermediate Language *)

module L = Logging
module F = Format
open Utils

(** {2 Programs and Types} *)

(** Type to represent one @Annotation. *)
type annotation =
  { class_name: string; (* name of the annotation *)
    parameters: string list; (* currently only one string parameter *) }

(** Annotation for one item: a list of annotations with visibility. *)
type item_annotation = (annotation * bool) list

(** Annotation for a method: return value and list of parameters. *)
type method_annotation =
  item_annotation * item_annotation list

type func_attribute =
  | FA_sentinel of int * int (** __attribute__((sentinel(int, int))) *)

(** Programming language. *)
type language = C_CPP | Java

(** Visibility modifiers. *)
type access = Default | Public | Private | Protected

(** Attributes of a procedure. *)
type proc_attributes =
  {
    access : access; (** visibility access *)
    exceptions : string list; (** exceptions thrown by the procedure *)
    is_abstract : bool; (** the procedure is abstract *)
    mutable is_bridge_method : bool; (** the procedure is a bridge method *)
    is_objc_instance_method : bool; (** the procedure is an objective-C instance method *)
    mutable is_synthetic_method : bool; (** the procedure is a synthetic method *)
    language : language;
    func_attributes : func_attribute list;
    method_annotation : method_annotation;
  }

let copy_proc_attributes pa =
  {
    access = pa.access;
    exceptions = pa.exceptions;
    is_abstract = pa.is_abstract;
    is_bridge_method = pa.is_bridge_method;
    is_objc_instance_method = pa.is_objc_instance_method;
    is_synthetic_method = pa.is_synthetic_method;
    language = pa.language;
    func_attributes = pa.func_attributes;
    method_annotation = pa.method_annotation;
  }

(** Compare function for annotations. *)
let annotation_compare a1 a2 =
  let n = string_compare a1.class_name a2.class_name in
  if n <> 0 then n else list_compare string_compare a1.parameters a2.parameters

(** Compare function for annotation items. *)
let item_annotation_compare ia1 ia2 =
  let cmp (a1, b1) (a2, b2) =
    let n = annotation_compare a1 a2 in
    if n <> 0 then n else bool_compare b1 b2 in
  list_compare cmp ia1 ia2

(** Compare function for Method annotations. *)
let method_annotation_compare (ia1, ial1) (ia2, ial2) =
  list_compare item_annotation_compare (ia1 :: ial1) (ia2 :: ial2)

(** Empty item annotation. *)
let item_annotation_empty = []

(** Empty method annotation. *)
let method_annotation_empty = [], []

(** Check if the item annotation is empty. *)
let item_annotation_is_empty avl =
  avl = []

(** Check if the item annodation is empty. *)
let item_annotation_is_empty ia = ia = []

(** Check if the method annodation is empty. *)
let method_annotation_is_empty (ia, ial) =
  list_for_all item_annotation_is_empty (ia :: ial)

(** Pretty print an annotation. *)
let pp_annotation fmt annotation = F.fprintf fmt "@@%s" annotation.class_name

(** Pretty print an item annotation. *)
let pp_item_annotation fmt item_annotation =
  let pp fmt (a, v) = pp_annotation fmt a in
  F.fprintf fmt "<%a>" (pp_seq pp) item_annotation

(** Pretty print a method annotation. *)
let pp_method_annotation s fmt (ia, ial) =
  F.fprintf fmt "%a %s(%a)" pp_item_annotation ia s (pp_seq pp_item_annotation) ial

(** Return the value of the FA_sentinel attribute in [attr_list] if it is found *)
let get_sentinel_func_attribute_value attr_list =
  (* Sentinel is the only kind of attributes *)
  let is_sentinel a = true in
  try
    match list_find is_sentinel attr_list with
    | FA_sentinel (sentinel, null_pos) -> Some (sentinel, null_pos)
  with Not_found -> None

(** current language *)
let curr_language = ref C_CPP

(** Class, struct, union, (Obj C) protocol *)
type csu =
  | Class
  | Struct
  | Union
  | Protocol

(** Named types. *)
type typename =
  | TN_typedef of Mangled.t
  | TN_enum of Mangled.t
  | TN_csu of csu * Mangled.t

(** Location in the original source file *)
type location = {
  line: int; (** The line number. -1 means "do not know" *)
  col: int; (** The column number. -1 means "do not know" *)
  file: DB.source_file; (** The name of the source file *)
  nLOC : int; (** Lines of code in the source file *)
}

let dummy_location = {
  line = -1;
  col = -1;
  file = DB.source_file_empty;
  nLOC = -1
}

(** Kind of global variables *)
type pvar_kind =
  | Local_var of Procname.t (** local variable belonging to a function *)
  | Callee_var of Procname.t (** local variable belonging to a callee *)
  | Abducted_retvar of Procname.t * location (** synthetic variable to represent return value *)
  | Abducted_ref_param of Procname.t * pvar * location
    (** synthetic variable to represent param passed by reference *)
  | Global_var (** gloval variable *)
  | Seed_var (** variable used to store the initial value of formal parameters *)

(** Names for program variables. *)
and pvar = { pv_name: Mangled.t; pv_kind: pvar_kind }

(** Unary operations *)
type unop =
  | Neg  (** Unary minus *)
  | BNot (** Bitwise complement (~) *)
  | LNot (** Logical Not (!) *)

(** Binary operations *)
type binop =
  | PlusA   (** arithmetic + *)
  | PlusPI  (** pointer + integer *)
  | MinusA  (** arithmetic - *)
  | MinusPI (** pointer - integer *)
  | MinusPP (** pointer - pointer *)
  | Mult    (** * *)
  | Div     (** / *)
  | Mod     (** % *)
  | Shiftlt (** shift left *)
  | Shiftrt (** shift right *)

  | Lt      (** <  (arithmetic comparison) *)
  | Gt      (** >  (arithmetic comparison) *)
  | Le      (** <= (arithmetic comparison) *)
  | Ge      (** >  (arithmetic comparison) *)
  | Eq      (** == (arithmetic comparison) *)
  | Ne      (** != (arithmetic comparison) *)
  | BAnd    (** bitwise and *)
  | BXor    (** exclusive-or *)
  | BOr     (** inclusive-or *)

  | LAnd    (** logical and. Does not always evaluate both operands. *)
  | LOr     (** logical or. Does not always evaluate both operands. *)
  | PtrFld  (** field offset via pointer to field: takes the address of a csu and a Cptr_to_fld constant to form an Lfield expression (see prop.ml) *)

(** Kinds of integers *)
type ikind =
    IChar       (** [char] *)
  | ISChar      (** [signed char] *)
  | IUChar      (** [unsigned char] *)
  | IBool       (** [bool] *)
  | IInt        (** [int] *)
  | IUInt       (** [unsigned int] *)
  | IShort      (** [short] *)
  | IUShort     (** [unsigned short] *)
  | ILong       (** [long] *)
  | IULong      (** [unsigned long] *)
  | ILongLong   (** [long long] (or [_int64] on Microsoft Visual C) *)
  | IULongLong  (** [unsigned long long] (or [unsigned _int64] on Microsoft Visual C) *)
  | I128        (** [__int128_t] *)
  | IU128       (** [__uint128_t] *)

(** Kinds of floating-point numbers*)
type fkind =
  | FFloat      (** [float] *)
  | FDouble     (** [double] *)
  | FLongDouble (** [long double] *)

type mem_kind =
  | Mmalloc (** memory allocated with malloc *)
  | Mnew (** memory allocated with new *)
  | Mnew_array (** memory allocated with new[] *)
  | Mobjc (** memory allocated with objective-c alloc *)

(** resource that can be allocated *)
type resource =
  | Rmemory of mem_kind
  | Rfile
  | Rignore
  | Rlock

(** kind of resource action *)
type res_act_kind =
  | Racquire
  | Rrelease

(** kind of dangling pointers *)
type dangling_kind =
  | DAuninit (** pointer is dangling because it is uninitialized *)
  | DAaddr_stack_var (** pointer is dangling because it is the address of a stack variable which went out of scope *)
  | DAminusone (** pointer is -1 *)

(** kind of pointer *)
type ptr_kind =
  | Pk_pointer (* C/C++, Java, Objc standard/__strong pointer*)
  | Pk_reference (* C++ reference *)
  | Pk_objc_weak (* Obj-C __weak pointer*)
  | Pk_objc_unsafe_unretained (* Obj-C __unsafe_unretained pointer *)
  | Pk_objc_autoreleasing (* Obj-C __autoreleasing pointer *)

(** position in a path: proc name, node id *)
type path_pos = Procname.t * int

(** module for subtypes, to be used with Sizeof info *)
module Subtype = struct

  let list_to_string list =
    let rec aux list =
      match list with
      | [] -> ""
      | el:: rest ->
          let s = (aux rest) in
          if (s = "") then (Mangled.to_string el)
          else (Mangled.to_string el)^", "^s in
    if (list_length list = 0) then "( sub )"
    else ("- {"^(aux list)^"}")

  let list_equal list1 list2 =
    if (list_length list1 = list_length list2) then
      list_for_all2 Mangled.equal list1 list2
    else false

  type t' =
    | Exact (** denotes the current type only *)
    | Subtypes of Mangled.t list(** denotes the current type and a list of types that are not their subtypes  *)

  type kind =
    | CAST
    | INSTOF
    | NORMAL

  type t = t' * kind

  module SubtypesPair = struct
    type t = (Mangled.t * Mangled.t)

    let compare (e1 : t)(e2 : t) : int =
      pair_compare Mangled.compare Mangled.compare e1 e2
  end

  module SubtypesMap = Map.Make (SubtypesPair)

  type subtMap = bool SubtypesMap.t

  let subtMap = ref SubtypesMap.empty

  let check_subtype f c1 c2 =
    try
      SubtypesMap.find (c1, c2) !subtMap
    with Not_found ->
        let is_subt = f c1 c2 in
        subtMap := (SubtypesMap.add (c1, c2) is_subt !subtMap);
        is_subt

  let flag_to_string flag =
    match flag with
    | CAST -> "(cast)"
    | INSTOF -> "(instof)"
    | NORMAL -> ""

  let pp f (t, flag) =
    match t with
    | Exact -> if !Config.print_types then F.fprintf f "%s" (flag_to_string flag)
    | Subtypes list -> if !Config.print_types then F.fprintf f "%s" ((list_to_string list)^(flag_to_string flag))

  let exact = Exact, NORMAL
  let all_subtypes = Subtypes []
  let subtypes = all_subtypes, NORMAL
  let subtypes_cast = all_subtypes, CAST
  let subtypes_instof = all_subtypes, INSTOF

  let is_cast t = snd t = CAST

  let is_instof t = snd t = INSTOF

  let list_intersect equal l1 l2 =
    let in_l2 a = list_mem equal a l2 in
    list_filter in_l2 l1

  let join_flag flag1 flag2 =
    match flag1, flag2 with
    | CAST, _ -> CAST
    | _, CAST -> CAST
    | _, _ -> NORMAL

  let join (s1, flag1) (s2, flag2) =
    let s =
      match s1, s2 with
      | Exact, _ -> s2
      | _, Exact -> s1
      | Subtypes l1, Subtypes l2 -> Subtypes (list_intersect Mangled.equal l1 l2) in
    let flag = join_flag flag1 flag2 in
    s, flag

  let subtypes_compare l1 l2 =
    list_compare Mangled.compare l1 l2

  let compare_flag flag1 flag2 =
    match flag1, flag2 with
    | CAST, CAST -> 0
    | INSTOF, INSTOF -> 0
    | NORMAL, NORMAL -> 0
    | CAST, _ -> -1
    | _, CAST -> 1
    | INSTOF, NORMAL -> -1
    | NORMAL, INSTOF -> 1

  let compare_subt s1 s2 =
    match s1, s2 with
    | Exact, Exact -> 0
    | Exact, _ -> -1
    | _, Exact -> 1
    | Subtypes l1, Subtypes l2 ->
        subtypes_compare l1 l2

  let compare t1 t2 =
    pair_compare compare_subt compare_flag t1 t2

  let equal_modulo_flag (st1, flag1) (st2, flag2) =
    compare_subt st1 st2 = 0

  let update_flag c1 c2 flag flag' =
    match flag with
    | INSTOF ->
        if (Mangled.equal c1 c2) then flag else flag'
    | _ -> flag'

  let change_flag st_opt c1 c2 flag' =
    match st_opt with
    | Some st ->
        (match st with
          | Exact, flag ->
              let new_flag = update_flag c1 c2 flag flag' in
              Some (Exact, new_flag)
          | Subtypes t, flag ->
              let new_flag = update_flag c1 c2 flag flag' in
              Some (Subtypes t, new_flag))
    | None -> None

  let normalize_subtypes t_opt c1 c2 flag1 flag2 =
    let new_flag = update_flag c1 c2 flag1 flag2 in
    match t_opt with
    | Some t ->
        (match t with
          | Exact -> Some (t, new_flag)
          | Subtypes l ->
              Some (Subtypes (list_sort Mangled.compare l), new_flag))
    | None -> None

  let subtypes_to_string t =
    match fst t with
    | Exact -> "ex"^(flag_to_string (snd t))
    | Subtypes l -> (list_to_string l)^(flag_to_string (snd t))

  (* c is a subtype when it does not appear in the list l of no-subtypes *)
  let is_subtype f c l =
    try ignore( list_find (f c) l); false
    with Not_found -> true

  let is_strict_subtype f c1 c2 =
    f c1 c2 && not (Mangled.equal c1 c2)

  (* checks for redundancies when adding c to l
  Xi in A - { X1,..., Xn } is redundant in two cases:
  1) not (Xi <: A) because removing the subtypes of Xi has no effect unless Xi is a subtype of A
  2) Xi <: Xj because the subtypes of Xi are a subset of the subtypes of Xj *)
  let check_redundancies f c l =
    let aux (l, add) ci =
      let l, should_add =
        if (f ci c) then (l, true)
        else if (f c ci) then (ci:: l, false)
        else (ci:: l, true) in
      l, (add && should_add) in
    (list_fold_left aux ([], true) l)

  let rec updates_head f c l =
    match l with
    | [] -> []
    | ci:: rest ->
        if (is_strict_subtype f ci c) then ci:: (updates_head f c rest)
        else (updates_head f c rest)

  (* adds the classes of l2 to l1 and checks that no redundancies or inconsistencies will occur
  A - { X1,..., Xn } is inconsistent if A <: Xi for some i *)
  let rec add_not_subtype f c1 l1 l2 =
    match l2 with
    | [] -> l1
    | c:: rest ->
        if (f c1 c) then (add_not_subtype f c1 l1 rest) (* checks for inconsistencies *)
        else
          let l1', should_add = (check_redundancies f c l1) in (* checks for redundancies *)
          let rest' = (add_not_subtype f c1 l1' rest) in
          if (should_add) then c:: rest' else rest'

  let get_subtypes (c1, (st1, flag1)) (c2, (st2, flag2)) f is_interface =
    let is_sub = f c1 c2 in
    (* L.d_strln_color Orange ((Mangled.to_string c1)^(subtypes_to_string (st1, flag1))^" <: "^ *)
    (* (Mangled.to_string c2)^(subtypes_to_string (st2, flag2))^" ?"^(string_of_bool is_sub)); *)
    let pos_st, neg_st = match st1, st2 with
      | Exact, Exact ->
          if (is_sub) then (Some st1, None)
          else (None, Some st1)
      | Exact, Subtypes l2 ->
          if is_sub && (is_subtype f c1 l2) then (Some st1, None)
          else (None, Some st1)
      | Subtypes l1, Exact ->
          if (is_sub) then (Some st1, None)
          else
            let l1' = updates_head f c2 l1 in
            if (is_subtype f c2 l1) then (Some (Subtypes l1'), Some (Subtypes (add_not_subtype f c1 l1 [c2])))
            else (None, Some st1)
      | Subtypes l1, Subtypes l2 ->
          if (is_interface c2) || (is_sub) then
            if (is_subtype f c1 l2) then
              let l2' = updates_head f c1 l2 in
              (Some (Subtypes (add_not_subtype f c1 l1 l2')), None)
            else (None, Some st1)
          else if ((is_interface c1) || (f c2 c1)) && (is_subtype f c2 l1) then
            let l1' = updates_head f c2 l1 in
            (Some (Subtypes (add_not_subtype f c2 l1' l2)), Some (Subtypes (add_not_subtype f c1 l1 [c2])))
          else (None, Some st1) in
    (normalize_subtypes pos_st c1 c2 flag1 flag2), (normalize_subtypes neg_st c1 c2 flag1 flag2)

  let case_analysis_basic (c1, st) (c2, (st2, flag2)) f =
    let (pos_st, neg_st) =
      if f c1 c2 then (Some st, None)
      else if f c2 c1 then
        match st with
        | Exact, flag ->
            if Mangled.equal c1 c2
            then (Some st, None)
            else (None, Some st)
        | Subtypes _ , flag ->
            if Mangled.equal c1 c2
            then (Some st, None)
            else (Some st, Some st)
      else (None, Some st) in
    (change_flag pos_st c1 c2 flag2), (change_flag neg_st c1 c2 flag2)

  (** [case_analysis (c1, st1) (c2,st2) f] performs case analysis on [c1 <: c2] according to [st1] and [st2]
  where f c1 c2 is true if c1 is a subtype of c2.
  get_subtypes returning a pair:
  - whether [st1] and [st2] admit [c1 <: c2], and in case return the updated subtype [st1]
  - whether [st1] and [st2] admit [not(c1 <: c2)], and in case return the updated subtype [st1] *)
  let case_analysis (c1, st1) (c2, st2) f is_interface =
    let f = check_subtype f in
    if (!Config.subtype_multirange) then
      get_subtypes (c1, st1) (c2, st2) f is_interface
    else case_analysis_basic (c1, st1) (c2, st2) f

end

(** module for signed and unsigned integers *)
module Int : sig
  type t
  val add : t -> t -> t
  val compare : t -> t -> int
  val compare_value : t -> t -> int
  val div : t -> t -> t
  val eq : t -> t -> bool
  val of_int : int -> t
  val of_int32 : int32 -> t
  val of_int64 : int64 -> t
  val of_int64_unsigned : int64 -> bool -> t
  val geq : t -> t -> bool
  val gt : t -> t -> bool
  val isminusone : t -> bool
  val isone : t -> bool
  val isnegative : t -> bool
  val isnull : t -> bool
  val iszero : t -> bool
  val leq : t -> t -> bool
  val logand : t -> t -> t
  val lognot : t -> t
  val logor : t -> t -> t
  val logxor : t -> t -> t
  val lt : t -> t -> bool
  val minus_one : t
  val mul : t -> t -> t
  val neg : t -> t
  val neq : t -> t -> bool
  val null : t
  val one : t
  val pp : Format.formatter -> t -> unit
  val rem : t -> t -> t
  val sub : t -> t -> t
  val to_int : t -> int
  val to_signed : t -> t option
  val to_string : t -> string
  val two : t
  val zero : t
end = struct
  (* the first bool indicates whether this is an unsigned value, and the second whether it is a pointer *)
  type t = bool * Int64.t * bool

  let area u i = match i < 0L, u with
    | true, false -> 1 (* only representable as signed *)
    | false, _ -> 2 (* in the intersection between signed and unsigned *)
    | true, true -> 3 (* only representable as unsigned *)

  let to_signed (unsigned, i, ptr) =
    if area unsigned i = 3 then None (* not representable as signed *)
    else Some (false, i, ptr)

  let compare (unsigned1, i1, ptr1) (unsigned2, i2, ptr2) =
    let n = bool_compare unsigned1 unsigned2 in
    if n <> 0 then n else Int64.compare i1 i2

  let compare_value (unsigned1, i1, ptr1) (unsigned2, i2, ptr2) =
    let area1 = area unsigned1 i1 in
    let area2 = area unsigned2 i2 in
    let n = int_compare area1 area2 in
    if n <> 0 then n else Int64.compare i1 i2

  let eq i1 i2 = compare_value i1 i2 = 0
  let neq i1 i2 = compare_value i1 i2 <> 0
  let leq i1 i2 = compare_value i1 i2 <= 0
  let lt i1 i2 = compare_value i1 i2 < 0
  let geq i1 i2 = compare_value i1 i2 >= 0
  let gt i1 i2 = compare_value i1 i2 > 0

  let of_int64 i = (false, i, false)
  let of_int32 i = of_int64 (Int64.of_int32 i)
  let of_int64_unsigned i unsigned = (unsigned, i, false)
  let of_int i = of_int64 (Int64.of_int i)
  let to_int (large, i, ptr) = Int64.to_int i
  let null = (false, 0L, true)
  let zero = of_int 0
  let one = of_int 1
  let two = of_int 2
  let minus_one = of_int (-1)

  let isone (_, i, ptr) = i = 1L
  let iszero (_, i, ptr) = i = 0L
  let isnull (_, i, ptr) = i = 0L && ptr
  let isminusone (unsigned, i, ptr) = not unsigned && i = -1L
  let isnegative (unsigned, i, ptr) = not unsigned && i < 0L

  let neg (unsigned, i, ptr) = (unsigned, Int64.neg i, ptr)

  let lift binop (unsigned1, i1, ptr1) (unsigned2, i2, ptr2) = (unsigned1 || unsigned2, binop i1 i2, ptr1 || ptr2)

  let lift1 unop (unsigned, i, ptr) = (unsigned, unop i, ptr)

  let add i1 i2 = lift Int64.add i1 i2

  let mul i1 i2 = lift Int64.mul i1 i2

  let div i1 i2 = lift Int64.div i1 i2

  let rem i1 i2 = lift Int64.rem i1 i2

  let logand i1 i2 = lift Int64.logand i1 i2

  let logor i1 i2 = lift Int64.logor i1 i2

  let logxor i1 i2 = lift Int64.logxor i1 i2

  let lognot i = lift1 Int64.lognot i

  let sub i1 i2 = add i1 (neg i2)

  let pp f (unsigned, n, ptr) =
    if ptr && n = 0L then F.fprintf f "null" else
    if unsigned then F.fprintf f "%Lu" n
    else F.fprintf f "%Ld" n

  let to_string i =
    Utils.pp_to_string pp i
end

(** Flags for a procedure call *)
type call_flags = {
  cf_virtual : bool;
  cf_noreturn : bool;
  cf_is_objc_block : bool;
}

let cf_default = { cf_virtual = false; cf_noreturn = false; cf_is_objc_block = false; }

(** expression representing the result of decompilation *)
type dexp =
  | Darray of dexp * dexp
  | Dbinop of binop * dexp * dexp
  | Dconst of const
  | Dsizeof of typ * Subtype.t
  | Dderef of dexp
  | Dfcall of dexp * dexp list * location * call_flags
  | Darrow of dexp * Ident.fieldname
  | Ddot of dexp * Ident.fieldname
  | Dpvar of pvar
  | Dpvaraddr of pvar
  | Dunop of unop * dexp
  | Dunknown
  | Dretcall of dexp * dexp list * location * call_flags

(** Value paths: identify an occurrence of a value in a symbolic heap
each expression represents a path, with Dpvar being the simplest one *)
and vpath =
  dexp option

(** acquire/release action on a resource *)
and res_action =
  { ra_kind : res_act_kind; (** kind of action *)
    ra_res : resource; (** kind of resource *)
    ra_pname : Procname.t; (** name of the procedure used to acquire/release the resource *)
    ra_loc : location; (** location of the acquire/release *)
    ra_vpath: vpath; (** vpath of the resource value *)
  }

(** Attributes *)
and attribute =
  | Aresource of res_action (** resource acquire/release *)
  | Aautorelease
  | Adangling of dangling_kind (** dangling pointer *)
  | Aundef of Procname.t * location * path_pos (** undefined value obtained by calling the given procedure *)
  | Ataint
  | Auntaint
  | Adiv0 of path_pos (** value appeared in second argument of division in path position *)
  | Aobjc_null of exp (** the exp. is null because of a call to a method with exp as a null receiver *)
  | Avariadic_function_argument of Procname.t * int * int (** (pn, n, i) the exp. is used as [i]th
                                                          argument of a call to the variadic
                                                          function [pn] that has [n] arguments *)
  | Aretval of Procname.t (** value was returned from a call to the given procedure *)

(** Categories of attributes *)
and attribute_category =
  | ACresource
  | ACautorelease
  | ACtaint
  | ACdiv0
  | ACobjc_null
  | ACvariadic_function_argument

(** Constants *)
and const =
  | Cint of Int.t (** integer constants *)
  | Cfun of Procname.t (** function names *)
  | Cstr of string (** string constants *)
  | Cfloat of float (** float constants *)
  | Cattribute of attribute (** attribute used in disequalities to annotate a value *)
  | Cexn of exp (** exception *)
  | Cclass of Ident.name (** class constant *)
  | Cptr_to_fld of Ident.fieldname * typ (** pointer to field constant, and type of the surrounding csu type *)
  | Ctuple of exp list (** tuple of values *)

and struct_fields = (Ident.fieldname * typ * item_annotation) list

(** types for sil (structured) expressions *)
and typ =
  | Tvar of typename  (** named type *)
  | Tint of ikind (** integer type *)
  | Tfloat of fkind (** float type *)
  | Tvoid (** void type *)
  | Tfun of bool (** function type with noreturn attribute *)
  | Tptr of typ * ptr_kind (** pointer type *)
  | Tstruct of struct_fields * struct_fields * csu * Mangled.t option * (csu * Mangled.t) list * Procname.t list * item_annotation (** structure type with class/struct/union flag and name and list of superclasses *)
  (** Structure type with nonstatic and static fields, class/struct/union flag, name, list of superclasses,
  methods defined, and annotations.
  The fld - typ pairs are always sorted. This means that we don't support programs that exploit specific layouts
  of C structs. *)
  | Tarray of typ * exp (** array type with fixed size *)
  | Tenum of (Mangled.t * const) list

(** program expressions *)
and exp =
  | Var of Ident.t (** pure variable: it is not an lvalue *)
  | UnOp of unop * exp * typ option (** unary operator with type of the result if known *)
  | BinOp of binop * exp * exp (** binary operator *)
  | Const of const  (** constants *)
  | Cast of typ * exp  (** type cast *)
  | Lvar of pvar  (** the address of a program variable *)
  | Lfield of exp * Ident.fieldname * typ (** a field offset, the type is the surrounding struct type *)
  | Lindex of exp * exp (** an array index offset: exp1[exp2] *)
  | Sizeof of typ * Subtype.t (** a sizeof expression *)

(** Unknown location *)
let loc_none =
  { line = - 1; col = - 1; file = DB.source_file_empty; nLOC = 0 }

(** Kind of prune instruction *)
type if_kind =
  | Ik_bexp (* boolean expressions, and exp ? exp : exp *)
  | Ik_dowhile
  | Ik_for
  | Ik_if
  | Ik_land_lor (* obtained from translation of && or || *)
  | Ik_while
  | Ik_switch

(** Stack operation for symbolic execution on propsets *)
type stackop =
  | Push (* copy the curreny propset to the stack *)
  | Swap (* swap the current propset and the top of the stack *)
  | Pop (* pop the stack and combine with the current propset *)

(** An instruction. *)
type instr =
  | Letderef of Ident.t * exp * typ * location (** declaration [let x = *lexp:typ] where [typ] is the root type of [lexp] *)
  | Set of exp * typ * exp * location (** assignment [*lexp1:typ = exp2] where [typ] is the root type of [lexp1] *)
  | Prune of exp * location * bool * if_kind (** prune the state based on [exp=1], the boolean indicates whether true branch *)
  | Call of Ident.t list * exp * (exp * typ) list * location * call_flags
  (** [Call (ret_id1..ret_idn, e_fun, arg_ts, loc, call_flags)] represents an instructions
  [ret_id1..ret_idn = e_fun(arg_ts);] where n = 0 for void return and n > 1 for struct return *)
  | Nullify of pvar * location * bool (** nullify stack variable, the bool parameter indicates whether to deallocate the variable *)
  | Abstract of location (** apply abstraction *)
  | Remove_temps of Ident.t list * location (** remove temporaries *)
  | Stackop of stackop * location (** operation on the stack of propsets *)
  | Declare_locals of (pvar * typ) list * location (** declare local variables *)
  | Goto_node of exp * location (** jump to a specific cfg node, assuming all the possible target nodes are successors of the current node *)

(** Check if an instruction is auxiliary, or if it comes from source instructions. *)
let instr_is_auxiliary = function
  | Letderef _ | Set _ | Prune _ | Call _ | Goto_node _ ->
      false
  | Nullify _ | Abstract _ | Remove_temps _ | Stackop _ | Declare_locals _ ->
      true

(** offset for an lvalue *)
type offset = Off_fld of Ident.fieldname * typ | Off_index of exp

(** {2 Components of Propositions} *)

(** an atom is a pure atomic formula *)
type atom =
  | Aeq of exp * exp (** equality *)
  | Aneq of exp * exp (** disequality*)

(** kind of lseg or dllseg predicates *)
type lseg_kind =
  | Lseg_NE (** nonempty (possibly circular) listseg *)
  | Lseg_PE (** possibly empty (possibly circular) listseg *)

(** The boolean is true when the pointer was dereferenced without testing for zero. *)
type zero_flag = bool option

(** True when the value was obtained by doing case analysis on null in a procedure call. *)
type null_case_flag = bool

(** instrumentation of heap values *)
type inst =
  | Iabstraction
  | Iactual_precondition
  | Ialloc
  | Iformal of zero_flag * null_case_flag
  | Iinitial
  | Ilookup
  | Inone
  | Inullify
  | Irearrange of zero_flag * null_case_flag * int * path_pos
  | Itaint
  | Iupdate of zero_flag * null_case_flag * int * path_pos
  | Ireturn_from_call of int

(** structured expressions represent a value of structured type, such as an array or a struct. *)
type strexp =
  | Eexp of exp * inst  (** Base case: expression with instrumentation *)
  | Estruct of (Ident.fieldname * strexp) list * inst  (** C structure *)
  | Earray of exp * (exp * strexp) list * inst  (** Array of given size. *)
(** There are two conditions imposed / used in the array case.
First, if some index and value pair appears inside an array
in a strexp, then the index is less than the size of the array.
For instance, x |->[10 | e1: v1] implies that e1 <= 9.
Second, if two indices appear in an array, they should be different.
For instance, x |->[10 | e1: v1, e2: v2] implies that e1 != e2. *)

(** an atomic heap predicate *)
and hpred =
  | Hpointsto of exp * strexp * exp
  (** represents [exp|->strexp:typexp] where [typexp]
  is an expression representing a type, e.h. [sizeof(t)]. *)
  | Hlseg of lseg_kind * hpara * exp * exp * exp list
  (** higher - order predicate for singly - linked lists.
  Should ensure that exp1!= exp2 implies that exp1 is allocated.
  This assumption is used in the rearrangement. The last [exp list] parameter
  is used to denote the shared links by all the nodes in the list. *)
  | Hdllseg of lseg_kind * hpara_dll * exp * exp * exp * exp * exp list
(** higher-order predicate for doubly-linked lists. *)

(** parameter for the higher-order singly-linked list predicate.
Means "lambda (root,next,svars). Exists evars. body".
Assume that root, next, svars, evars are disjoint sets of
primed identifiers, and include all the free primed identifiers in body.
body should not contain any non - primed identifiers or program
variables (i.e. pvars). *)
and hpara =
  { root: Ident.t;
    next: Ident.t;
    svars: Ident.t list;
    evars: Ident.t list;
    body: hpred list }

(** parameter for the higher-order doubly-linked list predicates.
Assume that all the free identifiers in body_dll should belong to
cell, blink, flink, svars_dll, evars_dll. *)
and hpara_dll =
  { cell: Ident.t;  (** address cell *)
    blink: Ident.t;  (** backward link *)
    flink: Ident.t;  (** forward link *)
    svars_dll: Ident.t list;
    evars_dll: Ident.t list;
    body_dll: hpred list }

(** Return the lhs expression of a hpred *)
let hpred_get_lhs h =
  match h with
  | Hpointsto (e, _, _)
  | Hlseg(_, _, e, _, _)
  | Hdllseg(_, _, e, _, _, _, _) -> e

let objc_ref_counter_annot =
  [({ class_name = "ref_counter"; parameters = []}, false)]

(** Field used for objective-c reference counting *)
let objc_ref_counter_field =
  (Ident.fieldname_hidden, Tint IInt, objc_ref_counter_annot)

(** {2 Comparision and Inspection Functions} *)

let is_objc_ref_counter_field (fld, t, a) =
  Ident.fieldname_is_hidden fld && (item_annotation_compare a objc_ref_counter_annot = 0)

let has_objc_ref_counter hpred =
  match hpred with
  | Hpointsto(_, _, Sizeof(Tstruct(fl, _, _, _, _, _, _), _)) ->
      list_exists is_objc_ref_counter_field fl
  | _ -> false

(** turn a *T into a T. fails if [typ] is not a pointer type *)
let typ_strip_ptr = function
  | Tptr (t, _) -> t
  | _ -> assert false

let pvar_get_name pv = pv.pv_name

let pvar_to_string pv = Mangled.to_string pv.pv_name

let pvar_get_simplified_name pv =
  let s = Mangled.to_string pv.pv_name in
  match string_split_character s '.' with
  | Some s1, s2 ->
      (match string_split_character s1 '.' with
        | Some s3, s4 -> s4 ^ "." ^ s2
        | _ -> s)
  | _ -> s

(** Check if the pvar is an abucted return var or param passed by ref *)
let pvar_is_abducted pv =
  match pv.pv_kind with
  | Abducted_retvar _ | Abducted_ref_param _ -> true
  | _ -> false

(** Turn a pvar into a seed pvar (which stored the initial value) *)
let pvar_to_seed pv = { pv with pv_kind = Seed_var }

(** Check if the pvar is a local var *)
let pvar_is_local pv =
  match pv.pv_kind with
  | Local_var _ -> true
  | _ -> false

(** Check if the pvar is a callee var *)
let pvar_is_callee pv =
  match pv.pv_kind with
  | Callee_var _ -> true
  | _ -> false

(** Check if the pvar is a seed var *)
let pvar_is_seed pv =
  match pv.pv_kind with
  | Seed_var -> true
  | _ -> false

(** Check if the pvar is a global var *)
let pvar_is_global pv =
  pv.pv_kind = Global_var

(** Check if a pvar is the special "this" var *)
let pvar_is_this pvar =
  Mangled.equal (pvar_get_name pvar) (Mangled.from_string "this")

(** Check if the pvar is a return var *)
let pvar_is_return pv =
  pvar_get_name pv = Ident.name_return

(** Make a static local name in objc *)
let mk_static_local_name pname vname =
  pname^"_"^vname

(** Check if a pvar is a local static in objc *)
let is_static_local_name pname pvar = (* local static name is of the form procname_varname *)
  let var_name = Mangled.to_string(pvar_get_name pvar) in
  match Str.split_delim (Str.regexp_string pname) var_name with
  | [s1; s2] -> true
  | _ -> false

let loc_compare loc1 loc2 =
  let n = int_compare loc1.line loc2.line in
  if n <> 0 then n else DB.source_file_compare loc1.file loc2.file

let loc_equal loc1 loc2 =
  loc_compare loc1 loc2 = 0

let rec pv_kind_compare k1 k2 = match k1, k2 with
  | Local_var n1, Local_var n2 -> Procname.compare n1 n2
  | Local_var _, _ -> - 1
  | _, Local_var _ -> 1
  | Callee_var n1, Callee_var n2 -> Procname.compare n1 n2
  | Callee_var _, _ -> - 1
  | _, Callee_var _ -> 1
  | Abducted_retvar (p1, l1), Abducted_retvar (p2, l2) ->
      let n = Procname.compare p1 p2 in
      if n <> 0 then n else loc_compare l1 l2
  | Abducted_retvar _, _ -> - 1
  | _, Abducted_retvar _ -> 1
  | Abducted_ref_param (p1, pv1, l1), Abducted_ref_param (p2, pv2, l2) ->
      let n = Procname.compare p1 p2 in
      if n <> 0 then n else
        let n = pvar_compare pv1 pv2 in
        if n <> 0 then n else loc_compare l1 l2
  | Abducted_ref_param _, _ -> - 1
  | _, Abducted_ref_param _ -> 1
  | Global_var, Global_var -> 0
  | Global_var, _ -> - 1
  | _, Global_var -> 1
  | Seed_var, Seed_var -> 0

and pvar_compare pv1 pv2 =
  let n = Mangled.compare pv1.pv_name pv2.pv_name in
  if n <> 0 then n else pv_kind_compare pv1.pv_kind pv2.pv_kind

let pvar_equal pvar1 pvar2 =
  pvar_compare pvar1 pvar2 = 0

let fld_compare (fld1 : Ident.fieldname) fld2 = Ident.fieldname_compare fld1 fld2

let fld_equal fld1 fld2 = fld_compare fld1 fld2 = 0

let exp_is_null_literal = function
  | Const (Cint n) -> Int.isnull n
  | _ -> false

let exp_is_this = function
  | Lvar pvar -> pvar_is_this pvar
  | _ -> false

let ikind_is_char = function
  | IChar | ISChar | IUChar -> true
  | _ -> false

let ikind_is_unsigned = function
  | IUChar | IUInt | IUShort | IULong | IULongLong -> true
  | _ -> false

let int_of_int64_kind i ik =
  Int.of_int64_unsigned i (ikind_is_unsigned ik)

let unop_compare o1 o2 = match o1, o2 with
  | Neg, Neg -> 0
  | Neg, _ -> - 1
  | _, Neg -> 1
  | BNot, BNot -> 0
  | BNot, _ -> - 1
  | _, BNot -> 1
  | LNot, LNot -> 0

let unop_equal o1 o2 = unop_compare o1 o2 = 0

let binop_compare o1 o2 = match o1, o2 with
  | PlusA, PlusA -> 0
  | PlusA, _ -> - 1
  | _, PlusA -> 1
  | PlusPI, PlusPI -> 0
  | PlusPI, _ -> - 1
  | _, PlusPI -> 1
  | MinusA, MinusA -> 0
  | MinusA, _ -> - 1
  | _, MinusA -> 1
  | MinusPI, MinusPI -> 0
  | MinusPI, _ -> - 1
  | _, MinusPI -> 1
  | MinusPP, MinusPP -> 0
  | MinusPP, _ -> - 1
  | _, MinusPP -> 1
  | Mult, Mult -> 0
  | Mult, _ -> - 1
  | _, Mult -> 1
  | Div, Div -> 0
  | Div, _ -> - 1
  | _, Div -> 1
  | Mod, Mod -> 0
  | Mod, _ -> - 1
  | _, Mod -> 1
  | Shiftlt, Shiftlt -> 0
  | Shiftlt, _ -> - 1
  | _, Shiftlt -> 1
  | Shiftrt, Shiftrt -> 0
  | Shiftrt, _ -> - 1
  | _, Shiftrt -> 1
  | Lt, Lt -> 0
  | Lt, _ -> - 1
  | _, Lt -> 1
  | Gt, Gt -> 0
  | Gt, _ -> - 1
  | _, Gt -> 1
  | Le, Le -> 0
  | Le, _ -> - 1
  | _, Le -> 1
  | Ge, Ge -> 0
  | Ge, _ -> - 1
  | _, Ge -> 1
  | Eq, Eq -> 0
  | Eq, _ -> - 1
  | _, Eq -> 1
  | Ne, Ne -> 0
  | Ne, _ -> - 1
  | _, Ne -> 1
  | BAnd, BAnd -> 0
  | BAnd, _ -> - 1
  | _, BAnd -> 1
  | BXor, BXor -> 0
  | BXor, _ -> - 1
  | _, BXor -> 1
  | BOr, BOr -> 0
  | BOr, _ -> - 1
  | _, BOr -> 1
  | LAnd, LAnd -> 0
  | LAnd, _ -> - 1
  | _, LAnd -> 1
  | LOr, LOr -> 0
  | LOr, _ -> -1
  | _, LOr -> 1
  | PtrFld, PtrFld -> 0

let binop_equal o1 o2 = binop_compare o1 o2 = 0

(** This function returns true if the operation is injective
wrt. each argument: op(e,-) and op(-, e) is injective for all e.
The return value false means "don't know". *)
let binop_injective = function
  | PlusA | PlusPI | MinusA | MinusPI | MinusPP -> true
  | _ -> false

(** This function returns true if the operation can be inverted. *)
let binop_invertible = function
  | PlusA | PlusPI | MinusA | MinusPI -> true
  | _ -> false

(** This function inverts an injective binary operator
with respect to the first argument. It returns an expression [e'] such that
BinOp([binop], [e'], [exp1]) = [exp2]. If the [binop] operation is not invertible,
the function raises an exception by calling "assert false". *)
let binop_invert bop e1 e2 =
  let inverted_bop = match bop with
    | PlusA -> MinusA
    | PlusPI -> MinusPI
    | MinusA -> PlusA
    | MinusPI -> PlusPI
    | _ -> assert false in
  BinOp(inverted_bop, e2, e1)

(** This function returns true if 0 is the right unit of [binop].
The return value false means "don't know". *)
let binop_is_zero_runit = function
  | PlusA | PlusPI | MinusA | MinusPI | MinusPP -> true
  | _ -> false

let path_pos_compare (pn1, nid1) (pn2, nid2) =
  let n = Procname.compare pn1 pn2 in
  if n <> 0 then n else int_compare nid1 nid2

let path_pos_equal pp1 pp2 =
  path_pos_compare pp1 pp2 = 0

let mem_kind_to_num = function
  | Mmalloc -> 0
  | Mnew -> 1
  | Mnew_array -> 2
  | Mobjc -> 3

(** name of the allocation function for the given memory kind *)
let mem_alloc_pname = function
  | Mmalloc -> Procname.from_string "malloc"
  | Mnew -> Procname.from_string "new"
  | Mnew_array -> Procname.from_string "new[]"
  | Mobjc -> Procname.from_string "alloc"

(** name of the deallocation function for the given memory kind *)
let mem_dealloc_pname = function
  | Mmalloc -> Procname.from_string "free"
  | Mnew -> Procname.from_string "delete"
  | Mnew_array -> Procname.from_string "delete[]"
  | Mobjc -> Procname.from_string "dealloc"

let mem_kind_compare mk1 mk2 =
  int_compare (mem_kind_to_num mk1) (mem_kind_to_num mk2)

let resource_compare r1 r2 =
  let res_to_num = function
    | Rmemory mk -> mem_kind_to_num mk
    | Rfile -> 100
    | Rignore -> 200
    | Rlock -> 300 in
  int_compare (res_to_num r1) (res_to_num r2)

let res_act_kind_compare rak1 rak2 = match rak1, rak2 with
  | Racquire, Racquire -> 0
  | Racquire, Rrelease -> - 1
  | Rrelease, Racquire -> 1
  | Rrelease, Rrelease -> 0

let dangling_kind_compare dk1 dk2 = match dk1, dk2 with
  | DAuninit, DAuninit -> 0
  | DAuninit, _ -> - 1
  | _, DAuninit -> 1
  | DAaddr_stack_var, DAaddr_stack_var -> 0
  | DAaddr_stack_var, _ -> - 1
  | _, DAaddr_stack_var -> 1
  | DAminusone, DAminusone -> 0

let attribute_category_compare (ac1 : attribute_category) (ac2 : attribute_category) : int =
  Pervasives.compare ac1 ac2

let attribute_category_equal att1 att2 =
  attribute_category_compare att1 att2 = 0

let attribute_to_category att =
  match att with
  | Aresource _
  | Adangling _
  | Aretval _
  | Aundef _ -> ACresource
  | Ataint
  | Auntaint -> ACtaint
  | Aautorelease -> ACautorelease
  | Adiv0 _ -> ACdiv0
  | Aobjc_null _ -> ACobjc_null
  | Avariadic_function_argument _ -> ACvariadic_function_argument

let cname_opt_compare nameo1 nameo2 = match nameo1, nameo2 with
  | None, None -> 0
  | None, _ -> - 1
  | _, None -> 1
  | Some n1, Some n2 -> Mangled.compare n1 n2

(** comparison for ikind *)
let ikind_compare k1 k2 = match k1, k2 with
  | IChar, IChar -> 0
  | IChar, _ -> - 1
  | _, IChar -> 1
  | ISChar, ISChar -> 0
  | ISChar, _ -> - 1
  | _, ISChar -> 1
  | IUChar, IUChar -> 0
  | IUChar, _ -> - 1
  | _, IUChar -> 1
  | IBool, IBool -> 0
  | IBool, _ -> - 1
  | _, IBool -> 1
  | IInt, IInt -> 0
  | IInt, _ -> - 1
  | _, IInt -> 1
  | IUInt, IUInt -> 0
  | IUInt, _ -> - 1
  | _, IUInt -> 1
  | IShort, IShort -> 0
  | IShort, _ -> - 1
  | _, IShort -> 1
  | IUShort, IUShort -> 0
  | IUShort, _ -> - 1
  | _, IUShort -> 1
  | ILong, ILong -> 0
  | ILong, _ -> - 1
  | _, ILong -> 1
  | IULong, IULong -> 0
  | IULong, _ -> - 1
  | _, IULong -> 1
  | ILongLong, ILongLong -> 0
  | ILongLong, _ -> - 1
  | _, ILongLong -> 1
  | IULongLong, IULongLong -> 0
  | IULongLong, _ -> -1
  | _, IULongLong -> 1
  | I128, I128 -> 0
  | I128, _ -> -1
  | _, I128 -> 1
  | IU128, IU128 -> 0

(** comparison for fkind *)
let fkind_compare k1 k2 = match k1, k2 with
  | FFloat, FFloat -> 0
  | FFloat, _ -> - 1
  | _, FFloat -> 1
  | FDouble, FDouble -> 0
  | FDouble, _ -> - 1
  | _, FDouble -> 1
  | FLongDouble, FLongDouble -> 0

let csu_compare csu1 csu2 = match csu1, csu2 with
  | Class, Class -> 0
  | Class, _ -> -1
  | _, Class -> 1
  | Struct, Struct -> 0
  | Struct, _ -> -1
  | _, Struct -> 1
  | Union, Union -> 0
  | Union, _ -> -1
  | _, Union -> 1
  | Protocol, Protocol -> 0

let typename_compare tn1 tn2 = match tn1, tn2 with
  | TN_typedef n1, TN_typedef n2 -> Mangled.compare n1 n2
  | TN_typedef _, _ -> - 1
  | _, TN_typedef _ -> 1
  | TN_enum n1, TN_enum n2 -> Mangled.compare n1 n2
  | TN_enum _, _ -> -1
  | _, TN_enum _ -> 1
  | TN_csu (csu1, n1), TN_csu (csu2, n2) ->
      let n = csu_compare csu1 csu2 in
      if n <> 0 then n else Mangled.compare n1 n2

let csu_name_compare tn1 tn2 = match tn1, tn2 with
  | (csu1, n1), (csu2, n2) ->
      let n = csu_compare csu1 csu2 in
      if n <> 0 then n else Mangled.compare n1 n2

let csu_name_equal tn1 tn2 =
  csu_name_compare tn1 tn2 = 0

let typename_equal tn1 tn2 =
  typename_compare tn1 tn2 = 0

let ptr_kind_compare pk1 pk2 = match pk1, pk2 with
  | Pk_pointer, Pk_pointer -> 0
  | Pk_pointer, _ -> -1
  | _, Pk_pointer -> 1
  | Pk_reference, Pk_reference -> 0
  | _ , Pk_reference -> -1
  | Pk_reference, _ -> 1
  | Pk_objc_weak, Pk_objc_weak -> 0
  | Pk_objc_weak, _ -> -1
  | _, Pk_objc_weak -> 1
  | Pk_objc_unsafe_unretained, Pk_objc_unsafe_unretained -> 0
  | Pk_objc_unsafe_unretained, _ -> -1
  | _, Pk_objc_unsafe_unretained -> 1
  | Pk_objc_autoreleasing, Pk_objc_autoreleasing -> 0

let const_kind_equal c1 c2 =
  let const_kind_number = function
    | Cint _ -> 1
    | Cfun _ -> 2
    | Cstr _ -> 3
    | Cfloat _ -> 4
    | Cattribute _ -> 5
    | Cexn _ -> 6
    | Cclass _ -> 7
    | Cptr_to_fld _ -> 8
    | Ctuple _ -> 9 in
  const_kind_number c1 = const_kind_number c2

let rec const_compare (c1 : const) (c2 : const) : int =
  match (c1, c2) with
  | Cint i1, Cint i2 -> Int.compare i1 i2
  | Cint _, _ -> - 1
  | _, Cint _ -> 1
  | Cfun fn1, Cfun fn2 -> Procname.compare fn1 fn2
  | Cfun _, _ -> - 1
  | _, Cfun _ -> 1
  | Cstr s1, Cstr s2 -> string_compare s1 s2
  | Cstr _, _ -> - 1
  | _, Cstr _ -> 1
  | Cfloat f1, Cfloat f2 -> float_compare f1 f2
  | Cfloat _, _ -> - 1
  | _, Cfloat _ -> 1
  | Cattribute att1, Cattribute att2 -> attribute_compare att1 att2
  | Cattribute _, _ -> -1
  | _, Cattribute _ -> 1
  | Cexn e1, Cexn e2 -> exp_compare e1 e2
  | Cexn _, _ -> -1
  | _, Cexn _ -> 1
  | Cclass c1, Cclass c2 -> Ident.name_compare c1 c2
  | Cclass _, _ -> -1
  | _, Cclass _ -> 1
  | Cptr_to_fld (fn1, t1), Cptr_to_fld (fn2, t2) ->
      let n = fld_compare fn1 fn2 in
      if n <> 0 then n else typ_compare t1 t2
  | Cptr_to_fld _, _ -> -1
  | _, Cptr_to_fld _ -> 1
  | Ctuple el1, Ctuple el2 -> list_compare exp_compare el1 el2

(** Comparision for types. *)
and typ_compare t1 t2 =
  if t1 == t2 then 0 else match t1, t2 with
    | Tvar tn1, Tvar tn2 -> typename_compare tn1 tn2
    | Tvar _, _ -> - 1
    | _, Tvar _ -> 1
    | Tint ik1, Tint ik2 -> ikind_compare ik1 ik2
    | Tint _, _ -> - 1
    | _, Tint _ -> 1
    | Tfloat fk1, Tfloat fk2 -> fkind_compare fk1 fk2
    | Tfloat _, _ -> - 1
    | _, Tfloat _ -> 1
    | Tvoid, Tvoid -> 0
    | Tvoid, _ -> - 1
    | _, Tvoid -> 1
    | Tfun noreturn1, Tfun noreturn2 -> bool_compare noreturn1 noreturn2
    | Tfun _, _ -> - 1
    | _, Tfun _ -> 1
    | Tptr (t1', pk1), Tptr (t2', pk2) ->
        let n = typ_compare t1' t2' in
        if n <> 0 then n else ptr_kind_compare pk1 pk2
    | Tptr _, _ -> - 1
    | _, Tptr _ -> 1
    | Tstruct (ntal1, sntal1, csu1, nameo1, _, _, _), Tstruct (ntal2, sntal2, csu2, nameo2, _, _, _) ->
        let n = fld_typ_ann_list_compare ntal1 ntal2 in
        if n <> 0 then n else let n = fld_typ_ann_list_compare sntal1 sntal2 in
          if n <> 0 then n else let n = csu_compare csu1 csu2 in
            if n <> 0 then n else cname_opt_compare nameo1 nameo2
    | Tstruct _, _ -> - 1
    | _, Tstruct _ -> 1
    | Tarray (t1, _), Tarray (t2, _) -> typ_compare t1 t2
    | Tarray _, _ -> -1
    | _, Tarray _ -> 1
    | Tenum l1, Tenum l2 ->
    (* Here we take as result the first non-zero result when comparing their (constant,value) pair.*)
        let compare_pair (n1, e1) (n2, e2) =
          let n = Mangled.compare n1 n2 in
          if n <> 0 then n else const_compare e1 e2 in
        list_compare compare_pair l1 l2

and typ_opt_compare to1 to2 = match to1, to2 with
  | None, None -> 0
  | None, Some _ -> - 1
  | Some _, None -> 1
  | Some t1, Some t2 -> typ_compare t1 t2

and fld_typ_ann_compare fta1 fta2 =
  triple_compare fld_compare typ_compare item_annotation_compare fta1 fta2

and fld_typ_ann_list_compare ftal1 ftal2 =
  list_compare fld_typ_ann_compare ftal1 ftal2

and attribute_compare (att1 : attribute) (att2 : attribute) : int =
  match att1, att2 with
  | Aresource ra1, Aresource ra2 ->
      let n = res_act_kind_compare ra1.ra_kind ra2.ra_kind in
      if n <> 0 then n else resource_compare ra1.ra_res ra2.ra_res (* ignore other values beside resources: arbitrary merging into one *)
  | Aresource _, _ -> - 1
  | _, Aresource _ -> 1
  | Aautorelease, Aautorelease -> 0
  | Aautorelease, _ -> -1
  | _, Aautorelease -> 1
  | Adangling dk1, Adangling dk2 -> dangling_kind_compare dk1 dk2
  | Adangling _, _ -> - 1
  | _, Adangling _ -> 1
  | Aundef (pn1, _, _), Aundef (pn2, _, _) -> Procname.compare pn1 pn2
  | Ataint, Ataint -> 0
  | Ataint, _ -> -1
  | _, Ataint -> 1
  | Auntaint, Auntaint -> 0
  | Auntaint, _ -> -1
  | _, Auntaint -> 1
  | Adiv0 pp1, Adiv0 pp2 ->
      path_pos_compare pp1 pp2
  | Adiv0 _, _ -> -1
  | _, Adiv0 _ -> 1
  | Aobjc_null exp1, Aobjc_null exp2 ->
      exp_compare exp1 exp2
  | Aobjc_null _, _ -> -1
  | _, Aobjc_null _ -> 1
  | Avariadic_function_argument (pn1, n1, i1), Avariadic_function_argument (pn2, n2, i2) ->
      Procname.compare pn1 pn2
      |> next int_compare n1 n2
      |> next int_compare i1 i2
  | Avariadic_function_argument _, _ -> -1
  | _, Avariadic_function_argument _ -> 1
  | Aretval pn1, Aretval pn2 -> Procname.compare pn1 pn2
  | Aretval _, _ -> -1
  | _, Aretval _ -> 1

(** Compare epressions. Variables come before other expressions. *)
and exp_compare (e1 : exp) (e2 : exp) : int =
  match (e1, e2) with
  | Var id1, Var id2 ->
      Ident.compare id2 id1
  | Var _, _ -> - 1
  | _, Var _ -> 1
  | UnOp (o1, e1, to1), UnOp (o2, e2, to2) ->
      let n = unop_compare o1 o2 in
      if n <> 0 then n else
        let n = exp_compare e1 e2 in
        if n <> 0 then n else typ_opt_compare to1 to2
  | UnOp _, _ -> - 1
  | _, UnOp _ -> 1
  | BinOp (o1, e1, f1), BinOp (o2, e2, f2) ->
      let n = binop_compare o1 o2 in
      if n <> 0 then n
      else
        let n = exp_compare e1 e2 in
        if n <> 0 then n else exp_compare f1 f2
  | BinOp _, _ -> - 1
  | _, BinOp _ -> 1
  | Const c1, Const c2 ->
      const_compare c1 c2
  | Const _, _ -> - 1
  | _, Const _ -> 1
  | Cast (t1, e1), Cast(t2, e2) ->
      let n = exp_compare e1 e2 in
      if n <> 0 then n else typ_compare t1 t2
  | Cast _, _ -> - 1
  | _, Cast _ -> 1
  | Lvar i1, Lvar i2 ->
      pvar_compare i1 i2
  | Lvar _, _ -> - 1
  | _, Lvar _ -> 1
  | Lfield (e1, f1, t1), Lfield (e2, f2, t2) ->
      let n = exp_compare e1 e2 in
      if n <> 0 then n else
        let n = fld_compare f1 f2 in
        if n <> 0 then n else typ_compare t1 t2
  | Lfield _, _ -> - 1
  | _, Lfield _ -> 1
  | Lindex (e1, f1), Lindex (e2, f2) ->
      let n = exp_compare e1 e2 in
      if n <> 0 then n else exp_compare f1 f2
  | Lindex _, _ -> - 1
  | _, Lindex _ -> 1
  | Sizeof (t1, s1), Sizeof (t2, s2) ->
      let n = typ_compare t1 t2 in
      if n <> 0 then n else Subtype.compare s1 s2

let const_equal c1 c2 =
  const_compare c1 c2 = 0

let typ_equal t1 t2 =
  (typ_compare t1 t2 = 0)

let exp_equal e1 e2 =
  exp_compare e1 e2 = 0

let ident_exp_compare =
  pair_compare Ident.compare exp_compare

let ident_exp_equal ide1 ide2 =
  ident_exp_compare ide1 ide2 = 0

let exp_list_compare =
  list_compare exp_compare

let exp_list_equal el1 el2 =
  exp_list_compare el1 el2 = 0

let attribute_equal att1 att2 =
  attribute_compare att1 att2 = 0

(** Compare atoms. Equalities come before disequalities *)
let atom_compare a b =
  if a == b then 0 else
    match (a, b) with
    | Aeq (e1, e2), Aeq(f1, f2) ->
        let n = exp_compare e1 f1 in
        if n <> 0 then n else exp_compare e2 f2
    | Aeq _, Aneq _ -> - 1
    | Aneq _, Aeq _ -> 1
    | Aneq (e1, e2), Aneq (f1, f2) ->
        let n = exp_compare e1 f1 in
        if n <> 0 then n else exp_compare e2 f2

let atom_equal x y =
  atom_compare x y = 0

let atom_list_compare l1 l2 =
  list_compare atom_compare l1 l2

let lseg_kind_compare k1 k2 = match k1, k2 with
  | Lseg_NE, Lseg_NE -> 0
  | Lseg_NE, Lseg_PE -> - 1
  | Lseg_PE, Lseg_NE -> 1
  | Lseg_PE, Lseg_PE -> 0

let lseg_kind_equal k1 k2 =
  lseg_kind_compare k1 k2 = 0

(* Comparison for strexps *)
let rec strexp_compare se1 se2 =
  if se1 == se2 then 0
  else match se1, se2 with
    | Eexp (e1, inst1), Eexp (e2, inst2) -> exp_compare e1 e2
    | Eexp _, _ -> - 1
    | _, Eexp _ -> 1
    | Estruct (fel1, inst1), Estruct (fel2, inst2) -> fld_strexp_list_compare fel1 fel2
    | Estruct _, _ -> - 1
    | _, Estruct _ -> 1
    | Earray (e1, esel1, inst1), Earray (e2, esel2, inst2) ->
        let n = exp_compare e1 e2 in
        if n <> 0 then n else exp_strexp_list_compare esel1 esel2

and fld_strexp_compare fse1 fse2 =
  pair_compare fld_compare strexp_compare fse1 fse2

and fld_strexp_list_compare fsel1 fsel2 =
  list_compare fld_strexp_compare fsel1 fsel2

and exp_strexp_compare ese1 ese2 =
  pair_compare exp_compare strexp_compare ese1 ese2

and exp_strexp_list_compare esel1 esel2 =
  list_compare exp_strexp_compare esel1 esel2

(** Comparsion between heap predicates. Hpointsto comes before others. *)
and hpred_compare hpred1 hpred2 =
  if hpred1 == hpred2 then 0 else
    match (hpred1, hpred2) with
    | Hpointsto (e1, _, _), Hlseg(_, _, e2, _, _) when exp_compare e2 e1 <> 0 ->
        exp_compare e2 e1
    | Hpointsto (e1, _, _), Hdllseg(_, _, e2, _, _, _, _) when exp_compare e2 e1 <> 0 ->
        exp_compare e2 e1
    | Hlseg(_, _, e1, _, _), Hpointsto (e2, _, _) when exp_compare e2 e1 <> 0 ->
        exp_compare e2 e1
    | Hlseg(_, _, e1, _, _), Hdllseg(_, _, e2, _, _, _, _) when exp_compare e2 e1 <> 0 ->
        exp_compare e2 e1
    | Hdllseg(_, _, e1, _, _, _, _), Hpointsto (e2, _, _) when exp_compare e2 e1 <> 0 ->
        exp_compare e2 e1
    | Hdllseg(_, _, e1, _, _, _, _), Hlseg(_, _, e2, _, _) when exp_compare e2 e1 <> 0 ->
        exp_compare e2 e1
    | Hpointsto (e1, se1, te1), Hpointsto (e2, se2, te2) ->
        let n = exp_compare e2 e1 in
        if n <> 0 then n else
          let n = strexp_compare se2 se1 in
          if n <> 0 then n else exp_compare te2 te1
    | Hpointsto _, _ -> - 1
    | _, Hpointsto _ -> 1
    | Hlseg (k1, hpar1, e1, f1, el1), Hlseg (k2, hpar2, e2, f2, el2) ->
        let n = exp_compare e2 e1 in
        if n <> 0 then n
        else let n = lseg_kind_compare k2 k1 in
          if n <> 0 then n
          else let n = hpara_compare hpar2 hpar1 in
            if n <> 0 then n
            else let n = exp_compare f2 f1 in
              if n <> 0 then n
              else exp_list_compare el2 el1
    | Hlseg _, Hdllseg _ -> - 1
    | Hdllseg _, Hlseg _ -> 1
    | Hdllseg (k1, hpar1, e1, f1, g1, h1, el1), Hdllseg (k2, hpar2, e2, f2, g2, h2, el2) ->
        let n = exp_compare e2 e1 in
        if n <> 0 then n
        else let n = lseg_kind_compare k2 k1 in
          if n <> 0 then n
          else let n = hpara_dll_compare hpar2 hpar1 in
            if n <> 0 then n
            else let n = exp_compare f2 f1 in
              if n <> 0 then n
              else let n = exp_compare g2 g1 in
                if n <> 0 then n
                else let n = exp_compare h2 h1 in
                  if n <> 0 then n
                  else exp_list_compare el2 el1

and hpred_list_compare l1 l2 =
  list_compare hpred_compare l1 l2

and hpara_compare hp1 hp2 =
  let n = Ident.compare hp1.root hp2.root in
  if n <> 0 then n
  else let n = Ident.compare hp1.next hp2.next in
    if n <> 0 then n
    else let n = Ident.ident_list_compare hp1.svars hp2.svars in
      if n <> 0 then n
      else let n = Ident.ident_list_compare hp1.evars hp2.evars in
        if n <> 0 then n
        else hpred_list_compare hp1.body hp2.body

and hpara_dll_compare hp1 hp2 =
  let n = Ident.compare hp1.cell hp2.cell in
  if n <> 0 then n
  else let n = Ident.compare hp1.blink hp2.blink in
    if n <> 0 then n
    else let n = Ident.compare hp1.flink hp2.flink in
      if n <> 0 then n
      else let n = Ident.ident_list_compare hp1.svars_dll hp2.svars_dll in
        if n <> 0 then n
        else let n = Ident.ident_list_compare hp1.evars_dll hp2.evars_dll in
          if n <> 0 then n
          else hpred_list_compare hp1.body_dll hp2.body_dll

let strexp_equal se1 se2 =
  (strexp_compare se1 se2 = 0)

let fld_strexp_equal fld_sexp1 fld_sexp2 =
  (fld_strexp_compare fld_sexp1 fld_sexp2 = 0)

let exp_strexp_equal ese1 ese2 =
  (exp_strexp_compare ese1 ese2 = 0)

let hpred_equal hpred1 hpred2 =
  (hpred_compare hpred1 hpred2 = 0)

let hpara_equal hpara1 hpara2 =
  (hpara_compare hpara1 hpara2 = 0)

let hpara_dll_equal hpara1 hpara2 =
  (hpara_dll_compare hpara1 hpara2 = 0)

(** {2 Sets and maps of types} *)
module TypSet = Set.Make(struct
    type t = typ
    let compare = typ_compare
  end)

module TypMap = Map.Make(struct
    type t = typ
    let compare = typ_compare
  end)

(** {2 Sets of expressions} *)

module ExpSet = Set.Make
  (struct
    type t = exp
    let compare = exp_compare
  end)

let elist_to_eset es =
  list_fold_left (fun set e -> ExpSet.add e set) ExpSet.empty es

(** {2 Sets of heap predicates} *)

module HpredSet = Set.Make
  (struct
    type t = hpred
    let compare = hpred_compare
  end)

(** {2 Pretty Printing} *)

(** Begin change color if using diff printing, return updated printenv and change status *)
let color_pre_wrapper pe f x =
  if !Config.print_using_diff && pe.pe_kind != PP_TEXT then begin
    let color = pe.pe_cmap_norm (Obj.repr x) in
    if color != pe.pe_color then begin
      (if pe.pe_kind == PP_HTML then Io_infer.Html.pp_start_color else Latex.pp_color) f color;
      if color == Red then ({ pe with pe_cmap_norm = colormap_red; pe_color = Red }, true) (** Al subexpressiona red *)
      else ({ pe with pe_color = color }, true) end
    else (pe, false) end
  else (pe, false)

(** Close color annotation if changed *)
let color_post_wrapper changed pe f =
  if changed then (if pe.pe_kind == PP_HTML then Io_infer.Html.pp_end_color f () else Latex.pp_color f pe.pe_color)

(** Print a sequence with difference mode if enabled. *)
let pp_seq_diff pp pe0 f =
  if not !Config.print_using_diff
  then pp_comma_seq pp f
  else
    let rec doit = function
      | [] -> ()
      | [x] ->
          let pe, changed = color_pre_wrapper pe0 f x in
          F.fprintf f "%a" pp x;
          color_post_wrapper changed pe0 f
      | x :: l ->
          let pe, changed = color_pre_wrapper pe0 f x in
          F.fprintf f "%a" pp x;
          color_post_wrapper changed pe0 f;
          F.fprintf f ", ";
          doit l in
    doit

let text_binop = function
  | PlusA -> "+"
  | PlusPI -> "+"
  | MinusA | MinusPP -> "-"
  | MinusPI -> "-"
  | Mult -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Shiftlt -> "<<"
  | Shiftrt -> ">>"
  | Lt -> "<"
  | Gt -> ">"
  | Le -> "<="
  | Ge -> ">="
  | Eq -> "=="
  | Ne -> "!="
  | BAnd -> "&"
  | BXor -> "^"
  | BOr -> "|"
  | LAnd -> "&&"
  | LOr -> "||"
  | PtrFld -> "_ptrfld_"

(** String representation of unary operator. *)
let str_unop = function
  | Neg -> "-"
  | BNot -> "~"
  | LNot -> "!"

(** Pretty print a binary operator. *)
let str_binop pe binop =
  match pe.pe_kind with
  | PP_HTML ->
      begin
        match binop with
        | Ge -> " &gt;= "
        | Le -> " &lt;= "
        | Gt -> " &gt; "
        | Lt -> " &lt; "
        | Shiftlt -> " &lt;&lt; "
        | Shiftrt -> " &gt;&gt; "
        | _ -> text_binop binop
      end
  | PP_LATEX ->
      begin
        match binop with
        | Ge -> " \\geq "
        | Le -> " \\leq "
        | _ -> text_binop binop
      end
  | _ ->
      text_binop binop

(** Pretty print a location *)
let pp_loc f (loc: location) =
  F.fprintf f "[line %d]" loc.line

let loc_to_string loc =
  let s = (string_of_int loc.line) in
  if (loc.col != -1) then
    s ^":"^(string_of_int loc.col)
  else s

(** Dump a location *)
let d_loc (loc: location) = L.add_print_action (L.PTloc, Obj.repr loc)

let rec _pp_pvar f pv =
  let name = pv.pv_name in
  match pv.pv_kind with
  | Local_var n ->
      if !Config.pp_simple then F.fprintf f "%a" Mangled.pp name
      else F.fprintf f "%a$%a" Procname.pp n Mangled.pp name
  | Callee_var n ->
      if !Config.pp_simple then F.fprintf f "%a|callee" Mangled.pp name
      else F.fprintf f "%a$%a|callee" Procname.pp n Mangled.pp name
  | Abducted_retvar (n, l) ->
      if !Config.pp_simple then F.fprintf f "%a|abductedRetvar" Mangled.pp name
      else F.fprintf f "%a$%a%a|abductedRetvar" Procname.pp n pp_loc l Mangled.pp name
  | Abducted_ref_param (n, pv, l) ->
      if !Config.pp_simple then F.fprintf f "%a|%a|abductedRefParam" _pp_pvar pv Mangled.pp name
      else F.fprintf f "%a$%a%a|abductedRefParam" Procname.pp n pp_loc l Mangled.pp name
  | Global_var -> F.fprintf f "#GB$%a" Mangled.pp name
  | Seed_var -> F.fprintf f "old_%a" Mangled.pp name

(** Pretty print a program variable in latex. *)
let pp_pvar_latex f pv =
  let name = pv.pv_name in
  match pv.pv_kind with
  | Local_var n ->
      Latex.pp_string Latex.Roman f (Mangled.to_string name)
  | Callee_var n ->
      F.fprintf f "%a_{%a}" (Latex.pp_string Latex.Roman) (Mangled.to_string name)
        (Latex.pp_string Latex.Roman) "callee"
  | Abducted_retvar (n, l) ->
      F.fprintf f "%a_{%a}" (Latex.pp_string Latex.Roman) (Mangled.to_string name)
        (Latex.pp_string Latex.Roman) "abductedRetvar"
   | Abducted_ref_param (n, pv, l) ->
      F.fprintf f "%a_{%a}" (Latex.pp_string Latex.Roman) (Mangled.to_string name)
        (Latex.pp_string Latex.Roman) "abductedRefParam"
  | Global_var ->
      Latex.pp_string Latex.Boldface f (Mangled.to_string name)
  | Seed_var ->
      F.fprintf f "%a^{%a}" (Latex.pp_string Latex.Roman) (Mangled.to_string name)
        (Latex.pp_string Latex.Roman) "old"

(** Pretty print a pvar which denotes a value, not an address *)
let pp_pvar_value pe f pv =
  match pe.pe_kind with
  | PP_TEXT -> _pp_pvar f pv
  | PP_HTML -> _pp_pvar f pv
  | PP_LATEX -> pp_pvar_latex f pv

(** Pretty print a program variable. *)
let pp_pvar pe f pv =
  let ampersand = match pe.pe_kind with
    | PP_TEXT -> "&"
    | PP_HTML -> "&amp;"
    | PP_LATEX -> "\\&" in
  F.fprintf f "%s%a" ampersand (pp_pvar_value pe) pv

(** Dump a program variable. *)
let d_pvar (pvar: pvar) = L.add_print_action (L.PTpvar, Obj.repr pvar)

(** Pretty print a list of program variables. *)
let pp_pvar_list pe f pvl =
  F.fprintf f "%a" (pp_seq (fun f e -> F.fprintf f "%a" (pp_pvar pe) e)) pvl

(** Dump a list of program variables. *)
let d_pvar_list pvl =
  list_iter (fun pv -> d_pvar pv; L.d_str " ") pvl

let ikind_to_string = function
  | IChar -> "char"
  | ISChar -> "signed char"
  | IUChar -> "unsigned char"
  | IBool -> "_Bool"
  | IInt -> "int"
  | IUInt -> "unsigned int"
  | IShort -> "short"
  | IUShort -> "unsigned short"
  | ILong -> "long"
  | IULong -> "unsigned long"
  | ILongLong -> "long long"
  | IULongLong -> "unsigned long long"
  | I128 -> "__int128_t"
  | IU128 -> "__uint128_t"

let fkind_to_string = function
  | FFloat -> "float"
  | FDouble -> "double"
  | FLongDouble -> "long double"

let csu_name = function
  | Class -> "class"
  | Struct -> "struct"
  | Union -> "union"
  | Protocol -> "protocol"

let typename_to_string = function
  | TN_enum name
  | TN_typedef name -> Mangled.to_string name
  | TN_csu (csu, name) -> csu_name csu ^ " " ^ Mangled.to_string name

let typename_name = function
  | TN_enum name
  | TN_typedef name
  | TN_csu (_, name) -> Mangled.to_string name

let ptr_kind_string = function
  | Pk_reference -> "&"
  | Pk_pointer -> "*"
  | Pk_objc_weak -> "__weak *"
  | Pk_objc_unsafe_unretained -> "__unsafe_unretained *"
  | Pk_objc_autoreleasing -> "__autoreleasing *"

let java () = !curr_language = Java
let eradicate_java () = !Config.eradicate && java ()

(** convert a dexp to a string *)
let rec dexp_to_string = function
  | Darray (de1, de2) -> dexp_to_string de1 ^ "[" ^ dexp_to_string de2 ^ "]"
  | Dbinop (op, de1, de2) ->
      "(" ^ dexp_to_string de1 ^ (str_binop pe_text op) ^ dexp_to_string de2 ^ ")"
  | Dconst (Cfun pn) ->
      Procname.to_simplified_string pn
  | Dconst c -> exp_to_string (Const c)
  | Dderef de -> "*" ^ dexp_to_string de
  | Dfcall (fun_dexp, args, loc, { cf_virtual = isvirtual }) ->
      let pp_arg fmt de = F.fprintf fmt "%s" (dexp_to_string de) in
      let pp_args fmt des =
        if eradicate_java ()
        then (if des <> [] then F.fprintf fmt "...")
        else (pp_comma_seq) pp_arg fmt des in
      let pp_fun fmt = function
        | Dconst (Cfun pname) ->
            let s = (if Procname.is_java pname then Procname.java_get_method else Procname.to_string) pname in
            F.fprintf fmt "%s" s
        | de -> F.fprintf fmt "%s" (dexp_to_string de) in
      let receiver, args' = match args with
        | (Dpvar pv):: args' when isvirtual && pvar_is_this pv ->
            (None, args')
        | a:: args' when isvirtual ->
            (Some a, args')
        | _ ->
            (None, args) in
      let pp fmt () =
        let pp_receiver fmt = function
          | None -> ()
          | Some arg -> F.fprintf fmt "%a." pp_arg arg in
        F.fprintf fmt "%a%a(%a)" pp_receiver receiver pp_fun fun_dexp pp_args args' in
      pp_to_string pp ()
  | Darrow ((Dpvar pv), f) when pvar_is_this pv -> (* this->fieldname *)
      Ident.fieldname_to_simplified_string f
  | Darrow (de, f) ->
      if Ident.fieldname_is_hidden f then dexp_to_string de
      else if java() then dexp_to_string de ^ "." ^ Ident.fieldname_to_flat_string f
      else dexp_to_string de ^ "->" ^ Ident.fieldname_to_string f
  | Ddot (Dpvar pv, fe) when eradicate_java () -> (* static field access *)
      Ident.fieldname_to_simplified_string fe
  | Ddot (de, f) ->
      if Ident.fieldname_is_hidden f then "&" ^ dexp_to_string de
      else if java() then dexp_to_string de ^ "." ^ Ident.fieldname_to_flat_string f
      else dexp_to_string de ^ "." ^ Ident.fieldname_to_string f
  | Dpvar pv -> Mangled.to_string (pvar_get_name pv)
  | Dpvaraddr pv ->
      let s =
        if eradicate_java () then pvar_get_simplified_name pv
        else Mangled.to_string (pvar_get_name pv) in
      let ampersand =
        if eradicate_java () then ""
        else "&" in
      ampersand ^ s
  | Dunop (op, de) -> str_unop op ^ dexp_to_string de
  | Dsizeof (typ, sub) -> pp_to_string (pp_typ_full pe_text) typ
  | Dunknown -> "unknown"
  | Dretcall (de, _, _, _) ->
      "returned by " ^ (dexp_to_string de)

(** Pretty print a dexp. *)
and pp_dexp pe fmt de = F.fprintf fmt "%s" (dexp_to_string de)

(** Pretty print a value path *)
and pp_vpath pe fmt vpath =
  let pp fmt = function
    | Some de -> pp_dexp pe fmt de
    | None -> () in
  if pe.pe_kind == PP_HTML then
    F.fprintf fmt " %a{vpath: %a}%a" Io_infer.Html.pp_start_color Orange pp vpath Io_infer.Html.pp_end_color ()
  else
    F.fprintf fmt "%a" pp vpath

(** convert the attribute to a string *)
and attribute_to_string pe = function
  | Aresource ra ->
      let mk_name = function
        | Mmalloc -> "ma"
        | Mnew -> "ne"
        | Mnew_array -> "na"
        | Mobjc -> "oc" in
      let name = match ra.ra_kind, ra.ra_res with
        | Racquire, Rmemory mk -> "MEM" ^ mk_name mk
        | Racquire, Rfile -> "FILE"
        | Rrelease, Rmemory mk -> "FREED" ^ mk_name mk
        | Rrelease, Rfile -> "CLOSED"
        | _, Rignore -> "IGNORE"
        | Racquire, Rlock -> "LOCKED"
        | Rrelease, Rlock -> "UNLOCKED" in
      let str_vpath =
        if !Config.trace_error
        then pp_to_string (pp_vpath pe) ra.ra_vpath
        else "" in
      name ^ (str_binop pe Lt) ^ Procname.to_string ra.ra_pname ^ ":" ^ (string_of_int ra.ra_loc.line) ^ (str_binop pe Gt) ^ str_vpath
  | Aautorelease -> "AUTORELEASE"
  | Adangling dk ->
      let dks = match dk with
        | DAuninit -> "UNINIT"
        | DAaddr_stack_var -> "ADDR_STACK"
        | DAminusone -> "MINUS1" in
      "DANGL" ^ (str_binop pe Lt) ^ dks ^ (str_binop pe Gt)
  | Aundef (pn, loc, _) -> "UND" ^ (str_binop pe Lt) ^ Procname.to_string pn ^ (str_binop pe Gt) ^ ":" ^ (string_of_int loc.line)
  | Ataint -> "TAINTED"
  | Auntaint -> "UNTAINTED"
  | Adiv0 (pn, nd_id) -> "DIV0"
  | Aobjc_null exp ->
      let info_s =
        match exp with
        | Lvar var -> "FORMAL "^(pvar_to_string var)
        | Lfield _ -> "FIELD "^(exp_to_string exp)
        | _ -> "" in
      "OBJC_NULL["^ info_s ^"]"
  | Avariadic_function_argument (pn, n, i) ->
      Printf.sprintf "VA_ARG" ^ (str_binop pe Lt)
      ^ Procname.to_string pn ^ "," ^ (string_of_int n) ^ "," ^ (string_of_int i)
      ^ (str_binop pe Gt)
  | Aretval pn -> "RET" ^ str_binop pe Lt ^ Procname.to_string pn ^ str_binop pe Gt

and pp_const pe f = function
  | Cint i -> Int.pp f i
  | Cfun fn ->
      (match pe.pe_kind with
        | PP_HTML -> F.fprintf f "_fun_%s" (Escape.escape_xml (Procname.to_string fn))
        | _ -> F.fprintf f "_fun_%s" (Procname.to_string fn))
  | Cstr s -> F.fprintf f "\"%s\"" (String.escaped s)
  | Cfloat v -> F.fprintf f "%f" v
  | Cattribute att -> F.fprintf f "%s" (attribute_to_string pe att)
  | Cexn e -> F.fprintf f "EXN %a" (pp_exp pe) e
  | Cclass c -> F.fprintf f "%a" Ident.pp_name c
  | Cptr_to_fld (fn, typ) -> F.fprintf f "__fld_%a" Ident.pp_fieldname fn
  | Ctuple el -> F.fprintf f "(%a)" (pp_comma_seq (pp_exp pe)) el

(** Pretty print a type. Do nothing by default. *)
and pp_typ pe f te =
  if !Config.print_types then pp_typ_full pe f te else ()

(** Pretty print a type declaration.
pp_base prints the variable for a declaration, or can be skip to print only the type
pp_size prints the expression for the array size *)
and pp_type_decl pe pp_base pp_size f = function
  | Tvar tname -> F.fprintf f "%s %a" (typename_to_string tname) pp_base ()
  | Tint ik -> F.fprintf f "%s %a" (ikind_to_string ik) pp_base ()
  | Tfloat fk -> F.fprintf f "%s %a" (fkind_to_string fk) pp_base ()
  | Tvoid -> F.fprintf f "void %a" pp_base ()
  | Tfun false -> F.fprintf f "_fn_ %a" pp_base ()
  | Tfun true -> F.fprintf f "_fn_noreturn_ %a" pp_base ()
  | Tptr ((Tarray _ | Tfun _) as typ, pk) ->
      let pp_base' fmt () = F.fprintf fmt "(%s%a)" (ptr_kind_string pk) pp_base () in
      pp_type_decl pe pp_base' pp_size f typ
  | Tptr (typ, pk) ->
      let pp_base' fmt () = F.fprintf fmt "%s%a" (ptr_kind_string pk) pp_base () in
      pp_type_decl pe pp_base' pp_size f typ
  | Tstruct (ftal, sftal, csu, Some name, _, _, _) when false -> (* remove "when false" to print the details of struct *)
      F.fprintf f "%s %a {%a} %a" (csu_name csu) Mangled.pp name
        (pp_seq (fun f (fld, t, ann) ->
                  F.fprintf f "%a %a" (pp_typ_full pe) t Ident.pp_fieldname fld))
        ftal pp_base ()
  | Tstruct (ftal, sftal, csu, Some name, _, _, _) ->
      F.fprintf f "%s %a %a" (csu_name csu) Mangled.pp name pp_base ()
  | Tstruct (ftal, sftal, csu, None, _, _, _) ->
      F.fprintf f "%s {%a} %a" (csu_name csu)
        (pp_seq (fun f (fld, t, ann) -> F.fprintf f "%a %a" (pp_typ_full pe) t Ident.pp_fieldname fld)) ftal pp_base ()
  | Tarray (typ, size) ->
      let pp_base' fmt () = F.fprintf fmt "%a[%a]" pp_base () (pp_size pe) size in
      pp_type_decl pe pp_base' pp_size f typ
  | Tenum econsts ->
      F.fprintf f "enum { %a }"
        (pp_seq (fun f (n, e) -> F.fprintf f " (%a, %a) " Mangled.pp n (pp_const pe) e)) econsts

(** Pretty print a type with all the details, using the C syntax. *)
and pp_typ_full pe = pp_type_decl pe (fun fmt () -> ()) pp_exp_full

(** Pretty print an expression. *)
and _pp_exp pe0 pp_t f e0 =
  let pe, changed = color_pre_wrapper pe0 f e0 in
  let e = match pe.pe_obj_sub with
    | Some sub -> Obj.obj (sub (Obj.repr e0)) (* apply object substitution to expression *)
    | None -> e0 in
  (if not (exp_equal e0 e)
    then
      match e with
      | Lvar pvar -> pp_pvar_value pe f pvar
      | _ -> assert false
    else
      let pp_exp = _pp_exp pe pp_t in
      let print_binop_stm_output e1 op e2 =
        match op with
        | Eq | Ne | PlusA | Mult -> F.fprintf f "(%a %s %a)" pp_exp e2 (str_binop pe op) pp_exp e1
        | Lt -> F.fprintf f "(%a %s %a)" pp_exp e2 (str_binop pe Gt) pp_exp e1
        | Gt -> F.fprintf f "(%a %s %a)" pp_exp e2 (str_binop pe Lt) pp_exp e1
        | Le -> F.fprintf f "(%a %s %a)" pp_exp e2 (str_binop pe Ge) pp_exp e1
        | Ge -> F.fprintf f "(%a %s %a)" pp_exp e2 (str_binop pe Le) pp_exp e1
        | _ -> F.fprintf f "(%a %s %a)" pp_exp e1 (str_binop pe op) pp_exp e2 in
      begin match e with
        | Var id -> (Ident.pp pe) f id
        | Const c -> F.fprintf f "%a" (pp_const pe) c
        | Cast (typ, e) -> F.fprintf f "(%a)%a" pp_t typ pp_exp e
        | UnOp (op, e, _) -> F.fprintf f "%s%a" (str_unop op) pp_exp e
        | BinOp (op, Const c, e2) when !Config.smt_output -> print_binop_stm_output (Const c) op e2
        | BinOp (op, e1, e2) -> F.fprintf f "(%a %s %a)" pp_exp e1 (str_binop pe op) pp_exp e2
        | Lvar pv -> pp_pvar pe f pv
        | Lfield (e, fld, typ) -> F.fprintf f "%a.%a" pp_exp e Ident.pp_fieldname fld
        | Lindex (e1, e2) -> F.fprintf f "%a[%a]" pp_exp e1 pp_exp e2
        | Sizeof (t, s) -> F.fprintf f "sizeof(%a%a)" pp_t t Subtype.pp s
      end);
  color_post_wrapper changed pe0 f

and pp_exp pe f e =
  _pp_exp pe (pp_typ pe) f e
and pp_exp_full pe f e =
  _pp_exp pe (pp_typ_full pe) f e

(** Convert an expression to a string *)
and exp_to_string e = pp_to_string (pp_exp pe_text) e

let typ_to_string typ =
  let pp fmt () = pp_typ_full Utils.pe_text fmt typ in
  Utils.pp_to_string pp ()

(** dump a type with all the details. *)
let d_typ_full (t: typ) = L.add_print_action (L.PTtyp_full, Obj.repr t)

(** dump a list of types. *)
let d_typ_list (tl: typ list) = L.add_print_action (L.PTtyp_list, Obj.repr tl)

let pp_pair pe f ((fld: Ident.fieldname), (t: typ)) =
  F.fprintf f "%a %a" (pp_typ pe) t Ident.pp_fieldname fld

(** dump an expression. *)
let d_exp (e: exp) = L.add_print_action (L.PTexp, Obj.repr e)

(** Pretty print a list of expressions. *)
let pp_exp_list pe f expl =
  (pp_seq (pp_exp pe)) f expl

(** dump a list of expressions. *)
let d_exp_list (el: exp list) = L.add_print_action (L.PTexp_list, Obj.repr el)

let pp_texp pe f = function
  | Sizeof (t, s) -> F.fprintf f "%a%a" (pp_typ pe) t Subtype.pp s
  | e -> (pp_exp pe) f e

(** Pretty print a type with all the details. *)
let pp_texp_full pe f = function
  | Sizeof (t, s) -> F.fprintf f "%a%a" (pp_typ_full pe) t Subtype.pp s
  | e -> (_pp_exp pe) (pp_typ_full pe) f e

(** Dump a type expression with all the details. *)
let d_texp_full (te: exp) = L.add_print_action (L.PTtexp_full, Obj.repr te)

(** Pretty print an offset *)
let pp_offset pe f = function
  | Off_fld (fld, typ) -> F.fprintf f "%a" Ident.pp_fieldname fld
  | Off_index exp -> F.fprintf f "%a" (pp_exp pe) exp

(** dump an offset. *)
let d_offset (off: offset) = L.add_print_action (L.PToff, Obj.repr off)

(** Pretty print a list of offsets *)
let rec pp_offset_list pe f = function
  | [] -> ()
  | [off1; off2] -> F.fprintf f "%a.%a" (pp_offset pe) off1 (pp_offset pe) off2
  | off:: off_list -> F.fprintf f "%a.%a" (pp_offset pe) off (pp_offset_list pe) off_list

(** Dump a list of offsets *)
let d_offset_list (offl: offset list) = L.add_print_action (L.PToff_list, Obj.repr offl)

let pp_exp_typ pe f (e, t) =
  F.fprintf f "%a:%a" (pp_exp pe) e (pp_typ pe) t

(** Get the location of the instruction *)
let instr_get_loc = function
  | Letderef (_, _, _, loc)
  | Set (_, _, _, loc)
  | Prune (_, loc, _, _)
  | Call (_, _, _, loc, _)
  | Nullify (_, loc, _)
  | Abstract loc
  | Remove_temps (_, loc)
  | Stackop (_, loc)
  | Declare_locals (_, loc)
  | Goto_node (_, loc) ->
      loc

(** get the expressions occurring in the instruction *)
let rec instr_get_exps = function
  | Letderef (id, e, _, _) ->
      [Var id; e]
  | Set (e1, _, e2, _) ->
      [e1; e2]
  | Prune (cond, _, _, _) ->
      [cond]
  | Call (ret_ids, e, _, _, _) ->
      e :: (list_map (fun id -> Var id)) ret_ids
  | Nullify (pvar, _, _) ->
      [Lvar pvar]
  | Abstract _ ->
      []
  | Remove_temps (temps, _) ->
      list_map (fun id -> Var id) temps
  | Stackop _ ->
      []
  | Declare_locals _ ->
      []
  | Goto_node (e, _) ->
      [e]

(** Pretty print call flags *)
let pp_call_flags f cf =
  if cf.cf_virtual then F.fprintf f " virtual";
  if cf.cf_noreturn then F.fprintf f " noreturn"

(** Pretty print an instruction. *)
let rec pp_instr pe0 f instr =
  let pe, changed = color_pre_wrapper pe0 f instr in
  (match instr with
    | Letderef (id, e, t, loc) -> F.fprintf f "%a=*%a:%a %a" (Ident.pp pe) id (pp_exp pe) e (pp_typ pe) t pp_loc loc
    | Set (e1, t, e2, loc) -> F.fprintf f "*%a:%a=%a %a" (pp_exp pe) e1 (pp_typ pe) t (pp_exp pe) e2 pp_loc loc
    | Prune (cond, loc, true_branch, ik) ->
        F.fprintf f "PRUNE(%a, %b); %a" (pp_exp pe) cond true_branch pp_loc loc
    | Call (ret_ids, e, arg_ts, loc, cf) ->
        (match ret_ids with
          | [] -> ()
          | _ -> F.fprintf f "%a=" (pp_comma_seq (Ident.pp pe)) ret_ids);
        F.fprintf f "%a(%a)%a %a" (pp_exp pe) e (pp_comma_seq (pp_exp_typ pe)) (arg_ts) pp_call_flags cf pp_loc loc
    | Nullify (pvar, loc, deallocate) ->
        F.fprintf f "NULLIFY(%a,%b); %a" (pp_pvar pe) pvar deallocate pp_loc loc
    | Abstract loc ->
        F.fprintf f "APPLY_ABSTRACTION; %a" pp_loc loc
    | Remove_temps (temps, loc) ->
        F.fprintf f "REMOVE_TEMPS(%a); %a" (Ident.pp_list pe) temps pp_loc loc
    | Stackop (stackop, loc) ->
        let s = match stackop with
          | Push -> "Push"
          | Swap -> "Swap"
          | Pop -> "Pop" in
        F.fprintf f "STACKOP.%s; %a" s pp_loc loc
    | Declare_locals (ptl, loc) ->
    (* let pp_pvar_typ fmt (pvar, typ) = F.fprintf fmt "%a:%a" (pp_pvar pe) pvar (pp_typ_full pe) typ in *)
        let pp_pvar_typ fmt (pvar, typ) = F.fprintf fmt "%a" (pp_pvar pe) pvar in
        F.fprintf f "DECLARE_LOCALS(%a); %a" (pp_comma_seq pp_pvar_typ) ptl pp_loc loc
    | Goto_node (e, loc) ->
        F.fprintf f "Goto_node %a %a" (pp_exp pe) e pp_loc loc
  );
  color_post_wrapper changed pe0 f

let has_block_prefix s =
  match Str.split_delim (Str.regexp_string Config.anonymous_block_prefix) s with
  | s1:: s2:: _ -> true
  | _ -> false

(** Check if a pvar is a local pointing to a block in objc *)
let is_block_pvar pvar =
  has_block_prefix (Mangled.to_string (pvar_get_name pvar))

(** Check if type is a type for a block in objc *)
let is_block_type typ =
  has_block_prefix (typ_to_string typ)

(** Iterate over all the subtypes in the type (including the type itself) *)
let rec typ_iter_types (f : typ -> unit) typ =
  f typ;
  match typ with
  | Tvar _
  | Tint _
  | Tfloat _
  | Tvoid
  | Tfun _ ->
      ()
  | Tptr (t', pk) ->
      typ_iter_types f t'
  | Tstruct (ftal, sftal, csu, nameo, supers, def_mthds, iann) ->
      list_iter (fun (_, t, _) -> typ_iter_types f t) ftal
  | Tarray (t, e) ->
      typ_iter_types f t;
      exp_iter_types f e
  | Tenum econsts ->
      ()

(** Iterate over all the subtypes in the type (including the type itself) *)
and exp_iter_types f e =
  match e with
  | Var id -> ()
  | Const (Cexn e1) ->
      exp_iter_types f e1
  | Const (Ctuple el) ->
      list_iter (exp_iter_types f) el
  | Const _ ->
      ()
  | Cast (t, e1) ->
      typ_iter_types f t;
      exp_iter_types f e1
  | UnOp (op, e1, typo) ->
      exp_iter_types f e1;
      (match typo with
        | Some t -> typ_iter_types f t
        | None -> ())
  | BinOp (op, e1, e2) ->
      exp_iter_types f e1;
      exp_iter_types f e2
  | Lvar id ->
      ()
  | Lfield (e1, fld, typ) ->
      exp_iter_types f e1;
      typ_iter_types f typ
  | Lindex (e1, e2) ->
      exp_iter_types f e1;
      exp_iter_types f e2
  | Sizeof (t, s) ->
      typ_iter_types f t

(** Iterate over all the types (and subtypes) in the instruction *)
let rec instr_iter_types f instr = match instr with
  | Letderef (id, e, t, loc) ->
      exp_iter_types f e;
      typ_iter_types f t
  | Set (e1, t, e2, loc) ->
      exp_iter_types f e1;
      typ_iter_types f t;
      exp_iter_types f e2
  | Prune (cond, loc, true_branch, ik) ->
      exp_iter_types f cond
  | Call (ret_ids, e, arg_ts, loc, cf) ->
      exp_iter_types f e;
      list_iter (fun (e, t) -> exp_iter_types f e; typ_iter_types f t) arg_ts
  | Nullify (pvar, loc, deallocate) ->
      ()
  | Abstract loc ->
      ()
  | Remove_temps (temps, loc) ->
      ()
  | Stackop (stackop, loc) ->
      ()
  | Declare_locals (ptl, loc) ->
      list_iter (fun (_, t) -> typ_iter_types f t) ptl
  | Goto_node _ ->
      ()

(** Dump an instruction. *)
let d_instr (i: instr) = L.add_print_action (L.PTinstr, Obj.repr i)

let rec pp_instr_list pe f = function
  | [] -> F.fprintf f ""
  | i:: is -> F.fprintf f "%a;@\n%a" (pp_instr pe) i (pp_instr_list pe) is

(** Dump a list of instructions. *)
let d_instr_list (il: instr list) = L.add_print_action (L.PTinstr_list, Obj.repr il)

let pp_atom pe0 f a =
  let pe, changed = color_pre_wrapper pe0 f a in
  begin match a with
    | Aeq (BinOp(op, e1, e2), Const (Cint i)) when Int.isone i ->
        (match pe.pe_kind with
          | PP_TEXT | PP_HTML ->
              F.fprintf f "%a" (pp_exp pe) (BinOp(op, e1, e2))
          | PP_LATEX ->
              F.fprintf f "%a" (pp_exp pe) (BinOp(op, e1, e2))
        )
    | Aeq (e1, e2) ->
        (match pe.pe_kind with
          | PP_TEXT | PP_HTML ->
              F.fprintf f "%a = %a" (pp_exp pe) e1 (pp_exp pe) e2
          | PP_LATEX ->
              F.fprintf f "%a{=}%a" (pp_exp pe) e1 (pp_exp pe) e2)
    | Aneq ((Const (Cattribute a) as ea), e)
    | Aneq (e, (Const (Cattribute a) as ea)) ->
        F.fprintf f "%a(%a)" (pp_exp pe) ea (pp_exp pe) e
    | Aneq (e1, e2) ->
        (match pe.pe_kind with
          | PP_TEXT | PP_HTML ->
              F.fprintf f "%a != %a" (pp_exp pe) e1 (pp_exp pe) e2
          | PP_LATEX ->
              F.fprintf f "%a{\\neq}%a" (pp_exp pe) e1 (pp_exp pe) e2)
  end;
  color_post_wrapper changed pe0 f

(** dump an atom *)
let d_atom (a: atom) = L.add_print_action (L.PTatom, Obj.repr a)

let pp_lseg_kind f = function
  | Lseg_NE -> F.fprintf f "ne"
  | Lseg_PE -> F.fprintf f ""

(** Print a *-separated sequence. *)
let rec pp_star_seq pp f = function
  | [] -> ()
  | [x] -> F.fprintf f "%a" pp x
  | x:: l -> F.fprintf f "%a * %a" pp x (pp_star_seq pp) l

(********* START OF MODULE Predicates **********)
(** Module Predicates records the occurrences of predicates as parameters
of (doubly -)linked lists and Epara. Provides unique numbering for predicates and an iterator. *)
module Predicates : sig
(** predicate environment *)
  type env
  (** create an empty predicate environment *)
  val empty_env : unit -> env
  (** return true if the environment is empty *)
  val is_empty : env -> bool
  (** return the id of the hpara *)
  val get_hpara_id : env -> hpara -> int
  (** return the id of the hpara_dll *)
  val get_hpara_dll_id : env -> hpara_dll -> int
  (** [iter env f f_dll] iterates [f] and [f_dll] on all the hpara and hpara_dll,
  passing the unique id to the functions. The iterator can only be used once. *)
  val iter : env -> (int -> hpara -> unit) -> (int -> hpara_dll -> unit) -> unit
  (** Process one hpred, updating the predicate environment *)
  val process_hpred : env -> hpred -> unit
end = struct

  (** hash tables for hpara *)
  module HparaHash = Hashtbl.Make (struct
      type t = hpara
      let equal = hpara_equal
      let hash = Hashtbl.hash
    end)

  (** hash tables for hpara_dll *)
  module HparaDllHash = Hashtbl.Make (struct
      type t = hpara_dll
      let equal = hpara_dll_equal
      let hash = Hashtbl.hash
    end)

  (** Map each visited hpara to a unique number and a boolean denoting whether it has been emitted,
  also keep a list of hparas still to be emitted. Same for hpara_dll. *)
  type env =
    {
      mutable num: int;
      hash: (int * bool) HparaHash.t;
      mutable todo: hpara list;
      hash_dll: (int * bool) HparaDllHash.t;
      mutable todo_dll: hpara_dll list;
    }

  (** return true if the environment is empty *)
  let is_empty env = env.num = 0

  (** return the id of the hpara *)
  let get_hpara_id env hpara =
    fst (HparaHash.find env.hash hpara)

  (** return the id of the hpara_dll *)
  let get_hpara_dll_id env hpara_dll =
    fst (HparaDllHash.find env.hash_dll hpara_dll)

  (** Process one hpara, updating the map from hparas to numbers, and the todo list *)
  let process_hpara env hpara =
    if not (HparaHash.mem env.hash hpara) then
      (HparaHash.add env.hash hpara (env.num, false);
        env.num <- env.num + 1;
        env.todo <- env.todo @ [hpara])

  (** Process one hpara_dll, updating the map from hparas to numbers, and the todo list *)
  let process_hpara_dll env hpara_dll =
    if not (HparaDllHash.mem env.hash_dll hpara_dll)
    then
      (HparaDllHash.add env.hash_dll hpara_dll (env.num, false);
        env.num <- env.num + 1;
        env.todo_dll <- env.todo_dll @ [hpara_dll])

  (** Process a sexp, updating env *)
  let rec process_sexp env = function
    | Eexp _ -> ()
    | Earray (_, esel, _) ->
        list_iter (fun (e, se) -> process_sexp env se) esel
    | Estruct (fsel, _) ->
        list_iter (fun (f, se) -> process_sexp env se) fsel

  (** Process one hpred, updating env *)
  let rec process_hpred env = function
    | Hpointsto (_, se, _) ->
        process_sexp env se
    | Hlseg (_, hpara, _, _, _) ->
        list_iter (process_hpred env) hpara.body;
        process_hpara env hpara
    | Hdllseg(_, hpara_dll, _, _, _, _, _) ->
        list_iter (process_hpred env) hpara_dll.body_dll;
        process_hpara_dll env hpara_dll

  (** create an empty predicate environment *)
  let empty_env () =
    {
      num = 0;
      hash = HparaHash.create 3;
      todo =[];
      hash_dll = HparaDllHash.create 3;
      todo_dll =[];
    }

  (** iterator for predicates which are marked as todo in env, unless they have been visited already.
  This can in turn extend the todo list for the nested predicates, which are then visited as well.
  Can be applied only once, as it destroys the todo list *)
  let iter (env: env) f f_dll =
    while env.todo != [] || env.todo_dll != [] do
      if env.todo != [] then
        begin
          let hpara = list_hd env.todo in
          let () = env.todo <- list_tl env.todo in
          let (n, emitted) = HparaHash.find env.hash hpara in
          if not emitted then f n hpara
        end
      else if env.todo_dll != [] then
        begin
          let hpara_dll = list_hd env.todo_dll in
          let () = env.todo_dll <- list_tl env.todo_dll in
          let (n, emitted) = HparaDllHash.find env.hash_dll hpara_dll in
          if not emitted then f_dll n hpara_dll
        end
    done
end
(********* END OF MODULE Predicates **********)

let pp_texp_simple pe = match pe.pe_opt with
  | PP_SIM_DEFAULT -> pp_texp pe
  | PP_SIM_WITH_TYP -> pp_texp_full pe

let inst_abstraction = Iabstraction
let inst_actual_precondition = Iactual_precondition
let inst_alloc = Ialloc
let inst_formal = Iformal (None, false) (** for formal parameters *)
let inst_initial = Iinitial (** for initial values *)
let inst_lookup = Ilookup
let inst_none = Inone
let inst_nullify = Inullify
let inst_rearrange b loc pos = Irearrange (Some b, false, loc.line, pos)
let inst_taint = Itaint
let inst_update loc pos = Iupdate (None, false, loc.line, pos)

(** update the location of the instrumentation *)
let inst_new_loc loc inst = match inst with
  | Iabstraction -> inst
  | Iactual_precondition -> inst
  | Ialloc -> inst
  | Iformal (zf, ncf) -> inst
  | Iinitial -> inst
  | Ilookup -> inst
  | Inone -> inst
  | Inullify -> inst
  | Irearrange (zf, ncf, n, pos) -> Irearrange (zf, ncf, loc.line, pos)
  | Itaint -> inst
  | Iupdate (zf, ncf, n, pos) -> Iupdate (zf, ncf, loc.line, pos)
  | Ireturn_from_call n -> Ireturn_from_call loc.line

(** return a string representing the inst *)
let inst_to_string inst =
  let zero_flag_to_string = function
    | Some true -> "(z)"
    | _ -> "" in
  let null_case_flag_to_string ncf =
    if ncf then "(ncf)" else "" in
  match inst with
  | Iabstraction -> "abstraction"
  | Iactual_precondition -> "actual_precondition"
  | Ialloc -> "alloc"
  | Iformal (zf, ncf) ->
      "formal" ^ zero_flag_to_string zf ^ null_case_flag_to_string ncf
  | Iinitial -> "initial"
  | Ilookup -> "lookup"
  | Inone -> "none"
  | Inullify -> "nullify"
  | Irearrange (zf, ncf, n, _) ->
      "rearrange:" ^ zero_flag_to_string zf ^ null_case_flag_to_string ncf ^ string_of_int n
  | Itaint -> "taint"
  | Iupdate (zf, ncf, n, _) ->
      "update:" ^ zero_flag_to_string zf ^ null_case_flag_to_string ncf ^ string_of_int n
  | Ireturn_from_call n -> "return_from_call: " ^ string_of_int n

(** join of instrumentations *)
let inst_partial_join inst1 inst2 =
  let fail () =
    L.d_strln ("inst_partial_join failed on " ^ inst_to_string inst1 ^ " " ^ inst_to_string inst2);
    raise Fail in
  if inst1 = inst2 then inst1
  else match inst1, inst2 with
    | _, Inone | Inone, _ -> inst_none
    | _, Ialloc | Ialloc, _ -> fail ()
    | _, Iinitial | Iinitial, _ -> fail ()
    | _, Iupdate _ | Iupdate _, _ -> fail ()
    | _ -> inst_none

(** meet of instrumentations *)
let inst_partial_meet inst1 inst2 =
  if inst1 = inst2 then inst1 else inst_none

(** Return the zero flag of the inst *)
let inst_zero_flag = function
  | Iabstraction -> None
  | Iactual_precondition -> None
  | Ialloc -> None
  | Iformal (zf, ncf) -> zf
  | Iinitial -> None
  | Ilookup -> None
  | Inone -> None
  | Inullify -> None
  | Irearrange (zf, ncf, n, _) -> zf
  | Itaint -> None
  | Iupdate (zf, ncf, n, _) -> zf
  | Ireturn_from_call _ -> None

(** Set the null case flag of the inst. *)
let inst_set_null_case_flag = function
  | Iformal (zf, false) ->
      Iformal (zf, true)
  | Irearrange (zf, false, n, pos) ->
      Irearrange (zf, true, n, pos)
  | Iupdate (zf, false, n, pos) ->
      Iupdate (zf, true, n, pos)
  | inst -> inst

(** Get the null case flag of the inst. *)
let inst_get_null_case_flag = function
  | Iupdate (_, ncf, _, _) -> Some ncf
  | _ -> None

(** Update [inst_old] to [inst_new] preserving the zero flag *)
let update_inst inst_old inst_new =
  let combine_zero_flags z1 z2 = match z1, z2 with
    | Some b1, Some b2 -> Some (b1 || b2)
    | Some b, None -> Some b
    | None, Some b -> Some b
    | None, None -> None in
  match inst_new with
  | Iabstraction -> inst_new
  | Iactual_precondition -> inst_new
  | Ialloc -> inst_new
  | Iformal (zf, ncf) ->
      let zf' = combine_zero_flags (inst_zero_flag inst_old) zf in
      Iformal (zf', ncf)
  | Iinitial -> inst_new
  | Ilookup -> inst_new
  | Inone -> inst_new
  | Inullify -> inst_new
  | Irearrange (zf, ncf, n, pos) ->
      let zf' = combine_zero_flags (inst_zero_flag inst_old) zf in
      Irearrange (zf', ncf, n, pos)
  | Itaint -> inst_new
  | Iupdate (zf, ncf, n, pos) ->
      let zf' = combine_zero_flags (inst_zero_flag inst_old) zf in
      Iupdate (zf', ncf, n, pos)
  | Ireturn_from_call _ -> inst_new

let string_of_language = function
  | Java -> "Java"
  | C_CPP -> "C_CPP"

(** describe an instrumentation with a string *)
let pp_inst pe f inst =
  let str = inst_to_string inst in
  if pe.pe_kind == PP_HTML then
    F.fprintf f " %a%s%a" Io_infer.Html.pp_start_color Orange str Io_infer.Html.pp_end_color ()
  else
    F.fprintf f "%s%s%s" (str_binop pe Lt) str (str_binop pe Gt)

let pp_inst_if_trace pe f inst =
  if !Config.trace_error then pp_inst pe f inst

(** pretty print a strexp with an optional predicate env *)
let rec pp_sexp_env pe0 envo f se =
  let pe, changed = color_pre_wrapper pe0 f se in
  begin
    match se with
    | Eexp (e, inst) ->
        F.fprintf f "%a%a" (pp_exp pe) e (pp_inst_if_trace pe) inst
    | Estruct (fel, inst) ->
        begin
          match pe.pe_kind with
          | PP_TEXT | PP_HTML ->
              let pp_diff f (n, se) = F.fprintf f "%a:%a" Ident.pp_fieldname n (pp_sexp_env pe envo) se in
              F.fprintf f "{%a}%a" (pp_seq_diff pp_diff pe) fel (pp_inst_if_trace pe) inst
          | PP_LATEX ->
              let pp_diff f (n, se) = F.fprintf f "%a:%a" (Ident.pp_fieldname_latex Latex.Boldface) n (pp_sexp_env pe envo) se in
              F.fprintf f "\\{%a\\}%a" (pp_seq_diff pp_diff pe) fel (pp_inst_if_trace pe) inst
        end
    | Earray (size, nel, inst) ->
        let pp_diff f (i, se) = F.fprintf f "%a:%a" (pp_exp pe) i (pp_sexp_env pe envo) se in
        F.fprintf f "[%a|%a]%a" (pp_exp pe) size (pp_seq_diff pp_diff pe) nel (pp_inst_if_trace pe) inst
  end;
  color_post_wrapper changed pe0 f

(** Pretty print an hpred with an optional predicate env *)
and pp_hpred_env pe0 envo f hpred =
  let pe, changed = color_pre_wrapper pe0 f hpred in
  begin match hpred with
    | Hpointsto (e, se, te) ->
        let pe' = match (e, se) with
          | Lvar pvar, Eexp (Var id, inst) when not (pvar_is_global pvar) ->
              { pe with pe_obj_sub = None } (* dont use obj sub on the var defining it *)
          | _ -> pe in
        (match pe'.pe_kind with
          | PP_TEXT | PP_HTML ->
              F.fprintf f "%a|->%a:%a" (pp_exp pe') e (pp_sexp_env pe' envo) se (pp_texp_simple pe') te
          | PP_LATEX ->
              F.fprintf f "%a\\mapsto %a" (pp_exp pe') e (pp_sexp_env pe' envo) se)
    | Hlseg (k, hpara, e1, e2, elist) ->
        (match pe.pe_kind with
          | PP_TEXT | PP_HTML ->
              F.fprintf f "lseg%a(%a,%a,[%a],%a)"
                pp_lseg_kind k (pp_exp pe) e1 (pp_exp pe) e2 (pp_comma_seq (pp_exp pe)) elist (pp_hpara_env pe envo) hpara
          | PP_LATEX ->
              F.fprintf f "\\textsf{lseg}_{%a}(%a,%a,[%a],%a)"
                pp_lseg_kind k (pp_exp pe) e1 (pp_exp pe) e2 (pp_comma_seq (pp_exp pe)) elist (pp_hpara_env pe envo) hpara)
    | Hdllseg (k, hpara_dll, iF, oB, oF, iB, elist) ->
        (match pe.pe_kind with
          | PP_TEXT | PP_HTML ->
              F.fprintf f "dllseg%a(%a,%a,%a,%a,[%a],%a)"
                pp_lseg_kind k (pp_exp pe) iF (pp_exp pe) oB (pp_exp pe) oF (pp_exp pe) iB (pp_comma_seq (pp_exp pe)) elist (pp_hpara_dll_env pe envo) hpara_dll
          | PP_LATEX ->
              F.fprintf f "\\textsf{dllseg}_{%a}(%a,%a,%a,%a,[%a],%a)"
                pp_lseg_kind k (pp_exp pe) iF (pp_exp pe) oB (pp_exp pe) oF (pp_exp pe) iB (pp_comma_seq (pp_exp pe)) elist (pp_hpara_dll_env pe envo) hpara_dll)
  end;
  color_post_wrapper changed pe0 f

and pp_hpara_env pe envo f hpara = match envo with
  | None ->
      let (r, n, svars, evars, b) = (hpara.root, hpara.next, hpara.svars, hpara.evars, hpara.body) in
      F.fprintf f "lam [%a,%a,%a]. exists [%a]. %a"
        (Ident.pp pe) r
        (Ident.pp pe) n
        (pp_seq (Ident.pp pe)) svars
        (pp_seq (Ident.pp pe)) evars
        (pp_star_seq (pp_hpred_env pe envo)) b
  | Some env ->
      F.fprintf f "P%d" (Predicates.get_hpara_id env hpara)

and pp_hpara_dll_env pe envo f hpara_dll = match envo with
  | None ->
      let (iF, oB, oF, svars, evars, b) = (hpara_dll.cell, hpara_dll.blink, hpara_dll.flink, hpara_dll.svars_dll, hpara_dll.evars_dll, hpara_dll.body_dll) in
      F.fprintf f "lam [%a,%a,%a,%a]. exists [%a]. %a"
        (Ident.pp pe) iF
        (Ident.pp pe) oB
        (Ident.pp pe) oF
        (pp_seq (Ident.pp pe)) svars
        (pp_seq (Ident.pp pe)) evars
        (pp_star_seq (pp_hpred_env pe envo)) b
  | Some env ->
      F.fprintf f "P%d" (Predicates.get_hpara_dll_id env hpara_dll)

(** pretty print a strexp *)
let pp_sexp pe f = pp_sexp_env pe None f

(** pretty print a hpara *)
let pp_hpara pe f = pp_hpara_env pe None f

(** pretty print a hpara_dll *)
let pp_hpara_dll pe f = pp_hpara_dll_env pe None f

(** pretty print a hpred *)
let pp_hpred pe f = pp_hpred_env pe None f

(** dump a strexp. *)
let d_sexp (se: strexp) = L.add_print_action (L.PTsexp, Obj.repr se)

(** Pretty print a list of expressions. *)
let pp_sexp_list pe f sel =
  F.fprintf f "%a" (pp_seq (fun f se -> F.fprintf f "%a" (pp_sexp pe) se)) sel

(** dump a list of expressions. *)
let d_sexp_list (sel: strexp list) = L.add_print_action (L.PTsexp_list, Obj.repr sel)

let rec pp_hpara_list pe f = function
  | [] -> ()
  | [para] ->
      F.fprintf f "PRED: %a" (pp_hpara pe) para
  | para:: paras ->
      F.fprintf f "PRED: %a@\n@\n%a" (pp_hpara pe) para (pp_hpara_list pe) paras

let rec pp_hpara_dll_list pe f = function
  | [] -> ()
  | [para] ->
      F.fprintf f "PRED: %a" (pp_hpara_dll pe) para
  | para:: paras ->
      F.fprintf f "PRED: %a@\n@\n%a" (pp_hpara_dll pe) para (pp_hpara_dll_list pe) paras

(** dump a hpred. *)
let d_hpred (hpred: hpred) = L.add_print_action (L.PThpred, Obj.repr hpred)

(** {2 Functions for traversing SIL data types} *)

let rec strexp_expmap (f: exp * inst option -> exp * inst option) =
  let fe e = fst (f (e, None)) in
  let fei (e, inst) = match f (e, Some inst) with
    | e', None -> (e', inst)
    | e', Some inst' -> (e', inst') in
  function
  | Eexp (e, inst) ->
      let e', inst' = fei (e, inst) in
      Eexp (e', inst')
  | Estruct (fld_se_list, inst) ->
      let f_fld_se (fld, se) = (fld, strexp_expmap f se) in
      Estruct (list_map f_fld_se fld_se_list, inst)
  | Earray (size, idx_se_list, inst) ->
      let size' = fe size in
      let f_idx_se (idx, se) =
        let idx' = fe idx in
        (idx', strexp_expmap f se) in
      Earray (size', list_map f_idx_se idx_se_list, inst)

let hpred_expmap (f: exp * inst option -> exp * inst option) =
  let fe e = fst (f (e, None)) in
  function
  | Hpointsto (e, se, te) ->
      let e' = fe e in
      let se' = strexp_expmap f se in
      let te' = fe te in
      Hpointsto(e', se', te')
  | Hlseg (k, hpara, root, next, shared) ->
      let root' = fe root in
      let next' = fe next in
      let shared' = list_map fe shared in
      Hlseg (k, hpara, root', next', shared')
  | Hdllseg (k, hpara, iF, oB, oF, iB, shared) ->
      let iF' = fe iF in
      let oB' = fe oB in
      let oF' = fe oF in
      let iB' = fe iB in
      let shared' = list_map fe shared in
      Hdllseg (k, hpara, iF', oB', oF', iB', shared')

let rec strexp_instmap (f: inst -> inst) strexp = match strexp with
  | Eexp (e, inst) ->
      Eexp (e, f inst)
  | Estruct (fld_se_list, inst) ->
      let f_fld_se (fld, se) = (fld, strexp_instmap f se) in
      Estruct (list_map f_fld_se fld_se_list, f inst)
  | Earray (size, idx_se_list, inst) ->
      let f_idx_se (idx, se) =
        (idx, strexp_instmap f se) in
      Earray (size, list_map f_idx_se idx_se_list, f inst)

and hpara_instmap (f: inst -> inst) hpara =
  { hpara with body = list_map (hpred_instmap f) hpara.body }

and hpara_dll_instmap (f: inst -> inst) hpara_dll =
  { hpara_dll with body_dll = list_map (hpred_instmap f) hpara_dll.body_dll }

and hpred_instmap (fn: inst -> inst) (hpred: hpred) : hpred = match hpred with
  | Hpointsto (e, se, te) ->
      let se' = strexp_instmap fn se in
      Hpointsto(e, se', te)
  | Hlseg (k, hpara, e, f, el) ->
      Hlseg (k, hpara_instmap fn hpara, e, f, el)
  | Hdllseg (k, hpar_dll, e, f, g, h, el) ->
      Hdllseg (k, hpara_dll_instmap fn hpar_dll, e, f, g, h, el)

let hpred_list_expmap (f: exp * inst option -> exp * inst option) (hlist: hpred list) =
  list_map (hpred_expmap f) hlist

let atom_expmap (f: exp -> exp) = function
  | Aeq (e1, e2) -> Aeq (f e1, f e2)
  | Aneq (e1, e2) -> Aneq (f e1, f e2)

let atom_list_expmap (f: exp -> exp) (alist: atom list) =
  list_map (atom_expmap f) alist

(** {2 Function for computing lexps in sigma} *)

let hpred_get_lexp acc = function
  | Hpointsto(e, _, _) -> e:: acc
  | Hlseg(_, _, e, _, _) -> e:: acc
  | Hdllseg(_, _, e1, _, _, e2, _) -> e1:: e2:: acc

let hpred_list_get_lexps (filter: exp -> bool) (hlist: hpred list) : exp list =
  let lexps = list_fold_left hpred_get_lexp [] hlist in
  list_filter filter lexps

(** {2 Utility Functions for Expressions} *)

let unsome_typ s = function
  | Some default_typ -> default_typ
  | None ->
      L.err "No default typ in %s@." s;
      assert false

(** Turn an expression representing a type into the type it represents
If not a sizeof, return the default type if given, otherwise raise an exception *)
let texp_to_typ default_opt = function
  | Sizeof (t, _) -> t
  | t ->
      unsome_typ "texp_to_typ" default_opt

(** If a struct type with field f, return the type of f.
If not, return the default type if given, otherwise raise an exception *)
let struct_typ_fld default_opt f =
  let def () = unsome_typ "struct_typ_fld" default_opt in
  function
  | Tstruct (ftal, sftal, _, _, _, _, _) ->
      (try (fun (x, y, z) -> y) (list_find (fun (_f, t, ann) -> Ident.fieldname_equal _f f) ftal)
      with Not_found -> def ())
  | _ -> def ()

(** If an array type, return the type of the element.
If not, return the default type if given, otherwise raise an exception *)
let array_typ_elem default_opt = function
  | Tarray (t_el, _) -> t_el
  | t ->
      unsome_typ "array_typ_elem" default_opt

(** Return the root of [lexp]. *)
let rec root_of_lexp lexp = match lexp with
  | Var _ -> lexp
  | Const _ -> lexp
  | Cast (t, e) -> root_of_lexp e
  | UnOp _ | BinOp _ -> lexp
  | Lvar _ -> lexp
  | Lfield(e, _, _) -> root_of_lexp e
  | Lindex(e, _) -> root_of_lexp e
  | Sizeof _ -> lexp

(** Checks whether an expression denotes a location by pointer arithmetic.
Currently, catches array - indexing expressions such as a[i] only. *)
let rec exp_pointer_arith = function
  | Lfield (e, _, _) -> exp_pointer_arith e
  | Lindex _ -> true
  | _ -> false

let exp_get_undefined footprint =
  Var (Ident.create_fresh (if footprint then Ident.kfootprint else Ident.kprimed))

(** Create integer constant *)
let exp_int i = Const (Cint i)

(** Create float constant *)
let exp_float v = Const (Cfloat v)

(** Integer constant 0 *)
let exp_zero = exp_int Int.zero

(** Null constant *)
let exp_null = exp_int Int.null

(** Integer constant 1 *)
let exp_one = exp_int Int.one

(** Integer constant -1 *)
let exp_minus_one = exp_int Int.minus_one

(** Create integer constant corresponding to the boolean value *)
let exp_bool b =
  if b then exp_one else exp_zero

(** Create expresstion [e1 == e2] *)
let exp_eq e1 e2 =
  BinOp (Eq, e1, e2)

(** Create expresstion [e1 != e2] *)
let exp_ne e1 e2 =
  BinOp (Ne, e1, e2)

(** Create expression [e1 <= e2] *)
let exp_le e1 e2 =
  BinOp (Le, e1, e2)

(** Create expression [e1 < e2] *)
let exp_lt e1 e2 =
  BinOp (Lt, e1, e2)

(** {2 Functions for computing program variables} *)

let rec exp_fpv = function
  | Var id -> []
  | Const (Cexn e) -> exp_fpv e
  | Const (Ctuple el) -> exp_list_fpv el
  | Const _ -> []
  | Cast (_, e) | UnOp (_, e, _) -> exp_fpv e
  | BinOp (_, e1, e2) -> exp_fpv e1 @ exp_fpv e2
  | Lvar name -> [name]
  | Lfield (e, _, _) -> exp_fpv e
  | Lindex (e1, e2) -> exp_fpv e1 @ exp_fpv e2
  | Sizeof _ -> []

and exp_list_fpv el = list_flatten (list_map exp_fpv el)

let atom_fpv = function
  | Aeq (e1, e2) -> exp_fpv e1 @ exp_fpv e2
  | Aneq (e1, e2) -> exp_fpv e1 @ exp_fpv e2

let rec strexp_fpv = function
  | Eexp (e, inst) -> exp_fpv e
  | Estruct (fld_se_list, inst) ->
      let f (_, se) = strexp_fpv se in
      list_flatten (list_map f fld_se_list)
  | Earray (size, idx_se_list, inst) ->
      let fpv_in_size = exp_fpv size in
      let f (idx, se) = exp_fpv idx @ strexp_fpv se in
      fpv_in_size @ list_flatten (list_map f idx_se_list)

and hpred_fpv = function
  | Hpointsto (base, se, te) ->
      exp_fpv base @ strexp_fpv se @ exp_fpv te
  | Hlseg (_, para, e1, e2, elist) ->
      let fpvars_in_elist = exp_list_fpv elist in
      hpara_fpv para (* This set has to be empty. *)
      @ exp_fpv e1
      @ exp_fpv e2
      @ fpvars_in_elist
  | Hdllseg (_, para, e1, e2, e3, e4, elist) ->
      let fpvars_in_elist = exp_list_fpv elist in
      hpara_dll_fpv para (* This set has to be empty. *)
      @ exp_fpv e1
      @ exp_fpv e2
      @ exp_fpv e3
      @ exp_fpv e4
      @ fpvars_in_elist

(** hpara should not contain any program variables.
This is because it might cause problems when we do interprocedural
analysis. In interprocedural analysis, we should consider the issue
of scopes of program variables. *)
and hpara_fpv para =
  let fpvars_in_body = list_flatten (list_map hpred_fpv para.body) in
  match fpvars_in_body with
  | [] -> []
  | _ -> assert false

(** hpara_dll should not contain any program variables.
This is because it might cause problems when we do interprocedural
analysis. In interprocedural analysis, we should consider the issue
of scopes of program variables. *)
and hpara_dll_fpv para =
  let fpvars_in_body = list_flatten (list_map hpred_fpv para.body_dll) in
  match fpvars_in_body with
  | [] -> []
  | _ -> assert false

(** {2 Functions for computing free non-program variables} *)

(** Type of free variables. These include primed, normal and footprint variables. We keep a count of how many types the variables appear. *)
type fav = Ident.t list ref

let fav_new () =
  ref []

(** Emptyness check. *)
let fav_is_empty fav = match !fav with
  | [] -> true
  | _ -> false

(** Check whether a predicate holds for all elements. *)
let fav_for_all fav predicate =
  list_for_all predicate !fav

(** Check whether a predicate holds for some elements. *)
let fav_exists fav predicate =
  list_exists predicate !fav

(** flag to indicate whether fav's are stored in duplicate form -- only to be used with fav_to_list *)
let fav_duplicates = ref false

(** extend [fav] with a [id] *)
let (++) fav id =
  if !fav_duplicates || not (list_exists (Ident.equal id) !fav) then fav := id::!fav

(** extend [fav] with ident list [idl] *)
let (+++) fav idl =
  list_iter (fun id -> fav ++ id) idl

(** add identity lists to fav *)
let ident_list_fav_add idl fav =
  fav +++ idl

(** Convert a list to a fav. *)
let fav_from_list l =
  let fav = fav_new () in
  let _ = list_iter (fun id -> fav ++ id) l in
  fav

let rec remove_duplicates_from_sorted special_equal = function
  | [] -> []
  | [x] -> [x]
  | x:: y:: l ->
      if (special_equal x y)
      then remove_duplicates_from_sorted special_equal (y:: l)
      else x:: (remove_duplicates_from_sorted special_equal (y:: l))

(** Convert a [fav] to a list of identifiers while preserving the order
that the identifiers were added to [fav]. *)
let fav_to_list fav =
  list_rev !fav

(** Pretty print a fav. *)
let pp_fav pe f fav =
  (pp_seq (Ident.pp pe)) f (fav_to_list fav)

(** Copy a [fav]. *)
let fav_copy fav =
  ref (list_map (fun x -> x) !fav)

(** Turn a xxx_fav_add function into a xxx_fav function *)
let fav_imperative_to_functional f x =
  let fav = fav_new () in
  let _ = f fav x in
  fav

(** [fav_filter_ident fav f] only keeps [id] if [f id] is true. *)
let fav_filter_ident fav filter =
  fav := list_filter filter !fav

(** Like [fav_filter_ident] but return a copy. *)
let fav_copy_filter_ident fav filter =
  ref (list_filter filter !fav)

(** checks whether every element in l1 appears l2 **)
let rec ident_sorted_list_subset l1 l2 =
  match l1, l2 with
  | [], _ -> true
  | _:: _,[] -> false
  | id1:: l1, id2:: l2 ->
      let n = Ident.compare id1 id2 in
      if n = 0 then ident_sorted_list_subset l1 (id2:: l2)
      else if n > 0 then ident_sorted_list_subset (id1:: l1) l2
      else false

(** [fav_subset_ident fav1 fav2] returns true if every ident in [fav1]
is in [fav2].*)
let fav_subset_ident fav1 fav2 =
  ident_sorted_list_subset (fav_to_list fav1) (fav_to_list fav2)

let fav_mem fav id =
  list_exists (Ident.equal id) !fav

let rec exp_fav_add fav = function
  | Var id -> fav ++ id
  | Const (Cexn e) -> exp_fav_add fav e
  | Const (Ctuple el) -> list_iter (exp_fav_add fav) el
  | Const _ -> ()
  | Cast (_, e) | UnOp (_, e, _) -> exp_fav_add fav e
  | BinOp (_, e1, e2) -> exp_fav_add fav e1; exp_fav_add fav e2
  | Lvar id -> () (* do nothing since we only count non-program variables *)
  | Lfield (e, _, _) -> exp_fav_add fav e
  | Lindex (e1, e2) -> exp_fav_add fav e1; exp_fav_add fav e2
  | Sizeof _ -> ()

let exp_fav =
  fav_imperative_to_functional exp_fav_add

let exp_fav_list e =
  fav_to_list (exp_fav e)

let rec ident_in_exp id e =
  let fav = fav_new () in
  exp_fav_add fav e;
  fav_mem fav id

let atom_fav_add fav = function
  | Aeq (e1, e2) | Aneq(e1, e2) -> exp_fav_add fav e1; exp_fav_add fav e2

let atom_fav =
  fav_imperative_to_functional atom_fav_add

(** Atoms do not contain binders *)
let atom_av_add = atom_fav_add

let hpara_fav_add fav para = () (* Global invariant: hpara is closed *)
let hpara_dll_fav_add fav para = () (* Global invariant: hpara_dll is closed *)

let rec strexp_fav_add fav = function
  | Eexp (e, inst) -> exp_fav_add fav e
  | Estruct (fld_se_list, inst) ->
      list_iter (fun (_, se) -> strexp_fav_add fav se) fld_se_list
  | Earray (size, idx_se_list, inst) ->
      exp_fav_add fav size;
      list_iter (fun (e, se) -> exp_fav_add fav e; strexp_fav_add fav se) idx_se_list

let rec hpred_fav_add fav = function
  | Hpointsto (base, sexp, te) -> exp_fav_add fav base; strexp_fav_add fav sexp; exp_fav_add fav te
  | Hlseg (_, para, e1, e2, elist) ->
      hpara_fav_add fav para;
      exp_fav_add fav e1; exp_fav_add fav e2;
      list_iter (exp_fav_add fav) elist
  | Hdllseg (_, para, e1, e2, e3, e4, elist) ->
      hpara_dll_fav_add fav para;
      exp_fav_add fav e1; exp_fav_add fav e2;
      exp_fav_add fav e3; exp_fav_add fav e4;
      list_iter (exp_fav_add fav) elist

let hpred_fav =
  fav_imperative_to_functional hpred_fav_add

(** This function should be used before adding a new
index to Earray. The [exp] is the newly created
index. This function "cleans" [exp] according to whether it is the footprint or current part of the prop.
The function faults in the re - execution mode, as an internal check of the tool. *)
let array_clean_new_index footprint_part new_idx =
  if footprint_part && not !Config.footprint then assert false;
  let fav = exp_fav new_idx in
  if footprint_part && fav_exists fav (fun id -> not (Ident.is_footprint id)) then
    begin
      L.d_warning ("Array index " ^ (exp_to_string new_idx) ^
          " has non-footprint vars: replaced by fresh footprint var");
      L.d_ln ();
      let id = Ident.create_fresh Ident.kfootprint in
      Var id
    end
  else new_idx

(** {2 Functions for computing all free or bound non-program variables} *)

let exp_av_add = exp_fav_add (** Expressions do not bind variables *)

let strexp_av_add = strexp_fav_add (** Structured expressions do not bind variables *)

let rec hpara_av_add fav para =
  list_iter (hpred_av_add fav) para.body;
  fav ++ para.root; fav ++ para.next;
  fav +++ para.svars; fav +++ para.evars

and hpara_dll_av_add fav para =
  list_iter (hpred_av_add fav) para.body_dll;
  fav ++ para.cell; fav ++ para.blink; fav ++ para.flink;
  fav +++ para.svars_dll; fav +++ para.evars_dll

and hpred_av_add fav = function
  | Hpointsto (base, se, te) ->
      exp_av_add fav base; strexp_av_add fav se; exp_av_add fav te
  | Hlseg (_, para, e1, e2, elist) ->
      hpara_av_add fav para;
      exp_av_add fav e1; exp_av_add fav e2;
      list_iter (exp_av_add fav) elist
  | Hdllseg (_, para, e1, e2, e3, e4, elist) ->
      hpara_dll_av_add fav para;
      exp_av_add fav e1; exp_av_add fav e2;
      exp_av_add fav e3; exp_av_add fav e4;
      list_iter (exp_av_add fav) elist

let hpara_shallow_av_add fav para =
  list_iter (hpred_fav_add fav) para.body;
  fav ++ para.root; fav ++ para.next;
  fav +++ para.svars; fav +++ para.evars

let hpara_dll_shallow_av_add fav para =
  list_iter (hpred_fav_add fav) para.body_dll;
  fav ++ para.cell; fav ++ para.blink; fav ++ para.flink;
  fav +++ para.svars_dll; fav +++ para.evars_dll

(** Variables in hpara, excluding bound vars in the body *)
let hpara_shallow_av = fav_imperative_to_functional hpara_shallow_av_add

(** Variables in hpara_dll, excluding bound vars in the body *)
let hpara_dll_shallow_av = fav_imperative_to_functional hpara_dll_shallow_av_add

(** {2 Functions for Substitution} *)

let rec reverse_with_base base = function
  | [] -> base
  | x:: l -> reverse_with_base (x:: base) l

let sorted_list_merge compare l1_in l2_in =
  let rec merge acc l1 l2 =
    match l1, l2 with
    | [], l2 -> reverse_with_base l2 acc
    | l1, [] -> reverse_with_base l1 acc
    | x1 :: l1', x2 :: l2' ->
        if compare x1 x2 <= 0 then merge (x1:: acc) l1' l2
        else merge (x2 :: acc) l1 l2' in
  merge [] l1_in l2_in

let rec sorted_list_check_consecutives f = function
  | [] | [_] -> false
  | x1:: ((x2:: _) as l) ->
      if f x1 x2 then true else sorted_list_check_consecutives f l

(** substitution *)
type subst = (Ident.t * exp) list

(** Comparison between substitutions. *)
let rec sub_compare (sub1: subst) (sub2: subst) =
  if sub1 == sub2 then 0
  else match sub1, sub2 with
    | [],[] -> 0
    | [], _ :: _ -> - 1
    | (i1, e1) :: sub1', (i2, e2):: sub2' ->
        let n = Ident.compare i1 i2 in
        if n <> 0 then n
        else let n = exp_compare e1 e2 in
          if n <> 0 then n
          else sub_compare sub1' sub2'
    | _ :: _, [] -> 1

(** Equality for substitutions. *)
let sub_equal sub1 sub2 =
  sub_compare sub1 sub2 = 0

let sub_check_duplicated_ids sub =
  let f (id1, _) (id2, _) = Ident.equal id1 id2 in
  sorted_list_check_consecutives f sub

let sub_check_sortedness sub =
  let sub' = list_sort ident_exp_compare sub in
  sub_equal sub sub'

let sub_check_inv sub =
  (sub_check_sortedness sub) && not (sub_check_duplicated_ids sub)

(** Create a substitution from a list of pairs.
For all (id1, e1), (id2, e2) in the input list,
if id1 = id2, then e1 = e2. *)
let sub_of_list sub =
  let sub' = list_sort ident_exp_compare sub in
  let sub'' = remove_duplicates_from_sorted ident_exp_equal sub' in
  (if sub_check_duplicated_ids sub'' then assert false);
  sub'

(** like sub_of_list, but allow duplicate ids and only keep the first occurrence *)
let sub_of_list_duplicates sub =
  let sub' = list_sort ident_exp_compare sub in
  let rec remove_duplicate_ids = function
    | (id1, e1) :: (id2, e2) :: l ->
        if Ident.equal id1 id2
        then remove_duplicate_ids ((id1, e1) :: l)
        else (id1, e1) :: remove_duplicate_ids ((id2, e2) :: l)
    | l -> l in
  remove_duplicate_ids sub'

(** Convert a subst to a list of pairs. *)
let sub_to_list sub =
  sub

(** The empty substitution. *)
let sub_empty = sub_of_list []

(** Join two substitutions into one.
For all id in dom(sub1) cap dom(sub2), sub1(id) = sub2(id). *)
let sub_join sub1 sub2 =
  let sub = sorted_list_merge ident_exp_compare sub1 sub2 in
  let sub' = remove_duplicates_from_sorted ident_exp_equal sub in
  (if sub_check_duplicated_ids sub' then assert false);
  sub

(** Compute the common id-exp part of two inputs [subst1] and [subst2].
The first component of the output is this common part.
The second and third components are the remainder of [subst1]
and [subst2], respectively. *)
let sub_symmetric_difference sub1_in sub2_in =
  let rec diff sub_common sub1_only sub2_only sub1 sub2 =
    match sub1, sub2 with
    | [], _ | _, [] ->
        let sub1_only' = reverse_with_base sub1 sub1_only in
        let sub2_only' = reverse_with_base sub2 sub2_only in
        let sub_common = reverse_with_base [] sub_common in
        (sub_common, sub1_only', sub2_only')
    | id_e1 :: sub1', id_e2 :: sub2' ->
        let n = ident_exp_compare id_e1 id_e2 in
        if n = 0 then
          diff (id_e1:: sub_common) sub1_only sub2_only sub1' sub2'
        else if n < 0 then
          diff sub_common (id_e1:: sub1_only) sub2_only sub1' sub2
        else
          diff sub_common sub1_only (id_e2:: sub2_only) sub1 sub2' in
  diff [] [] [] sub1_in sub2_in

module Typtbl = Hashtbl.Make (struct type t = typ let equal = typ_equal let hash = Hashtbl.hash end)

let typ_update_memo = Typtbl.create 17

(** [sub_find filter sub] returns the expression associated to the first identifier that satisfies [filter]. Raise [Not_found] if there isn't one. *)
let sub_find filter (sub: subst) =
  snd (list_find (fun (i, _) -> filter i) sub)

(** [sub_filter filter sub] restricts the domain of [sub] to the
identifiers satisfying [filter]. *)
let sub_filter filter (sub: subst) =
  list_filter (fun (i, _) -> filter i) sub

(** [sub_filter_pair filter sub] restricts the domain of [sub] to the
identifiers satisfying [filter(id, sub(id))]. *)
let sub_filter_pair = list_filter

(** [sub_range_partition filter sub] partitions [sub] according to
whether range expressions satisfy [filter]. *)
let sub_range_partition filter (sub: subst) =
  list_partition (fun (_, e) -> filter e) sub

(** [sub_domain_partition filter sub] partitions [sub] according to
whether domain identifiers satisfy [filter]. *)
let sub_domain_partition filter (sub: subst) =
  list_partition (fun (i, _) -> filter i) sub

(** Return the list of identifiers in the domain of the substitution. *)
let sub_domain sub =
  list_map fst sub

(** Return the list of expressions in the range of the substitution. *)
let sub_range sub =
  list_map snd sub

(** [sub_range_map f sub] applies [f] to the expressions in the range of [sub]. *)
let sub_range_map f sub =
  sub_of_list (list_map (fun (i, e) -> (i, f e)) sub)

(** [sub_map f g sub] applies the renaming [f] to identifiers in the domain
of [sub] and the substitution [g] to the expressions in the range of [sub]. *)
let sub_map f g sub =
  sub_of_list (list_map (fun (i, e) -> (f i, g e)) sub)

let mem_sub id sub =
  list_exists (fun (id1, _) -> Ident.equal id id1) sub

(** Extend substitution and return [None] if not possible. *)
let extend_sub sub id exp : subst option =
  let compare (id1, _) (id2, _) = Ident.compare id1 id2 in
  if mem_sub id sub then None
  else Some (sorted_list_merge compare sub [(id, exp)])

(** Free auxilary variables in the domain and range of the
substitution. *)
let sub_fav_add fav (sub: subst) =
  list_iter (fun (id, e) -> fav ++ id; exp_fav_add fav e) sub

let sub_fpv (sub: subst) =
  list_flatten (list_map (fun (_, e) -> exp_fpv e) sub)

(** Substitutions do not contain binders *)
let sub_av_add = sub_fav_add

let rec typ_sub (subst: subst) typ =
  match typ with
  | Tvar _
  | Tint _
  | Tfloat _
  | Tvoid
  | Tstruct _
  | Tfun _ ->
      typ
  | Tptr (t', pk) ->
      Tptr (typ_sub subst t', pk)
  | Tarray (t, e) ->
      Tarray (typ_sub subst t, exp_sub subst e)
  | Tenum econsts ->
      typ

and exp_sub (subst: subst) e =
  match e with
  | Var id ->
      let rec apply_sub = function
        | [] -> e
        | (i, e):: l -> if Ident.equal i id then e else apply_sub l in
      apply_sub subst
  | Const (Cexn e1) ->
      let e1' = exp_sub subst e1 in
      Const (Cexn e1')
  | Const (Ctuple el) ->
      let el' = list_map (exp_sub subst) el in
      Const (Ctuple el')
  | Const _ ->
      e
  | Cast (t, e1) ->
      let e1' = exp_sub subst e1 in
      Cast (t, e1')
  | UnOp (op, e1, typo) ->
      let e1' = exp_sub subst e1 in
      let typo' = match typo with
        | None -> None
        | Some typ -> Some (typ_sub subst typ) in
      UnOp(op, e1', typo')
  | BinOp (op, e1, e2) ->
      let e1' = exp_sub subst e1 in
      let e2' = exp_sub subst e2 in
      BinOp (op, e1', e2')
  | Lvar id ->
      e
  | Lfield (e1, fld, typ) ->
      let e1' = exp_sub subst e1 in
      let typ' = typ_sub subst typ in
      Lfield (e1', fld, typ')
  | Lindex (e1, e2) ->
      let e1' = exp_sub subst e1 in
      let e2' = exp_sub subst e2 in
      Lindex (e1', e2')
  | Sizeof (t, s) ->
      Sizeof (typ_sub subst t, s)

let instr_sub (subst: subst) instr =
  let id_s id = match exp_sub subst (Var id) with
    | Var id' -> id'
    | _ -> id in
  let exp_s = exp_sub subst in
  let typ_s = typ_sub subst in
  match instr with
  | Letderef (id, e, t, loc) ->
      Letderef (id_s id, exp_s e, typ_s t, loc)
  | Set (e1, t, e2, loc) ->
      Set (exp_s e1, typ_s t, exp_s e2, loc)
  | Prune (cond, loc, true_branch, ik) ->
      Prune (exp_s cond, loc, true_branch, ik)
  | Call (ret_ids, e, arg_ts, loc, cf) ->
      let arg_s (e, t) = (exp_s e, typ_s t) in
      Call (list_map id_s ret_ids, exp_s e, list_map arg_s arg_ts, loc, cf)
  | Nullify (pvar, loc, deallocate) ->
      instr
  | Abstract loc ->
      instr
  | Remove_temps (temps, loc) ->
      Remove_temps (list_map id_s temps, loc)
  | Stackop (stackop, loc) ->
      instr
  | Declare_locals (ptl, loc) ->
      let pt_s (pv, t) = (pv, typ_s t) in
      Declare_locals (list_map pt_s ptl, loc)
  | Goto_node (e, loc) ->
      Goto_node (exp_s e, loc)

let call_flags_compare cflag1 cflag2 =
  let n = bool_compare cflag1.cf_virtual cflag2.cf_virtual in
  if n <> 0 then n else bool_compare cflag1.cf_noreturn cflag2.cf_noreturn

let exp_typ_compare (exp1, typ1) (exp2, typ2) =
  let n = exp_compare exp1 exp2 in
  if n <> 0 then n else typ_compare typ1 typ2

let instr_compare instr1 instr2 = match instr1, instr2 with
  | Letderef (id1, e1, t1, loc1), Letderef (id2, e2, t2, loc2) ->
      let n = Ident.compare id1 id2 in
      if n <> 0 then n else let n = exp_compare e1 e2 in
        if n <> 0 then n else let n = typ_compare t1 t2 in
          if n <> 0 then n else loc_compare loc1 loc2
  | Letderef _, _ -> -1
  | _, Letderef _ -> 1
  | Set (e11, t1, e21, loc1), Set (e12, t2, e22, loc2) ->
      let n = exp_compare e11 e12 in
      if n <> 0 then n else let n = typ_compare t1 t2 in
        if n <> 0 then n else let n = exp_compare e21 e22 in
          if n <> 0 then n else loc_compare loc1 loc2
  | Set _, _ -> -1
  | _, Set _ -> 1
  | Prune (cond1, loc1, true_branch1, ik1), Prune (cond2, loc2, true_branch2, ik2) ->
      let n = exp_compare cond1 cond2 in
      if n <> 0 then n else let n = loc_compare loc1 loc2 in
        if n <> 0 then n else let n = bool_compare true_branch1 true_branch2 in
          if n <> 0 then n else Pervasives.compare ik1 ik2
  | Prune _, _ -> -1
  | _, Prune _ -> 1
  | Call (ret_ids1, e1, arg_ts1, loc1, cf1), Call (ret_ids2, e2, arg_ts2, loc2, cf2) ->
      let n = list_compare Ident.compare ret_ids1 ret_ids2 in
      if n <> 0 then n else let n = exp_compare e1 e2 in
        if n <> 0 then n else let n = list_compare exp_typ_compare arg_ts1 arg_ts2 in
          if n <> 0 then n else let n = loc_compare loc1 loc2 in
            if n <> 0 then n else call_flags_compare cf1 cf2
  | Call _, _ -> -1
  | _, Call _ -> 1
  | Nullify (pvar1, loc1, deallocate1), Nullify (pvar2, loc2, deallocate2) ->
      let n = pvar_compare pvar1 pvar2 in
      if n <> 0 then n else let n = loc_compare loc1 loc2 in
        if n <> 0 then n else bool_compare deallocate1 deallocate2
  | Nullify _, _ -> -1
  | _, Nullify _ -> 1
  | Abstract loc1, Abstract loc2 ->
      loc_compare loc1 loc2
  | Abstract _, _ -> -1
  | _, Abstract _ -> 1
  | Remove_temps (temps1, loc1), Remove_temps (temps2, loc2) ->
      let n = list_compare Ident.compare temps1 temps2 in
      if n <> 0 then n else loc_compare loc1 loc2
  | Remove_temps _, _ -> -1
  | _, Remove_temps _ -> 1
  | Stackop (stackop1, loc1), Stackop (stackop2, loc2) ->
      let n = Pervasives.compare stackop1 stackop2 in
      if n <> 0 then n else loc_compare loc1 loc2
  | Stackop _, _ -> -1
  | _, Stackop _ -> 1
  | Declare_locals (ptl1, loc1), Declare_locals (ptl2, loc2) ->
      let pt_compare (pv1, t1) (pv2, t2) =
        let n = pvar_compare pv1 pv2 in
        if n <> 0 then n else typ_compare t1 t2 in

      let n = list_compare pt_compare ptl1 ptl2 in
      if n <> 0 then n else loc_compare loc1 loc2
  | Declare_locals _, _ -> -1
  | _, Declare_locals _ -> 1
  | Goto_node (e1, loc1), Goto_node (e2, loc2) ->
      let n = exp_compare e1 e2 in
      if n <> 0 then n else loc_compare loc1 loc2

let atom_sub subst =
  atom_expmap (exp_sub subst)

let range_sub subst range =
  let lower, upper = range in
  let lower' = exp_sub subst lower in
  let upper' = exp_sub subst upper in
  (lower', upper')

let hpred_sub subst =
  let f (e, inst_opt) = (exp_sub subst e, inst_opt) in
  hpred_expmap f

let hpara_sub subst para = para

let hpara_dll_sub subst para = para

(** {2 Functions for replacing occurrences of expressions.} *)

let exp_replace_exp epairs e =
  try
    let (_, e') = list_find (fun (e1, _) -> exp_equal e e1) epairs in
    e'
  with Not_found -> e

let exp_list_replace_exp epairs l =
  list_map (exp_replace_exp epairs) l

let atom_replace_exp epairs = function
  | Aeq (e1, e2) ->
      let e1' = exp_replace_exp epairs e1 in
      let e2' = exp_replace_exp epairs e2 in
      Aeq (e1', e2')
  | Aneq (e1, e2) ->
      let e1' = exp_replace_exp epairs e1 in
      let e2' = exp_replace_exp epairs e2 in
      Aneq (e1', e2')

let rec strexp_replace_exp epairs = function
  | Eexp (e, inst) ->
      Eexp (exp_replace_exp epairs e, inst)
  | Estruct (fsel, inst) ->
      let f (fld, se) = (fld, strexp_replace_exp epairs se) in
      Estruct (list_map f fsel, inst)
  | Earray (size, isel, inst) ->
      let size' = exp_replace_exp epairs size in
      let f (idx, se) =
        let idx' = exp_replace_exp epairs idx in
        (idx', strexp_replace_exp epairs se) in
      Earray (size', list_map f isel, inst)

let rec hpred_replace_exp epairs = function
  | Hpointsto (root, se, te) ->
      let root_repl = exp_replace_exp epairs root in
      let strexp_repl = strexp_replace_exp epairs se in
      let te_repl = exp_replace_exp epairs te in
      Hpointsto (root_repl, strexp_repl, te_repl)
  | Hlseg (k, para, root, next, shared) ->
      let root_repl = exp_replace_exp epairs root in
      let next_repl = exp_replace_exp epairs next in
      let shared_repl = list_map (exp_replace_exp epairs) shared in
      Hlseg (k, para, root_repl, next_repl, shared_repl)
  | Hdllseg (k, para, e1, e2, e3, e4, shared) ->
      let e1' = exp_replace_exp epairs e1 in
      let e2' = exp_replace_exp epairs e2 in
      let e3' = exp_replace_exp epairs e3 in
      let e4' = exp_replace_exp epairs e4 in
      let shared_repl = list_map (exp_replace_exp epairs) shared in
      Hdllseg (k, para, e1', e2', e3', e4', shared_repl)

(** {2 Compaction} *)
module ExpHash = Hashtbl.Make (struct
    type t = exp
    let equal = exp_equal
    let hash = Hashtbl.hash end)

module HpredHash = Hashtbl.Make (struct
    type t = hpred
    let equal = hpred_equal
    let hash = Hashtbl.hash end)

type sharing_env =
  { exph : exp ExpHash.t;
    hpredh : hpred HpredHash.t }

(** Create a sharing env to store canonical representations *)
let create_sharing_env () =
  { exph = ExpHash.create 3;
    hpredh = HpredHash.create 3 }

(** Return a canonical representation of the exp *)
let exp_compact sh e =
  try ExpHash.find sh.exph e with
  | Not_found ->
      ExpHash.add sh.exph e e;
      e

let rec sexp_compact sh se =
  match se with
  | Eexp (e, inst) ->
      Eexp (exp_compact sh e, inst)
  | Estruct (fsel, inst) ->
      Estruct (list_map (fun (f, se) -> (f, sexp_compact sh se)) fsel, inst)
  | Earray _ ->
      se

(** Return a compact representation of the hpred *)
let _hpred_compact sh hpred = match hpred with
  | Hpointsto (e1, se, e2) ->
      let e1' = exp_compact sh e1 in
      let e2' = exp_compact sh e2 in
      let se' = sexp_compact sh se in
      Hpointsto (e1', se', e2')
  | Hlseg _ -> hpred
  | Hdllseg _ -> hpred

let hpred_compact sh hpred =
  try HpredHash.find sh.hpredh hpred with
  | Not_found ->
      let hpred' = _hpred_compact sh hpred in
      HpredHash.add sh.hpredh hpred' hpred';
      hpred'

(** {2 Type Environment} *)
(** hash tables on strings *)

module TypenameHash =
  Hashtbl.Make(struct
    type t = typename
    let equal tn1 tn2 = typename_equal tn1 tn2
    let hash = Hashtbl.hash
  end)

(** Type for type environment. *)
type tenv = typ TypenameHash.t

(** Create a new type environment. *)
let create_tenv () = TypenameHash.create 1000

(** Check if typename is found in tenv *)
let tenv_mem tenv name =
  TypenameHash.mem tenv name

(** Look up a name in the global type environment. *)
let tenv_lookup tenv name =
  try Some (TypenameHash.find tenv name)
  with Not_found -> None

(** Add a (name,type) pair to the global type environment. *)
let tenv_add tenv name typ =
  TypenameHash.replace tenv name typ

(** look up the type for a mangled name in the current type environment *)
let get_typ name csu_option tenv =
  let csu = match csu_option with
    | Some t -> t
    | None -> Class in
  tenv_lookup tenv (TN_csu (csu, name))

(** expand a type if it is a typename by looking it up in the type environment *)
let rec expand_type tenv typ =
  match typ with
  | Tvar tname ->
      begin
        match tenv_lookup tenv tname with
        | None -> assert false
        | Some typ' -> expand_type tenv typ'
      end
  | _ -> typ

(** type environment used for parsing, to be set by the client of the parser module *)
let tenv_for_parsing = ref (create_tenv ())

(** Serializer for type environments *)
let tenv_serializer : tenv Serialization.serializer = Serialization.create_serializer Serialization.tenv_key

let global_tenv: (tenv option) Lazy.t =
  lazy (Serialization.from_file tenv_serializer (DB.global_tenv_fname ()))

(** Load a type environment from a file *)
let load_tenv_from_file (filename : DB.filename) : tenv option =
  if filename = DB.global_tenv_fname () then
    Lazy.force global_tenv
  else
    Serialization.from_file tenv_serializer filename

(** Save a type environment into a file *)
let store_tenv_to_file (filename : DB.filename) (tenv : tenv) =
  Serialization.to_file tenv_serializer filename tenv

let tenv_iter f tenv =
  TypenameHash.iter f tenv

let tenv_fold f tenv =
  TypenameHash.fold f tenv

let pp_tenv f (tenv : tenv) =
  TypenameHash.iter
    (fun name typ ->
          Format.fprintf f "@[<6>NAME: %s@." (typename_to_string name);
          Format.fprintf f "@[<6>TYPE: %a@." (pp_typ_full pe_text) typ)
    tenv

(** {2 Functions for constructing or destructing entities in this module} *)

(** [mk_pvar name proc_name] creates a program var with the given function name *)
let mk_pvar (name: Mangled.t) (proc_name: Procname.t) : pvar =
  { pv_name = name; pv_kind = Local_var proc_name }

(** [mk_pvar_callee name proc_name] creates a program var for a callee function with the given function name *)
let mk_pvar_callee (name: Mangled.t) (proc_name: Procname.t) : pvar =
  { pv_name = name; pv_kind = Callee_var proc_name }

(** create a global variable with the given name *)
let mk_pvar_global (name: Mangled.t) : pvar =
  { pv_name = name; pv_kind = Global_var }

(** create an abducted return variable for a call to [proc_name] at [loc] *)
let mk_pvar_abducted_ret (proc_name : Procname.t) (loc : location) : pvar =
  let name = Mangled.from_string ("$RET_" ^ (Procname.to_unique_id proc_name)) in
  { pv_name = name; pv_kind = Abducted_retvar (proc_name, loc) }

let mk_pvar_abducted_ref_param (proc_name : Procname.t) (pv : pvar) (loc : location) : pvar =
  let name = Mangled.from_string ("$REF_PARAM_" ^ (Procname.to_unique_id proc_name)) in
  { pv_name = name; pv_kind = Abducted_ref_param (proc_name, pv, loc) }

(** Turn an ordinary program variable into a callee program variable *)
let pvar_to_callee pname pvar = match pvar.pv_kind with
  | Local_var _ ->
      { pvar with pv_kind = Callee_var pname }
  | Global_var -> pvar
  | Callee_var _ | Abducted_retvar _ | Abducted_ref_param _ | Seed_var ->
      L.d_str "Cannot convert pvar to callee: ";
      d_pvar pvar; L.d_ln ();
      assert false

(** Compute the offset list of an expression *)
let exp_get_offsets exp =
  let rec f offlist_past e = match e with
    | Var _ | Const _ | UnOp _ | BinOp _ | Lvar _ | Sizeof _ -> offlist_past
    | Cast(t, sub_exp) -> f offlist_past sub_exp
    | Lfield(sub_exp, fldname, typ) -> f (Off_fld (fldname, typ):: offlist_past) sub_exp
    | Lindex(sub_exp, e) -> f (Off_index e :: offlist_past) sub_exp in
  f [] exp

let exp_add_offsets exp offsets =
  let rec f acc = function
    | [] -> acc
    | Off_fld (fld, typ) :: offs' -> f (Lfield(acc, fld, typ)) offs'
    | Off_index e :: offs' -> f (Lindex(acc, e)) offs' in
  f exp offsets

(** Convert all the lseg's in sigma to nonempty lsegs. *)
let sigma_to_sigma_ne sigma : (atom list * hpred list) list =
  if !Config.nelseg then
    let f eqs_sigma_list hpred = match hpred with
      | Hpointsto _ | Hlseg(Lseg_NE, _, _, _, _) | Hdllseg(Lseg_NE, _, _, _, _, _, _) ->
          let g (eqs, sigma) = (eqs, hpred:: sigma) in
          list_map g eqs_sigma_list
      | Hlseg(Lseg_PE, para, e1, e2, el) ->
          let g (eqs, sigma) = [(Aeq(e1, e2):: eqs, sigma); (eqs, Hlseg(Lseg_NE, para, e1, e2, el):: sigma)] in
          list_flatten (list_map g eqs_sigma_list)
      | Hdllseg(Lseg_PE, para_dll, e1, e2, e3, e4, el) ->
          let g (eqs, sigma) = [(Aeq(e1, e3):: Aeq(e2, e4):: eqs, sigma); (eqs, Hdllseg(Lseg_NE, para_dll, e1, e2, e3, e4, el):: sigma)] in
          list_flatten (list_map g eqs_sigma_list) in
    list_fold_left f [([],[])] sigma
  else
    [([], sigma)]

(** [hpara_instantiate para e1 e2 elist] instantiates [para] with [e1],
[e2] and [elist]. If [para = lambda (x, y, xs). exists zs. b],
then the result of the instantiation is [b\[e1 / x, e2 / y, elist / xs, _zs'/ zs\]]
for some fresh [_zs'].*)
let hpara_instantiate para e1 e2 elist =
  let subst_for_svars =
    let g id e = (id, e) in
    try (list_map2 g para.svars elist)
    with Invalid_argument _ -> assert false in
  let ids_evars =
    let g id = Ident.create_fresh Ident.kprimed in
    list_map g para.evars in
  let subst_for_evars =
    let g id id' = (id, Var id') in
    try (list_map2 g para.evars ids_evars)
    with Invalid_argument _ -> assert false in
  let subst = sub_of_list ((para.root, e1):: (para.next, e2):: subst_for_svars@subst_for_evars) in
  (ids_evars, list_map (hpred_sub subst) para.body)

(** [hpara_dll_instantiate para cell blink flink  elist] instantiates [para] with [cell],
[blink], [flink], and [elist]. If [para = lambda (x, y, z, xs). exists zs. b],
then the result of the instantiation is [b\[cell / x, blink / y, flink / z, elist / xs, _zs'/ zs\]]
for some fresh [_zs'].*)
let hpara_dll_instantiate (para: hpara_dll) cell blink flink elist =
  let subst_for_svars =
    let g id e = (id, e) in
    try (list_map2 g para.svars_dll elist)
    with Invalid_argument _ -> assert false in
  let ids_evars =
    let g id = Ident.create_fresh Ident.kprimed in
    list_map g para.evars_dll in
  let subst_for_evars =
    let g id id' = (id, Var id') in
    try (list_map2 g para.evars_dll ids_evars)
    with Invalid_argument _ -> assert false in
  let subst = sub_of_list ((para.cell, cell):: (para.blink, blink):: (para.flink, flink):: subst_for_svars@subst_for_evars) in
  (ids_evars, list_map (hpred_sub subst) para.body_dll)

(** Return the list of expressions that could be understood as outgoing arrows from the strexp *)
let rec strexp_get_target_exps = function
  | Eexp (e, inst) -> [e]
  | Estruct (fsel, inst) -> list_flatten (list_map (fun (_, se) -> strexp_get_target_exps se) fsel)
  | Earray (_, esel, _) ->
  (* We ignore size and indices since they are not quite outgoing arrows. *)
      list_flatten (list_map (fun (_, se) -> strexp_get_target_exps se) esel)

let global_error =
  mk_pvar_global (Mangled.from_string "INFER_ERROR")

(* A block pvar used to explain retain cycles *)
let block_pvar =
  mk_pvar (Mangled.from_string "block") (Procname.from_string "")
