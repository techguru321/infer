# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

ROOT_DIR = $(TESTS_DIR)/../..

CLEAN_EXTRA += duplicates.txt

OBJECTS = $(foreach source,$(filter %.c %.cpp %.m %.mm,$(SOURCES)),$(basename $(source)).o)

include $(TESTS_DIR)/infer.make
include $(TESTS_DIR)/clang-base.make

infer-out$(TEST_SUFFIX)/report.json: $(CLANG_DEPS) $(SOURCES) $(HEADERS) $(TESTS_DIR)/.inferconfig $(MAKEFILE_LIST)
	$(QUIET)$(call silent_on_success,Testing infer/clang$(ANALYZER_STRING) in $(TEST_REL_DIR),\
	  $(INFER_BIN) --results-dir $(@D) --dump-duplicate-symbols \
	    $(INFER_OPTIONS) -a $(ANALYZER) -- \
	    clang $(CLANG_OPTIONS) $(SOURCES))
	$(QUIET)$(call check_no_duplicates,infer-out$(TEST_SUFFIX)/duplicates.txt)
