(*
* Copyright (c) 2009 - 2013 Monoidics ltd.
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*)

(** The Smallfoot Intermediate Language *)

open Utils

(** Programming language. *)
type language = C_CPP | Java

(** current language *)
val curr_language : language ref (* TODO: move to Config. It is good to have all global variables in the same place *)

val string_of_language : language -> string

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
  | FA_sentinel of int * int

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

(** Create a copy of a proc_attributes *)
val copy_proc_attributes : proc_attributes -> proc_attributes

(** Type for program variables. There are 4 kinds of variables:
1) local variables, used for local variables and formal parameters
2) callee program variables, used to handle recursion ([x | callee] is distinguished from [x])
3) global variables
4) seed variables, used to store the initial value of formal parameters
*)
type pvar

(** Location in the original source file *)
type location = {
  line: int; (** The line number. -1 means "do not know" *)
  col: int; (** The column number. -1 means "do not know" *)
  file: DB.source_file; (** The name of the source file *)
  nLOC : int; (** Lines of code in the source file *)
}

val dummy_location : location

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
  | Ge      (** >= (arithmetic comparison) *)
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
module Subtype : sig
  type t
  val exact : t (** denotes the current type only *)
  val subtypes : t (** denotes the current type and any subtypes *)
  val subtypes_cast : t
  val subtypes_instof : t
  val join : t -> t -> t
  (** [case_analysis (c1, st1) (c2,st2) f] performs case analysis on [c1 <: c2] according to [st1] and [st2]
  where f c1 c2 is true if c1 is a subtype of c2.
  get_subtypes returning a pair:
  - whether [st1] and [st2] admit [c1 <: c2], and in case return the updated subtype [st1]
  - whether [st1] and [st2] admit [not(c1 <: c2)], and in case return the updated subtype [st1] *)
  val case_analysis : (Mangled.t * t) -> (Mangled.t * t) -> (Mangled.t -> Mangled.t -> bool) -> (Mangled.t -> bool) -> t option * t option
  val check_subtype : (Mangled.t -> Mangled.t -> bool) -> Mangled.t -> Mangled.t -> bool
  val subtypes_to_string : t -> string
  val is_cast : t -> bool
  val is_instof : t -> bool
  (** equality ignoring flags in the subtype *)
  val equal_modulo_flag : t -> t -> bool
end

(** module for signed and unsigned integers *)
module Int : sig
  type t
  val add : t -> t -> t

  (** compare the value of the integers, notice this is different from const compare, which distinguished between signed and unsigned +1 *)
  val compare_value : t -> t -> int
  val div : t -> t -> t
  val eq : t -> t -> bool
  val of_int : int -> t
  val of_int32 : int32 -> t
  val of_int64 : int64 -> t
  val geq : t -> t -> bool
  val gt : t -> t -> bool
  val isminusone : t -> bool
  val isnegative : t -> bool
  val isnull : t -> bool
  val isone : t -> bool
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
  val null : t (** null behaves like zero except for the function isnull *)
  val one : t
  val pp : Format.formatter -> t -> unit
  val rem : t -> t -> t
  val sub : t -> t -> t
  val to_int : t -> int
  val to_signed : t -> t option (** convert to signed if the value is representable *)
  val to_string : t -> string
  val two : t
  val zero : t
end

(** Flags for a procedure call *)
type call_flags = {
  cf_virtual: bool;
  cf_noreturn : bool;
  cf_is_objc_block : bool;
}

(** Default value for call_flags where all fields are set to false *)
val cf_default : call_flags

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
  | Adiv0 of path_pos (** value appeared in second argument of division at given path position *)
  | Aobjc_null of exp (** the exp. is null because of a call to a method with exp as a null receiver *)
  | Aretval of Procname.t (** value was returned from a call to the given procedure *)

(** Categories of attributes *)
and attribute_category =
  | ACresource
  | ACautorelease
  | ACtaint
  | ACdiv0
  | ACobjc_null

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

(** Types for sil (structured) expressions. *)
and typ =
  | Tvar of typename (** named type *)
  | Tint of ikind (** integer type *)
  | Tfloat of fkind (** float type *)
  | Tvoid (** void type *)
  | Tfun of bool (** function type with noreturn attribute *)
  | Tptr of typ * ptr_kind (** pointer type *)
  | Tstruct of struct_fields * struct_fields * csu * Mangled.t option * (csu * Mangled.t) list * Procname.t list * item_annotation
  (** Structure type with nonstatic and static fields, class/struct/union flag, name, list of superclasses,
  methods defined, and annotations.
  The fld - typ pairs are always sorted. This means that we don't support programs that exploit specific layouts
  of C structs. *)
  | Tarray of typ * exp (** array type with fixed size *)
  | Tenum of (Mangled.t * const) list

