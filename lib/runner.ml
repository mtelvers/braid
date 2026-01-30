(** Run day10 commands and collect results *)

open Types

let ( let* ) = Result.bind

(** Run a command and return stdout *)
let run_cmd args =
  let cmd = Bos.Cmd.of_list args in
  Logs.info (fun m -> m "Executing: %a" Bos.Cmd.pp cmd);
  Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.out_string

(** Run a command, ignoring output *)
let run_cmd_quiet args =
  let cmd = Bos.Cmd.of_list args in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.out_null with
  | Ok ((), _status) -> Ok ()
  | Error e -> Error e

(** Get list of packages from day10 list *)
let list_packages ~repo_path ~os ~os_family ~os_distribution ~os_version =
  let args = [
    "day10"; "list";
    "--opam-repository"; repo_path;
    "--os"; os;
    "--os-family"; os_family;
    "--os-distribution"; os_distribution;
    "--os-version"; os_version;
  ] in
  let* (output, _) = run_cmd args in
  let packages = String.split_on_char '\n' output
    |> List.filter (fun s -> String.length s > 0)
  in
  Ok packages

(** Get git commits *)
let get_commits ~repo_path ~num_commits =
  let* () = Bos.OS.Dir.set_current (Fpath.v repo_path) in
  let args = ["git"; "log"; "--oneline"; "-n"; string_of_int num_commits; "--format=%H"] in
  let* (output, _) = run_cmd args in
  let commits = String.split_on_char '\n' output
    |> List.filter (fun s -> String.length s > 0)
  in
  Ok commits

(** Get commit message *)
let get_commit_message commit =
  let args = ["git"; "log"; "-1"; "--format=%s"; commit] in
  match run_cmd args with
  | Ok (msg, _) -> String.trim msg
  | Error _ -> ""

(** Checkout a commit *)
let checkout commit =
  let args = ["git"; "checkout"; "-q"; commit] in
  run_cmd_quiet args

(** Parse results from a results directory *)
let parse_results results_dir =
  let* entries = Bos.OS.Dir.contents (Fpath.v results_dir) in
  let results = List.filter_map (fun path ->
    if Fpath.has_ext "json" path then
      match Bos.OS.File.read path with
      | Ok content ->
        (try
          let json = Yojson.Basic.from_string content in
          Some (Json.parse_day10_result json)
        with _ -> None)
      | Error _ -> None
    else None
  ) entries in
  Ok results

