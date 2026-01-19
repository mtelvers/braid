(** Braid CLI - Build status tracker for opam overlay repositories *)

open Cmdliner
open Braid

let setup_log style_renderer level =
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level level;
  Logs.set_reporter (Logs_fmt.reporter ());
  ()

let setup_log_term =
  Term.(const setup_log $ Fmt_cli.style_renderer () $ Logs_cli.level ())

(* Common arguments *)
let manifest_file =
  let doc = "Path to manifest.json file" in
  Arg.(value & opt string "manifest.json" & info ["m"; "manifest"] ~docv:"FILE" ~doc)

(* Run subcommand *)
let run_cmd =
  let repo_path =
    let doc = "Path to the overlay opam repository" in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"REPO" ~doc)
  in
  let opam_repo =
    let doc = "Path to the main opam repository" in
    Arg.(value & opt string "/home/mtelvers/opam-repository" & info ["opam-repo"] ~docv:"PATH" ~doc)
  in
  let cache_dir =
    let doc = "Cache directory for day10" in
    Arg.(value & opt string "/var/cache/day10" & info ["cache-dir"] ~docv:"PATH" ~doc)
  in
  let output_dir =
    let doc = "Output directory for results" in
    Arg.(value & opt string "results" & info ["o"; "output"] ~docv:"PATH" ~doc)
  in
  let num_commits =
    let doc = "Number of commits to process" in
    Arg.(value & opt int 10 & info ["n"; "num-commits"] ~docv:"N" ~doc)
  in
  let fork_jobs =
    let doc = "Number of parallel jobs for solving" in
    Arg.(value & opt int 40 & info ["j"; "jobs"] ~docv:"N" ~doc)
  in
  let os =
    let doc = "Operating system" in
    Arg.(value & opt string "linux" & info ["os"] ~docv:"OS" ~doc)
  in
  let os_family =
    let doc = "OS family" in
    Arg.(value & opt string "debian" & info ["os-family"] ~docv:"FAMILY" ~doc)
  in
  let os_distribution =
    let doc = "OS distribution" in
    Arg.(value & opt string "debian" & info ["os-distribution"] ~docv:"DIST" ~doc)
  in
  let os_version =
    let doc = "OS version" in
    Arg.(value & opt string "13" & info ["os-version"] ~docv:"VERSION" ~doc)
  in

  let run _setup repo_path opam_repo cache_dir output_dir num_commits fork_jobs
      os os_family os_distribution os_version =
    match Runner.run ~repo_path ~opam_repo_path:opam_repo ~cache_dir ~output_dir
            ~os ~os_family ~os_distribution ~os_version
            ~fork_jobs ~num_commits with
    | Ok manifest ->
      let (s, f, d, n, b, e) = Query.summary manifest in
      Fmt.pr "Processed %d commits, %d packages@."
        (List.length manifest.commits) (List.length manifest.packages);
      Fmt.pr "Latest: %d success, %d failure, %d dep_failed, %d no_solution, %d solution, %d error@."
        s f d n b e;
      `Ok ()
    | Error e ->
      Fmt.epr "Error: %a@." Rresult.R.pp_msg e;
      `Error (false, "run failed")
  in

  let doc = "Run day10 health checks across commits" in
  let info = Cmd.info "run" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ repo_path $ opam_repo $ cache_dir
                        $ output_dir $ num_commits $ fork_jobs
                        $ os $ os_family $ os_distribution $ os_version))

(* Query: failures *)
let failures_cmd =
  let run _setup manifest_file =
    match Json.read_manifest manifest_file with
    | Error e ->
      Fmt.epr "Error reading manifest: %a@." Rresult.R.pp_msg e;
      `Error (false, "read failed")
    | Ok manifest ->
      let failures = Query.failures manifest in
      if failures = [] then
        Fmt.pr "No failures@."
      else begin
        Fmt.pr "Failures in commit %s:@." (fst (List.hd failures));
        List.iter (fun (_, p) ->
          Fmt.pr "  %s@." p.Types.name
        ) failures
      end;
      `Ok ()
  in
  let doc = "List packages with status 'failure'" in
  let info = Cmd.info "failures" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ manifest_file))

(* Query: log *)
let log_cmd =
  let commit =
    let doc = "Commit hash (short or full)" in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"COMMIT" ~doc)
  in
  let package =
    let doc = "Package name" in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"PACKAGE" ~doc)
  in
  let run _setup manifest_file commit package =
    match Json.read_manifest manifest_file with
    | Error e ->
      Fmt.epr "Error reading manifest: %a@." Rresult.R.pp_msg e;
      `Error (false, "read failed")
    | Ok manifest ->
      match Query.log manifest ~commit ~package with
      | None ->
        Fmt.epr "No log found for %s at %s@." package commit;
        `Error (false, "not found")
      | Some log ->
        Fmt.pr "%s@." log;
        `Ok ()
  in
  let doc = "Show build log for a package at a commit" in
  let info = Cmd.info "log" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ manifest_file $ commit $ package))

(* Query: history *)
let history_cmd =
  let package =
    let doc = "Package name" in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PACKAGE" ~doc)
  in
  let run _setup manifest_file package =
    match Json.read_manifest manifest_file with
    | Error e ->
      Fmt.epr "Error reading manifest: %a@." Rresult.R.pp_msg e;
      `Error (false, "read failed")
    | Ok manifest ->
      match Query.history manifest ~package with
      | None ->
        Fmt.epr "Package %s not found@." package;
        `Error (false, "not found")
      | Some h ->
        Fmt.pr "Package: %s@." h.Types.package;
        Fmt.pr "First seen: %s@." h.first_seen;
        Fmt.pr "Latest status: %s@." (Types.string_of_status h.latest_status);
        Fmt.pr "History:@.";
        List.iter (fun (c, s) ->
          Fmt.pr "  %s: %s@." c (Types.string_of_status s)
        ) h.history;
        `Ok ()
  in
  let doc = "Show history of a package across commits" in
  let info = Cmd.info "history" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ manifest_file $ package))

