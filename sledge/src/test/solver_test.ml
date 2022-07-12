(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Sledge
open Fol

let%test_module _ =
  ( module struct
    let () =
      Dbg.init ~margin:68 ~config:(Dbg.parse_exn "+Solver.infer_frame") ()

    (* let () =
     *   Dbg.init ~margin:160
     *     ~config:(Dbg.parse_exn "+Solver.infer_frame+Solver.excise")
     *     () *)

    [@@@warning "-unused-value-declaration"]

    let infer_frame p xs q =
      Solver.infer_frame p (Var.Set.of_list xs) q |> ignore

    let check_frame p xs q =
      Solver.infer_frame p (Var.Set.of_list xs) q
      |> fun r -> assert (Option.is_some r)

    let i n = Term.integer (Z.of_int n)
    let ( + ) = Term.add
    let ( - ) = Term.sub
    let ( * ) i e = Term.mulq (Q.of_int i) e
    let wrt = Var.Set.empty
    let a_, wrt = Var.fresh "a" ~wrt
    let a2_, wrt = Var.fresh "a" ~wrt
    let a3_, wrt = Var.fresh "a" ~wrt
    let b_, wrt = Var.fresh "b" ~wrt
    let k_, wrt = Var.fresh "k" ~wrt
    let l_, wrt = Var.fresh "l" ~wrt
    let l2_, wrt = Var.fresh "l" ~wrt
    let m_, wrt = Var.fresh "m" ~wrt
    let n_, _ = Var.fresh "n" ~wrt
    let a = Term.var a_
    let a2 = Term.var a2_
    let a3 = Term.var a3_
    let b = Term.var b_
    let k = Term.var k_
    let l = Term.var l_
    let l2 = Term.var l2_
    let m = Term.var m_
    let n = Term.var n_

    let%expect_test _ =
      check_frame Sh.emp [] Sh.emp ;
      [%expect
        {|
        ( Solver.infer_frame: 0   emp \-   emp
        ) Solver.infer_frame:   emp |}]

    let%expect_test _ =
      check_frame (Sh.false_ Var.Set.empty) [] Sh.emp ;
      [%expect
        {|
        ( Solver.infer_frame: 1 false \-   emp
        ) Solver.infer_frame: false |}]

    let%expect_test _ =
      check_frame Sh.emp [n_; m_] (Sh.and_ (Formula.eq m n) Sh.emp) ;
      [%expect
        {|
        ( Solver.infer_frame: 2   emp \- ∃ %m_8, %n_9 .   %m_8 = %n_9 ∧ emp
        ) Solver.infer_frame:   %m_8 = %n_9 ∧ emp |}]

    let%expect_test _ =
      check_frame
        (Sh.seg {loc= l; bas= b; len= m; siz= n; cnt= a})
        [] Sh.emp ;
      [%expect
        {|
        ( Solver.infer_frame: 3
            %l_6 -[ %b_4, %m_8 )-> ⟨%n_9,%a_1⟩ \-   emp
        ) Solver.infer_frame:   %l_6 -[ %b_4, %m_8 )-> ⟨%n_9,%a_1⟩ |}]

    let%expect_test _ =
      check_frame
        (Sh.seg {loc= l; bas= b; len= m; siz= n; cnt= a})
        []
        (Sh.seg {loc= l; bas= b; len= m; siz= n; cnt= a}) ;
      [%expect
        {|
        ( Solver.infer_frame: 4
            %l_6 -[ %b_4, %m_8 )-> ⟨%n_9,%a_1⟩
          \-   %l_6 -[ %b_4, %m_8 )-> ⟨%n_9,%a_1⟩
        ) Solver.infer_frame:   emp |}]

    let%expect_test _ =
      let common =
        Sh.seg {loc= l2; bas= b; len= i 10; siz= i 10; cnt= a2}
      in
      let seg1 = Sh.seg {loc= l; bas= b; len= i 10; siz= i 10; cnt= a} in
      let minued = Sh.star common seg1 in
      let subtrahend =
        Sh.and_ (Formula.eq m n)
          (Sh.exists (Var.Set.of_list [m_])
             (Sh.extend_us (Var.Set.of_list [m_]) common) )
      in
      infer_frame minued [n_; m_] subtrahend ;
      [%expect
        {|
        ( Solver.infer_frame: 5
            %l_6 -[ %b_4, 10 )-> ⟨10,%a_1⟩ * %l_7 -[ %b_4, 10 )-> ⟨10,%a_2⟩
          \- ∃ %m_8, %n_9 .
            ∃ %m_10 .   %m_8 = %n_9 ∧ %l_7 -[ %b_4, 10 )-> ⟨10,%a_2⟩
        ) Solver.infer_frame:
          ∃ %m_10 .   %m_8 = %n_9 ∧ %l_6 -[ %b_4, 10 )-> ⟨10,%a_1⟩ |}]

    let%expect_test _ =
      check_frame
        (Sh.star
           (Sh.seg {loc= l; bas= b; len= m; siz= n; cnt= a})
           (Sh.seg {loc= l2; bas= b; len= m; siz= n; cnt= a2}) )
        []
        (Sh.seg {loc= l; bas= b; len= m; siz= n; cnt= a}) ;
      [%expect
        {|
        ( Solver.infer_frame: 6
            %l_6 -[ %b_4, %m_8 )-> ⟨%n_9,%a_1⟩
          * %l_7 -[ %b_4, %m_8 )-> ⟨%n_9,%a_2⟩
          \-   %l_6 -[ %b_4, %m_8 )-> ⟨%n_9,%a_1⟩
        ) Solver.infer_frame:   %l_7 -[ %b_4, %m_8 )-> ⟨%n_9,%a_2⟩ |}]

    let%expect_test _ =
      check_frame
        (Sh.star
           (Sh.seg {loc= l; bas= l; len= i 16; siz= i 8; cnt= a})
           (Sh.seg {loc= l + i 8; bas= l; len= i 16; siz= i 8; cnt= a2}) )
        [a3_]
        (Sh.seg {loc= l; bas= l; len= i 16; siz= i 16; cnt= a3}) ;
      [%expect
        {|
        ( Solver.infer_frame: 7
            %l_6 -[)-> ⟨8,%a_1⟩^⟨8,%a_2⟩ \- ∃ %a_3 .   %l_6 -[)-> ⟨16,%a_3⟩
        ) Solver.infer_frame:   (⟨8,%a_1⟩^⟨8,%a_2⟩) = %a_3 ∧ emp |}]

    let%expect_test _ =
      check_frame
        (Sh.star
           (Sh.seg {loc= l; bas= l; len= i 16; siz= i 8; cnt= a})
           (Sh.seg {loc= l + i 8; bas= l; len= i 16; siz= i 8; cnt= a2}) )
        [a3_; m_]
        (Sh.seg {loc= l; bas= l; len= m; siz= i 16; cnt= a3}) ;
      [%expect
        {|
        ( Solver.infer_frame: 8
            %l_6 -[)-> ⟨8,%a_1⟩^⟨8,%a_2⟩
          \- ∃ %a_3, %m_8 .
              %l_6 -[ %l_6, %m_8 )-> ⟨16,%a_3⟩
        ) Solver.infer_frame:
            16 = %m_8 ∧ (⟨8,%a_1⟩^⟨8,%a_2⟩) = %a_3 ∧ emp |}]

    let%expect_test _ =
      check_frame
        (Sh.star
           (Sh.seg {loc= l; bas= l; len= i 16; siz= i 8; cnt= a})
           (Sh.seg {loc= l + i 8; bas= l; len= i 16; siz= i 8; cnt= a2}) )
        [a3_; m_]
        (Sh.seg {loc= l; bas= l; len= m; siz= m; cnt= a3}) ;
      [%expect
        {|
        ( Solver.infer_frame: 9
            %l_6 -[)-> ⟨8,%a_1⟩^⟨8,%a_2⟩
          \- ∃ %a_3, %m_8 .
              %l_6 -[ %l_6, %m_8 )-> ⟨%m_8,%a_3⟩
        ) Solver.infer_frame:
            16 = %m_8 ∧ (⟨8,%a_1⟩^⟨8,%a_2⟩) = %a_3 ∧ emp |}]

    let%expect_test _ =
      check_frame
        (Sh.star
           (Sh.seg {loc= k; bas= k; len= i 16; siz= i 32; cnt= a})
           (Sh.seg {loc= l; bas= l; len= i 8; siz= i 8; cnt= i 16}) )
        [a2_; m_; n_]
        (Sh.star
           (Sh.seg {loc= l; bas= l; len= i 8; siz= i 8; cnt= n})
           (Sh.seg {loc= k; bas= k; len= m; siz= n; cnt= a2}) ) ;
      [%expect
        {|
        ( Solver.infer_frame: 10
            %k_5 -[ %k_5, 16 )-> ⟨32,%a_1⟩ * %l_6 -[)-> ⟨8,16⟩
          \- ∃ %a_2, %m_8, %n_9 .
              %k_5 -[ %k_5, %m_8 )-> ⟨%n_9,%a_2⟩ * %l_6 -[)-> ⟨8,%n_9⟩
        ) Solver.infer_frame:
          ∃ %a0_10, %a1_11 .
            %a_2 = %a0_10
          ∧ 16 = %m_8 = %n_9
          ∧ (⟨16,%a_2⟩^⟨16,%a1_11⟩) = %a_1
          ∧ (%k_5 + 16) -[ %k_5, 16 )-> ⟨16,%a1_11⟩ |}]

    let%expect_test _ =
      infer_frame
        (Sh.star
           (Sh.seg {loc= k; bas= k; len= i 16; siz= i 32; cnt= a})
           (Sh.seg {loc= l; bas= l; len= i 8; siz= i 8; cnt= i 16}) )
        [a2_; m_; n_]
        (Sh.star
           (Sh.seg {loc= k; bas= k; len= m; siz= n; cnt= a2})
           (Sh.seg {loc= l; bas= l; len= i 8; siz= i 8; cnt= n}) ) ;
      [%expect
        {|
        ( Solver.infer_frame: 11
            %k_5 -[ %k_5, 16 )-> ⟨32,%a_1⟩ * %l_6 -[)-> ⟨8,16⟩
          \- ∃ %a_2, %m_8, %n_9 .
              %k_5 -[ %k_5, %m_8 )-> ⟨%n_9,%a_2⟩ * %l_6 -[)-> ⟨8,%n_9⟩
        ) Solver.infer_frame:
          ∃ %a0_10, %a1_11 .
            %a_2 = %a0_10
          ∧ 16 = %m_8 = %n_9
          ∧ (⟨16,%a_2⟩^⟨16,%a1_11⟩) = %a_1
          ∧ (%k_5 + 16) -[ %k_5, 16 )-> ⟨16,%a1_11⟩ |}]

    let seg_split_symbolically =
      Sh.star
        (Sh.seg {loc= l; bas= l; len= i 16; siz= 8 * n; cnt= a2})
        (Sh.seg
           { loc= l + (8 * n)
           ; bas= l
           ; len= i 16
           ; siz= i 16 - (8 * n)
           ; cnt= a3 } )

    let%expect_test _ =
      check_frame
        (Sh.and_
           Formula.(or_ (or_ (eq n (i 0)) (eq n (i 1))) (eq n (i 2)))
           seg_split_symbolically )
        [m_; a_]
        (Sh.seg {loc= l; bas= l; len= m; siz= m; cnt= a}) ;
      [%expect
        {|
        ( Solver.infer_frame: 12
            %l_6 -[ %l_6, 16 )-> ⟨8×%n_9,%a_2⟩^⟨(-8×%n_9 + 16),%a_3⟩
          * ( (  0 = %n_9 ∧ emp)
            ∨ (  2 = %n_9 ∧ emp)
            ∨ (  1 = %n_9 ∧ emp)
            )
          \- ∃ %a_1, %m_8 .
              %l_6 -[ %l_6, %m_8 )-> ⟨%m_8,%a_1⟩
        ) Solver.infer_frame:
            ( (  1 = %n_9 ∧ 16 = %m_8 ∧ (⟨8,%a_2⟩^⟨8,%a_3⟩) = %a_1 ∧ emp)
            ∨ (  %a_1 = %a_2
               ∧ 2 = %n_9
               ∧ 16 = %m_8
               ∧ (%l_6 + 16) -[ %l_6, 16 )-> ⟨0,%a_3⟩)
            ) |}]

    (* Incompleteness: equivalent to above but using ≤ instead of ∨ *)
    let%expect_test _ =
      infer_frame
        (Sh.and_ (Formula.le n (i 2)) seg_split_symbolically)
        [m_; a_]
        (Sh.seg {loc= l; bas= l; len= m; siz= m; cnt= a}) ;
      [%expect
        {|
        ( Solver.infer_frame: 13
            (2 ≥ %n_9)
          ∧ %l_6 -[ %l_6, 16 )-> ⟨8×%n_9,%a_2⟩^⟨(-8×%n_9 + 16),%a_3⟩
          \- ∃ %a_1, %m_8 .
              %l_6 -[ %l_6, %m_8 )-> ⟨%m_8,%a_1⟩
        ) Solver.infer_frame: |}]

    (* Incompleteness: cannot witness existentials to satisfy non-equality
       pure constraints *)
    let%expect_test _ =
      let subtrahend =
        Sh.and_ (Formula.eq m a) (Sh.pure (Formula.dq m (i 0)))
      in
      let minuend = Sh.extend_us (Var.Set.of_ a_) Sh.emp in
      infer_frame minuend [m_] subtrahend ;
      [%expect
        {|
        ( Solver.infer_frame: 14
            emp \- ∃ %m_8 .   %a_1 = %m_8 ∧ (0 ≠ %a_1) ∧ emp
        ) Solver.infer_frame: |}]
  end )