(** Run day10 health-check with two-stage approach (solve then build) *)
let health_check ~repo_path ~opam_repo_path ~cache_dir ~os ~os_family ~os_distribution ~os_version ~solve_jobs ~build_jobs ~output_dir ~packages ~bare =
  (* Create packages JSON file *)
  let packages_file = Filename.concat output_dir "packages.json" in
  let packages_json = Printf.sprintf {|{"packages":[%s]}|}
    (String.concat "," (List.map (Printf.sprintf {|"%s"|}) packages))
  in
  let* () = Bos.OS.File.write (Fpath.v packages_file) packages_json in

  let results_dir = Filename.concat output_dir "results" in
  let* _ = Bos.OS.Dir.create (Fpath.v results_dir) in

  (* Build repo args: include opam_repo_path unless bare mode *)
  let repo_args = if bare then
    ["--opam-repository"; repo_path]
  else
    ["--opam-repository"; repo_path; "--opam-repository"; opam_repo_path]
  in

  (* Stage 1: dry-run with high parallelism to solve dependencies *)
  let args_stage1 = [
    "day10"; "health-check";
  ] @ repo_args @ [
    "--cache-dir"; cache_dir;
    "--os"; os;
    "--os-family"; os_family;
    "--os-distribution"; os_distribution;
    "--os-version"; os_version;
    "--dry-run";
    "--fork"; string_of_int solve_jobs;
    "--json"; results_dir;
    "@" ^ packages_file;
  ] in
  let* _ = run_cmd args_stage1 in

  (* Parse stage 1 results *)
  let* results_stage1 = parse_results results_dir in

  (* Stage 2: find packages with status "solution" and actually build them *)
  let solution_packages = results_stage1
    |> List.filter (fun r -> r.status = Solution)
    |> List.map (fun r -> r.name)
  in

  if solution_packages = [] then
    (* No packages need building *)
    Ok results_stage1
  else begin
    Logs.info (fun m -> m "Stage 2: building %d packages" (List.length solution_packages));

    (* Create packages file for stage 2 *)
    let packages_file2 = Filename.concat output_dir "packages_stage2.json" in
    let packages_json2 = Printf.sprintf {|{"packages":[%s]}|}
      (String.concat "," (List.map (Printf.sprintf {|"%s"|}) solution_packages))
    in
    let* () = Bos.OS.File.write (Fpath.v packages_file2) packages_json2 in

    (* Stage 2: actual builds with configurable parallelism *)
    let args_stage2 = [
      "day10"; "health-check";
    ] @ repo_args @ [
      "--cache-dir"; cache_dir;
      "--os"; os;
      "--os-family"; os_family;
      "--os-distribution"; os_distribution;
      "--os-version"; os_version;
      "--fork"; string_of_int build_jobs;
      "--json"; results_dir;
      "@" ^ packages_file2;
    ] in
    let* _ = run_cmd args_stage2 in

    (* Parse final results (stage 2 overwrites stage 1 results for built packages) *)
    parse_results results_dir
  end

(** Process a single commit *)
let process_commit ~repo_path ~opam_repo_path ~cache_dir ~os ~os_family ~os_distribution ~os_version ~solve_jobs ~build_jobs ~bare ~temp_dir commit =
  let short_commit = String.sub commit 0 7 in
  let message = get_commit_message commit in

  Logs.info (fun m -> m "Processing commit %s: %s" short_commit message);

  let* () = checkout commit in

  let* packages = list_packages ~repo_path ~os ~os_family ~os_distribution ~os_version in

  if packages = [] then
    Ok { commit; short_commit; message; packages = [] }
  else begin
    let output_dir = Filename.concat temp_dir short_commit in
    let* _ = Bos.OS.Dir.create (Fpath.v output_dir) in

    let* results = health_check
      ~repo_path ~opam_repo_path ~cache_dir
      ~os ~os_family ~os_distribution ~os_version
      ~solve_jobs ~build_jobs ~output_dir ~packages ~bare
    in

    (* Sort results by package name *)
    let sorted_results = List.sort (fun a b -> String.compare a.name b.name) results in

    Ok { commit; short_commit; message; packages = sorted_results }
  end

