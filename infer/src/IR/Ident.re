/*
 * vim: set ft=rust:
 * vim: set ft=reason:
 *
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */
open! Utils;


/** Module for Names and Identifiers */
let module L = Logging;

let module F = Format;

let module Name = {
  type t =
    | Primed
    | Normal
    | Footprint
    | Spec
    | FromString string
  [@@deriving compare];
  let primed = "t";
  let normal = "n";
  let footprint = "f";
  let spec = "val";
  let from_string s => FromString s;
  let to_string =
    fun
    | Primed => primed
    | Normal => normal
    | Footprint => footprint
    | Spec => spec
    | FromString s => s;
  let equal n1 n2 => compare n1 n2 == 0;
};

type name = Name.t [@@deriving compare];

let name_spec = Name.Spec;

let name_primed = Name.Primed;

let equal_name x y => 0 == compare_name x y;

type fieldname = {fpos: int, fname: Mangled.t} [@@deriving compare];

let equal_fieldname x y => 0 == compare_fieldname x y;

type kind =
  | KNone
  /** special kind of "null ident" (basically, a more compact way of implementing an ident option).
      useful for situations when an instruction requires an id, but no one should read the result. */
  | KFootprint
  | KNormal
  | KPrimed
[@@deriving compare];

let kfootprint = KFootprint;

let knormal = KNormal;

let kprimed = KPrimed;

let equal_kind x y => 0 == compare_kind x y;

/* timestamp for a path identifier */
let path_ident_stamp = (-3);

type t = {kind: kind, name: Name.t, stamp: int} [@@deriving compare];

/* most unlikely first */
let equal i1 i2 => i1.stamp === i2.stamp && i1.kind === i2.kind && equal_name i1.name i2.name;


/** {2 Set for identifiers} */
let module IdentSet = Set.Make {
  type nonrec t = t;
  let compare = compare;
};

let module IdentMap = Map.Make {
  type nonrec t = t;
  let compare = compare;
};

let module IdentHash = Hashtbl.Make {
  type nonrec t = t;
  let equal = equal;
  let hash (id: t) => Hashtbl.hash id;
};

let module FieldSet = Set.Make {
  type t = fieldname [@@deriving compare];
};

let module FieldMap = Map.Make {
  type t = fieldname [@@deriving compare];
};

let idlist_to_idset ids => IList.fold_left (fun set id => IdentSet.add id set) IdentSet.empty ids;


/** {2 Conversion between Names and Strings} */
let module NameHash = Hashtbl.Make {
  type t = name;
  let equal = equal_name;
  let hash = Hashtbl.hash;
};


/** Convert a string to a name */
let string_to_name = Name.from_string;


/** Create a field name with the given position (field number in the CSU) */
let create_fieldname (n: Mangled.t) (position: int) => {fpos: position, fname: n};


/** Convert a name to a string. */
let name_to_string = Name.to_string;


/** Convert a fieldname to a string. */
let fieldname_to_string fn => Mangled.to_string fn.fname;


/** Convert a fieldname to a string, including the mangled part. */
let fieldname_to_complete_string fn => Mangled.to_string_full fn.fname;


/** Convert a fieldname to a simplified string with at most one-level path. */
let fieldname_to_simplified_string fn => {
  let s = Mangled.to_string fn.fname;
  switch (string_split_character s '.') {
  | (Some s1, s2) =>
    switch (string_split_character s1 '.') {
    | (Some _, s4) => s4 ^ "." ^ s2
    | _ => s
    }
  | _ => s
  }
};


/** Convert a fieldname to a flat string without path. */
let fieldname_to_flat_string fn => {
  let s = Mangled.to_string fn.fname;
  switch (string_split_character s '.') {
  | (Some _, s2) => s2
  | _ => s
  }
};


/** Returns the class part of the fieldname */
let java_fieldname_get_class fn => {
  let fn = fieldname_to_string fn;
  let ri = String.rindex fn '.';
  String.sub fn 0 ri
};


/** Returns the last component of the fieldname */
let java_fieldname_get_field fn => {
  let fn = fieldname_to_string fn;
  let ri = 1 + String.rindex fn '.';
  String.sub fn ri (String.length fn - ri)
};


/** Check if the field is the synthetic this$n of a nested class, used to access the n-th outher instance. */
let java_fieldname_is_outer_instance fn => {
  let fn = fieldname_to_string fn;
  let fn_len = String.length fn;
  let this = ".this$";
  let this_len = String.length this;
  let zero_to_nine s => s >= "0" && s <= "9";
  fn_len > this_len &&
  String.sub fn (fn_len - this_len - 1) this_len == this &&
  zero_to_nine (String.sub fn (fn_len - 1) 1)
};

let fieldname_offset fn => fn.fpos;


/** hidded fieldname constant */
let fieldname_hidden = create_fieldname (Mangled.from_string ".hidden") 0;


/** hidded fieldname constant */
let fieldname_is_hidden fn => equal_fieldname fn fieldname_hidden;


/** {2 Functions and Hash Tables for Managing Stamps} */

