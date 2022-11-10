(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

(** Entries in the results directory (infer-out/). Unless you want to specify a custom results
    directory you probably want to use {!ResultsDir.Entry} instead of this module. *)

type id =
  | AllocationTraces  (** directory for storing allocation traces *)
  | AnalysisDB  (** the analysis database *)
  | AnalysisDBShm  (** SQLite-generated index file for the results database's write-ahead log *)
  | AnalysisDBWal  (** the results database's write-ahead log generated by SQLite *)
  | CaptureDB  (** the capture database *)
  | CaptureDBShm  (** SQLite-generated index file for the capture database's write-ahead log *)
  | CaptureDBWal  (** the capture database's write-ahead log generated by SQLite *)
  | CaptureDependencies  (** list of infer-out/ directories that contain capture artefacts *)
  | ChangedFunctions  (** results of the clang test determinator *)
  | ChangedFunctionsTempResults  (** a directory for temporary [ChangedFunctions] files *)
  | DatalogFacts  (** directory for datalog facts *)
  | Debug  (** directory containing debug data *)
  | Differential  (** contains the results of [infer reportdiff] *)
  | DuplicateFunctions  (** list of duplicated functions *)
  | JavaGlobalTypeEnvironment  (** internal {!Tenv.t} object corresponding to the whole project *)
  | LintDotty  (** directory of linters' dotty debug output for CTL evaluation *)
  | Logs  (** log file *)
  | PerfEvents  (** file containing events for performance profiling *)
  | ProcnamesLocks
      (** directory of per-{!Procname.t} file locks, used by the analysis scheduler in certain modes *)
  | ReportConfigImpactJson  (** reports of the config impact analysis *)
  | ReportCostsJson  (** reports of the costs analysis *)
  | ReportHtml  (** directory of the HTML report *)
  | ReportJson  (** the main product of the analysis: [report.json] *)
  | ReportSarif  (** a sarif version of [report.json]: [report.sarif] *)
  | ReportText  (** a human-readable textual version of [report.json] *)
  | ReportXML  (** a PMD-style XML version of [report.json] *)
  | RetainCycles  (** directory of retain cycles dotty files *)
  | RunState  (** internal data about the last infer run *)
  | Temporary  (** directory containing temp files *)
  | TestDeterminatorReport  (** the report produced by the test determinator capture mode *)
  | TestDeterminatorTempResults  (** a directory for temporary [TestDeterminatorReport] files *)

val get_path : results_dir:string -> id -> string
(** the absolute path for the given entry *)

val to_delete_before_incremental_capture_and_analysis : results_dir:string -> string list
(** utility for {!ResultsDir.scrub_for_incremental}, you probably want to use that instead *)

val to_delete_before_caching_capture : results_dir:string -> string list
(** utility for {!ResultsDir.scrub_for_caching}, you probably want to use that instead *)

val buck_infer_deps_file_name : string
(** sad that we have to have this here but some code path is looking for all files with that name in
    buck-out/ *)
