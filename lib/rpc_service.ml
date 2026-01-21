(** RPC service implementation for BraidService *)

module Api = Rpc_schema.MakeRPC(Capnp_rpc)

(** Clone a git repository to a temporary directory *)
let clone_repo ~temp_dir url =
  let repo_name =
    (* Extract repo name from URL, e.g., "https://github.com/user/repo" -> "repo" *)
    let base = Filename.basename url in
    if String.length base > 4 && String.sub base (String.length base - 4) 4 = ".git" then
      String.sub base 0 (String.length base - 4)
    else
      base
  in
  let repo_path = Filename.concat temp_dir repo_name in
  (* GIT_TERMINAL_PROMPT=0 prevents git from prompting for credentials *)
  let cmd_str = Printf.sprintf "GIT_TERMINAL_PROMPT=0 git clone --depth 100 %s %s" url repo_path in
  match Unix.system cmd_str with
  | Unix.WEXITED 0 -> Ok repo_path
  | _ -> Error (`Msg (Printf.sprintf "Failed to clone %s" url))

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

      (* Create temp directory for cloned repo *)
      let temp_dir = Filename.concat (Filename.get_temp_dir_name ())
                       (Printf.sprintf "braid-%d" (Unix.getpid ())) in
      (try Unix.mkdir temp_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());

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
      let dry_run = Params.dry_run_get params in
      let fork_jobs = Params.fork_jobs_get params |> Stdint.Uint32.to_int in
      let os = Params.os_get params in
      let os_family = Params.os_family_get params in
      let os_distribution = Params.os_distribution_get params in
      let os_version = Params.os_version_get params in

      (* Create temp directory for cloned repos *)
      let temp_dir = Filename.concat (Filename.get_temp_dir_name ())
                       (Printf.sprintf "braid-%d" (Unix.getpid ())) in
      (try Unix.mkdir temp_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());

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
                  ~os ~os_family ~os_distribution ~os_version ~fork_jobs ~dry_run with
          | Ok manifest ->
            let json = Json.manifest_to_json manifest in
            Ok (Yojson.Basic.to_string json)
          | Error (`Msg msg) -> Error msg
      in

      (* Clean up temp directory *)
      let _ = Unix.system (Printf.sprintf "rm -rf %s" temp_dir) in

      let response, results = Capnp_rpc.Service.Response.create Results.init_pointer in
      (match result with
       | Ok manifest_json -> Results.manifest_json_set results manifest_json
       | Error msg -> Results.manifest_json_set results (Printf.sprintf "{\"error\": \"%s\"}" msg));
      Capnp_rpc.Service.return response
  end
