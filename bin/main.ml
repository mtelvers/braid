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
  let repo_url =
    let doc = "URL to the overlay opam repository" in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"REPO_URL" ~doc)
  in
  let cap_file =
    let doc = "Cap'n Proto capability file for remote execution" in
    Arg.(required & opt (some string) None & info ["connect"] ~docv:"CAP_FILE" ~doc)
  in
  let output_dir =
    let doc = "Output directory for results" in
    Arg.(value & opt string "results" & info ["o"; "output"] ~docv:"PATH" ~doc)
  in
  let num_commits =
    let doc = "Number of commits to process" in
    Arg.(value & opt int 10 & info ["n"; "num-commits"] ~docv:"N" ~doc)
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

  let run _setup repo_url cap_file output_dir num_commits
      os os_family os_distribution os_version =
    Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
        let net = Eio.Stdenv.net env in
        let manifest_json = Rpc_client.run_remote ~sw ~net ~cap_file
            ~repo_url ~num_commits
            ~os ~os_family ~os_distribution ~os_version in
        let json = Yojson.Basic.from_string manifest_json in
        (* Check for error response *)
        match Yojson.Basic.Util.(json |> member "error" |> to_string_option) with
        | Some err_msg ->
          Fmt.epr "Remote error: %s@." err_msg;
          `Error (false, "remote run failed")
        | None ->
          let manifest = Json.manifest_of_json json in
          (* Write manifest to output directory *)
          (try Unix.mkdir output_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          let manifest_path = Filename.concat output_dir "manifest.json" in
          let _ = Json.write_manifest manifest_path manifest in
          let (s, f, d, n, b, e) = Query.summary manifest in
          Fmt.pr "Processed %d commits, %d packages@."
            (List.length manifest.commits) (List.length manifest.packages);
          Fmt.pr "Latest: %d success, %d failure, %d dep_failed, %d no_solution, %d solution, %d error@."
            s f d n b e;
          `Ok ()
  in

  let doc = "Run day10 health checks across commits" in
  let info = Cmd.info "run" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ repo_url $ cap_file
                        $ output_dir $ num_commits
                        $ os $ os_family $ os_distribution $ os_version))

(* Merge-test subcommand *)
let merge_test_cmd =
  let repo_urls =
    let doc = "Overlay repository URLs (in priority order, first = highest priority)" in
    Arg.(non_empty & pos_all string [] & info [] ~docv:"REPO_URLS" ~doc)
  in
  let cap_file =
    let doc = "Cap'n Proto capability file for remote execution" in
    Arg.(required & opt (some string) None & info ["connect"] ~docv:"CAP_FILE" ~doc)
  in
  let output_dir =
    let doc = "Output directory for results" in
    Arg.(value & opt string "results" & info ["o"; "output"] ~docv:"PATH" ~doc)
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

  let run _setup repo_urls cap_file output_dir
      os os_family os_distribution os_version =
    Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
        let net = Eio.Stdenv.net env in
        let manifest_json = Rpc_client.merge_test_remote ~sw ~net ~cap_file
            ~repo_urls
            ~os ~os_family ~os_distribution ~os_version in
        let json = Yojson.Basic.from_string manifest_json in
        (* Check for error response *)
        match Yojson.Basic.Util.(json |> member "error" |> to_string_option) with
        | Some err_msg ->
          Fmt.epr "Remote error: %s@." err_msg;
          `Error (false, "remote merge-test failed")
        | None ->
          let manifest = Json.manifest_of_json json in
          (* Write manifest to output directory *)
          (try Unix.mkdir output_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          let manifest_path = Filename.concat output_dir "manifest.json" in
          let _ = Json.write_manifest manifest_path manifest in
          let (s, f, d, n, _b, e) = Query.summary manifest in
          Fmt.pr "Merge test: %d overlay repos, %d packages@."
            (List.length repo_urls) (List.length manifest.packages);
          Fmt.pr "Overlay repos (priority order):@.";
          List.iter (fun r -> Fmt.pr "  %s@." r) repo_urls;
          Fmt.pr "Results: %d success, %d failure, %d dep_failed, %d no_solution, %d error@."
            s f d n e;
          `Ok ()
  in

  let doc = "Test cumulative effect of merging multiple overlay repositories" in
  let info = Cmd.info "merge-test" ~doc in
  Cmd.v info Term.(ret (const run $ setup_log_term $ repo_urls $ cap_file
                        $ output_dir
                        $ os $ os_family $ os_distribution $ os_version))

