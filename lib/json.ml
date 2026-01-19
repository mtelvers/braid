(** JSON serialization for braid types *)

open Types

let status_to_json status =
  `String (string_of_status status)

let status_of_json = function
  | `String s -> status_of_string s
  | _ -> Error

let package_result_to_json r =
  let fields = [
    "name", `String r.name;
    "status", status_to_json r.status;
  ] in
  let fields = match r.sha with
    | Some s -> ("sha", `String s) :: fields
    | None -> fields
  in
  let fields = match r.layer with
    | Some s -> ("layer", `String s) :: fields
    | None -> fields
  in
  let fields = match r.log with
    | Some s -> ("log", `String s) :: fields
    | None -> fields
  in
  let fields = match r.solution with
    | Some s -> ("solution", `String s) :: fields
    | None -> fields
  in
  `Assoc (List.rev fields)

let package_result_of_json json =
  let open Yojson.Basic.Util in
  let name = json |> member "name" |> to_string in
  let status = json |> member "status" |> status_of_json in
  let sha = json |> member "sha" |> to_string_option in
  let layer = json |> member "layer" |> to_string_option in
  let log = json |> member "log" |> to_string_option in
  let solution = json |> member "solution" |> to_string_option in
  { name; status; sha; layer; log; solution }

let commit_result_to_json r =
  `Assoc [
    "commit", `String r.commit;
    "short_commit", `String r.short_commit;
    "message", `String r.message;
    "packages", `List (List.map package_result_to_json r.packages);
  ]

let commit_result_of_json json =
  let open Yojson.Basic.Util in
  let commit = json |> member "commit" |> to_string in
  let short_commit = json |> member "short_commit" |> to_string in
  let message = json |> member "message" |> to_string in
  let packages = json |> member "packages" |> to_list |> List.map package_result_of_json in
  { commit; short_commit; message; packages }

let package_history_to_json h =
  `Assoc [
    "package", `String h.package;
    "first_seen", `String h.first_seen;
    "latest_status", status_to_json h.latest_status;
    "history", `List (List.map (fun (c, s) ->
      `Assoc ["commit", `String c; "status", status_to_json s]
    ) h.history);
  ]

let manifest_to_json m =
  `Assoc [
    "repo_path", `String m.repo_path;
    "opam_repo_path", `String m.opam_repo_path;
    "os", `String m.os;
    "os_version", `String m.os_version;
    "generated_at", `String m.generated_at;
    "commits", `List (List.map (fun c -> `String c) m.commits);
    "packages", `List (List.map (fun p -> `String p) m.packages);
    "results", `List (List.map commit_result_to_json m.results);
  ]

let manifest_of_json json =
  let open Yojson.Basic.Util in
  let repo_path = json |> member "repo_path" |> to_string in
  let opam_repo_path = json |> member "opam_repo_path" |> to_string in
  let os = json |> member "os" |> to_string in
  let os_version = json |> member "os_version" |> to_string in
  let generated_at = json |> member "generated_at" |> to_string in
  let commits = json |> member "commits" |> to_list |> List.map to_string in
  let packages = json |> member "packages" |> to_list |> List.map to_string in
  let results = json |> member "results" |> to_list |> List.map commit_result_of_json in
  { repo_path; opam_repo_path; os; os_version; generated_at; commits; packages; results }

(** Parse a day10 JSON result file *)
let parse_day10_result json =
  let open Yojson.Basic.Util in
  let name = json |> member "name" |> to_string in
  let status = json |> member "status" |> status_of_json in
  let sha = json |> member "sha" |> to_string_option in
  let layer = json |> member "layer" |> to_string_option in
  let log = json |> member "log" |> to_string_option in
  let solution = json |> member "solution" |> to_string_option in
  { name; status; sha; layer; log; solution }

(** Write manifest to file *)
let write_manifest path manifest =
  let json = manifest_to_json manifest in
  let content = Yojson.Basic.pretty_to_string json in
  Bos.OS.File.write (Fpath.v path) content

(** Read manifest from file *)
let read_manifest path =
  match Bos.OS.File.read (Fpath.v path) with
  | Ok content ->
    let json = Yojson.Basic.from_string content in
    Ok (manifest_of_json json)
  | Error e -> Error e
