(*
* Copyright (c) 2009 -2013 Monoidics ltd.
* Copyright (c) 2013 - Facebook.
* All rights reserved.
*)

(** Specifications and spec table *)

module L = Logging
module F = Format
open Utils

(* =============== START of support for spec tables =============== *)

(** Module for joined props *)
module Jprop = struct

  (** Remember when a prop is obtained as the join of two other props; the first parameter is an id *)
  type 'a t =
    | Prop of int * 'a Prop.t
    | Joined of int * 'a Prop.t * 'a t * 'a t

  let to_prop = function
    | Prop (_, p) -> p
    | Joined (_, p, _, _) -> p

  let to_number = function
    | Prop (n, _) -> n
    | Joined (n, _, _, _) -> n

  let rec fav_add_dfs fav = function
    | Prop (_, p) -> Prop.prop_fav_add_dfs fav p
    | Joined (_, p, jp1, jp2) ->
        Prop.prop_fav_add_dfs fav p;
        fav_add_dfs fav jp1;
        fav_add_dfs fav jp2

  let rec jprop_sub sub = function
    | Prop (n, p) -> Prop (n, Prop.prop_sub sub p)
    | Joined (n, p, jp1, jp2) -> Joined (n, Prop.prop_sub sub p, jprop_sub sub jp1, jprop_sub sub jp2)

  let rec normalize = function
    | Prop (n, p) -> Prop (n, Prop.normalize p)
    | Joined (n, p, jp1, jp2) -> Joined (n, Prop.normalize p, normalize jp1, normalize jp2)

  (** Return a compact representation of the jprop *)
  let rec compact sh = function
    | Prop (n, p) ->
        Prop (n, Prop.prop_compact sh p)
    | Joined(n, p, jp1, jp2) ->
        Joined(n, Prop.prop_compact sh p, compact sh jp1, compact sh jp2)

  (** Print the toplevel prop *)
  let pp_short pe f jp =
    Prop.pp_prop pe f (to_prop jp)

  (** Dump the toplevel prop *)
  let d_shallow (jp: Prop.normal t) = L.add_print_action (L.PTjprop_short, Obj.repr jp)

  (** Get identifies of the jprop *)
  let get_id = function
    | Prop (n, _) -> n
    | Joined (n, _, _, _) -> n

  (** Print a list of joined props, the boolean indicates whether to print subcomponents of joined props *)
  let pp_list pe shallow f jplist =
    let rec pp_seq_newline f = function
      | [] -> ()
      | [Prop (n, p)] -> F.fprintf f "PROP %d:@\n%a" n (Prop.pp_prop pe) p
      | [Joined (n, p, p1, p2)] ->
          if not shallow then F.fprintf f "%a@\n" pp_seq_newline [p1];
          if not shallow then F.fprintf f "%a@\n" pp_seq_newline [p2];
          F.fprintf f "PROP %d (join of %d,%d):@\n%a" n (get_id p1) (get_id p2) (Prop.pp_prop pe) p
      | jp:: l ->
          F.fprintf f "%a@\n" pp_seq_newline [jp];
          pp_seq_newline f l in
    pp_seq_newline f jplist

  (** dump a joined prop list, the boolean indicates whether to print toplevel props only *)
  let d_list (shallow: bool) (jplist: Prop.normal t list) = L.add_print_action (L.PTjprop_list, Obj.repr (shallow, jplist))

  (** Comparison for joined_prop *)
  let rec compare jp1 jp2 = match jp1, jp2 with
    | Prop (_, p1), Prop (_, p2) ->
        Prop.prop_compare p1 p2
    | Prop _, _ -> - 1
    | _, Prop _ -> 1
    | Joined (_, p1, jp1, jq1), Joined (_, p2, jp2, jq2) ->
        let n = Prop.prop_compare p1 p2 in
        if n <> 0 then n
        else
          let n = compare jp1 jp2 in
          if n <> 0 then n else compare jq1 jq2

  (** Return true if the two join_prop's are equal *)
  let equal jp1 jp2 =
    compare jp1 jp2 == 0

  let rec fav_add fav = function
    | Prop (_, p) -> Prop.prop_fav_add fav p
    | Joined (_, p, jp1, jp2) ->
        Prop.prop_fav_add fav p;
        fav_add fav jp1;
        fav_add fav jp2

  let rec jprop_sub sub = function
    | Prop (n, p) -> Prop (n, Prop.prop_sub sub p)
    | Joined (n, p, jp1, jp2) ->
        let p' = Prop.prop_sub sub p in
        let jp1' = jprop_sub sub jp1 in
        let jp2' = jprop_sub sub jp2 in
        Joined (n, p', jp1', jp2')

  let filter (f: 'a t -> 'b option) jpl =
    let rec do_filter acc = function
      | [] -> acc
      | (Prop (_, p) as jp) :: jpl ->
          (match f jp with
            | Some x ->
                do_filter (x:: acc) jpl
            | None -> do_filter acc jpl)
      | (Joined (_, p, jp1, jp2) as jp) :: jpl ->
          (match f jp with
            | Some x ->
                do_filter (x:: acc) jpl
            | None ->
                do_filter acc (jpl @ [jp1; jp2])) in
    do_filter [] jpl

  let rec map (f : 'a Prop.t -> 'b Prop.t) = function
    | Prop (n, p) -> Prop (n, f p)
    | Joined (n, p, jp1, jp2) -> Joined (n, f p, map f jp1, map f jp2)
end
(***** End of module Jprop *****)

module Visitedset =
  Set.Make (struct
    type t = int * int list
    let compare (node_id1, line1) (node_id2, line2) = int_compare node_id1 node_id2
  end)

let visited_str vis =
  let s = ref "" in
  let lines = ref IntSet.empty in
  let do_one (node, ns) =
    (* if list_length ns > 1 then
    begin
    let ss = ref "" in
    list_iter (fun n -> ss := !ss ^ " " ^ string_of_int n) ns;
    L.err "Node %d has lines %s@." node !ss
    end; *)
    list_iter (fun n -> lines := IntSet.add n !lines) ns in
  Visitedset.iter do_one vis;
  IntSet.iter (fun n -> s := !s ^ " " ^ string_of_int n) !lines;
  !s

(** A spec consists of:
pre: a joined prop
post: a list of props with path
visited: a list of pairs (node_id, line) for the visited nodes *)
type 'a spec = { pre: 'a Jprop.t; posts: ('a Prop.t * Paths.Path.t) list; visited : Visitedset.t }

module NormSpec : sig (* encapsulate type for normalized specs *)
  type t
  val normalize : Prop.normal spec -> t
  val tospec : t -> Prop.normal spec
  val tospecs : t list -> Prop.normal spec list
  val compact : Sil.sharing_env -> t -> t (** Return a compact representation of the spec *)
  val erase_join_info_pre : t -> t (** Erase join info from pre of spec *)
end = struct
  type t = Prop.normal spec

  let tospec spec = spec

  let tospecs specs = specs

  let spec_fav (spec: Prop.normal spec) : Sil.fav =
    let fav = Sil.fav_new () in
    Jprop.fav_add_dfs fav spec.pre;
    list_iter (fun (p, path) -> Prop.prop_fav_add_dfs fav p) spec.posts;
    fav

  let spec_sub sub spec =
    { pre = Jprop.normalize (Jprop.jprop_sub sub spec.pre);
      posts = list_map (fun (p, path) -> (Prop.normalize (Prop.prop_sub sub p), path)) spec.posts;
      visited = spec.visited }

  (** Convert spec into normal form w.r.t. variable renaming *)
  let normalize (spec: Prop.normal spec) : Prop.normal spec =
    let fav = spec_fav spec in
    let idlist = Sil.fav_to_list fav in
    let count = ref 0 in
    let sub = Sil.sub_of_list (list_map (fun id -> incr count; (id, Sil.Var (Ident.create_normal Ident.name_spec !count))) idlist) in
    spec_sub sub spec

  (** Return a compact representation of the spec *)
  let compact sh spec =
    let pre = Jprop.compact sh spec.pre in
    let posts = list_map (fun (p, path) -> (Prop.prop_compact sh p, path)) spec.posts in
    { pre = pre; posts = posts; visited = spec.visited }

  (** Erase join info from pre of spec *)
  let erase_join_info_pre spec =
    let spec' = { spec with pre = Jprop.Prop (1, Jprop.to_prop spec.pre) } in
    normalize spec'
end

type norm_spec = NormSpec.t

(** Convert spec into normal form w.r.t. variable renaming *)
let spec_normalize =
  NormSpec.normalize

(** Cast a list of normalized specs to a list of specs *)
let normalized_specs_to_specs =
  NormSpec.tospecs

module CallStats = struct (** module for tracing stats of function calls *)
  module PnameLocHash = Hashtbl.Make (struct
      type t = Procname.t * Sil.location
      let hash (pname, loc) = Hashtbl.hash (Procname.hash_pname pname, loc.Sil.line)
      let equal (pname1, loc1) (pname2, loc2) =
        Sil.loc_equal loc1 loc2 && Procname.equal pname1 pname2
    end)

  type call_result = (** kind of result of a procedure call *)
    | CR_success (** successful call *)
    | CR_not_met (** precondition not met *)
    | CR_not_found (** the callee has no specs *)
    | CR_skip (** the callee was skipped *)

  type trace = (call_result * bool) list

  type t = trace PnameLocHash.t

  let trace_add tr (res : call_result) in_footprint = (res, in_footprint) :: tr

  let empty_trace : trace = []

  let init calls =
    let hash = PnameLocHash.create 1 in
    let do_call pn_loc = PnameLocHash.add hash pn_loc empty_trace in
    list_iter do_call calls;
    hash

  let trace t proc_name loc res in_footprint =
    let tr_old = try PnameLocHash.find t (proc_name, loc) with
      | Not_found ->
          PnameLocHash.add t (proc_name, loc) empty_trace;
          empty_trace in
    let tr_new = trace_add tr_old res in_footprint in
    PnameLocHash.replace t (proc_name, loc) tr_new

  let tr_elem_str (cr, in_footprint) =
    let s1 = match cr with
      | CR_success -> "OK"
      | CR_not_met -> "NotMet"
      | CR_not_found -> "NotFound"
      | CR_skip -> "Skip" in
    let s2 = if in_footprint then "FP" else "RE" in
    s1 ^ ":" ^ s2

  let pp_trace fmt tr = Utils.pp_seq (fun fmt x -> F.fprintf fmt "%s" (tr_elem_str x)) fmt (list_rev tr)

  let iter f t =
    let elems = ref [] in
    PnameLocHash.iter (fun x tr -> elems := (x, tr) :: !elems) t;
    let sorted_elems =
      let compare ((pname1, loc1), _) ((pname2, loc2), _) =
        let n = Procname.compare pname1 pname2 in
        if n <> 0 then n else Sil.loc_compare loc1 loc2 in
      list_sort compare !elems in
    list_iter (fun (x, tr) -> f x tr) sorted_elems

  let pp fmt t =
    let do_call (pname, loc) tr = F.fprintf fmt "%a %a: %a@\n" Procname.pp pname Sil.pp_loc loc pp_trace tr in
    iter do_call t
end

(** stats of the calls performed during the analysis *)
type call_stats = CallStats.t

(** Execution statistics *)
type stats =
  { stats_time: float; (** Analysis time for the procedure *)
    stats_timeout: bool; (** Flag to indicate whether a timeout occurred *)
    stats_calls: Cg.in_out_calls; (** num of procs calling, and called *)
    symops: int; (** Number of SymOp's throughout the whole analysis of the function *)
    err_log: Errlog.t; (** Error log for the procedure *)
    mutable nodes_visited_fp : IntSet.t; (** Nodes visited during the footprint phase *)
    mutable nodes_visited_re : IntSet.t; (** Nodes visited during the re-execution phase *)
    call_stats : call_stats;
    cyclomatic : int;
  }

type status = ACTIVE | INACTIVE

type phase = FOOTPRINT | RE_EXECUTION

type dependency_map_t = int Procname.Map.t

type is_library = Source | Library

(** Payload: results of some analysis *)
type payload =
  | PrePosts of NormSpec.t list (** list of specs *)
  | TypeState of unit TypeState.t option (** final typestate *)

type summary =
  { dependency_map: dependency_map_t;  (** maps children procs to timestamp as last seen at the start of an analysys phase for this proc *)
    loc: Sil.location; (** original file and line number *)
    nodes: int list; (** ids of cfg nodes of the procedure *)
    ret_type : Sil.typ; (** type of the return parameter *)
    formals : (string * Sil.typ) list; (** name and type of the formal parameters of the procedure *)
    phase: phase; (** in FOOTPRINT phase or in RE_EXECUTION PHASE *)
    proc_name : Procname.t; (** name of the procedure *)
    proc_flags : proc_flags; (** flags of the procedure *)
    payload: payload;  (** payload containing the result of some analysis *)
    sessions: int ref; (** Session number: how many nodes went trough symbolic execution *)
    stats: stats;  (** statistics: execution time and list of errors *)
    status: status; (** ACTIVE when the proc is being analyzed *)
    timestamp: int; (** Timestamp of the specs, >= 0, increased every time the specs change *)
    attributes : Sil.proc_attributes; (** Attributes of the procedure *)
  }

(** origin of a summary: current results dir, a spec library, or models *)
type origin =
  | Res_dir
  | Spec_lib
  | Models

type spec_tbl = (summary * origin) Procname.Hash.t

let spec_tbl: spec_tbl = Procname.Hash.create 128

let clear_spec_tbl () = Procname.Hash.clear spec_tbl

(** pretty print analysis time; if [whole_seconds] is true, only print time in seconds *)
let pp_time whole_seconds fmt t =
  if whole_seconds then F.fprintf fmt "%3.0f s" t
  else F.fprintf fmt "%f s" t

let pp_timeout fmt = function
  | true -> F.fprintf fmt "Y"
  | false -> F.fprintf fmt "N"

let pp_stats whole_seconds fmt stats =
  F.fprintf fmt "TIME:%a TIMEOUT:%a SYMOPS:%d CALLS:%d,%d@\n" (pp_time whole_seconds) stats.stats_time pp_timeout stats.stats_timeout stats.symops stats.stats_calls.Cg.in_calls stats.stats_calls.Cg.out_calls;
  F.fprintf fmt "ERRORS: @[<h>%a@]" Errlog.pp stats.err_log

(** Print the spec *)
let pp_spec pe num_opt fmt spec =
  let num_str = match num_opt with
    | None -> "----------"
    | Some (n, tot) -> Format.sprintf "%d of %d [nvisited:%s]" n tot (visited_str spec.visited) in
  let pre = Jprop.to_prop spec.pre in
  let pe_post = Prop.prop_update_obj_sub pe pre in
  let post_list = list_map fst spec.posts in
  match pe.pe_kind with
  | PP_TEXT ->
      F.fprintf fmt "--------------------------- %s ---------------------------@\n" num_str;
      F.fprintf fmt "PRE:@\n%a@\n" (Prop.pp_prop pe_text) pre;
      F.fprintf fmt "%a@\n" (Propgraph.pp_proplist pe_post "POST" (pre, true)) post_list;
      F.fprintf fmt "----------------------------------------------------------------"
  | PP_HTML ->
      F.fprintf fmt "--------------------------- %s ---------------------------@\n" num_str;
      F.fprintf fmt "PRE:@\n%a%a%a@\n" Io_infer.Html.pp_start_color Blue (Prop.pp_prop (pe_html Blue)) pre Io_infer.Html.pp_end_color ();
      F.fprintf fmt "%a" (Propgraph.pp_proplist pe_post "POST" (Jprop.to_prop spec.pre, true)) post_list;
      F.fprintf fmt "----------------------------------------------------------------"
  | PP_LATEX ->
      F.fprintf fmt "\\textbf{\\large Requires}\\\\@\n@[%a%a%a@]\\\\@\n" Latex.pp_color Blue (Prop.pp_prop (pe_latex Blue)) pre Latex.pp_color pe.pe_color;
      F.fprintf fmt "\\textbf{\\large Ensures}\\\\@\n@[%a@]" (Propgraph.pp_proplist pe_post "POST" (pre, true)) post_list

(** Dump a spec *)
let d_spec (spec: 'a spec) = L.add_print_action (L.PTspec, Obj.repr spec)

let pp_specs pe fmt specs =
  let total = list_length specs in
  let cnt = ref 0 in
  match pe.pe_kind with
  | PP_TEXT ->
      list_iter (fun spec -> incr cnt; F.fprintf fmt "%a@\n" (pp_spec pe (Some (!cnt, total))) spec) specs
  | PP_HTML ->
      list_iter (fun spec -> incr cnt; F.fprintf fmt "%a<br>@\n" (pp_spec pe (Some (!cnt, total))) spec) specs
  | PP_LATEX ->
      list_iter (fun spec -> incr cnt; F.fprintf fmt "\\subsection*{Spec %d of %d}@\n\\(%a\\)@\n" !cnt total (pp_spec pe None) spec) specs

(** Print the decpendency map *)
let pp_dependency_map fmt dependency_map =
  let pp_entry fmt proc_name n = F.fprintf fmt "%a=%d " Procname.pp proc_name n in
  Procname.Map.iter (pp_entry fmt) dependency_map

let describe_timestamp summary =
  ("Timestamp", Printf.sprintf "%d" summary.timestamp)

let describe_status summary =
  ("Status", if summary.status == ACTIVE then "ACTIVE" else "INACTIVE")

let describe_phase summary =
  ("Phase", if summary.phase == FOOTPRINT then "FOOTRPRINT" else "RE_EXECUTION")

(** Return the signature of a procedure declaration as a string *)
let get_signature summary =
  let s = ref "" in
  list_iter (fun (p, typ) ->
          let pp_name f () = F.fprintf f "%s" p in
          let pp f () = Sil.pp_type_decl pe_text pp_name Sil.pp_exp f typ in
          let decl = pp_to_string pp () in
          s := if !s = "" then decl else !s ^ ", " ^ decl) summary.formals;
  let pp_procname f () = F.fprintf f "%a" Procname.pp summary.proc_name in
  let pp f () = Sil.pp_type_decl pe_text pp_procname Sil.pp_exp f summary.ret_type in
  let decl = pp_to_string pp () in
  decl ^ "(" ^ !s ^ ")"

let pp_summary_no_stats_specs fmt summary =
  let pp_pair fmt (x, y) = F.fprintf fmt "%s: %s" x y in
  F.fprintf fmt "%s@\n" (get_signature summary);
  F.fprintf fmt "%a@\n" pp_pair (describe_timestamp summary);
  F.fprintf fmt "%a@\n" pp_pair (describe_status summary);
  F.fprintf fmt "%a@\n" pp_pair (describe_phase summary);
  F.fprintf fmt "Dependency_map: @[%a@]@\n" pp_dependency_map summary.dependency_map

let pp_stats_html fmt stats =
  Errlog.pp_html [] fmt stats.err_log

let get_specs_from_payload summary = match summary.payload with
  | PrePosts specs -> NormSpec.tospecs specs
  | TypeState _ -> []

(** Print the summary *)
let pp_summary pe whole_seconds fmt summary = match pe.pe_kind with
  | PP_TEXT ->
      pp_summary_no_stats_specs fmt summary;
      F.fprintf fmt "%a@\n" (pp_stats whole_seconds) summary.stats;
      F.fprintf fmt "%a" (pp_specs pe) (get_specs_from_payload summary)
  | PP_HTML ->
      Io_infer.Html.pp_start_color fmt Black;
      F.fprintf fmt "@\n%a" pp_summary_no_stats_specs summary;
      Io_infer.Html.pp_end_color fmt ();
      pp_stats_html fmt summary.stats;
      Io_infer.Html.pp_hline fmt ();
      F.fprintf fmt "<LISTING>@\n";
      pp_specs pe fmt (get_specs_from_payload summary);
      F.fprintf fmt "</LISTING>@\n"
  | PP_LATEX ->
      F.fprintf fmt "\\begin{verbatim}@\n";
      pp_summary_no_stats_specs fmt summary;
      F.fprintf fmt "%a@\n" (pp_stats whole_seconds) summary.stats;
      F.fprintf fmt "\\end{verbatim}@\n";
      F.fprintf fmt "%a@\n" (pp_specs pe) (get_specs_from_payload summary)

(** Print the spec table *)
let pp_spec_table pe whole_seconds fmt () =
  Procname.Hash.iter (fun proc_name (summ, orig) -> F.fprintf fmt "PROC %a@\n%a@\n" Procname.pp proc_name (pp_summary pe whole_seconds) summ) spec_tbl

let empty_stats err_log calls cyclomatic in_out_calls_opt =
  { stats_time = 0.0;
    stats_timeout = false;
    stats_calls =
      (match in_out_calls_opt with
        | Some in_out_calls -> in_out_calls
        | None -> { Cg.in_calls = 0; Cg.out_calls = 0 });
    symops = 0;
    err_log = err_log;
    nodes_visited_fp = IntSet.empty;
    nodes_visited_re = IntSet.empty;
    call_stats = CallStats.init calls;
    cyclomatic = cyclomatic;
  }

let rec post_equal pl1 pl2 = match pl1, pl2 with
  | [],[] -> true
  | [], _:: _ -> false
  | _:: _,[] -> false
  | p1:: pl1', p2:: pl2' ->
      if Prop.prop_equal p1 p2 then post_equal pl1' pl2'
      else false

let payload_compact sh payload = match payload with
  | PrePosts specs -> PrePosts (list_map (NormSpec.compact sh) specs)
  | TypeState _ -> payload

(** Return a compact representation of the summary *)
let summary_compact sh summary =
  { summary with payload = payload_compact sh summary.payload }

let set_summary_origin proc_name summary origin =
  Procname.Hash.replace spec_tbl proc_name (summary, origin)

let add_summary_origin (proc_name : Procname.t) (summary: summary) (origin: origin) : unit =
  L.out "Adding summary for %a@\n@[<v 2>  %a@]@." Procname.pp proc_name (pp_summary pe_text false) summary;
  set_summary_origin proc_name summary origin

(** Add the summary to the table for the given function *)
let add_summary (proc_name : Procname.t) (summary: summary) : unit =
  add_summary_origin proc_name summary Res_dir

let specs_filename pname =
  let pname_file = Procname.to_filename pname in
  pname_file ^ ".specs"

(** path to the .specs file for the given procedure in the current results directory *)
let res_dir_specs_filename pname =
  DB.Results_dir.path_to_filename DB.Results_dir.Abs_root [Config.specs_dir_name; specs_filename pname]

let summary_exists pname =
  Sys.file_exists (DB.filename_to_string (res_dir_specs_filename pname))

(** paths to the .specs file for the given procedure in the current spec libraries *)
let specs_library_filenames pname =
  list_map
    (fun specs_dir -> DB.filename_from_string (Filename.concat specs_dir (specs_filename pname)))
    !Config.specs_library

(** paths to the .specs file for the given procedure in the models folder *)
let specs_models_filename pname =
  DB.filename_from_string (Filename.concat Config.models_dir (specs_filename pname))

let summary_exists_in_models pname =
  Sys.file_exists (DB.filename_to_string (specs_models_filename pname))

let summary_serializer : summary Serialization.serializer = Serialization.create_serializer Serialization.summary_key

(** Save summary for the procedure into the spec database *)
let store_summary pname (summ: summary) =
  let process_payload = function
    | PrePosts specs -> PrePosts (list_map NormSpec.erase_join_info_pre specs)
    | TypeState typestate_opt -> TypeState typestate_opt in
  let summ' = { summ with payload = process_payload summ.payload } in
  let summ'' = if !Config.save_compact_summaries
    then summary_compact (Sil.create_sharing_env ()) summ'
    else summ' in
  Serialization.to_file summary_serializer (res_dir_specs_filename pname) summ''

(** Load procedure summary from the given file *)
let load_summary specs_file =
  Serialization.from_file summary_serializer specs_file

(** Load procedure summary from the given zip file *)
(* TODO: instead of always going through the same list for zip files for every proc_name, *)
(* create beforehand a map from specs filenames to zip filenames, so that looking up the specs for a given procedure is fast *)
let load_summary_from_zip zip_specs_path zip_channel =
  let found_summary =
    try
      let entry = Zip.find_entry zip_channel zip_specs_path in
      begin
        match Serialization.from_string summary_serializer (Zip.read_entry zip_channel entry) with
        | Some summ -> Some summ
        | None ->
            L.err "Could not load specs datastructure from %s@." zip_specs_path;
            None
      end
    with Not_found -> None in
  found_summary

(** Load procedure summary for the given procedure name and update spec table *)
let load_summary_to_spec_table proc_name =
  let add summ origin =
    add_summary_origin proc_name summ origin;
    true in
  let load_summary_models models_dir =
    match load_summary models_dir with
    | None -> false
    | Some summ -> add summ Models in
  let rec load_summary_libs = function (* try to load the summary from a list of libs *)
    | [] -> false
    | spec_path :: spec_paths ->
        (match load_summary spec_path with
          | None -> load_summary_libs spec_paths
          | Some summ ->
              add summ Spec_lib) in
  let rec load_summary_ziplibs zip_libraries = (* try to load the summary from a list of zip libraries *)
    let zip_specs_filename = specs_filename proc_name in
    let zip_specs_path =
      let root = Filename.concat Config.default_in_zip_results_dir Config.specs_dir_name in
      Filename.concat root zip_specs_filename in
    match zip_libraries with
    | [] -> false
    | zip_library:: zip_libraries ->
        begin
          match load_summary_from_zip zip_specs_path (Config.zip_channel zip_library) with
          | None -> load_summary_ziplibs zip_libraries
          | Some summ ->
              let origin = if zip_library.Config.models then Models else Spec_lib in
              add summ origin
        end in
  let default_spec_dir = res_dir_specs_filename proc_name in
  match load_summary default_spec_dir with
  | None ->
  (* search on models, libzips, and libs *)
      if load_summary_models (specs_models_filename proc_name) then true
      else if load_summary_ziplibs !Config.zip_libraries then true
      else load_summary_libs (specs_library_filenames proc_name)

  | Some summ ->
      add summ Res_dir

let rec get_summary_origin proc_name =
  try
    Some (Procname.Hash.find spec_tbl proc_name)
  with Not_found ->
      if load_summary_to_spec_table proc_name then
        get_summary_origin proc_name
      else None

let get_summary proc_name =
  match get_summary_origin proc_name with
  | Some (summary, _) -> Some summary
  | None -> None

let get_summary_unsafe proc_name =
  match get_summary proc_name with
  | None ->
      raise (Failure ("Specs.get_summary_unsafe: " ^ (Procname.to_string proc_name) ^ "Not_found"))
  | Some summary -> summary

(** Check if the procedure is from a library:
It's not defined in the current proc desc, and there is no spec file for it. *)
let proc_is_library proc_name proc_desc =
  let defined = Cfg.Procdesc.is_defined proc_desc in
  if not defined then
    match get_summary proc_name with
    | None -> true
    | Some _ -> false
  else false

(** Get the attributes of a procedure, looking first in the procdesc and then in the .specs file. *)
let proc_get_attributes proc_name proc_desc : Sil.proc_attributes =
  let from_proc_desc = Cfg.Procdesc.get_attributes proc_desc in
  let defined = Cfg.Procdesc.is_defined proc_desc in
  if not defined then
    match get_summary proc_name with
    | None -> from_proc_desc
    | Some summary ->
        summary.attributes (* get attributes from .specs file *)
  else from_proc_desc

let proc_get_method_annotation proc_name proc_desc =
  (proc_get_attributes proc_name proc_desc).Sil.method_annotation

let get_origin proc_name =
  match get_summary_origin proc_name with
  | Some (_, origin) -> origin
  | None -> Res_dir

let summary_exists proc_name =
  match get_summary proc_name with
  | Some _ -> true
  | None -> false

let get_status summary =
  summary.status

let is_active proc_name =
  get_status (get_summary_unsafe proc_name) = ACTIVE

let is_inactive proc_name =
  get_status (get_summary_unsafe proc_name) = INACTIVE

let get_timestamp summary =
  summary.timestamp

let get_proc_name summary =
  summary.proc_name

let get_attributes summary =
  summary.attributes

(** Get the flag with the given key for the procedure, if any *)
(* TODO get_flag should get a summary as parameter *)
let get_flag proc_name key =
  match get_summary proc_name with
  | None -> None
  | Some summary ->
      let proc_flags = summary.proc_flags in
      try
        Some (Hashtbl.find proc_flags key)
      with Not_found -> None

(** Get the iterations associated to the procedure if any, or the default timeout from the
command line *)
let get_iterations proc_name =
  match get_summary proc_name with
  | None ->
      raise (Failure ("Specs.get_iterations: " ^ (Procname.to_string proc_name) ^ "Not_found"))
  | Some summary ->
      let proc_flags = summary.proc_flags in
      try
        let time_str = Hashtbl.find proc_flags proc_flag_iterations in
        Pervasives.int_of_string time_str
      with exn when exn_not_timeout exn -> !iterations_cmdline

(** Return the specs and parameters for the proc in the spec table *)
let get_specs_formals proc_name =
  match get_summary proc_name with
  | None ->
      raise (Failure ("Specs.get_specs_formals: " ^ (Procname.to_string proc_name) ^ "Not_found"))
  | Some summary ->
      let specs = get_specs_from_payload summary in
      let formals = summary.formals in
      (specs, formals)

(** Return the specs for the proc in the spec table *)
let get_specs proc_name =
  fst (get_specs_formals proc_name)

(** Return the current phase for the proc *)
let get_phase proc_name =
  match get_summary_origin proc_name with
  | None -> raise (Failure ("Specs.get_phase: " ^ (Procname.to_string proc_name) ^ " Not_found"))
  | Some (summary, origin) -> summary.phase

(** Set the current status for the proc *)
let set_status proc_name status =
  match get_summary_origin proc_name with
  | None -> raise (Failure ("Specs.set_status: " ^ (Procname.to_string proc_name) ^ " Not_found"))
  | Some (summary, origin) -> set_summary_origin proc_name { summary with status = status } origin

(** Create the initial dependency map with the given list of dependencies *)
let mk_initial_dependency_map proc_list : dependency_map_t =
  list_fold_left (fun map pname -> Procname.Map.add pname (- 1) map) Procname.Map.empty proc_list

(** Re-initialize a dependency map *)
let re_initialize_dependency_map dependency_map =
  Procname.Map.map (fun dep_proc -> - 1) dependency_map

(** Update the dependency map of [proc_name] with the current
timestamps of the dependents *)
let update_dependency_map proc_name =
  match get_summary_origin proc_name with
  | None ->
      raise
        (Failure ("Specs.update_dependency_map: " ^ (Procname.to_string proc_name) ^ " Not_found"))
  | Some (summary, origin) ->
      let current_dependency_map =
        Procname.Map.mapi
          (fun dep_proc old_stamp -> get_timestamp summary)
          summary.dependency_map in
      set_summary_origin proc_name { summary with dependency_map = current_dependency_map } origin

(** [init_summary loc (proc_name, ret_type, formals, depend_list, loc, nodes,
proc_flags, initial_err_log, calls, cyclomatic, in_out_calls_opt, proc_attributes)]
initializes the summary for [proc_name] given dependent procs in list [depend_list]. *)
let init_summary
    (proc_name, ret_type, formals, depend_list, loc,
    nodes, proc_flags, initial_err_log, calls, cyclomatic, in_out_calls_opt,
    proc_attributes) =
  let dependency_map = mk_initial_dependency_map depend_list in
  let summary =
    {
      dependency_map = dependency_map;
      loc = loc;
      nodes = nodes;
      ret_type = ret_type;
      formals = formals;
      phase = FOOTPRINT;
      proc_name = proc_name;
      proc_flags = proc_flags;
      sessions = ref 0;
      payload = PrePosts [];
      stats = empty_stats initial_err_log calls cyclomatic in_out_calls_opt;
      status = INACTIVE;
      timestamp = 0;
      attributes = proc_attributes;
    } in
  Procname.Hash.replace spec_tbl proc_name (summary, Res_dir)

let reset_summary call_graph proc_name loc =
  let dependents = Cg.get_defined_children call_graph proc_name in
  let proc_attributes = {
    Sil.access = Sil.Default;
    Sil.exceptions = [];
    Sil.is_abstract = false;
    Sil.is_bridge_method = false;
    Sil.is_objc_instance_method = false;
    Sil.is_synthetic_method = false;
    Sil.language = !Sil.curr_language;
    Sil.func_attributes = [];
    Sil.method_annotation = Sil.method_annotation_empty;
  } in
  init_summary (
      proc_name,
      Sil.Tvoid,
      [],
      Procname.Set.elements
        dependents,
      loc,
      [],
      proc_flags_empty (),
      Errlog.empty (),
      [],
      0,
      Some (Cg.get_calls call_graph proc_name),
      proc_attributes
    )

(* =============== END of support for spec tables =============== *)
