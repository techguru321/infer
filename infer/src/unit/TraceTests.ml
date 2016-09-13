(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

module L = Logging
module F = Format

module MockTraceElem = struct
  type kind =
    | Kind1
    | Kind2

  type t = kind

  let call_site _ = assert false

  let kind t = t

  let make kind _ = kind

  let compare t1 t2 =
    match t1, t2 with
    | Kind1, Kind1 -> 0
    | Kind1, _ -> (-1)
    | _, Kind1 -> 1
    | Kind2, Kind2 -> 0

  let equal t1 t2 =
    compare t1 t2 = 0

  let pp_kind fmt = function
    | Kind1 -> F.fprintf fmt "Kind1"
    | Kind2 -> F.fprintf fmt "Kind2"

  let pp = pp_kind

  module Set = PrettyPrintable.MakePPSet(struct
      type nonrec t = t
      let compare = compare
      let pp_element = pp
    end)

  let to_callee _ _ = assert false
end

module MockSource = struct
  include MockTraceElem

  let make : kind -> CallSite.t -> t = MockTraceElem.make

  let get _ = assert false
  let is_footprint _ = assert false
  let make_footprint _ = assert false
  let get_footprint_access_path _ = assert false
  let to_return _ _ = assert false
end

module MockSink = struct
  include MockTraceElem


  let get _ = assert false
end


module MockTrace = Trace.Make(struct
    module Source = MockSource
    module Sink = MockSink

    let should_report source sink =
      Source.kind source = Sink.kind sink

    let get_reportable_exn _ _ _ = assert false
  end)

let tests =
  let open OUnit2 in
  let get_reports =
    let get_reports_ _ =
      let source1 = MockSource.make MockTraceElem.Kind1 CallSite.dummy in
      let source2 = MockSource.make MockTraceElem.Kind2 CallSite.dummy in
      let sink1 = MockSink.make MockTraceElem.Kind1 CallSite.dummy in
      let sink2 = MockSink.make MockTraceElem.Kind2 CallSite.dummy in
      let trace =
        MockTrace.of_source source1
        |> MockTrace.add_source source2
        |> MockTrace.add_sink sink1
        |> MockTrace.add_sink sink2 in
      let reports = MockTrace.get_reports trace in

      assert_equal (IList.length reports) 2;
      assert_bool
        "Reports should contain source1 -> sink1"
        (IList.exists
           (fun (source, sink, _) -> MockSource.equal source source1 && MockSink.equal sink sink1)
           reports);
      assert_bool
        "Reports should contain source2 -> sink2"
        (IList.exists
           (fun (source, sink, _) -> MockSource.equal source source2 && MockSink.equal sink sink2)
           reports) in
    "get_reports">::get_reports_ in

  "trace_domain_suite">:::[get_reports]
