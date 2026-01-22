(** RPC client for connecting to remote BraidService *)

module Api = Rpc_schema.MakeRPC(Capnp_rpc)

(** Connect to a remote BraidService using a capability file *)
let connect ~sw ~net cap_file =
  let vat = Capnp_rpc_unix.client_only_vat ~sw net in
  let sr = Capnp_rpc_unix.Cap_file.load vat cap_file |> Result.get_ok in
  Capnp_rpc.Sturdy_ref.connect_exn sr

(** Run health checks on a remote server *)
let run_remote ~sw ~net ~cap_file ~repo_url ~num_commits ~fork_jobs
    ~os ~os_family ~os_distribution ~os_version =
  let service = connect ~sw ~net cap_file in
  let open Api.Client.BraidService.Run in
  let request, params = Capnp_rpc.Capability.Request.create Params.init_pointer in
  Params.repo_url_set params repo_url;
  Params.num_commits_set params (Stdint.Uint32.of_int num_commits);
  Params.fork_jobs_set params (Stdint.Uint32.of_int fork_jobs);
  Params.os_set params os;
  Params.os_family_set params os_family;
  Params.os_distribution_set params os_distribution;
  Params.os_version_set params os_version;
  let response = Capnp_rpc.Capability.call_for_value_exn service method_id request in
  Results.manifest_json_get response

(** Run merge test on a remote server *)
let merge_test_remote ~sw ~net ~cap_file ~repo_urls ~fork_jobs
    ~os ~os_family ~os_distribution ~os_version =
  let service = connect ~sw ~net cap_file in
  let open Api.Client.BraidService.MergeTest in
  let request, params = Capnp_rpc.Capability.Request.create Params.init_pointer in
  let _ = Params.repo_urls_set_list params repo_urls in
  Params.fork_jobs_set params (Stdint.Uint32.of_int fork_jobs);
  Params.os_set params os;
  Params.os_family_set params os_family;
  Params.os_distribution_set params os_distribution;
  Params.os_version_set params os_version;
  let response = Capnp_rpc.Capability.call_for_value_exn service method_id request in
  Results.manifest_json_get response
