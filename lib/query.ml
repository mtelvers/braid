(** Query functions for braid manifest data *)

open Types

(** Get all failures (status = Failure) from latest commit *)
let failures manifest =
  match manifest.results with
  | [] -> []
  | latest :: _ ->
    latest.packages
    |> List.filter (fun p -> p.status = Failure)
    |> List.map (fun p -> (latest.short_commit, p))

(** Get all packages with a specific status from latest commit *)
let by_status manifest status =
  match manifest.results with
  | [] -> []
  | latest :: _ ->
    latest.packages
    |> List.filter (fun p -> p.status = status)
    |> List.map (fun p -> (latest.short_commit, p))

(** Get log for a specific commit and package *)
let log manifest ~commit ~package =
  let commit_result = List.find_opt (fun r ->
    r.short_commit = commit || r.commit = commit
  ) manifest.results in
  match commit_result with
  | None -> None
  | Some r ->
    let pkg_result = List.find_opt (fun p -> p.name = package) r.packages in
    match pkg_result with
    | None -> None
    | Some p -> p.log

(** Get full result for a specific commit and package *)
let result manifest ~commit ~package =
  let commit_result = List.find_opt (fun r ->
    r.short_commit = commit || r.commit = commit
  ) manifest.results in
  match commit_result with
  | None -> None
  | Some r ->
    List.find_opt (fun p -> p.name = package) r.packages

(** Get history for a package across all commits *)
let history manifest ~package =
  let hist = List.filter_map (fun (r : commit_result) ->
    match List.find_opt (fun p -> p.name = package) r.packages with
    | None -> None
    | Some p -> Some (r.short_commit, p.status)
  ) manifest.results in
  match hist with
  | [] -> None
  | _ ->
    let latest_status = snd (List.hd hist) in
    let first_seen = fst (List.hd (List.rev hist)) in
    Some { package; first_seen; latest_status; history = hist }

(** Get dependencies for a package (from solution graph) *)
let deps manifest ~commit ~package =
  match result manifest ~commit ~package with
  | None -> None
  | Some r -> r.solution

(** Get packages that depend on a given package *)
let rdeps manifest ~commit ~package =
  let commit_result = List.find_opt (fun r ->
    r.short_commit = commit || r.commit = commit
  ) manifest.results in
  match commit_result with
  | None -> []
  | Some r ->
    r.packages
    |> List.filter (fun p ->
      match p.solution with
      | None -> false
      | Some sol ->
        (* Check if the solution graph mentions our package *)
        let pattern = "\"" ^ package in
        String.length sol > 0 &&
        (try let _ = Str.search_forward (Str.regexp_string pattern) sol 0 in true
         with Not_found -> false))
    |> List.map (fun p -> p.name)

(** Get summary statistics *)
let summary manifest =
  match manifest.results with
  | [] -> (0, 0, 0, 0, 0, 0)
  | latest :: _ ->
    let count status = List.length (List.filter (fun p -> p.status = status) latest.packages) in
    (count Success, count Failure, count Dependency_failed, count No_solution, count Solution, count Error)

(** Find when a package first started failing *)
let first_failure manifest ~package =
  let hist = List.filter_map (fun (r : commit_result) ->
    match List.find_opt (fun p -> p.name = package) r.packages with
    | None -> None
    | Some p -> Some (r.short_commit, r.message, p.status)
  ) manifest.results in
  (* Find transition from non-failure to failure (going backwards in time) *)
  let rec find_transition = function
    | [] -> None
    | [(c, m, s)] -> if s = Failure then Some (c, m) else None
    | (c1, m1, s1) :: ((_c2, _m2, s2) :: _ as rest) ->
      if s1 = Failure && s2 <> Failure then Some (c1, m1)
      else find_transition rest
  in
  find_transition (List.rev hist)

(** Generate terminal-friendly matrix with vertical package names *)
let matrix manifest =
  let buf = Buffer.create 4096 in
  Buffer.add_string buf "Build Status Matrix\n";
  Buffer.add_string buf "Legend: S=success, F=failure, D=dependency_failed, -=no_solution, B=solution\n\n";

  let packages = manifest.packages in
  (* Strip .dev suffix for display *)
  let display_names = List.map (fun pkg ->
    if String.length pkg > 4 && String.sub pkg (String.length pkg - 4) 4 = ".dev" then
      String.sub pkg 0 (String.length pkg - 4)
    else pkg
  ) packages in
  let commit_width = 9 in (* "Commit" + padding *)

  (* Find the longest display name for vertical header height *)
  let max_pkg_len = List.fold_left (fun acc pkg -> max acc (String.length pkg)) 0 display_names in

  (* Print vertical package names (bottom-aligned) *)
  for row = 0 to max_pkg_len - 1 do
    Buffer.add_string buf (String.make commit_width ' ');
    List.iter (fun pkg ->
      let pkg_len = String.length pkg in
      let offset = max_pkg_len - pkg_len in
      let ch = if row >= offset then String.make 1 pkg.[row - offset] else " " in
      Buffer.add_string buf (Printf.sprintf " %s " ch)
    ) display_names;
    Buffer.add_char buf '\n'
  done;

  (* Separator line *)
  Buffer.add_string buf (String.make commit_width '-');
  List.iter (fun _ -> Buffer.add_string buf "---") display_names;
  Buffer.add_char buf '\n';

  (* Data rows *)
  List.iter (fun (r : commit_result) ->
    Buffer.add_string buf (Printf.sprintf "%-8s " r.short_commit);
    List.iter (fun pkg_name ->
      let symbol = match List.find_opt (fun p -> p.name = pkg_name) r.packages with
        | None -> " "
        | Some p -> status_symbol p.status
      in
      Buffer.add_string buf (Printf.sprintf " %s " symbol)
    ) packages;
    Buffer.add_char buf '\n'
  ) manifest.results;

  Buffer.contents buf
