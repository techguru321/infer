(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open !Utils

module F = Format

let make_base base_str =
  Var.of_pvar (Pvar.mk (Mangled.from_string base_str) Procname.empty_block), Typ.Tvoid

let make_field_access access_str =
  AccessPath.FieldAccess (Ident.create_fieldname (Mangled.from_string access_str) 0, Typ.Tvoid)

let make_access_path base_str accesses =
  let rec make_accesses accesses_acc = function
    | [] -> accesses_acc
    | access_str :: l -> make_accesses ((make_field_access access_str) :: accesses_acc) l in
  let accesses = make_accesses [] accesses in
  make_base base_str, IList.rev accesses

let tests =
  let x = make_access_path "x" [] in
  let y = make_access_path "y" [] in
  let f_access = make_field_access "f" in
  let g_access = make_field_access "g" in
  let xF = make_access_path "x" ["f"] in
  let xFG = make_access_path "x" ["f"; "g";] in
  let yF = make_access_path "y" ["f"] in

  let x_exact = AccessPath.Exact x in
  let y_exact = AccessPath.Exact y in
  let x_abstract = AccessPath.Abstracted x in
  let xF_exact = AccessPath.Exact xF in
  let xFG_exact = AccessPath.Exact xFG in
  let yF_exact = AccessPath.Exact yF in
  let yF_abstract = AccessPath.Abstracted yF in

  let open OUnit2 in
  let equal_test =
    let equal_test_ _ =
      assert_bool "equal works for bases" (AccessPath.raw_equal x (make_access_path "x" []));
      assert_bool
        "equal works for paths"
        (AccessPath.raw_equal xFG (make_access_path "x" ["f"; "g";]));
      assert_bool "disequality works for bases" (not (AccessPath.raw_equal x y));
      assert_bool "disequality works for paths" (not (AccessPath.raw_equal xF xFG)) in
    "equal">::equal_test_ in

  let append_test =
    let pp_diff fmt (actual, expected) =
      F.fprintf
        fmt
        "Expected output %a but got %a"
        AccessPath.pp_raw expected
        AccessPath.pp_raw actual in
    let assert_eq input expected =
      assert_equal ~cmp:AccessPath.raw_equal ~pp_diff input expected in
    let append_test_ _ =
      assert_eq xF (AccessPath.append x f_access);
      assert_eq xFG (AccessPath.append xF g_access) in
    "append">::append_test_ in

  let prefix_test =
    let prefix_test_ _ =
      assert_bool "x is prefix of self" (AccessPath.is_prefix x x);
      assert_bool "x.f is prefix of self" (AccessPath.is_prefix xF xF);
      assert_bool "x is not prefix of y" (not (AccessPath.is_prefix x y));
      assert_bool "x is prefix of x.f" (AccessPath.is_prefix x xF);
      assert_bool "x.f not prefix of x" (not (AccessPath.is_prefix xF x));
      assert_bool "x.f is prefix of x.f.g" (AccessPath.is_prefix xF xFG);
      assert_bool "x.f.g is not prefix of x.f" (not (AccessPath.is_prefix xFG xF));
      assert_bool "y.f is not prefix of x.f" (not (AccessPath.is_prefix yF xF));
      assert_bool "y.f is not prefix of x.f.g" (not (AccessPath.is_prefix yF xFG)) in
    "prefix">::prefix_test_ in

  let abstraction_test =
    let abstraction_test_ _ =
      assert_bool "extract" (AccessPath.raw_equal (AccessPath.extract xF_exact) xF);
      assert_bool "is_exact" (AccessPath.is_exact x_exact);
      assert_bool "not is_exact" (not (AccessPath.is_exact x_abstract));
      assert_bool "(<=)1" (AccessPath.(<=) ~lhs:x_exact ~rhs:x_abstract);
      assert_bool "(<=)2" (AccessPath.(<=) ~lhs:xF_exact ~rhs:x_abstract);
      assert_bool
        "not (<=)1"
        (not (AccessPath.(<=) ~lhs:x_abstract ~rhs:x_exact));
      assert_bool
        "not (<=)2"
        (not (AccessPath.(<=) ~lhs:x_abstract ~rhs:xF_exact)) in
    "abstraction">::abstraction_test_ in

  let domain_test =
    let domain_test_ _ =
      let pp_diff fmt (actual, expected) =
        F.fprintf fmt "Expected %s but got %s" expected actual in
      let assert_eq input_aps expected =
        let input = pp_to_string AccessPathDomains.Set.pp input_aps in
        assert_equal ~cmp:(=) ~pp_diff input expected in
      let aps1 = AccessPathDomains.Set.of_list [x_exact; x_abstract] in (* { x*, x } *)
      let aps2 = AccessPathDomains.Set.add xF_exact aps1 in (* x*, x, x.f *)
      let aps3 = AccessPathDomains.Set.add yF_exact aps2 in (* x*, x, x.f, y.f *)

      assert_bool "mem_easy" (AccessPathDomains.Set.mem x_exact aps1);
      assert_bool "mem_harder1" (AccessPathDomains.Set.mem xFG_exact aps1);
      assert_bool "mem_harder2" (AccessPathDomains.Set.mem x_abstract aps1);
      assert_bool "mem_negative" (not (AccessPathDomains.Set.mem y_exact aps1));
      assert_bool "mem_not_fully_contained" (not (AccessPathDomains.Set.mem yF_abstract aps3));

      assert_bool "mem_fuzzy_easy" (AccessPathDomains.Set.mem_fuzzy x_exact aps1);
      assert_bool "mem_fuzzy_harder1" (AccessPathDomains.Set.mem_fuzzy xFG_exact aps1);
      assert_bool "mem_fuzzy_harder2" (AccessPathDomains.Set.mem_fuzzy x_abstract aps1);
      assert_bool "mem_fuzzy_negative" (not (AccessPathDomains.Set.mem_fuzzy y_exact aps1));
      (* [mem_fuzzy] should behave the same as [mem] except in this case *)
      assert_bool
        "mem_fuzzy_not_fully_contained"
        (AccessPathDomains.Set.mem_fuzzy yF_abstract aps3);

      assert_bool "<= on same is true" (AccessPathDomains.Set.(<=) ~lhs:aps1 ~rhs:aps1);
      assert_bool "aps1 <= aps2" (AccessPathDomains.Set.(<=) ~lhs:aps1 ~rhs:aps2);
      assert_bool "aps2 <= aps1" (AccessPathDomains.Set.(<=) ~lhs:aps2 ~rhs:aps1);
      assert_bool "aps1 <= aps3" (AccessPathDomains.Set.(<=) ~lhs:aps1 ~rhs:aps3);
      assert_bool "not aps3 <= aps1" (not (AccessPathDomains.Set.(<=) ~lhs:aps3 ~rhs:aps1));

      assert_eq (AccessPathDomains.Set.join aps1 aps1) "{ &x*, &x }";
      assert_eq (AccessPathDomains.Set.join aps1 aps2) "{ &x*, &x, &x.f }";
      assert_eq (AccessPathDomains.Set.join aps1 aps3) "{ &x*, &x, &x.f, &y.f }";

      let widen s1 s2 =
        AccessPathDomains.Set.widen ~prev:s1 ~next:s2 ~num_iters:10 in
      assert_eq (widen aps1 aps1) "{ &x*, &x }";
      assert_eq (widen aps2 aps3) "{ &x*, &y.f*, &x, &x.f }";
      let aps_prev = AccessPathDomains.Set.of_list [x_exact; y_exact] in (* { x, y } *)
      let aps_next = AccessPathDomains.Set.of_list [y_exact; yF_exact] in (* { y. y.f } *)
      (* { x, y } \/ { y, y.f } = { y.f*, x, y } *)
      assert_eq (widen aps_prev aps_next) "{ &y.f*, &x, &y }";
      (* { y, y.f } \/ { x, y } = { x*, y, y.f } *)
      assert_eq (widen aps_next aps_prev) "{ &x*, &y, &y.f }";

      assert_eq (AccessPathDomains.Set.normalize aps1) "{ &x* }";
      assert_eq (AccessPathDomains.Set.normalize aps2) "{ &x* }";
      assert_eq (AccessPathDomains.Set.normalize aps3) "{ &x*, &y.f }" in
    "domain">::domain_test_ in

  "all_tests_suite">:::[equal_test; append_test; prefix_test; abstraction_test; domain_test]
