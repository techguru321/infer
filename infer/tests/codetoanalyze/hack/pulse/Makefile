# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

TESTS_DIR = ../../..

INFER_OPTIONS = --pulse-only --debug-exceptions --pulse-specialization-partial \
  --pulse-max-disjuncts 8 \
  --pulse-transitive-access-config transitive-access-config.json
INFERPRINT_OPTIONS = --issues-tests

SOURCES = $(sort $(wildcard *.hack))

include $(TESTS_DIR)/hack.make
