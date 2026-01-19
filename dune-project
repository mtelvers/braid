(lang dune 3.0)
(name braid)
(version 0.1.0)
(generate_opam_files true)

(source (github mtelvers/braid))
(license ISC)
(authors "Mark Mayfield Mayfield")
(maintainers "mark@mtelvers.com")

(package
 (name braid)
 (synopsis "Build status tracker for opam overlay repositories")
 (description "Track and query package build status across git commits using day10")
 (depends
  (ocaml (>= 4.14))
  (cmdliner (>= 1.2))
  (yojson (>= 2.0))
  (bos (>= 0.2))
  (fmt (>= 0.9))
  (logs (>= 0.7))
  (fpath (>= 0.7))))
