(** RPC service implementation for BraidService *)

module Api = Rpc_schema.MakeRPC(Capnp_rpc)

(** Parse a URL with optional #fragment for commit/branch reference *)
let parse_url_fragment url =
  match String.index_opt url '#' with
  | None -> (url, None)
  | Some idx ->
    let base_url = String.sub url 0 idx in
    let fragment = String.sub url (idx + 1) (String.length url - idx - 1) in
    (base_url, Some fragment)

(** Clone a git repository to a temporary directory *)
let clone_repo ~temp_dir url =
  let base_url, commit_ref = parse_url_fragment url in
  let repo_name =
    (* Extract repo name from URL, e.g., "https://github.com/user/repo" -> "repo" *)
    let base = Filename.basename base_url in
    if String.length base > 4 && String.sub base (String.length base - 4) 4 = ".git" then
      String.sub base 0 (String.length base - 4)
    else
      base
  in
  let repo_path = Filename.concat temp_dir repo_name in
  (* GIT_TERMINAL_PROMPT=0 prevents git from prompting for credentials *)
  (* Use blobless clone for minimal data transfer - downloads commits/trees but not blobs until checkout *)
  let clone_cmd = Printf.sprintf "GIT_TERMINAL_PROMPT=0 git clone --filter=blob:none --no-checkout %s %s" base_url repo_path in
  match Unix.system clone_cmd with
  | Unix.WEXITED 0 ->
    (* Checkout the specific commit or default branch *)
    let checkout_ref = match commit_ref with Some r -> r | None -> "HEAD" in
    let checkout_cmd = Printf.sprintf "git -C %s checkout %s" repo_path checkout_ref in
    (match Unix.system checkout_cmd with
     | Unix.WEXITED 0 -> Ok repo_path
     | _ -> Error (`Msg (Printf.sprintf "Failed to checkout %s in %s" checkout_ref url)))
  | _ -> Error (`Msg (Printf.sprintf "Failed to clone %s" url))

(** Create a unique temp directory using mktemp *)
let make_temp_dir () =
  let ic = Unix.open_process_in "mktemp -d -t braid.XXXXXX" in
  let temp_dir = input_line ic in
  let _ = Unix.close_process_in ic in
  temp_dir

(** Get current working directory *)
let get_cwd () =
  Unix.getcwd ()

(** Restore working directory *)
let restore_cwd cwd =
  try Unix.chdir cwd with _ -> ()

(** Create the local BraidService implementation *)
let local ~opam_repo_path ~cache_dir =
  let module Service = Api.Service.BraidService in
  Service.local @@ object
    inherit Service.service

    method run_impl params release_param_caps =
      let open Service.Run in
      release_param_caps ();
      let repo_url = Params.repo_url_get params in
      let num_commits = Params.num_commits_get params |> Stdint.Uint32.to_int in
      let fork_jobs = Params.fork_jobs_get params |> Stdint.Uint32.to_int in
      let os = Params.os_get params in
      let os_family = Params.os_family_get params in
      let os_distribution = Params.os_distribution_get params in
      let os_version = Params.os_version_get params in

      (* Save current working directory - Runner.run changes it *)
      let saved_cwd = get_cwd () in

      (* Create unique temp directory for each request *)
      let temp_dir = make_temp_dir () in

      let result =
        match clone_repo ~temp_dir repo_url with
        | Error (`Msg msg) -> Error msg
        | Ok repo_path ->
          let output_dir = Filename.concat temp_dir "results" in
          (try Unix.mkdir output_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          match Runner.run ~repo_path ~opam_repo_path ~cache_dir ~output_dir
                  ~os ~os_family ~os_distribution ~os_version
                  ~fork_jobs ~num_commits with
          | Ok manifest ->
            let json = Json.manifest_to_json manifest in
            Ok (Yojson.Basic.to_string json)
          | Error (`Msg msg) -> Error msg
      in

      (* Restore working directory before cleanup *)
      restore_cwd saved_cwd;

      (* Clean up temp directory *)
      let _ = Unix.system (Printf.sprintf "rm -rf %s" temp_dir) in

      let response, results = Capnp_rpc.Service.Response.create Results.init_pointer in
      (match result with
       | Ok manifest_json -> Results.manifest_json_set results manifest_json
       | Error msg -> Results.manifest_json_set results (Printf.sprintf "{\"error\": \"%s\"}" msg));
      Capnp_rpc.Service.return response

    method merge_test_impl params release_param_caps =
      let open Service.MergeTest in
      release_param_caps ();
      let repo_urls = Params.repo_urls_get_list params in
      let fork_jobs = Params.fork_jobs_get params |> Stdint.Uint32.to_int in
      let os = Params.os_get params in
      let os_family = Params.os_family_get params in
      let os_distribution = Params.os_distribution_get params in
      let os_version = Params.os_version_get params in

      (* Save current working directory *)
      let saved_cwd = get_cwd () in

      (* Create unique temp directory for each request *)
      let temp_dir = make_temp_dir () in

      let result =
        (* Clone all repos *)
        let rec clone_all urls acc =
          match urls with
          | [] -> Ok (List.rev acc)
          | url :: rest ->
            match clone_repo ~temp_dir url with
            | Error e -> Error e
            | Ok path -> clone_all rest (path :: acc)
        in
        match clone_all repo_urls [] with
        | Error (`Msg msg) -> Error msg
        | Ok overlay_repos ->
          let output_dir = Filename.concat temp_dir "results" in
          (try Unix.mkdir output_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          match Runner.merge_test ~overlay_repos ~opam_repo_path ~cache_dir ~output_dir
                  ~os ~os_family ~os_distribution ~os_version ~fork_jobs with
          | Ok manifest ->
            let json = Json.manifest_to_json manifest in
            Ok (Yojson.Basic.to_string json)
          | Error (`Msg msg) -> Error msg
      in

      (* Restore working directory before cleanup *)
      restore_cwd saved_cwd;

      (* Clean up temp directory *)
      let _ = Unix.system (Printf.sprintf "rm -rf %s" temp_dir) in

      let response, results = Capnp_rpc.Service.Response.create Results.init_pointer in
      (match result with
       | Ok manifest_json -> Results.manifest_json_set results manifest_json
       | Error msg -> Results.manifest_json_set results (Printf.sprintf "{\"error\": \"%s\"}" msg));
      Capnp_rpc.Service.return response
  end