(** Program expressions. *)
and exp =
  | Var of Ident.t (** pure variable: it is not an lvalue *)
  | UnOp of unop * exp * typ option (** unary operator with type of the result if known *)
  | BinOp of binop * exp * exp (** binary operator *)
  | Const of const  (** constants *)
  | Cast of typ * exp  (** type cast *)
  | Lvar of pvar  (** the address of a program variable *)
  | Lfield of exp * Ident.fieldname * typ (** a field offset, the type is the surrounding struct type *)
  | Lindex of exp * exp (** an array index offset: [exp1\[exp2\]] *)
  | Sizeof of typ * Subtype.t (** a sizeof expression *)

(** Sets of types. *)
module TypSet : Set.S with type elt = typ

(** Maps with type keys. *)
module TypMap : Map.S with type key = typ

(** Sets of expressions. *)
module ExpSet : Set.S with type elt = exp

(** Maps with expression keys. *)
module ExpMap : Map.S with type key = exp

(** Hashtable with expressions as keys. *)
module ExpHash : Hashtbl.S with type key = exp

(** Convert expression lists to expression sets. *)
val elist_to_eset : exp list -> ExpSet.t

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
val instr_is_auxiliary : instr -> bool

(** Offset for an lvalue. *)
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

val inst_abstraction : inst
val inst_actual_precondition : inst
val inst_alloc : inst
val inst_formal : inst (** for formal parameters and heap values at the beginning of the function *)
val inst_initial : inst (** for initial values *)
val inst_lookup : inst
val inst_none : inst
val inst_nullify : inst
val inst_rearrange : bool -> location -> path_pos -> inst (** the boolean indicates whether the pointer is known nonzero *)
val inst_taint : inst
val inst_update : location -> path_pos -> inst

(** Get the null case flag of the inst. *)
val inst_get_null_case_flag : inst -> bool option

(** Set the null case flag of the inst. *)
val inst_set_null_case_flag : inst -> inst

(** update the location of the instrumentation *)
val inst_new_loc : location -> inst -> inst

(** Update [inst_old] to [inst_new] preserving the zero flag *)
val update_inst : inst -> inst -> inst

(** join of instrumentations *)
val inst_partial_join : inst -> inst -> inst

(** meet of instrumentations *)
val inst_partial_meet : inst -> inst -> inst

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
  is used to denote the shared links by all the nodes in the list.*)
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

(** Sets of heap predicates *)
module HpredSet : Set.S with type elt = hpred

(** {2 Compaction} *)

type sharing_env

(** Create a sharing env to store canonical representations *)
val create_sharing_env : unit -> sharing_env

(** Return a canonical representation of the exp *)
val exp_compact : sharing_env -> exp -> exp

(** Return a compact representation of the exp *)
val hpred_compact : sharing_env -> hpred -> hpred

(** {2 Type Environment} *)

type tenv (** Type for type environment. *)

(** Create a new type environment. *)
val create_tenv : unit -> tenv

(** Check if typename is found in tenv *)
val tenv_mem : tenv -> typename -> bool

(** Look up a name in the global type environment. *)
val tenv_lookup : tenv -> typename -> typ option

(** Add a (name,typ) pair to the global type environment. *)
val tenv_add : tenv -> typename -> typ -> unit

(** look up the type for a mangled name in the current type environment *)
val get_typ : Mangled.t -> csu option -> tenv -> typ option

(** expand a type if it is a typename by looking it up in the type environment *)
val expand_type : tenv -> typ -> typ

(** type environment used for parsing, to be set by the client of the parser module *)
val tenv_for_parsing : tenv ref

(** Load a type environment from a file *)
val load_tenv_from_file : DB.filename -> tenv option

(** Save a type environment into a file *)
val store_tenv_to_file : DB.filename -> tenv -> unit

(** convert the typename to a string *)
val typename_to_string : typename -> string

(** name of the typename without qualifier *)
val typename_name : typename -> string

(** iterate over a type environment *)
val tenv_iter : (typename -> typ -> unit) -> tenv -> unit

val tenv_fold : (typename -> typ -> 'a -> 'a) -> tenv -> 'a -> 'a