/** Set the stamp of the identifier */
let set_stamp i stamp => {...i, stamp};


/** Get the stamp of the identifier */
let get_stamp i => i.stamp;

let module NameGenerator = {
  type t = NameHash.t int;
  let create () :t => NameHash.create 17;

  /** Map from names to stamps. */
  let name_map = ref (create ());
  let get_current () => !name_map;
  let set_current map => name_map := map;

  /** Reset the name generator */
  let reset () => name_map := create ();

  /** Create a fresh identifier with the given kind and name. */
  let create_fresh_ident kind name => {
    let stamp =
      try {
        let stamp = NameHash.find !name_map name;
        NameHash.replace !name_map name (stamp + 1);
        stamp + 1
      } {
      | Not_found =>
        NameHash.add !name_map name 0;
        0
      };
    {kind, name, stamp}
  };

  /** Make sure that fresh ids after whis one will be with different stamps */
  let update_name_hash name stamp =>
    try {
      let curr_stamp = NameHash.find !name_map name;
      let new_stamp = max curr_stamp stamp;
      NameHash.replace !name_map name new_stamp
    } {
    | Not_found => NameHash.add !name_map name stamp
    };
};


/** Name used for the return variable */
let name_return = Mangled.from_string "return";


/** Return the standard name for the given kind */
let standard_name kind =>
  if (kind === KNormal || kind === KNone) {
    Name.Normal
  } else if (kind === KFootprint) {
    Name.Footprint
  } else {
    Name.Primed
  };


/** Every identifier with a given stamp should unltimately be created using this function */
let create_with_stamp kind name stamp => {
  NameGenerator.update_name_hash name stamp;
  {kind, name, stamp}
};


/** Create an identifier with default name for the given kind */
let create kind stamp => create_with_stamp kind (standard_name kind) stamp;


/** Generate a normal identifier with the given name and stamp */
let create_normal name stamp => create_with_stamp KNormal name stamp;


/** Create a fresh identifier with default name for the given kind. */
let create_fresh kind => NameGenerator.create_fresh_ident kind (standard_name kind);

let create_none () => create_fresh KNone;


/** Generate a primed identifier with the given name and stamp */
let create_primed name stamp => create_with_stamp KPrimed name stamp;


/** Generate a footprint identifier with the given name and stamp */
let create_footprint name stamp => create_with_stamp KFootprint name stamp;


/** {2 Functions for Identifiers} */

/** Get a name of an identifier */
let get_name id => id.name;

let is_primed (id: t) => id.kind === KPrimed;

let is_normal (id: t) => id.kind === KNormal || id.kind === KNone;

let is_footprint (id: t) => id.kind === KFootprint;

let is_none (id: t) => id.kind == KNone;

let is_path (id: t) => id.kind === KNormal && id.stamp == path_ident_stamp;

let make_unprimed id =>
  if (id.kind != KPrimed) {
    assert false
  } else if (id.kind === KNone) {
    {...id, kind: KNone}
  } else {
    {...id, kind: KNormal}
  };


/** Update the name generator so that the given id's are not generated again */
let update_name_generator ids => {
  let upd id => ignore (create_with_stamp id.kind id.name id.stamp);
  IList.iter upd ids
};


/** Generate a normal identifier whose name encodes a path given as a string. */
let create_path pathstring =>
  create_normal (string_to_name ("%path%" ^ pathstring)) path_ident_stamp;


/** {2 Pretty Printing} */

/** Convert an identifier to a string. */
let to_string id =>
  if (id.kind === KNone) {
    "_"
  } else {
    let base_name = name_to_string id.name;
    let prefix =
      if (id.kind === KFootprint) {
        "@"
      } else if (id.kind === KNormal) {
        ""
      } else {
        "_"
      };
    let suffix = "$" ^ string_of_int id.stamp;
    prefix ^ base_name ^ suffix
  };


/** Pretty print a name. */
let pp_name f name => F.fprintf f "%s" (name_to_string name);

let pp_fieldname f fn =>
  /* only use for debug F.fprintf f "%a#%d" pp_name fn.fname fn.fpos */
  Mangled.pp f fn.fname;


/** Pretty print a name in latex. */
let pp_name_latex style f (name: name) => Latex.pp_string style f (name_to_string name);

let pp_fieldname_latex style f fn => Latex.pp_string style f (Mangled.to_string fn.fname);


/** Pretty print an identifier. */
let pp pe f id =>
  switch pe.pe_kind {
  | PP_TEXT
  | PP_HTML => F.fprintf f "%s" (to_string id)
  | PP_LATEX =>
    let base_name = name_to_string id.name;
    let style =
      if (id.kind == KFootprint) {
        Latex.Boldface
      } else if (id.kind == KNormal) {
        Latex.Roman
      } else {
        Latex.Roman
      };
    F.fprintf f "%a_{%s}" (Latex.pp_string style) base_name (string_of_int id.stamp)
  };


/** pretty printer for lists of identifiers */
let pp_list pe => pp_comma_seq (pp pe);


/** pretty printer for lists of names */
let pp_name_list = pp_comma_seq pp_name;
