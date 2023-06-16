(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

(** Entries in the results directory (infer-out/). *)

type id =
  | AllocationTraces  (** directory for storing allocation traces *)
  | AnalysisDependencyGraphDot
      (** the inter-procedures dependencies revealed during an analysis phase used for the replay,
          in dotty format for debug *)
  | AnalysisDependencyInvalidationGraphDot
      (** the inter-procedures dependencies revealed during an analysis phase used for invalidating
          procedure summaries that need re-analyzing, in dotty format for debug *)
  | AnalysisDB  (** the analysis database *)
  | AnalysisDBShm  (** SQLite-generated index file for the results database's write-ahead log *)
  | AnalysisDBWal  (** the results database's write-ahead log generated by SQLite *)
  | CallGraphCyclesDot  (** cycles in the call graph used for analysis scheduling in dotty format *)
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
  | JavaGlobalTypeEnvironment
      (** internal {!IR.Tenv.t} object corresponding to the whole project *)
  | Logs  (** log file *)
  | MissingSourceFiles  (** Source files missing during analysis *)
  | MissingProcedures  (** Procedures missing during analysis *)
  | PerfEvents  (** file containing events for performance profiling *)
  | ProcnamesLocks
      (** directory of per-{!IR.Procname.t} file locks, used by the analysis scheduler in certain
          modes *)
  | ReportConfigImpactJson  (** reports of the config impact analysis *)
  | ReportCostsJson  (** reports of the costs analysis *)
  | ReportHtml  (** directory of the HTML report *)
  | ReportJson  (** the main product of the analysis: [report.json] *)
  | ReportSarif  (** a sarif version of [report.json]: [report.sarif] *)
  | ReportText  (** a human-readable textual version of [report.json] *)
  | ReportXML  (** a PMD-style XML version of [report.json] *)
  | RetainCycles  (** directory of retain cycles dotty files *)
  | RunState  (** internal data about the last infer run *)
  | SyntacticDependencyGraphDot
      (** the inter-procedures dependencies obtained by syntactically inspecting the source of each
          procedure and recording the (static) calls it makes during an analysis phase; used by the
          [callgraph] analysis scheduler and presented here in dotty format for debug purposes *)
  | Temporary  (** directory containing temp files *)
  | TestDeterminatorReport  (** the report produced by the test determinator capture mode *)
  | TestDeterminatorTempResults  (** a directory for temporary [TestDeterminatorReport] files *)

val get_path : results_dir:string -> id -> string
(** the absolute path for the given entry *)

val to_delete_before_incremental_capture_and_analysis : results_dir:string -> string list
(** utility for {!ResultsDir.scrub_for_incremental}, you probably want to use that instead *)

val to_delete_before_caching_capture : results_dir:string -> string list
(** utility for {!ResultsDir.scrub_for_caching}, you probably want to use that instead *)

val to_keep_before_new_capture : results_dir:string -> string list
(** utility for {!ResultsDir.remove_results_dir}, you probably want to use that instead *)

val buck_infer_deps_file_name : string
(** sad that we have to have this here but some code path is looking for all files with that name in
    buck-out/ *)