(* Query: deps *)
let deps_cmd =
  let commit =
    let doc = "Commit hash (short or full)" in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"COMMIT" ~doc)
  in
  let package =
    let doc = "Package name" in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"PACKAGE" ~doc)
  in
  let run _setup manifest_file commit package =
    match Json.read_manifest manifest_file with
    | Error e ->
      Fmt.epr "Error reading manifest: %a@." Rresult.R.pp_msg e;
      `Error (false, "read failed")
    | Ok manifest ->
      match Query.deps manifest ~commit ~package with
      | None ->
        Fmt.epr "No dependency info for %s at %s@." package commit;
        `Error (false, "not found")
      | Some deps ->
        Fmt.pr "%s@." deps;
        `Ok ()
  in
  let doc = "Show dependency graph for a package (in dot format)" in
  let info = Cmd.info "deps" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ manifest_file $ commit $ package))

(* Query: summary *)
let summary_cmd =
  let run _setup manifest_file =
    match Json.read_manifest manifest_file with
    | Error e ->
      Fmt.epr "Error reading manifest: %a@." Rresult.R.pp_msg e;
      `Error (false, "read failed")
    | Ok manifest ->
      Fmt.pr "Repository: %s@." manifest.repo_path;
      Fmt.pr "Generated: %s@." manifest.generated_at;
      Fmt.pr "OS: %s@." manifest.os;
      Fmt.pr "Commits: %d@." (List.length manifest.commits);
      Fmt.pr "Packages: %d@." (List.length manifest.packages);
      let (s, f, d, n, b, e) = Query.summary manifest in
      Fmt.pr "@.Latest commit status:@.";
      Fmt.pr "  Success: %d@." s;
      Fmt.pr "  Failure: %d@." f;
      Fmt.pr "  Dependency failed: %d@." d;
      Fmt.pr "  No solution: %d@." n;
      Fmt.pr "  Solution (buildable): %d@." b;
      Fmt.pr "  Error: %d@." e;
      `Ok ()
  in
  let doc = "Show summary statistics" in
  let info = Cmd.info "summary" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ manifest_file))

(* Query: matrix *)
let matrix_cmd =
  let run _setup manifest_file =
    match Json.read_manifest manifest_file with
    | Error e ->
      Fmt.epr "Error reading manifest: %a@." Rresult.R.pp_msg e;
      `Error (false, "read failed")
    | Ok manifest ->
      Fmt.pr "%s@." (Query.matrix manifest);
      `Ok ()
  in
  let doc = "Output status matrix in markdown format" in
  let info = Cmd.info "matrix" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ manifest_file))

(* Query: result - get full result for commit/package *)
let result_cmd =
  let commit =
    let doc = "Commit hash (short or full)" in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"COMMIT" ~doc)
  in
  let package =
    let doc = "Package name" in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"PACKAGE" ~doc)
  in
  let run _setup manifest_file commit package =
    match Json.read_manifest manifest_file with
    | Error e ->
      Fmt.epr "Error reading manifest: %a@." Rresult.R.pp_msg e;
      `Error (false, "read failed")
    | Ok manifest ->
      match Query.result manifest ~commit ~package with
      | None ->
        Fmt.epr "No result for %s at %s@." package commit;
        `Error (false, "not found")
      | Some r ->
        let json = Json.package_result_to_json r in
        Fmt.pr "%s@." (Yojson.Basic.pretty_to_string json);
        `Ok ()
  in
  let doc = "Get full result JSON for a package at a commit" in
  let info = Cmd.info "result" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ manifest_file $ commit $ package))

(* Query: first-failure - find when a package first failed *)
let first_failure_cmd =
  let package =
    let doc = "Package name" in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PACKAGE" ~doc)
  in
  let run _setup manifest_file package =
    match Json.read_manifest manifest_file with
    | Error e ->
      Fmt.epr "Error reading manifest: %a@." Rresult.R.pp_msg e;
      `Error (false, "read failed")
    | Ok manifest ->
      match Query.first_failure manifest ~package with
      | None ->
        Fmt.pr "Package %s has not failed (or was never successful)@." package;
        `Ok ()
      | Some (commit, message) ->
        Fmt.pr "First failure: %s (%s)@." commit message;
        `Ok ()
  in
  let doc = "Find when a package first started failing" in
  let info = Cmd.info "first-failure" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ manifest_file $ package))

(* Main command *)
let main_cmd =
  let doc = "Build status tracker for opam overlay repositories" in
  let info = Cmd.info "braid" ~version:"0.1.0" ~doc in
  let default = Term.(ret (const (`Help (`Pager, None)))) in
  Cmd.group info ~default [
    run_cmd;
    failures_cmd;
    log_cmd;
    history_cmd;
    deps_cmd;
    summary_cmd;
    matrix_cmd;
    result_cmd;
    first_failure_cmd;
  ]

let () = exit (Cmd.eval main_cmd)
