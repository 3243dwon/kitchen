#!/bin/bash
# Give one repo its wall: a `check` workflow that runs the base gates on every PR.
# Everything else (verify CLI, map, rules, skills) comes from the base and needs nothing
# in the repo. Never overwrites, never commits, never changes GitHub settings: making
# `gates` a required check is a separate, asked-for step (see the kitchen skill).
#
#   install.sh <repo>
set -euo pipefail
R=$(git -C "${1:?usage: install.sh <repo>}" rev-parse --show-toplevel)
F="$R/.github/workflows/check.yml"
if [ -e "$F" ]; then echo "kept      .github/workflows/check.yml (exists)"; exit 0; fi
mkdir -p "$(dirname "$F")"
cat > "$F" <<'EOF'
# Every gate, on every pull request, before anything reaches main. The gates are the
# repo's own (lint, typecheck, test, build, gate:*, pytest), run by the base verify CLI
# from 3243dwon/kitchen — the same file `node ~/.claude/kitchen/verify.mjs gates` runs.
name: check

on:
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: check-${{ github.ref }}
  cancel-in-progress: true

jobs:
  gates:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: 3243dwon/kitchen@v1
EOF
echo "wrote     .github/workflows/check.yml"
echo
echo "next: run \`node ~/.claude/kitchen/verify.mjs gates\` here, commit on a branch, open a PR,"
echo "      let check go green, then make 'gates' required on the default branch (ask first)."
