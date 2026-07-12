#!/usr/bin/env bash
#
# CI-only shim for the vendored CompetingClocks dependency.
#
# For local development this repo is checked out alongside a sibling
# CompetingClocks.jl clone, and the `[sources]` entries in Project.toml and
# test/Project.toml point at that sibling by relative path. A GitHub runner has
# no such sibling, so those paths do not resolve and instantiation fails before
# any test runs. Here we rewrite the source to the public CompetingClocks repo
# (whose main branch carries the unregistered 0.4 changes this repo needs) for
# the duration of the CI job only. The checked-in files keep the path form.
#
# We also drop the committed root Manifest.toml so Pkg re-resolves against the
# git source instead of trying to reuse the stale, path-pinned manifest.
set -euo pipefail

repo_url='CompetingClocks = {url = "https://github.com/adolgert/CompetingClocks.jl.git"}'

for f in Project.toml test/Project.toml docs/Project.toml; do
  if [[ -f "$f" ]] && grep -qE '^CompetingClocks = \{path = ' "$f"; then
    sed -i -E 's#^CompetingClocks = \{path = "[^"]*"\}#'"$repo_url"'#' "$f"
    echo "Rewrote CompetingClocks source in $f:"
    grep -E '^CompetingClocks = ' "$f"
  fi
done

rm -f Manifest.toml
echo "Removed committed root Manifest.toml so Pkg resolves the git source fresh."
