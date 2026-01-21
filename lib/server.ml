(** Cap'n Proto RPC server for BraidService *)

(** Start the RPC server *)
let run ~sw ~net ~fs ~listen_addr ~listen_port ~public_addr ~key_file ~cap_file ~opam_repo_path ~cache_dir =
  let service = Rpc_service.local ~opam_repo_path ~cache_dir in
  let addr = `TCP (listen_addr, listen_port) in
  let public_address = `TCP (public_addr, listen_port) in
  let secret_key = `File (Eio.Path.(fs / key_file)) in
  let config = Capnp_rpc_unix.Vat_config.create ~secret_key ~public_address ~net addr in
  let service_id = Capnp_rpc_unix.Vat_config.derived_id config "main" in
  let restore = Capnp_rpc_net.Restorer.single service_id service in
  let vat = Capnp_rpc_unix.serve ~sw ~restore config in
  Capnp_rpc_unix.Cap_file.save_service vat service_id cap_file |> Result.get_ok;
  Fmt.pr "Server listening on %s:%d@." listen_addr listen_port;
  Fmt.pr "  Public address: %s:%d@." public_addr listen_port;
  Fmt.pr "  Key file: %s@." key_file;
  Fmt.pr "  Capability file: %s@." cap_file;
  (* Block forever - server runs until killed *)
  Eio.Fiber.await_cancel ()
