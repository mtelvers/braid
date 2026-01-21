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

### Merge Testing

Test the cumulative effect of merging multiple overlay repositories without tracking commit history.

```bash
braid merge-test <REPOS>... [OPTIONS]
```

**Arguments:**
- `REPOS` - One or more overlay repository paths (in priority order, first = highest priority)

**Options:**
- `-j, --jobs N` - Number of parallel jobs for solving (default: 40)
- `-o, --output PATH` - Output directory for results (default: results)
- `--opam-repo PATH` - Path to the main opam repository (default: /home/mtelvers/opam-repository)
- `--cache-dir PATH` - Cache directory for day10 (default: /var/cache/day10)
- `--dry-run` - Only solve dependencies, don't actually build
- `--os OS` - Operating system (default: linux)
- `--os-family FAMILY` - OS family (default: debian)
- `--os-distribution DIST` - OS distribution (default: debian)
- `--os-version VERSION` - OS version (default: 13)
- `-v, --verbose` - Increase verbosity

**Examples:**
```bash
# Test a single overlay repository
braid merge-test /home/mtelvers/my-overlay -o results

# Test what happens if 'experimental' is merged into 'stable'
braid merge-test /path/to/experimental /path/to/stable -o merge-results

# Stack multiple overlays (first has highest priority)
braid merge-test /path/to/repo1 /path/to/repo2 /path/to/repo3

# Quick dependency check without building
braid merge-test /path/to/overlay --dry-run
```

**How it works:**

1. Lists packages from all overlay repositories (not from opam-repository)
2. **Stage 1:** Runs `day10 health-check --dry-run --fork N` for fast parallel dependency solving
3. **Stage 2:** For packages that returned "solution" (solvable but not built), runs `day10 health-check` without `--dry-run` to actually build them

With `--dry-run`, only stage 1 runs, showing which packages are solvable without building them.

**Querying merge-test results:**

Query commands work with merge-test manifests using `merge-q` as the commit identifier:

```bash
# Show history for a package
braid history smtpd.dev -m merge-results/manifest.json
# Output: First seen: merge-q, Latest status: failure

# Show build log
braid log merge-q smtpd.dev -m merge-results/manifest.json

# Show dependencies
braid deps merge-q smtpd.dev -m merge-results/manifest.json
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
  ],
  "mode": "history",
  "overlay_repos": []
}
```

### Manifest Fields

| Field | Description |
|-------|-------------|
| `repo_path` | Primary overlay repository path |
| `opam_repo_path` | Main opam-repository path |
| `os` | Target OS (e.g., "debian-13") |
| `os_version` | OS version |
| `generated_at` | ISO 8601 timestamp |
| `commits` | List of commit hashes (or `["merge-test"]` for merge-test mode; short form: "merge-q") |
| `packages` | List of all package names |
| `results` | Array of per-commit results |
| `mode` | "history" for `run` command, "merge-test" for `merge-test` command |
| `overlay_repos` | For merge-test: list of stacked repos in priority order (first = highest) |
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

## Tutorial: Merge Testing Workflow

This tutorial demonstrates using `braid merge-test` to validate overlay repositories before merging.

### 1. Create a Test Overlay Repository

Create an opam repository structure with packages to test:

```bash
mkdir -p ~/claude-repo/packages/mypackage/mypackage.dev
```

Create the `repo` file:
```bash
echo 'opam-version: "2.0"' > ~/claude-repo/repo
```

For each package, create an opam file at `packages/<name>/<name>.dev/opam`:

```
opam-version: "2.0"
synopsis: "My package"
depends: [
  "ocaml" {>= "5.0"}
  "dune" {>= "3.0"}
]
build: [
  ["dune" "build" "-p" name "-j" jobs]
]
url {
  src: "git+https://github.com/user/repo.git"
}
```

### 2. Run Initial Merge Test

Test the overlay with a quick dry-run first:

```bash
braid merge-test ~/claude-repo --dry-run -o results
```

This shows which packages are solvable without building. The output includes a "solution" count for packages that can be built.

### 3. Run Full Build Test

Run the actual build:

```bash
braid merge-test ~/claude-repo -o results
```

Example output:
```
Merge test: 1 overlay repos, 3 packages
Overlay repos (priority order):
  /home/user/claude-repo
Results: 1 success, 2 failure, 0 dep_failed, 0 no_solution, 0 error
```

### 4. Diagnose Failures

Check which packages failed:

```bash
braid failures -m results/manifest.json
```

View the build log for a failing package:

```bash
braid log merge-q smtpd.dev -m results/manifest.json
```

Example output showing a missing dependency:
```
pam_stubs.c:7:10: fatal error: security/pam_appl.h: No such file or directory
    7 | #include <security/pam_appl.h>
      |          ^~~~~~~~~~~~~~~~~~~~~
```

### 5. Fix and Retest

In this case, the package needs `conf-pam` as a build dependency. Update the opam file:

```
depends: [
  "ocaml" {>= "5.0"}
  "dune" {>= "3.0"}
  "conf-pam" {build}   # Added for PAM headers
  ...
]
```