(* Server subcommand *)
let server_cmd =
  let port_arg =
    let doc = "Port to listen on" in
    Arg.(required & opt (some int) None & info ["port"] ~docv:"PORT" ~doc)
  in
  let public_addr_arg =
    let doc = "Public hostname/IP for capability URI (what clients use to connect)" in
    Arg.(required & opt (some string) None & info ["public-addr"] ~docv:"HOST" ~doc)
  in
  let key_file_arg =
    let doc = "Path to secret key file (created if doesn't exist)" in
    Arg.(value & opt string "braid.key" & info ["key-file"] ~docv:"FILE" ~doc)
  in
  let cap_dir_arg =
    let doc = "Directory to write capability files (one per user)" in
    Arg.(value & opt string "." & info ["cap-dir"] ~docv:"DIR" ~doc)
  in
  let users_arg =
    let doc = "User IDs to generate capability files for (comma-separated or multiple flags)" in
    Arg.(non_empty & opt_all string [] & info ["users"] ~docv:"USER" ~doc)
  in
  let listen_addr_arg =
    let doc = "Address to listen on" in
    Arg.(value & opt string "0.0.0.0" & info ["listen-addr"] ~docv:"ADDR" ~doc)
  in
  let opam_repo =
    let doc = "Path to the main opam repository" in
    Arg.(value & opt string "/home/mtelvers/opam-repository" & info ["opam-repo"] ~docv:"PATH" ~doc)
  in
  let cache_dir =
    let doc = "Cache directory for day10" in
    Arg.(value & opt string "/var/cache/day10" & info ["cache-dir"] ~docv:"PATH" ~doc)
  in
  let git_cache_dir =
    let doc = "Cache directory for git repository mirrors" in
    Arg.(value & opt string "/var/cache/braid/git" & info ["git-cache-dir"] ~docv:"PATH" ~doc)
  in
  let solve_jobs =
    let doc = "Number of parallel jobs for dependency solving (stage 1)" in
    Arg.(value & opt int 40 & info ["solve-jobs"] ~docv:"N" ~doc)
  in
  let build_jobs =
    let doc = "Number of parallel jobs for building (stage 2)" in
    Arg.(value & opt int 1 & info ["build-jobs"] ~docv:"N" ~doc)
  in

  let server _setup port public_addr key_file cap_dir users listen_addr opam_repo cache_dir git_cache_dir solve_jobs build_jobs =
    (* Expand comma-separated user lists into individual users *)
    let users = List.concat_map (String.split_on_char ',') users
      |> List.map String.trim
      |> List.filter (fun s -> String.length s > 0)
    in
    if users = [] then begin
      Fmt.epr "Error: at least one user must be specified with --users@.";
      exit 1
    end;
    Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
        let net = Eio.Stdenv.net env in
        let fs = Eio.Stdenv.cwd env in
        Server.run ~sw ~net ~fs ~listen_addr ~listen_port:port ~public_addr
          ~key_file ~cap_dir ~users ~opam_repo_path:opam_repo ~cache_dir
          ~git_cache_dir ~solve_jobs ~build_jobs
  in

  let doc = "Start RPC server for remote braid execution" in
  let info = Cmd.info "server" ~doc in
  Cmd.v info Term.(const server $ setup_log_term $ port_arg $ public_addr_arg
                   $ key_file_arg $ cap_dir_arg $ users_arg $ listen_addr_arg $ opam_repo $ cache_dir
                   $ git_cache_dir $ solve_jobs $ build_jobs)

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
    merge_test_cmd;
    server_cmd;
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
