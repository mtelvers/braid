(** Cap'n Proto RPC server for BraidService *)

(** Start the RPC server with per-user capability files *)
let run ~sw ~net ~fs ~listen_addr ~listen_port ~public_addr ~key_file ~cap_dir ~users ~opam_repo_path ~cache_dir ~git_cache_dir ~solve_jobs ~build_jobs =
  let service = Rpc_service.local ~opam_repo_path ~cache_dir ~git_cache_dir ~solve_jobs ~build_jobs in
  let addr = `TCP (listen_addr, listen_port) in
  let public_address = `TCP (public_addr, listen_port) in
  let secret_key = `File (Eio.Path.(fs / key_file)) in
  let config = Capnp_rpc_unix.Vat_config.create ~secret_key ~public_address ~net addr in

  (* Create a restorer table with an entry for each user *)
  let make_sturdy = Capnp_rpc_unix.Vat_config.sturdy_uri config in
  let table = Capnp_rpc_net.Restorer.Table.create make_sturdy ~sw in

  (* Generate a derived ID for each user and add to the table *)
  let user_ids = List.map (fun user ->
    let service_id = Capnp_rpc_unix.Vat_config.derived_id config user in
    Capnp_rpc_net.Restorer.Table.add table service_id service;
    (user, service_id)
  ) users in

  let restore = Capnp_rpc_net.Restorer.of_table table in
  let vat = Capnp_rpc_unix.serve ~sw ~restore config in

  (* Create cap_dir if it doesn't exist *)
  (try Unix.mkdir cap_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());

  (* Save a capability file for each user *)
  List.iter (fun (user, service_id) ->
    let cap_file = Filename.concat cap_dir (user ^ ".cap") in
    Capnp_rpc_unix.Cap_file.save_service vat service_id cap_file |> Result.get_ok;
    Fmt.pr "  Created capability file: %s@." cap_file
  ) user_ids;

  Fmt.pr "Server listening on %s:%d@." listen_addr listen_port;
  Fmt.pr "  Public address: %s:%d@." public_addr listen_port;
  Fmt.pr "  Key file: %s@." key_file;
  Fmt.pr "  Users: %s@." (String.concat ", " users);
  (* Block forever - server runs until killed *)
  Eio.Fiber.await_cancel ()