(** print a type environment *)
val pp_tenv : Format.formatter -> tenv -> unit

(** Return the lhs expression of a hpred *)
val hpred_get_lhs : hpred -> exp

(** Field used for objective-c reference counting *)
val objc_ref_counter_field : (Ident.fieldname * typ * item_annotation)

(** {2 Comparision And Inspection Functions} *)

val is_objc_ref_counter_field : (Ident.fieldname * typ * item_annotation) -> bool

val has_objc_ref_counter : hpred -> bool

val exp_is_null_literal : exp -> bool

(** return true if [exp] is the special this/self expression *)
val exp_is_this : exp -> bool

val loc_compare : location -> location -> int

val loc_equal : location -> location -> bool

val path_pos_equal : path_pos -> path_pos -> bool

(** turn a *T into a T. fails if [typ] is not a pointer type *)
val typ_strip_ptr : typ -> typ

val pvar_get_name : pvar -> Mangled.t

val pvar_to_string : pvar -> string

(** Turn a pvar into a seed pvar (which stores the initial value of a stack var) *)
val pvar_to_seed : pvar -> pvar

(** Check if the pvar is a callee var *)
val pvar_is_callee : pvar -> bool

(** Check if the pvar is an abducted return var or param passed by ref *)
val pvar_is_abducted : pvar -> bool

(** Check if the pvar is a local var *)
val pvar_is_local : pvar -> bool

(** Check if the pvar is a seed var *)
val pvar_is_seed : pvar -> bool

(** Check if the pvar is a global var *)
val pvar_is_global : pvar -> bool

(** Check if a pvar is the special "this" var *)
val pvar_is_this : pvar -> bool

(** Check if the pvar is a return var *)
val pvar_is_return : pvar -> bool

(** Make a static local name in objc *)
val mk_static_local_name : string -> string -> string

(** Check if a pvar is a local static in objc *)
val is_static_local_name : string -> pvar -> bool

(* A block pvar used to explain retain cycles *)
val block_pvar : pvar

(** Check if a pvar is a local pointing to a block in objc *)
val is_block_pvar : pvar -> bool

(** Check if type is a type for a block in objc *)
val is_block_type : typ -> bool

