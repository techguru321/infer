% Copyright (c) Facebook, Inc. and its affiliates.
%
% This source code is licensed under the MIT license found in the
% LICENSE file in the root directory of this source tree.

-module(pulse_taint_types).
-export([
    test_taint1_Bad/0,
    test_taint2_Bad/0,
    test_taint3_Ok/0
]).

-type dirty() :: atom().

-spec(source1() -> dirty()).
source1() -> hey.

-spec(source2() -> dirty()).
source2() -> hey.

-spec(not_source() -> atom()).
not_source() -> hey.

sink(_) -> oops.

test_taint1_Bad() -> sink(source1()).

test_taint2_Bad() -> sink(source2()).

test_taint3_Ok() -> sink(not_source()).
