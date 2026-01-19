# Braid

Build status tracker for opam overlay repositories. Braid runs [day10](https://github.com/mtelvers/day10) health checks across git commits and provides a queryable manifest of results.

## Overview

Braid solves the problem of tracking package build status across multiple commits in an opam overlay repository. It:

1. **Runs day10 health checks** across a configurable number of commits
2. **Generates a manifest.json** containing all results, build logs, and dependency graphs
3. **Provides query commands** to investigate failures, track package history, and diagnose problems

The manifest format is designed for both human inspection and AI agent consumption.

## Installation

```bash
# Clone the repository
git clone https://github.com/mtelvers/braid.git
cd braid

# Create an opam switch and install dependencies
opam switch create . 5.4.0 --deps-only
eval $(opam env)
opam install . --deps-only

# Build
dune build

# Install (optional)
dune install
```

## Usage

### Running Health Checks

```bash
braid run <REPO_PATH> [OPTIONS]
```

**Arguments:**
- `REPO_PATH` - Path to the overlay opam repository

**Options:**
- `-n, --num-commits N` - Number of commits to process (default: 10)
- `-j, --jobs N` - Number of parallel jobs for solving (default: 40)
- `-o, --output PATH` - Output directory for results (default: results)
- `--opam-repo PATH` - Path to the main opam repository (default: /home/mtelvers/opam-repository)
- `--cache-dir PATH` - Cache directory for day10 (default: /var/cache/day10)
- `--os OS` - Operating system (default: linux)
- `--os-family FAMILY` - OS family (default: debian)
- `--os-distribution DIST` - OS distribution (default: debian)
- `--os-version VERSION` - OS version (default: 13)
- `-v, --verbose` - Increase verbosity

**Example:**
```bash
# Run on the last 57 commits of an overlay repository
braid run /home/mtelvers/aoah-opam-repo -n 57 -o results -v
```

### Query Commands

All query commands read from a manifest file (default: `manifest.json`). Use `-m PATH` to specify a different manifest.

#### summary

Show overview statistics.

```bash
$ braid summary -m results/manifest.json
Repository: /home/mtelvers/aoah-opam-repo
Generated: 2026-01-19T19:45:16Z
OS: debian-13
Commits: 57
Packages: 55

Latest commit status:
  Success: 12
  Failure: 11
  Dependency failed: 10
  No solution: 22
  Solution (buildable): 0
  Error: 0
```

#### failures

List packages with status 'failure' in the latest commit.

```bash
$ braid failures -m results/manifest.json
Failures in commit 3289824:
  atp.dev
  bytesrw-eio.dev
  claude.dev
  frontmatter.dev
  hermest.dev
  html5rw.dev
  init.dev
  langdetect.dev
  monopam.dev
  owntracks.dev
  srcsetter-cmd.dev
```

#### log

Show the build log for a specific package at a specific commit.

```bash
$ braid log 3289824 bytesrw-eio.dev -m results/manifest.json
Processing: [default: loading data]
[bytesrw-eio.dev: git]
...
-> retrieved bytesrw-eio.dev  (git+https://tangled.org/@anil.recoil.org/ocaml-bytesrw-eio.git#main)
[bytesrw-eio: dune subst]
+ /home/opam/.opam/default/bin/dune "subst" (CWD=/home/opam/.opam/default/.opam-switch/build/bytesrw-eio.dev)
- File "dune-project", line 25, characters 16-33:
- 25 |  (documentation (depends bytesrw)))
-                      ^^^^^^^^^^^^^^^^^
- Error: Atom or quoted string expected
[ERROR] The compilation of bytesrw-eio.dev failed at "dune subst".
build failed...
```

#### history

Show the status of a package across all commits.

```bash
$ braid history cbort.dev -m results/manifest.json
Package: cbort.dev
First seen: 82661d5
Latest status: success
History:
  3289824: success
  b92aa39: success
  2345324: success
  ...
```

#### first-failure

Find when a package first started failing (the commit where it transitioned from success to failure).

```bash
$ braid first-failure atp.dev -m results/manifest.json
First failure: 160dd2e (Add owntracks and owntracks-cli dev packages)
```

#### deps

Show the dependency graph for a package (in DOT format).

```bash
$ braid deps 3289824 cbort.dev -m results/manifest.json
digraph opam {
  "bytesrw.0.3.0" -> {"conf-pkg-config.4" "ocaml.5.3.0" "ocamlbuild.0.16.1" "ocamlfind.1.9.8" "topkg.1.1.1"}
  "cbort.dev" -> {"bytesrw.0.3.0" "dune.3.21.0" "ocaml.5.3.0" "zarith.1.14"}
  ...
}
```

#### result

Get the full JSON result for a package at a commit.

```bash
$ braid result 3289824 cbort.dev -m results/manifest.json
{
  "name": "cbort.dev",
  "status": "success",
  "sha": "32898245e4f7e95e2122f6aa8106c2680c4daffa...",
  "layer": "d41bb6c70aa39c972b04922bb5d9be03",
  "log": "Processing: [default: loading data]...",
  "solution": "digraph opam { ... }"
}
```

#### matrix

Output a terminal-friendly status matrix with vertical package names for better readability.

```bash
$ braid matrix -m results/manifest.json
Build Status Matrix
Legend: S=success, F=failure, D=dependency_failed, -=no_solution, B=solution, (space)=not present

                b
                y
                t
                e
                s
                r
          c     w
          b     -
          o  a  e
          r  t  i
          t  p  o
---------------------
3289824   S  F  F  ...
b92aa39   S  F  F  ...
```

Package names are displayed vertically and bottom-aligned (with `.dev` suffix stripped), so all names end at the same row just above the data. This makes it easy to read package names of varying lengths.

## Manifest Format

The manifest.json file contains all results in a structured format:

```json
{
  "repo_path": "/home/mtelvers/aoah-opam-repo",
  "opam_repo_path": "/home/mtelvers/opam-repository",
  "os": "debian-13",
  "os_version": "13",
  "generated_at": "2026-01-19T19:45:16Z",
  "commits": ["3289824", "b92aa39", ...],
  "packages": ["atp.dev", "cbort.dev", ...],
  "results": [
    {
      "commit": "3289824...",
      "short_commit": "3289824",
      "message": "activitypub",
      "packages": [
        {
          "name": "cbort.dev",
          "status": "success",
          "sha": "...",
          "layer": "...",
          "log": "...",
          "solution": "..."
        },
        ...
      ]
    },
    ...
  ]
}
```

### Status Values

| Status | Symbol | Description |
|--------|--------|-------------|
| `success` | S | Package built successfully |
| `failure` | F | Package build failed |
| `dependency_failed` | D | A dependency failed to build |
| `no_solution` | - | Dependencies cannot be solved |
| `solution` | B | Solvable but not yet built (build candidate) |
| not present | (space) | Package does not exist at this commit |

## AI Agent Integration

Braid is designed for easy integration with AI agents. The manifest.json provides:

1. **Structured data** - All results in a single queryable JSON file
2. **Build logs** - Full build output for diagnosing failures
3. **Dependency graphs** - DOT format graphs showing package dependencies
4. **History tracking** - Status of each package across all commits

### Example: Diagnosing a Failure

An AI agent can:

1. Read the manifest to get an overview:
   ```bash
   braid summary -m manifest.json
   ```

2. List current failures:
   ```bash
   braid failures -m manifest.json
   ```

3. Get the build log for a failing package:
   ```bash
   braid log 3289824 atp.dev -m manifest.json
   ```

4. Check when it started failing:
   ```bash
   braid first-failure atp.dev -m manifest.json
   ```

5. View dependencies to understand the failure context:
   ```bash
   braid deps 3289824 atp.dev -m manifest.json
   ```

### Programmatic Access

The manifest can also be read directly as JSON for more complex queries:

```python
import json

with open('manifest.json') as f:
    manifest = json.load(f)

# Find all packages that have ever failed
failed_packages = set()
for result in manifest['results']:
    for pkg in result['packages']:
        if pkg['status'] == 'failure':
            failed_packages.add(pkg['name'])

print(f"Packages that have failed: {failed_packages}")
```

## Dependencies

- OCaml >= 4.14
- cmdliner >= 1.2
- yojson >= 2.0
- bos >= 0.2
- fmt >= 0.9
- logs >= 0.7
- fpath >= 0.7
- [day10](https://github.com/mtelvers/day10) (must be in PATH)

## License

ISC
