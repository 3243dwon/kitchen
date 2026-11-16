#!/bin/bash
# Cases for the kitchen: every audit check and every verify rule must be seen to fail
# and to pass. Builds throwaway repos in a temp dir; touches nothing real, no network.
set -u
K="$HOME/.claude/kitchen"; A="$K/audit.sh"; V="$K/verify.mjs"
bash -n "$A" && node --check "$V" && echo syntax-ok
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
say() { [ "$1" = "$2" ] && s=ok || { s=WRONG; fails=$((fails+1)); }; printf '%-5s got=%-8s want=%-8s %s\n' "$s" "$1" "$2" "$3"; }
col() { "$A" "$1" 2>/dev/null | awk -v c="$2" 'NR==1 {for (i=1;i<=NF;i++) k[$i]=i; next} NR==2 {print $(k[c])}'; }
mk() { git init -q "$T/$1" && git -C "$T/$1" config user.email t@t && git -C "$T/$1" config user.name t; }

echo '— audit'
mk bare
say "$(col "$T/bare" pr-ci)" MISSING "pr-ci: empty repo"
say "$(col "$T/bare" required)" unknown "required: no remote"
say "$(col "$T/bare" rules)" none "rules: none is advice, not a gap"

mk ci; R="$T/ci"; mkdir -p "$R/.github/workflows"
printf 'on:\n  pull_request:\n' > "$R/.github/workflows/check.yml"
say "$(col "$R" pr-ci)" ok "pr-ci: block form"
printf 'on: [push, pull_request]\n' > "$R/.github/workflows/check.yml"
say "$(col "$R" pr-ci)" ok "pr-ci: flow form"
printf 'on:\n  push:\n' > "$R/.github/workflows/check.yml"
say "$(col "$R" pr-ci)" MISSING "pr-ci: push only"
printf 'on: [push]\njobs:\n  pull_request_review: {}\n' > "$R/.github/workflows/check.yml"
say "$(col "$R" pr-ci)" MISSING "pr-ci: the word elsewhere is not a trigger"
echo x > "$R/CLAUDE.md"
say "$(col "$R" rules)" none "rules: untracked CLAUDE.md"
git -C "$R" add -A && git -C "$R" commit -qm i
say "$(col "$R" rules)" ok "rules: tracked CLAUDE.md"

mk skip; S="$T/skip"; mkdir -p "$S/.claude"
printf 'pr-ci\n' > "$S/.claude/kitchen-skip"; git -C "$S" add -A && git -C "$S" commit -qm s
say "$(col "$S" pr-ci)" MISSING "opt-out without a reason does not count"
printf 'pr-ci  # brand assets\n' > "$S/.claude/kitchen-skip"; git -C "$S" commit -qam s
say "$(col "$S" pr-ci)" skip "opt-out with a reason"

say "$("$A" --hook "$T/bare")" "bare is missing: pr-ci" "hook names only walls"
mkdir -p "$S/sub"; say "$("$A" --hook "$S/sub")" "" "hook: opted-out repo, from a subdirectory"
say "$("$A" --hook "$T")" "" "hook outside a repo prints nothing"

echo '— verify'
mk empty; E="$T/empty"
(cd "$E" && node "$V" gates >/dev/null 2>&1); say "$?" 1 "gates: none declared fails"
mkdir -p "$E/.claude"; printf 'gates  # assets only\n' > "$E/.claude/kitchen-skip"
(cd "$E" && node "$V" gates >/dev/null 2>&1); say "$?" 0 "gates: opted out with a reason passes"

mk npm; N="$T/npm"
printf '{"name":"n","scripts":{"test":"exit 0","gate:x":"exit 1","build":"exit 0"}}' > "$N/package.json"
out=$(cd "$N" && node "$V" gates 2>&1); code=$?
say "$code" 1 "gates: a failing gate:* fails the run"
say "$(echo "$out" | grep -cE '^  (pass|FAIL) ')" 3 "gates: test, build and gate:x all ran"
printf '{"name":"n","scripts":{"test":"exit 0"}}' > "$N/package.json"
(cd "$N" && node "$V" gates >/dev/null 2>&1); say "$?" 0 "gates: all pass"

printf '// The thing that does it.\nexport const a = 1\n' > "$N/a.mjs"
say "$(cd "$N" && node "$V" map | grep -c 'The thing that does it')" 1 "map: describes a new file"
mkdir -p "$N/dist"; printf '// generated\n' > "$N/dist/x.mjs"; echo dist/ > "$N/.gitignore"
say "$(cd "$N" && node "$V" map | grep -c 'dist/x.mjs')" 0 "map: ignores gitignored output"

mkdir -p "$N/.claude/skills/verify"
printf 'console.log("local " + process.argv.slice(2).join(" "))\n' > "$N/.claude/skills/verify/verify.mjs"
say "$(cd "$N" && node "$V" gates 2>/dev/null)" "local gates" "hands over to a local CLI"
say "$(cd "$N" && KITCHEN_BASE_ONLY=1 node "$V" gates 2>/dev/null | grep -c pass)" 1 "KITCHEN_BASE_ONLY skips the hand-over"

echo "fails=$fails"
[ "$fails" -eq 0 ]
