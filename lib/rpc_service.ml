(** RPC service implementation for BraidService *)

module Api = Rpc_schema.MakeRPC(Capnp_rpc)

(** Per-repository locking to prevent concurrent git operations on the same mirror *)
module RepoLock = struct
  (* Table mapping URL -> mutex *)
  let locks : (string, Mutex.t) Hashtbl.t = Hashtbl.create 16

  (* Mutex to protect the locks table itself *)
  let table_mutex = Mutex.create ()

  (* Get or create a mutex for a given URL *)
  let get_mutex url =
    Mutex.lock table_mutex;
    let mutex =
      match Hashtbl.find_opt locks url with
      | Some m -> m
      | None ->
        let m = Mutex.create () in
        Hashtbl.add locks url m;
        m
    in
    Mutex.unlock table_mutex;
    mutex

  (* Execute a function while holding the lock for a URL *)
  let with_lock url f =
    let mutex = get_mutex url in
    Mutex.lock mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock mutex) f
end

(** Parse a URL with optional #fragment for commit/branch reference *)
let parse_url_fragment url =
  match String.index_opt url '#' with
  | None -> (url, None)
  | Some idx ->
    let base_url = String.sub url 0 idx in
    let fragment = String.sub url (idx + 1) (String.length url - idx - 1) in
    (base_url, Some fragment)

(** Convert URL to a safe cache directory name *)
let url_to_cache_name url =
  (* Replace unsafe characters with underscores, keep it readable *)
  let s = String.map (fun c ->
    match c with
    | 'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '_' | '.' -> c
    | _ -> '_'
  ) url in
  (* Truncate if too long and add hash suffix for uniqueness *)
  if String.length s > 100 then
    let hash = Hashtbl.hash url |> Printf.sprintf "%08x" in
    String.sub s 0 80 ^ "_" ^ hash
  else
    s

(** Get or update a cached mirror of a repository (internal, not locked) *)
let get_cached_mirror_unlocked ~git_cache_dir base_url =
  let cache_name = url_to_cache_name base_url in
  let mirror_path = Filename.concat git_cache_dir cache_name in
  (* Create cache directory if needed *)
  let _ = Unix.system (Printf.sprintf "mkdir -p %s" git_cache_dir) in
  if Sys.file_exists mirror_path then begin
    (* Update existing mirror *)
    let fetch_cmd = Printf.sprintf "GIT_TERMINAL_PROMPT=0 git -C %s fetch --all --prune 2>&1" mirror_path in
    match Unix.system fetch_cmd with
    | Unix.WEXITED 0 -> Ok mirror_path
    | _ -> Error (`Msg (Printf.sprintf "Failed to fetch updates for %s" base_url))
  end else begin
    (* Create new mirror *)
    let clone_cmd = Printf.sprintf "GIT_TERMINAL_PROMPT=0 git clone --mirror %s %s 2>&1" base_url mirror_path in
    match Unix.system clone_cmd with
    | Unix.WEXITED 0 -> Ok mirror_path
    | _ -> Error (`Msg (Printf.sprintf "Failed to clone mirror of %s" base_url))
  end

(** Get or update a cached mirror of a repository (with per-URL locking) *)
let get_cached_mirror ~git_cache_dir base_url =
  RepoLock.with_lock base_url (fun () ->
    get_cached_mirror_unlocked ~git_cache_dir base_url
  )

(** Create a worktree from cached mirror for a specific commit *)
let create_worktree ~mirror_path ~worktree_path ~commit_ref =
  (* Ensure parent directory exists *)
  let parent = Filename.dirname worktree_path in
  let _ = Unix.system (Printf.sprintf "mkdir -p %s" parent) in
  let add_cmd = Printf.sprintf "git -C %s worktree add --detach %s %s 2>&1" mirror_path worktree_path commit_ref in
  match Unix.system add_cmd with
  | Unix.WEXITED 0 -> Ok worktree_path
  | _ -> Error (`Msg (Printf.sprintf "Failed to create worktree for %s" commit_ref))

(** Remove a worktree *)
let remove_worktree ~mirror_path ~worktree_path =
  let _ = Unix.system (Printf.sprintf "git -C %s worktree remove --force %s 2>/dev/null" mirror_path worktree_path) in
  ()

(** Checkout a repository using cached mirror *)
let checkout_repo ~git_cache_dir ~temp_dir url =
  let base_url, commit_ref = parse_url_fragment url in
  let commit_ref = match commit_ref with Some r -> r | None -> "HEAD" in
  match get_cached_mirror ~git_cache_dir base_url with
  | Error e -> Error e
  | Ok mirror_path ->
    let repo_name =
      let base = Filename.basename base_url in
      if String.length base > 4 && String.sub base (String.length base - 4) 4 = ".git" then
        String.sub base 0 (String.length base - 4)
      else
        base
    in
    let worktree_path = Filename.concat temp_dir repo_name in
    match create_worktree ~mirror_path ~worktree_path ~commit_ref with
    | Error e -> Error e
    | Ok path -> Ok (path, mirror_path)

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
let local ~opam_repo_path ~cache_dir ~git_cache_dir ~solve_jobs ~build_jobs =
  let module Service = Api.Service.BraidService in
  Service.local @@ object
    inherit Service.service

    method run_impl params release_param_caps =
      let open Service.Run in
      release_param_caps ();
      let repo_url = Params.repo_url_get params in
      let num_commits = Params.num_commits_get params |> Stdint.Uint32.to_int in
      let os = Params.os_get params in
      let os_family = Params.os_family_get params in
      let os_distribution = Params.os_distribution_get params in
      let os_version = Params.os_version_get params in

      (* Save current working directory - Runner.run changes it *)
      let saved_cwd = get_cwd () in

      (* Create unique temp directory for each request *)
      let temp_dir = make_temp_dir () in

      let checkout_result = checkout_repo ~git_cache_dir ~temp_dir repo_url in
      let result =
        match checkout_result with
        | Error (`Msg msg) -> Error msg
        | Ok (repo_path, _mirror_path) ->
          let output_dir = Filename.concat temp_dir "results" in
          (try Unix.mkdir output_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          match Runner.run ~repo_path ~opam_repo_path ~cache_dir ~output_dir
                  ~os ~os_family ~os_distribution ~os_version
                  ~solve_jobs ~build_jobs ~num_commits with
          | Ok manifest ->
            let json = Json.manifest_to_json manifest in
            Ok (Yojson.Basic.to_string json)
          | Error (`Msg msg) -> Error msg
      in

      (* Restore working directory before cleanup *)
      restore_cwd saved_cwd;

      (* Clean up worktree and temp directory *)
      (match checkout_result with
       | Ok (worktree_path, mirror_path) -> remove_worktree ~mirror_path ~worktree_path
       | Error _ -> ());
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
      let os = Params.os_get params in
      let os_family = Params.os_family_get params in
      let os_distribution = Params.os_distribution_get params in
      let os_version = Params.os_version_get params in

      (* Save current working directory *)
      let saved_cwd = get_cwd () in

      (* Create unique temp directory for each request *)
      let temp_dir = make_temp_dir () in

      (* Checkout all repos using cached mirrors *)
      let rec checkout_all urls acc mirrors =
        match urls with
        | [] -> Ok (List.rev acc, List.rev mirrors)
        | url :: rest ->
          match checkout_repo ~git_cache_dir ~temp_dir url with
          | Error e -> Error e
          | Ok (path, mirror) -> checkout_all rest (path :: acc) ((path, mirror) :: mirrors)
      in
      let checkout_result = checkout_all repo_urls [] [] in
      let result =
        match checkout_result with
        | Error (`Msg msg) -> Error msg
        | Ok (overlay_repos, _mirrors) ->
          let output_dir = Filename.concat temp_dir "results" in
          (try Unix.mkdir output_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          match Runner.merge_test ~overlay_repos ~opam_repo_path ~cache_dir ~output_dir
                  ~os ~os_family ~os_distribution ~os_version ~solve_jobs ~build_jobs with
          | Ok manifest ->
            let json = Json.manifest_to_json manifest in
            Ok (Yojson.Basic.to_string json)
          | Error (`Msg msg) -> Error msg
      in

      (* Restore working directory before cleanup *)
      restore_cwd saved_cwd;

      (* Clean up worktrees and temp directory *)
      (match checkout_result with
       | Ok (_, mirrors) ->
         List.iter (fun (worktree_path, mirror_path) ->
           remove_worktree ~mirror_path ~worktree_path
         ) mirrors
       | Error _ -> ());
      let _ = Unix.system (Printf.sprintf "rm -rf %s" temp_dir) in

      let response, results = Capnp_rpc.Service.Response.create Results.init_pointer in
      (match result with
       | Ok manifest_json -> Results.manifest_json_set results manifest_json
       | Error msg -> Results.manifest_json_set results (Printf.sprintf "{\"error\": \"%s\"}" msg));
      Capnp_rpc.Service.return response
  end