(** Compare two pvar's *)
val pvar_compare : pvar -> pvar -> int

(** Equality for pvar's *)
val pvar_equal : pvar -> pvar -> bool

(** Comparision for fieldnames. *)
val fld_compare : Ident.fieldname -> Ident.fieldname -> int

(** Equality for fieldnames. *)
val fld_equal : Ident.fieldname -> Ident.fieldname -> bool

(** Check wheter the integer kind is a char *)
val ikind_is_char : ikind -> bool

(** Check wheter the integer kind is unsigned *)
val ikind_is_unsigned : ikind -> bool

(** Convert an int64 into an Int.t given the kind: the int64 is interpreted as unsigned according to the kind *)
val int_of_int64_kind : int64 -> ikind -> Int.t

(** Comparison for typenames *)
val typename_compare : typename -> typename -> int

(** Equality for typenames *)
val typename_equal : typename -> typename -> bool

(** Equality for typenames *)
val csu_name_equal : (csu * Mangled.t) -> (csu * Mangled.t) -> bool

(** Comparision for ptr_kind *)
val ptr_kind_compare : ptr_kind -> ptr_kind -> int

(** Equality for consts. *)
val const_equal : const -> const -> bool

(** Comparision for types. *)
val typ_compare : typ -> typ -> int

(** Equality for types. *)
val typ_equal : typ -> typ -> bool

(** Comparision for fieldnames * types * item annotations. *)
val fld_typ_ann_compare : Ident.fieldname * typ * item_annotation -> Ident.fieldname * typ * item_annotation -> int

val unop_equal : unop -> unop -> bool

val binop_equal : binop -> binop -> bool

(** This function returns true if the operation is injective
wrt. each argument: op(e,-) and op(-, e) is injective for all e.
The return value false means "don't know". *)
val binop_injective : binop -> bool

(** This function returns true if the operation can be inverted. *)
val binop_invertible : binop -> bool

(** This function inverts an injective binary operator
with respect to the first argument. It returns an expression [e'] such that
BinOp([binop], [e'], [exp1]) = [exp2]. If the [binop] operation is not invertible,
the function raises an exception by calling "assert false". *)
val binop_invert : binop -> exp -> exp -> exp

(** This function returns true if 0 is the right unit of [binop].
The return value false means "don't know". *)
val binop_is_zero_runit : binop -> bool

val mem_kind_compare : mem_kind -> mem_kind -> int

val attribute_compare : attribute -> attribute -> int

val attribute_equal : attribute -> attribute -> bool

val attribute_category_compare : attribute_category -> attribute_category -> int

val attribute_category_equal : attribute_category -> attribute_category -> bool

(**  Return the category to which the attribute belongs. *)
val attribute_to_category : attribute -> attribute_category

val const_compare : const -> const -> int

val const_equal : const -> const -> bool

(** Return true if the constants have the same kind (both integers, ...) *)
val const_kind_equal : const -> const -> bool

val exp_compare : exp -> exp -> int

val exp_equal : exp -> exp -> bool

val call_flags_compare : call_flags -> call_flags -> int

val exp_typ_compare : (exp * typ) -> (exp * typ) -> int

val instr_compare : instr -> instr -> int

val exp_list_compare : exp list -> exp list -> int

val exp_list_equal : exp list -> exp list -> bool

val atom_compare : atom -> atom -> int

val atom_equal : atom -> atom -> bool

val strexp_compare : strexp -> strexp -> int

val strexp_equal : strexp -> strexp -> bool

val hpara_compare : hpara -> hpara -> int

val hpara_equal : hpara -> hpara -> bool

val hpara_dll_compare : hpara_dll -> hpara_dll -> int

val hpara_dll_equal : hpara_dll -> hpara_dll -> bool

val lseg_kind_compare : lseg_kind -> lseg_kind -> int

val lseg_kind_equal : lseg_kind -> lseg_kind -> bool

val hpred_compare : hpred -> hpred -> int

val hpred_equal : hpred -> hpred -> bool

val fld_strexp_compare : Ident.fieldname * strexp -> Ident.fieldname * strexp -> int

val fld_strexp_list_compare : (Ident.fieldname * strexp) list -> (Ident.fieldname * strexp) list -> int

val exp_strexp_compare : exp * strexp -> exp * strexp -> int

(** Compare function for annotations. *)
val annotation_compare : annotation -> annotation -> int

(** Compare function for annotation items. *)
val item_annotation_compare : item_annotation -> item_annotation -> int

(** Compare function for Method annotations. *)
val method_annotation_compare : method_annotation -> method_annotation -> int

(** Empty item annotation. *)
val item_annotation_empty : item_annotation

(** Empty method annotation. *)
val method_annotation_empty : method_annotation

(** Check if the item annodation is empty. *)
val item_annotation_is_empty : item_annotation -> bool

(** Check if the method annodation is empty. *)
val method_annotation_is_empty : method_annotation -> bool

(** Return the value of the FA_sentinel attribute in [attr_list] if it is found *)
val get_sentinel_func_attribute_value : func_attribute list -> (int * int) option

(** {2 Pretty Printing} *)

(** Begin change color if using diff printing, return updated printenv and change status *)
val color_pre_wrapper : printenv -> Format.formatter -> 'a -> printenv * bool

(** Close color annotation if changed *)
val color_post_wrapper : bool -> printenv -> Format.formatter -> unit

(** String representation of a unary operator. *)
val str_unop : unop -> string

(** String representation of a binary operator. *)
val str_binop : printenv -> binop -> string

(** Pretty print a location. *)
val pp_loc : Format.formatter -> location -> unit

val loc_to_string : location -> string

(** Dump a location. *)
val d_loc : location -> unit

(** name of the allocation function for the given memory kind *)
val mem_alloc_pname : mem_kind -> Procname.t

(** name of the deallocation function for the given memory kind *)
val mem_dealloc_pname : mem_kind -> Procname.t

(** Pretty print an annotation. *)
val pp_annotation : Format.formatter -> annotation -> unit

(** Pretty print a const. *)
val pp_const: printenv -> Format.formatter -> const -> unit

(** Pretty print an item annotation. *)
val pp_item_annotation : Format.formatter -> item_annotation -> unit

(** Pretty print a method annotation. *)
val pp_method_annotation : string -> Format.formatter -> method_annotation -> unit

(** Pretty print a type. *)
val pp_typ : printenv -> Format.formatter -> typ -> unit

(** Pretty print a type with all the details. *)
val pp_typ_full : printenv -> Format.formatter -> typ -> unit

val typ_to_string : typ -> string

(** [pp_type_decl pe pp_base pp_size f typ] pretty prints a type declaration.
pp_base prints the variable for a declaration, or can be skip to print only the type
pp_size prints the expression for the array size *)
val pp_type_decl: printenv -> (Format.formatter -> unit -> unit) ->
(printenv -> Format.formatter -> exp -> unit) ->
Format.formatter -> typ -> unit

(** Dump a type with all the details. *)
val d_typ_full : typ -> unit

(** Dump a list of types. *)
val d_typ_list : typ list -> unit

(** Pretty print a program variable. *)
val pp_pvar : printenv -> Format.formatter -> pvar -> unit

(** Pretty print a pvar which denotes a value, not an address *)
val pp_pvar_value : printenv -> Format.formatter -> pvar -> unit

(** Dump a program variable. *)
val d_pvar : pvar -> unit

(** Pretty print a list of program variables. *)
val pp_pvar_list : printenv -> Format.formatter -> pvar list -> unit

(** Dump a list of program variables. *)
val d_pvar_list : pvar list -> unit

(** convert the attribute to a string *)
val attribute_to_string : printenv -> attribute -> string

(** convert a dexp to a string *)
val dexp_to_string : dexp -> string

(** Pretty print a dexp. *)
val pp_dexp : printenv -> Format.formatter -> dexp -> unit

(** Pretty print an expression. *)
val pp_exp : printenv -> Format.formatter -> exp -> unit

(** Pretty print an expression with type. *)
val pp_exp_typ : printenv -> Format.formatter -> exp * typ -> unit

(** Convert an expression to a string *)
val exp_to_string : exp -> string

(** dump an expression. *)
val d_exp : exp -> unit

(** Pretty print a type. *)
val pp_texp : printenv -> Format.formatter -> exp -> unit

(** Pretty print a type with all the details. *)
val pp_texp_full : printenv -> Format.formatter -> exp -> unit

(** Dump a type expression with all the details. *)
val d_texp_full : exp -> unit

(** Pretty print a list of expressions. *)
val pp_exp_list : printenv -> Format.formatter -> exp list -> unit

(** Dump a list of expressions. *)
val d_exp_list : exp list -> unit

(** Pretty print an offset *)
val pp_offset : printenv -> Format.formatter -> offset -> unit

(** Dump an offset *)
val d_offset : offset -> unit

(** Pretty print a list of offsets *)
val pp_offset_list : printenv -> Format.formatter -> offset list -> unit

(** Dump a list of offsets *)
val d_offset_list : offset list -> unit

(** Get the location of the instruction *)
val instr_get_loc : instr -> location

(** get the expressions occurring in the instruction *)
val instr_get_exps : instr -> exp list

(** Pretty print an instruction. *)
val pp_instr : printenv -> Format.formatter -> instr -> unit

(** Dump an instruction. *)
val d_instr : instr -> unit

(** Pretty print a list of instructions. *)
val pp_instr_list : printenv -> Format.formatter -> instr list -> unit

(** Dump a list of instructions. *)
val d_instr_list : instr list -> unit

(** Pretty print a value path *)
val pp_vpath : printenv -> Format.formatter -> vpath -> unit

(** Pretty print an atom. *)
val pp_atom : printenv -> Format.formatter -> atom -> unit

(** Dump an atom. *)
val d_atom : atom -> unit

(** return a string representing the inst *)
val inst_to_string : inst -> string

(** Pretty print a strexp. *)
val pp_sexp : printenv -> Format.formatter -> strexp -> unit

(** Dump a strexp. *)
val d_sexp : strexp -> unit

(** Pretty print a strexp list. *)
val pp_sexp_list : printenv -> Format.formatter -> strexp list -> unit

(** Dump a strexp. *)
val d_sexp_list : strexp list -> unit

(** Pretty print a hpred. *)
val pp_hpred : printenv -> Format.formatter -> hpred -> unit

(** Dump a hpred. *)
val d_hpred : hpred -> unit

(** Pretty print a hpara. *)
val pp_hpara : printenv -> Format.formatter -> hpara -> unit

(** Pretty print a list of hparas. *)
val pp_hpara_list : printenv -> Format.formatter -> hpara list -> unit

(** Pretty print a hpara_dll. *)
val pp_hpara_dll : printenv -> Format.formatter -> hpara_dll -> unit

(** Pretty print a list of hpara_dlls. *)
val pp_hpara_dll_list : printenv -> Format.formatter -> hpara_dll list -> unit

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
end

(** Pretty print a hpred with optional predicate env *)
val pp_hpred_env : printenv -> Predicates.env option -> Format.formatter -> hpred -> unit

(** {2 Functions for traversing SIL data types} *)

(** This function should be used before adding a new
index to Earray. The [exp] is the newly created
index. This function "cleans" [exp] according to whether it is the footprint or current part of the prop.
The function faults in the re - execution mode, as an internal check of the tool. *)
val array_clean_new_index : bool -> exp -> exp

(** Change exps in strexp using [f]. *)
(** WARNING: the result might not be normalized. *)
val strexp_expmap : (exp * inst option -> exp * inst option) -> strexp -> strexp

(** Change exps in hpred by [f]. *)
(** WARNING: the result might not be normalized. *)
val hpred_expmap : (exp * inst option -> exp * inst option) -> hpred -> hpred

(** Change instrumentations in hpred using [f]. *)
val hpred_instmap : (inst -> inst) -> hpred -> hpred

(** Change exps in hpred list by [f]. *)
(** WARNING: the result might not be normalized. *)
val hpred_list_expmap : (exp * inst option -> exp * inst option) -> hpred list -> hpred list

(** Change exps in atom by [f]. *)
(** WARNING: the result might not be normalized. *)
val atom_expmap : (exp -> exp) -> atom -> atom

(** Change exps in atom list by [f]. *)
(** WARNING: the result might not be normalized. *)
val atom_list_expmap : (exp -> exp) -> atom list -> atom list

(** {2 Function for computing lexps in sigma} *)

val hpred_list_get_lexps : (exp -> bool) -> hpred list -> exp list

(** {2 Utility Functions for Expressions} *)

(** Turn an expression representing a type into the type it represents
If not a sizeof, return the default type if given, otherwise raise an exception *)
val texp_to_typ : typ option -> exp -> typ

(** If a struct type with field f, return the type of f.
If not, return the default type if given, otherwise raise an exception *)
val struct_typ_fld : typ option -> Ident.fieldname -> typ -> typ

(** If an array type, return the type of the element.
If not, return the default type if given, otherwise raise an exception *)
val array_typ_elem : typ option -> typ -> typ

(** Return the root of [lexp]. *)
val root_of_lexp : exp -> exp

(** Get an expression "undefined", the boolean indicates whether the undefined value goest into the footprint *)
val exp_get_undefined : bool -> exp

(** Checks whether an expression denotes a location using pointer arithmetic.
Currently, catches array - indexing expressions such as a[i] only. *)
val exp_pointer_arith : exp -> bool

(** Integer constant 0 *)
val exp_zero : exp

(** Null constant *)
val exp_null : exp

(** Integer constant 1 *)
val exp_one : exp

(** Integer constant -1 *)
val exp_minus_one : exp

(** Create integer constant *)
val exp_int : Int.t -> exp

(** Create float constant *)
val exp_float : float -> exp

(** Create integer constant corresponding to the boolean value *)
val exp_bool : bool -> exp

(** Create expresstion [e1 == e2] *)
val exp_eq : exp -> exp -> exp

(** Create expresstion [e1 != e2] *)
val exp_ne : exp -> exp -> exp

(** Create expresstion [e1 <= e2] *)
val exp_le : exp -> exp -> exp

(** Create expression [e1 < e2] *)
val exp_lt : exp -> exp -> exp

(** {2 Functions for computing program variables} *)

val exp_fpv : exp -> pvar list

val strexp_fpv : strexp -> pvar list

val atom_fpv : atom -> pvar list

val hpred_fpv : hpred -> pvar list

val hpara_fpv : hpara -> pvar list

(** {2 Functions for computing free non-program variables} *)

(** Type of free variables. These include primed, normal and footprint variables. We remember the order in which variables are added. *)
type fav

(** flag to indicate whether fav's are stored in duplicate form -- only to be used with fav_to_list *)
val fav_duplicates : bool ref

(** Pretty print a fav. *)
val pp_fav : printenv -> Format.formatter -> fav -> unit

(** Create a new [fav]. *)
val fav_new : unit -> fav

(** Emptyness check. *)
val fav_is_empty : fav -> bool

(** Check whether a predicate holds for all elements. *)
val fav_for_all : fav -> (Ident.t -> bool) -> bool

(** Check whether a predicate holds for some elements. *)
val fav_exists : fav -> (Ident.t -> bool) -> bool

(** Membership test fot [fav] *)
val fav_mem : fav -> Ident.t -> bool

(** Convert a list to a fav. *)
val fav_from_list : Ident.t list -> fav

(** Convert a [fav] to a list of identifiers while preserving the order
that identifiers were added to [fav]. *)
val fav_to_list : fav -> Ident.t list

(** Copy a [fav]. *)
val fav_copy : fav -> fav

(** Turn a xxx_fav_add function into a xxx_fav function *)
val fav_imperative_to_functional : (fav -> 'a -> unit) -> 'a -> fav

(** [fav_filter_ident fav f] only keeps [id] if [f id] is true. *)
val fav_filter_ident : fav -> (Ident.t -> bool) -> unit

(** Like [fav_filter_ident] but return a copy. *)
val fav_copy_filter_ident : fav -> (Ident.t -> bool) -> fav

(** [fav_subset_ident fav1 fav2] returns true if every ident in [fav1]
is in [fav2].*)
val fav_subset_ident : fav -> fav -> bool

(** add identifier list to fav *)
val ident_list_fav_add : Ident.t list -> fav -> unit

(** [exp_fav_add fav exp] extends [fav] with the free variables of [exp] *)
val exp_fav_add : fav -> exp -> unit

val exp_fav : exp -> fav

val exp_fav_list : exp -> Ident.t list

val ident_in_exp : Ident.t -> exp -> bool

val strexp_fav_add : fav -> strexp -> unit

val atom_fav_add : fav -> atom -> unit

val atom_fav: atom -> fav

val hpred_fav_add : fav -> hpred -> unit

val hpred_fav : hpred -> fav

val hpara_fav_add : fav -> hpara -> unit

(** Variables in hpara, excluding bound vars in the body *)
val hpara_shallow_av : hpara -> fav

(** Variables in hpara_dll, excluding bound vars in the body *)
val hpara_dll_shallow_av : hpara_dll -> fav

(** {2 Functions for computing all free or bound non-program variables} *)

(** Non-program variables include all of primed, normal and footprint
variables. Thus, the functions essentially compute all the
identifiers occuring in a parameter. Some variables can appear more
than once in the result. *)

val exp_av_add : fav -> exp -> unit

val strexp_av_add : fav -> strexp -> unit

val atom_av_add : fav -> atom -> unit

val hpred_av_add : fav -> hpred -> unit

val hpara_av_add : fav -> hpara -> unit

(** {2 Substitution} *)

type subst

(** Create a substitution from a list of pairs.
For all (id1, e1), (id2, e2) in the input list,
if id1 = id2, then e1 = e2. *)
val sub_of_list : (Ident.t * exp) list -> subst

(** like sub_of_list, but allow duplicate ids and only keep the first occurrence *)
val sub_of_list_duplicates : (Ident.t * exp) list -> subst

(** Convert a subst to a list of pairs. *)
val sub_to_list : subst -> (Ident.t * exp) list

(** The empty substitution. *)
val sub_empty : subst

(** Comparison for substitutions. *)
val sub_compare : subst -> subst -> int

(** Equality for substitutions. *)
val sub_equal : subst -> subst -> bool

(** Compute the common id-exp part of two inputs [subst1] and [subst2].
The first component of the output is this common part.
The second and third components are the remainder of [subst1]
and [subst2], respectively. *)
val sub_join : subst -> subst -> subst

(** Compute the common id-exp part of two inputs [subst1] and [subst2].
The first component of the output is this common part.
The second and third components are the remainder of [subst1]
and [subst2], respectively. *)
val sub_symmetric_difference : subst -> subst -> subst * subst * subst

(** [sub_find filter sub] returns the expression associated to the first identifier that satisfies [filter]. Raise [Not_found] if there isn't one. *)
val sub_find : (Ident.t -> bool) -> subst -> exp

(** [sub_filter filter sub] restricts the domain of [sub] to the
identifiers satisfying [filter]. *)
val sub_filter : (Ident.t -> bool) -> subst -> subst

(** [sub_filter_exp filter sub] restricts the domain of [sub] to the
identifiers satisfying [filter(id, sub(id))]. *)
val sub_filter_pair : (Ident.t * exp -> bool) -> subst -> subst

(** [sub_range_partition filter sub] partitions [sub] according to
whether range expressions satisfy [filter]. *)
val sub_range_partition : (exp -> bool) -> subst -> subst * subst

(** [sub_domain_partition filter sub] partitions [sub] according to
whether domain identifiers satisfy [filter]. *)
val sub_domain_partition : (Ident.t -> bool) -> subst -> subst * subst

(** Return the list of identifiers in the domain of the substitution. *)
val sub_domain : subst -> Ident.t list

(** Return the list of expressions in the range of the substitution. *)
val sub_range : subst -> exp list

(** [sub_range_map f sub] applies [f] to the expressions in the range of [sub]. *)
val sub_range_map : (exp -> exp) -> subst -> subst

(** [sub_map f g sub] applies the renaming [f] to identifiers in the domain
of [sub] and the substitution [g] to the expressions in the range of [sub]. *)
val sub_map : (Ident.t -> Ident.t) -> (exp -> exp) -> subst -> subst

(** Checks whether [id] belongs to the domain of [subst]. *)
val mem_sub : Ident.t -> subst -> bool

(** Extend substitution and return [None] if not possible. *)
val extend_sub : subst -> Ident.t -> exp -> subst option

(** Free auxilary variables in the domain and range of the
substitution. *)
val sub_fav_add : fav -> subst -> unit

(** Free or bound auxilary variables in the domain and range of the
substitution. *)
val sub_av_add : fav -> subst -> unit

(** Compute free pvars in a sub *)
val sub_fpv : subst -> pvar list

(** substitution functions *)
(** WARNING: these functions do not ensure that the results are normalized. *)
val exp_sub : subst -> exp -> exp

val atom_sub : subst -> atom -> atom

val instr_sub : subst -> instr -> instr

val hpred_sub : subst -> hpred -> hpred

val hpara_sub : subst -> hpara -> hpara

(** {2 Functions for replacing occurrences of expressions.} *)

(** The first parameter should define a partial function.
No parts of hpara are replaced by these functions. *)

val exp_replace_exp : (exp * exp) list -> exp -> exp

val strexp_replace_exp : (exp * exp) list -> strexp -> strexp

val atom_replace_exp : (exp * exp) list -> atom -> atom

val hpred_replace_exp : (exp * exp) list -> hpred -> hpred

(** {2 Functions for constructing or destructing entities in this module} *)

(** Unknown location *)
val loc_none : location

(** [mk_pvar name proc_name suffix] creates a program var with the given function name and suffix *)
val mk_pvar : Mangled.t -> Procname.t -> pvar

(** [get_ret_pvar proc_name] retuns the return pvar associated with the procedure name *)
val get_ret_pvar : Procname.t -> pvar

(** [mk_pvar_callee name proc_name] creates a program var for a callee function with the given function name *)
val mk_pvar_callee : Mangled.t -> Procname.t -> pvar

(** create a global variable with the given name *)
val mk_pvar_global : Mangled.t -> pvar

(** create an abducted return variable for a call to [proc_name] at [loc] *)
val mk_pvar_abducted_ret : Procname.t -> location -> pvar

val mk_pvar_abducted_ref_param : Procname.t -> pvar -> location -> pvar

(** Turn an ordinary program variable into a callee program variable *)
val pvar_to_callee : Procname.t -> pvar -> pvar

(** Compute the offset list of an expression *)
val exp_get_offsets : exp -> offset list

(** Add the offset list to an expression *)
val exp_add_offsets : exp -> offset list -> exp

val sigma_to_sigma_ne : hpred list -> (atom list * hpred list) list

(** [hpara_instantiate para e1 e2 elist] instantiates [para] with [e1],
[e2] and [elist]. If [para = lambda (x, y, xs). exists zs. b],
then the result of the instantiation is [b\[e1 / x, e2 / y, elist / xs, _zs'/ zs\]]
for some fresh [_zs'].*)
val hpara_instantiate : hpara -> exp -> exp -> exp list -> Ident.t list * hpred list

(** [hpara_dll_instantiate para cell blink flink  elist] instantiates [para] with [cell],
[blink], [flink], and [elist]. If [para = lambda (x, y, z, xs). exists zs. b],
then the result of the instantiation is [b\[cell / x, blink / y, flink / z, elist / xs, _zs'/ zs\]]
for some fresh [_zs'].*)
val hpara_dll_instantiate : hpara_dll -> exp -> exp -> exp -> exp list -> Ident.t list * hpred list

(** Return the list of expressions that could be understood as outgoing arrows from the strexp *)
val strexp_get_target_exps : strexp -> exp list

(** Iterate over all the subtypes in the type (including the type itself) *)
val typ_iter_types : (typ -> unit) -> typ -> unit
(** Iterate over all the types (and subtypes) in the expression *)
val exp_iter_types : (typ -> unit) -> exp -> unit
(** Iterate over all the types (and subtypes) in the instruction *)
val instr_iter_types : (typ -> unit) -> instr -> unit

val global_error : pvar
