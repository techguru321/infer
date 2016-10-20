/* Copyright (c) 2016 - present Facebook, Inc.
  * All rights reserved.
  *
  * This source code is licensed under the BSD style license found in the
  * LICENSE file in the root directory of this source tree. An additional grant
  * of patent rights can be found in the PATENTS file in the same directory.
 */

/** Given a clang command, normalize it via `clang -###` if needed to get a clear view of what work
    is being done and which source files are being compiled, if any, then replace compilation
    commands by our own clang with our plugin attached for each source file. */
open! Utils;


/** Given a list of arguments for clang [args], return a list of new commands to run according to
    the results of `clang -### [args]`. Assembly commands (eg, clang -cc1as ...) are filtered out,
    although the type cannot reflect that fact. */
let normalize (args: array string) :list ClangCommand.t =>
  switch (ClangCommand.mk ClangQuotes.SingleQuotes args) {
  | CC1 args =>
    Logging.out "InferClang got toplevel -cc1 command@\n";
    [ClangCommand.CC1 args]
  | NonCCCommand args =>
    let clang_hashhashhash =
      Printf.sprintf
        "%s 2>&1" (ClangCommand.prepend_arg "-###" args |> ClangCommand.command_to_run);
    Logging.out "clang -### invocation: %s@\n" clang_hashhashhash;
    let normalized_commands = ref [];
    let one_line line =>
      if (string_is_prefix " \"" line) {
        /* massage line to remove edge-cases for splitting */
        "\"" ^ line ^ " \"" |>
        /* split by whitespace */
        Str.split (Str.regexp_string "\" \"") |> Array.of_list |>
        ClangCommand.mk ClangQuotes.EscapedDoubleQuotes
      } else if (
        Str.string_match (Str.regexp "clang[^ :]*: warning: ") line 0
      ) {
        ClangCommand.ClangWarning line
      } else {
        ClangCommand.ClangError line
      };
    let commands_or_errors =
      /* commands generated by `clang -### ...` start with ' "/absolute/path/to/binary"' */
      Str.regexp " \"/\\|clang[^ :]*: \\(error\\|warning\\): ";
    let consume_input i =>
      try (
        while true {
          let line = input_line i;
          /* keep only commands and errors */
          if (Str.string_match commands_or_errors line 0) {
            normalized_commands := [one_line line, ...!normalized_commands]
          }
        }
      ) {
      | End_of_file => ()
      };
    /* collect stdout and stderr output together (in reverse order) */
    with_process_in clang_hashhashhash consume_input |> ignore;
    normalized_commands := IList.rev !normalized_commands;
    /* Discard assembly commands. This may make the list of commands empty, in which case we'll run
       the original clang command. We could be smarter about this and try to execute the assembly
       commands with our own clang. */
    IList.filter
      (
        fun
        | ClangCommand.Assembly asm_cmd => {
            Logging.out "Skipping assembly command %s@\n" (ClangCommand.command_to_run asm_cmd);
            false
          }
        | _ => true
      )
      !normalized_commands
  | Assembly _ =>
    /* discard assembly commands -- see above */
    Logging.out "InferClang got toplevel assembly command@\n";
    []
  | ClangError _
  | ClangWarning _ =>
    /* we cannot possibly get this from the command-line... */
    assert false
  };

let execute_clang_command (clang_cmd: ClangCommand.t) => {
  /* reset logging, otherwise we might print into the logs of the previous file that was compiled */
  Logging.set_log_file_identifier None;
  switch clang_cmd {
  | CC1 args =>
    /* this command compiles some code; replace the invocation of clang with our own clang and
       plugin */
    Logging.out "Capturing -cc1 command: %s@\n" (ClangCommand.command_to_run args);
    Capture.capture args
  | ClangError error =>
    /* An error in the output of `clang -### ...`. Outputs the error and fail. This is because
       `clang -###` pretty much never fails, but warns of failures on stderr instead. */
    Logging.err "%s" error;
    exit 1
  | ClangWarning warning => Logging.err "%s@\n" warning
  | Assembly args =>
    /* We shouldn't get any assembly command at this point */
    (if Config.debug_mode {failwithf} else {Logging.err})
      "WARNING: unexpected assembly command: %s@\n" (ClangCommand.command_to_run args)
  | NonCCCommand args =>
    /* Non-compilation (eg, linking) command. Run the command as-is. It will not get captured
       further since `clang -### ...` will only output commands that invoke binaries using their
       absolute paths. */
    let argv = ClangCommand.get_orig_argv args;
    Logging.out "Executing raw command: %s@\n" (String.concat " " (Array.to_list argv));
    Process.create_process_and_wait argv
  }
};

let () = {
  let xx_suffix =
    if (string_is_suffix "++" Sys.argv.(0)) {
      "++"
    } else {
      try (Sys.getenv "INFER_XX") {
      | Not_found => ""
      }
    };
  let args = Array.copy Sys.argv;
  /* make sure we don't call ourselves recursively */
  args.(0) = CFrontend_config.clang_bin xx_suffix;
  let commands = normalize args;
  /* xcodebuild projects may require the object files to be generated by the Apple compiler, eg to
     generate precompiled headers compatible with Apple's clang. */
  let should_run_original_command =
    switch (Sys.getenv "FCP_APPLE_CLANG") {
    | bin =>
      let bin_xx = bin ^ xx_suffix;
      Logging.out "Will run Apple clang %s" bin_xx;
      args.(0) = bin_xx;
      true
    | exception Not_found => false
    };
  IList.iter execute_clang_command commands;
  if (commands == [] || should_run_original_command) {
    if (commands == []) {
      /* No command to execute after -###, let's execute the original command
         instead.

         In particular, this can happen when
         - there are only assembly commands to execute, which we skip, or
         - the user tries to run `infer -- clang -c file_that_does_not_exist.c`. In this case, this
           will fail with the appropriate error message from clang instead of silently analyzing 0
           files. */
      Logging.out
        "WARNING: `clang -### <args>` returned an empty set of commands to run and no error. Will run the original command directly:@\n  %s@\n"
        (String.concat " " @@ Array.to_list args)
    };
    Process.create_process_and_wait args
  }
};
