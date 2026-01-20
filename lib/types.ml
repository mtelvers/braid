(** Core types for braid *)

type status =
  | Success
  | Failure
  | Dependency_failed
  | No_solution
  | Solution  (* solvable but not yet built *)
  | Error

let status_of_string = function
  | "success" -> Success
  | "failure" -> Failure
  | "dependency_failed" -> Dependency_failed
  | "no_solution" -> No_solution
  | "solution" -> Solution
  | _ -> Error

let string_of_status = function
  | Success -> "success"
  | Failure -> "failure"
  | Dependency_failed -> "dependency_failed"
  | No_solution -> "no_solution"
  | Solution -> "solution"
  | Error -> "error"

let status_symbol = function
  | Success -> "S"
  | Failure -> "F"
  | Dependency_failed -> "D"
  | No_solution -> "-"
  | Solution -> "B"
  | Error -> " "

(** Result of a single package build/check *)
type package_result = {
  name : string;
  status : status;
  sha : string option;
  layer : string option;
  log : string option;
  solution : string option;  (* dependency graph in dot format *)
}

(** Results for a single commit *)
type commit_result = {
  commit : string;        (* full sha *)
  short_commit : string;  (* 7-char prefix *)
  message : string;
  packages : package_result list;
}

(** Package history across commits *)
type package_history = {
  package : string;
  first_seen : string;    (* commit where first appeared *)
  latest_status : status;
  history : (string * status) list;  (* commit, status pairs, newest first *)
}

(** Summary manifest for the entire run *)
type manifest = {
  repo_path : string;
  opam_repo_path : string;
  os : string;
  os_version : string;
  generated_at : string;
  commits : string list;  (* newest first *)
  packages : string list; (* sorted alphabetically *)
  results : commit_result list;
  mode : string;  (* "history" for run command, "merge-test" for merge-test command *)
  overlay_repos : string list;  (* for merge-test: list of stacked repos in priority order *)
}