Rerun the merge test:

```bash
braid merge-test ~/claude-repo -o results
```

```
Results: 3 success, 0 failure, 0 dep_failed, 0 no_solution, 0 error
```

### 6. Test Multiple Stacked Overlays

Test what happens when merging multiple overlays together:

```bash
braid merge-test ~/my-overlay ~/upstream-overlay -o merge-results
```

Overlays are listed in priority order (first = highest priority, "on top"). This tests the combined effect of merging all overlays.

### 7. Query Results

After testing, query the manifest for details:

```bash
# Package history
braid history smtpd.dev -m results/manifest.json

# Dependency graph
braid deps merge-q smtpd.dev -m results/manifest.json

# Full JSON result
braid result merge-q smtpd.dev -m results/manifest.json
```

## Tutorial: Remote Execution via RPC

Braid supports remote execution using Cap'n Proto RPC. This allows you to run health checks on a remote server that has day10 and opam-repository available, from a client that only needs the braid binary and a capability file.

### Use Cases

- **Dev containers**: Run builds from lightweight development environments without day10 or opam-repository
- **Centralised build server**: Share a single build server across multiple developers
- **CI/CD integration**: Submit builds from CI pipelines to a dedicated build infrastructure

### 1. Start the Server

On a machine with day10 and opam-repository:

```bash
braid server --port 5000 \
  --public-addr build.example.com \
  --key-file /var/lib/braid/server.key \
  --cap-file /var/lib/braid/braid.cap \
  --opam-repo /home/user/opam-repository \
  --cache-dir /var/cache/day10
```

**Server options:**
- `--port PORT` - Port to listen on (required)
- `--public-addr HOST` - Public hostname for the capability URI (required)
- `--key-file PATH` - Path to store/load the server's secret key (default: server.key)
- `--cap-file PATH` - Path to write the capability file (default: braid.cap)
- `--opam-repo PATH` - Path to opam-repository
- `--cache-dir PATH` - Cache directory for day10

The `--key-file` option ensures the capability URI remains stable across server restarts. Without it, clients would need a new capability file each time the server restarts.

### 2. Distribute the Capability File

Copy the capability file to any client machine:

```bash
scp build.example.com:/var/lib/braid/braid.cap ~/.config/braid.cap
```

The capability file contains a URI like:
```
capnp://sha-256:abc123...@build.example.com:5000/def456...
```

This URI encodes both the server address and a cryptographic capability token.

### 3. Run Remote Merge Tests

From the client, use `--connect` with a repository URL (not a local path):

```bash
braid merge-test https://github.com/user/overlay-repo \
  --connect ~/.config/braid.cap \
  -o results
```

The server will:
1. Clone the repository to a temporary directory
2. Run day10 health checks
3. Return the manifest JSON
4. Clean up the temporary directory

Example output:
```
Merge test: 1 overlay repos, 4 packages (remote)
Overlay repos (priority order):
  https://github.com/user/overlay-repo
Results: 4 success, 0 failure, 0 dep_failed, 0 no_solution, 0 error
```

### 4. Run Remote History Checks

The `run` command also supports remote execution:

```bash
braid run https://github.com/user/overlay-repo \
  --connect ~/.config/braid.cap \
  -n 10 \
  -o results
```

### 5. Query Results Locally

Once the manifest is downloaded, all query commands work locally:

```bash
braid summary -m results/manifest.json
braid failures -m results/manifest.json
braid log merge-q mypackage.dev -m results/manifest.json
```

### Important Notes for RPC Usage

1. **Repository URLs**: When using `--connect`, pass git URLs instead of local paths. The server clones the repository.

2. **Opam file requirements**: Packages in the overlay repository must have a `url` section in their opam files:
   ```
   url {
     src: "git+https://github.com/user/package-repo.git"
   }
   ```
   This tells day10 where to fetch the package source.

3. **Network requirements**: The server must be able to clone repositories from the URLs you provide.

4. **Capability security**: The capability file grants full access to the braid server. Treat it like a password.

### Example: Complete Workflow

```bash
# On the server (once)
braid server --port 5000 \
  --public-addr basil.caelum.ci.dev \
  --key-file ~/braid-server.key \
  --cap-file ~/braid.cap \
  --opam-repo ~/opam-repository \
  --cache-dir /var/cache/day10

# Distribute capability (once)
scp basil.caelum.ci.dev:~/braid.cap ~/.config/

# From any client - test an overlay
braid merge-test https://github.com/mtelvers/claude-repo \
  --connect ~/.config/braid.cap \
  -o /tmp/results

# Check results
braid summary -m /tmp/results/manifest.json
braid failures -m /tmp/results/manifest.json
```

## Dependencies

- OCaml >= 4.14
- cmdliner >= 1.2
- yojson >= 2.0
- bos >= 0.2
- fmt >= 0.9
- logs >= 0.7
- fpath >= 0.7
- capnp-rpc = 2.1 (for RPC support)
- eio >= 1.2 (for RPC support)
- [day10](https://github.com/mtelvers/day10) (must be in PATH on server)

## License

ISC
