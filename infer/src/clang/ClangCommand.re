/*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */
open! Utils;

type t = {
  exec: string,
  argv: list string,
  orig_argv: list string,
  quoting_style: ClangQuotes.style
};

let fcp_dir =
  Config.bin_dir /\/ Filename.parent_dir_name /\/ Filename.parent_dir_name /\/ "facebook-clang-plugins";


/** path of the plugin to load in clang */
let plugin_path = fcp_dir /\/ "libtooling" /\/ "build" /\/ "FacebookClangPlugin.dylib";


/** name of the plugin to use */
let plugin_name = "BiniouASTExporter";


/** whether to amend include search path with C++ model headers */
let infer_cxx_models = Config.cxx_experimental;

let value_of_argv_option argv opt_name =>
  IList.fold_left
    (
      fun (prev_arg, result) arg => {
        let result' =
          if (Option.is_some result) {
            result
          } else if (Core.Std.String.equal opt_name prev_arg) {
            Some arg
          } else {
            None
          };
        (arg, result')
      }
    )
    ("", None)
    argv |> snd;

let value_of_option {orig_argv} => value_of_argv_option orig_argv;

let has_flag {orig_argv} flag => IList.exists (Core.Std.String.equal flag) orig_argv;

let can_attach_ast_exporter cmd =>
  has_flag cmd "-cc1" && (
    switch (value_of_option cmd "-x") {
    | None =>
      Logging.stderr "malformed -cc1 command has no \"-x\" flag!";
      false
    | Some lang when string_is_prefix "assembler" lang => false
    | Some _ => true
    }
  );

let argv_cons a b => [a, ...b];

let argv_do_if cond action x =>
  if cond {
    action x
  } else {
    x
  };

let file_arg_cmd_sanitizer cmd => {
  let file = ClangQuotes.mk_arg_file "clang_command_" cmd.quoting_style cmd.argv;
  {...cmd, argv: [Format.sprintf "@%s" file]}
};

/* Work around various path or library issues occurring when one tries to substitute Apple's version
   of clang with a different version. Also mitigate version discrepancies in clang's
   fatal warnings. */
let clang_cc1_cmd_sanitizer cmd => {
  /* command line options not supported by the opensource compiler or the plugins */
  let flags_blacklist = ["-fembed-bitcode-marker", "-fno-canonical-system-headers"];
  let replace_option_arg option arg =>
    if (Core.Std.String.equal option "-arch" && Core.Std.String.equal arg "armv7k") {
      "armv7"
      /* replace armv7k arch with armv7 */
    } else if (
      Core.Std.String.equal option "-isystem"
    ) {
      switch Config.clang_include_to_override {
      | Some to_replace when Core.Std.String.equal arg to_replace =>
        fcp_dir /\/ "clang" /\/ "install" /\/ "lib" /\/ "clang" /\/ "4.0.0" /\/ "include"
      | _ => arg
      }
    } else {
      arg
    };
  let post_args_rev =
    [] |> IList.rev_append ["-include", Config.lib_dir /\/ "clang_wrappers" /\/ "global_defines.h"] |>
    /* Never error on warnings. Clang is often more strict than Apple's version.  These arguments
       are appended at the end to override previous opposite settings.  How it's done: suppress
       all the warnings, since there are no warnings, compiler can't elevate them to error
       level. */
    argv_cons "-Wno-everything";
  let rec filter_unsupported_args_and_swap_includes (prev, res_rev) =>
    fun
    | [] =>
      /* return non-reversed list */
      IList.rev (post_args_rev @ res_rev)
    | [flag, ...tl] when IList.mem Core.Std.String.equal flag flags_blacklist =>
      filter_unsupported_args_and_swap_includes (flag, res_rev) tl
    | [arg, ...tl] => {
        let res_rev' = [replace_option_arg prev arg, ...res_rev];
        filter_unsupported_args_and_swap_includes (arg, res_rev') tl
      };
  let clang_arguments = filter_unsupported_args_and_swap_includes ("", []) cmd.argv;
  file_arg_cmd_sanitizer {...cmd, argv: clang_arguments}
};

let mk quoting_style argv => {
  let argv_list = Array.to_list argv;
  switch argv_list {
  | [exec, ...argv_no_exec] => {exec, orig_argv: argv_no_exec, argv: argv_no_exec, quoting_style}
  | [] => failwith "argv cannot be an empty list"
  }
};

let command_to_run cmd => {
  let mk_cmd normalizer => {
    let {exec, argv, quoting_style} = normalizer cmd;
    Printf.sprintf
      "'%s' %s" exec (IList.map (ClangQuotes.quote quoting_style) argv |> String.concat " ")
  };
  if (can_attach_ast_exporter cmd) {
    mk_cmd clang_cc1_cmd_sanitizer
  } else if (
    string_is_prefix "clang" (Filename.basename cmd.exec)
  ) {
    /* `clang` supports argument files and the commands can be longer than the maximum length of the
       command line, so put arguments in a file */
    mk_cmd file_arg_cmd_sanitizer
  } else {
    /* other commands such as `ld` do not support argument files */
    mk_cmd (fun x => x)
  }
};

let with_exec exec args => {...args, exec};

let with_plugin_args args => {
  let args_before_rev =
    [] |>
    /* -cc1 has to be the first argument or clang will think it runs in driver mode */
    argv_cons "-cc1" |>
    /* It's important to place this option before other -isystem options. */
    argv_do_if infer_cxx_models (IList.rev_append ["-isystem", Config.cpp_extra_include_dir]) |>
    IList.rev_append [
      "-load",
      plugin_path,
      /* (t7400979) this is a workaround to avoid that clang crashes when the -fmodules flag and the
         YojsonASTExporter plugin are used. Since the -plugin argument disables the generation of .o
         files, we invoke apple clang again to generate the expected artifacts. This will keep
         xcodebuild plus all the sub-steps happy. */
      if (has_flag args "-fmodules") {
        "-plugin"
      } else {
        "-add-plugin"
      },
      plugin_name,
      "-plugin-arg-" ^ plugin_name,
      "-",
      "-plugin-arg-" ^ plugin_name,
      "PREPEND_CURRENT_DIR=1"
    ];
  let args_after_rev = [] |> argv_do_if Config.fcp_syntax_only (argv_cons "-fsyntax-only");
  {...args, argv: IList.rev_append args_before_rev (args.argv @ IList.rev args_after_rev)}
};

let prepend_arg arg clang_args => {...clang_args, argv: [arg, ...clang_args.argv]};

let prepend_args args clang_args => {...clang_args, argv: args @ clang_args.argv};

let append_args args clang_args => {...clang_args, argv: clang_args.argv @ args};

let get_orig_argv {exec, orig_argv} => Array.of_list [exec, ...orig_argv];
