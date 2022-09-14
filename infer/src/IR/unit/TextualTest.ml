(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open Textual
module F = Format

let parse_module text =
  match TextualParser.parse_string (SourceFile.create "dummy.sil") text with
  | Ok m ->
      m
  | _ ->
      raise (Failure "Couldn't parse a module")


let%test_module "parsing" =
  ( module struct
    let text =
      {|
       attribute source_language = "hack"
       attribute source_file = "original.hack"

       attribute source_language = "java" // Won't have an effect

       define nothing(): void {
         #node0:
           ret null
       }
       |}


    let%expect_test _ =
      let module_ = parse_module text in
      let attrs = module_.attrs in
      F.printf "%a" (Pp.seq ~sep:"\n" Attr.pp_with_loc) attrs ;
      [%expect
        {|
        line 2, column 7: source_language = "hack"
        line 3, column 7: source_file = "original.hack"
        line 5, column 7: source_language = "java" |}] ;
      let lang = Option.value_exn (Module.lang module_) in
      F.printf "%s" (Lang.to_string lang) ;
      [%expect {| hack |}]

    let%expect_test _ =
      let module_ = parse_module text in
      F.printf "%a" Module.pp module_ ;
      [%expect
        {|
          attribute source_language = "hack"

          attribute source_file = "original.hack"

          attribute source_language = "java"

          define nothing() : void {
            #node0:
                ret null

          } |}]
  end )

let%test_module "procnames" =
  ( module struct
    let%expect_test _ =
      let toplevel_proc =
        Procname.
          { qualified_name=
              { enclosing_class= TopLevel
              ; name= {value= "toplevel"; loc= Location.known ~line:0 ~col:0} }
          ; formals_types= []
          ; result_type= Typ.Void
          ; kind= NonVirtual }
      in
      let as_java = Procname.to_sil Lang.Java toplevel_proc in
      let as_hack = Procname.to_sil Lang.Hack toplevel_proc in
      F.printf "%a@\n" SilProcname.pp as_java ;
      F.printf "%a@\n" SilProcname.pp as_hack ;
      [%expect {|
        void $TOPLEVEL$CLASS$.toplevel()
        toplevel |}]
  end )

let%test_module "to_sil" =
  ( module struct
    let%expect_test _ =
      let no_lang = {|define nothing() : void { #node: ret null }|} in
      let m = parse_module no_lang in
      try Module.to_sil m |> ignore
      with ToSilTransformationError pp_msg ->
        pp_msg F.std_formatter () ;
        [%expect {| Missing or unsupported source_language attribute |}]
  end )

let%test_module "remove_internal_calls transformation" =
  ( module struct
    let input_text =
      {|
        declare g1(int) : int

        declare g2(int) : int

        declare g3(int) : int

        declare m(int, int) : int

        define f(x: int, y: int) : int {
          #entry:
              n0:int = load &x
              n1:int = load &y
              n3 = __sil_mult_int(g3(n0), m(g1(n0), g2(n1)))
              n4 = m(n0, g3(n1))
              jmp lab1(g1(n3), g3(n0)), lab2(g2(n3), g3(n0))
          #lab1(n6, n7):
              n8 = __sil_mult_int(n6, n7)
              jmp lab
          #lab2(n10, n11):
              ret g3(m(n10, n11))
          #lab:
              throw g1(n8)
        }

        define empty() : void {
          #entry:
              ret null
        }|}


    let%expect_test _ =
      let module_ = parse_module input_text |> Transformation.remove_internal_calls in
      F.printf "%a" Module.pp module_ ;
      [%expect
        {|
        declare g1(int) : int

        declare g2(int) : int

        declare g3(int) : int

        declare m(int, int) : int

        define f(x: int, y: int) : int {
          #entry:
              n0:int = load &x
              n1:int = load &y
              n12 = g3(n0)
              n13 = g1(n0)
              n14 = g2(n1)
              n15 = m(n13, n14)
              n3 = __sil_mult_int(n12, n15)
              n16 = g3(n1)
              n4 = m(n0, n16)
              n17 = g1(n3)
              n18 = g3(n0)
              n19 = g2(n3)
              n20 = g3(n0)
              jmp lab1(n17, n18), lab2(n19, n20)

          #lab1(n6, n7):
              n8 = __sil_mult_int(n6, n7)
              jmp lab

          #lab2(n10, n11):
              n21 = m(n10, n11)
              n22 = g3(n21)
              ret n22

          #lab:
              n23 = g1(n8)
              throw n23

        }

        define empty() : void {
          #entry:
              ret null

        } |}]
  end )

let%test_module "let_propagation transformation" =
  ( module struct
    let input_text =
      {|

        define f(x: int, y: int) : int {
          #entry:
              n0:int = load &x
              n1:int = load &y
              n3 = __sil_mult_int(n0, n1)
              n4 = __sil_neg(n3, n0)
              jmp lab(n4)
          #lab(n5):
              n6 = __sil_neg(n1)
              n7 = __sil_plusa(n6, n3)
              n8 = 42 // dead
              ret n7
        } |}


    let%expect_test _ =
      let module_ = parse_module input_text |> Transformation.let_propagation in
      F.printf "%a" Module.pp module_ ;
      [%expect
        {|
          define f(x: int, y: int) : int {
            #entry:
                n0:int = load &x
                n1:int = load &y
                jmp lab(__sil_neg(__sil_mult_int(n0, n1), n0))

            #lab(n5):
                ret __sil_plusa(__sil_neg(n1), __sil_mult_int(n0, n1))

          } |}]
  end )