(** Run the full analysis *)
let run ~repo_path ~opam_repo_path ~cache_dir ~output_dir
    ~os ~os_family ~os_distribution ~os_version
    ~solve_jobs ~build_jobs ~num_commits ~bare =

  let* () = Bos.OS.Dir.set_current (Fpath.v repo_path) in

  (* Reset to main branch *)
  let* () = checkout "main" in

  (* Get commits to process *)
  let* commits = get_commits ~repo_path ~num_commits in

  Logs.info (fun m -> m "Processing %d commits" (List.length commits));

  (* Create temp directory for intermediate results *)
  let* temp_dir = Bos.OS.Dir.tmp "braid-%s" in
  let temp_dir = Fpath.to_string temp_dir in

  (* Process each commit *)
  let results = List.filter_map (fun commit ->
    match process_commit ~repo_path ~opam_repo_path ~cache_dir
            ~os ~os_family ~os_distribution ~os_version
            ~solve_jobs ~build_jobs ~bare ~temp_dir commit with
    | Ok result -> Some result
    | Error (`Msg e) ->
      Logs.err (fun m -> m "Error processing %s: %s" commit e);
      None
  ) commits in

  (* Return to main branch *)
  let _ = checkout "main" in

  (* Collect all unique packages *)
  let all_packages = results
    |> List.concat_map (fun (r : commit_result) -> List.map (fun p -> p.name) r.packages)
    |> List.sort_uniq String.compare
  in

  (* Build manifest *)
  let generated_at =
    let t = Unix.gettimeofday () in
    let tm = Unix.gmtime t in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in

  let manifest = {
    repo_path;
    opam_repo_path;
    os = Printf.sprintf "%s-%s" os_distribution os_version;
    os_version;
    generated_at;
    commits = List.map (fun c -> String.sub c 0 7) commits;
    packages = all_packages;
    results;
    mode = "history";
    overlay_repos = [];
  } in

  (* Write manifest *)
  let* _ = Bos.OS.Dir.create (Fpath.v output_dir) in
  let manifest_path = Filename.concat output_dir "manifest.json" in
  let* () = Json.write_manifest manifest_path manifest in

  Logs.info (fun m -> m "Manifest written to %s" manifest_path);

  Ok manifest

(** List packages from multiple overlay repos (union of all) *)
let list_packages_multi ~repo_paths ~os ~os_family ~os_distribution ~os_version =
  (* Build args with multiple --opam-repository flags *)
  let repo_args = List.concat_map (fun path ->
    ["--opam-repository"; path]
  ) repo_paths in
  let args = ["day10"; "list"] @ repo_args @ [
    "--os"; os;
    "--os-family"; os_family;
    "--os-distribution"; os_distribution;
    "--os-version"; os_version;
  ] in
  let* (output, _) = run_cmd args in
  let packages = String.split_on_char '\n' output
    |> List.filter (fun s -> String.length s > 0)
  in
  Ok packages

(** Run day10 health-check with multiple overlay repos (two-stage: solve then build) *)
let health_check_multi ~overlay_repos ~opam_repo_path ~cache_dir ~os ~os_family ~os_distribution ~os_version ~solve_jobs ~build_jobs ~output_dir ~packages ~bare =
  (* Create packages JSON file *)
  let packages_file = Filename.concat output_dir "packages.json" in
  let packages_json = Printf.sprintf {|{"packages":[%s]}|}
    (String.concat "," (List.map (Printf.sprintf {|"%s"|}) packages))
  in
  let* () = Bos.OS.File.write (Fpath.v packages_file) packages_json in

  let results_dir = Filename.concat output_dir "results" in
  let* _ = Bos.OS.Dir.create (Fpath.v results_dir) in

  (* Build repo args: overlay repos, optionally followed by opam-repository *)
  let repo_args = List.concat_map (fun path ->
    ["--opam-repository"; path]
  ) overlay_repos in
  let repo_args = if bare then repo_args else repo_args @ ["--opam-repository"; opam_repo_path] in

  (* Stage 1: dry-run with high parallelism to solve dependencies *)
  let args_stage1 = [
    "day10"; "health-check";
  ] @ repo_args @ [
    "--cache-dir"; cache_dir;
    "--os"; os;
    "--os-family"; os_family;
    "--os-distribution"; os_distribution;
    "--os-version"; os_version;
    "--dry-run";
    "--fork"; string_of_int solve_jobs;
    "--json"; results_dir;
    "@" ^ packages_file;
  ] in
  let* _ = run_cmd args_stage1 in

  (* Parse stage 1 results *)
  let* results_stage1 = parse_results results_dir in

  (* Stage 2: find packages with status "solution" and actually build them *)
  let solution_packages = results_stage1
    |> List.filter (fun r -> r.status = Solution)
    |> List.map (fun r -> r.name)
  in

  if solution_packages = [] then
    (* No packages need building *)
    Ok results_stage1
  else begin
    Logs.info (fun m -> m "Stage 2: building %d packages" (List.length solution_packages));

    (* Create packages file for stage 2 *)
    let packages_file2 = Filename.concat output_dir "packages_stage2.json" in
    let packages_json2 = Printf.sprintf {|{"packages":[%s]}|}
      (String.concat "," (List.map (Printf.sprintf {|"%s"|}) solution_packages))
    in
    let* () = Bos.OS.File.write (Fpath.v packages_file2) packages_json2 in

    (* Stage 2: actual builds with configurable parallelism *)
    let args_stage2 = [
      "day10"; "health-check";
    ] @ repo_args @ [
      "--cache-dir"; cache_dir;
      "--os"; os;
      "--os-family"; os_family;
      "--os-distribution"; os_distribution;
      "--os-version"; os_version;
      "--fork"; string_of_int build_jobs;
      "--json"; results_dir;
      "@" ^ packages_file2;
    ] in
    let* _ = run_cmd args_stage2 in

    (* Parse final results (stage 2 overwrites stage 1 results for built packages) *)
    parse_results results_dir
  end

(** Run merge test on stacked repositories *)
let merge_test ~overlay_repos ~opam_repo_path ~cache_dir ~output_dir
    ~os ~os_family ~os_distribution ~os_version ~solve_jobs ~build_jobs ~bare =

  (* List packages from overlay repos only (not opam-repository) *)
  let* packages = list_packages_multi ~repo_paths:overlay_repos ~os ~os_family ~os_distribution ~os_version in

  Logs.info (fun m -> m "Found %d packages across %d overlay repos" (List.length packages) (List.length overlay_repos));

  if packages = [] then begin
    Logs.warn (fun m -> m "No packages found in overlay repos");
    let generated_at =
      let t = Unix.gettimeofday () in
      let tm = Unix.gmtime t in
      Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
        (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
        tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
    in
    let manifest = {
      repo_path = List.hd overlay_repos;
      opam_repo_path;
      os = Printf.sprintf "%s-%s" os_distribution os_version;
      os_version;
      generated_at;
      commits = ["merge-test"];
      packages = [];
      results = [{ commit = "merge-test"; short_commit = "merge-q"; message = "Merge queue snapshot"; packages = [] }];
      mode = "merge-test";
      overlay_repos;
    } in
    let* _ = Bos.OS.Dir.create (Fpath.v output_dir) in
    let manifest_path = Filename.concat output_dir "manifest.json" in
    let* () = Json.write_manifest manifest_path manifest in
    Ok manifest
  end else begin
    (* Create output directory *)
    let* _ = Bos.OS.Dir.create (Fpath.v output_dir) in

    (* Run health check with all overlay repos stacked *)
    let* results = health_check_multi
      ~overlay_repos ~opam_repo_path ~cache_dir
      ~os ~os_family ~os_distribution ~os_version
      ~solve_jobs ~build_jobs ~output_dir ~packages ~bare
    in

    (* Sort results by package name *)
    let sorted_results = List.sort (fun a b -> String.compare a.name b.name) results in

    (* Build manifest *)
    let generated_at =
      let t = Unix.gettimeofday () in
      let tm = Unix.gmtime t in
      Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
        (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
        tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
    in

    let all_packages = sorted_results
      |> List.map (fun p -> p.name)
      |> List.sort_uniq String.compare
    in

    let commit_result = {
      commit = "merge-test";
      short_commit = "merge-q";
      message = "Merge queue snapshot";
      packages = sorted_results;
    } in

    let manifest = {
      repo_path = List.hd overlay_repos;
      opam_repo_path;
      os = Printf.sprintf "%s-%s" os_distribution os_version;
      os_version;
      generated_at;
      commits = ["merge-test"];
      packages = all_packages;
      results = [commit_result];
      mode = "merge-test";
      overlay_repos;
    } in

    (* Write manifest *)
    let manifest_path = Filename.concat output_dir "manifest.json" in
    let* () = Json.write_manifest manifest_path manifest in

    Logs.info (fun m -> m "Manifest written to %s" manifest_path);

    Ok manifest
  end
