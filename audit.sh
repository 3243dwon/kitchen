#!/bin/bash
# The kitchen audit: is this repo a place an agent can work unwatched?
# (The why: ~/.claude/KITCHEN.md. How to close a gap: the `kitchen` skill.)
#
#   audit.sh [repo ...]          table for each repo (default: the current one)
#   audit.sh --all               every project repo under ~, ~/dev, ~/Desktop
#   audit.sh --network [...]     also ask GitHub whether the PR check is REQUIRED
#                                on the default branch, and cache the answer
#   audit.sh --hook <repo>       one line of gaps, or nothing; offline, for SessionStart
#
# The base (~/.claude/kitchen: verify CLI, map, rules, skills, hooks) reaches every repo
# by itself. What only a repo can hold is the wall GitHub enforces, so that is what this
# audits:
#   pr-ci     a workflow triggered by pull_request: checks run before merge, not after
#   required  a required status check on the default branch: a red PR cannot merge
#   rules     (advice, never a gap) a tracked CLAUDE.md or AGENTS.md for project rules
#
# A repo opts out of a check by listing it, with a reason, in a tracked
# .claude/kitchen-skip ("pr-ci  # brand assets, nothing to run"). An opt-out
# without a reason does not count.
set -uo pipefail

CACHE="$HOME/.claude/state/kitchen-required.tsv"   # repo<TAB>yes|no<TAB>checked-at
CHECKS=(pr-ci required rules)
WALLS=(pr-ci required)

skipped() {  # $1 repo, $2 check -> 0 if opted out with a reason
  local f="$1/.claude/kitchen-skip"
  [ -f "$f" ] && git -C "$1" ls-files --error-unmatch .claude/kitchen-skip >/dev/null 2>&1 &&
    grep -qE "^$2[[:space:]]+#[[:space:]]*[^[:space:]]" "$f"
}

slug() { git -C "$1" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##'; }

required_cached() {  # $1 slug -> yes|no|unknown
  [ -n "$1" ] && [ -f "$CACHE" ] || { echo unknown; return; }
  awk -F'\t' -v s="$1" '$1==s {v=$2} END {print v ? v : "unknown"}' "$CACHE"
}

required_live() {  # $1 slug -> yes|no ; refreshes the cache
  local branch rules ans
  branch=$(gh api "repos/$1" -q .default_branch 2>/dev/null) || { echo unknown; return; }
  rules=$(gh api "repos/$1/rules/branches/$branch" -q '[.[].type]|join(",")' 2>/dev/null)
  prot=$(gh api "repos/$1/branches/$branch/protection/required_status_checks" -q '.contexts|length' 2>/dev/null)
  if [[ "$rules" == *required_status_checks* ]] || [ "${prot:-0}" -gt 0 ] 2>/dev/null; then ans=yes; else ans=no; fi
  mkdir -p "$(dirname "$CACHE")"
  { [ -f "$CACHE" ] && awk -F'\t' -v s="$1" '$1!=s' "$CACHE"; printf '%s\t%s\t%s\n' "$1" "$ans" "$(date +%F)"; } > "$CACHE.tmp" &&
    mv "$CACHE.tmp" "$CACHE"
  echo "$ans"
}

check() {  # $1 repo, $2 check, $3 network(0/1) -> prints ok|MISSING|skip|unknown
  local r="$1"
  if skipped "$r" "$2"; then echo skip; return; fi
  case "$2" in
    rules)
      git -C "$r" ls-files --error-unmatch CLAUDE.md >/dev/null 2>&1 ||
        git -C "$r" ls-files --error-unmatch AGENTS.md >/dev/null 2>&1 && echo ok || echo none ;;
    pr-ci)
      # block form (`  pull_request:`) or flow form (`on: [push, pull_request]`)
      grep -lqE '^[[:space:]]*pull_request(_target)?[[:space:]]*:|^on:.*[[ ,]pull_request(_target)?[] ,]' \
        "$r"/.github/workflows/*.y*ml 2>/dev/null && echo ok || echo MISSING ;;
    required)
      local s ans; s=$(slug "$r")
      if [ "$3" = 1 ] && [ -n "$s" ]; then ans=$(required_live "$s"); else ans=$(required_cached "$s"); fi
      case "$ans" in yes) echo ok ;; no) echo MISSING ;; *) echo unknown ;; esac ;;
  esac
}

all_repos() {
  find "$HOME" "$HOME/dev" "$HOME/Desktop" "$HOME"/Desktop/*/ -maxdepth 2 -name .git -type d \
    -not -path '*/node_modules/*' -not -path '*/.claude/*' -not -path "$HOME/Library/*" 2>/dev/null |
    xargs -n1 dirname | sort -u
}

NETWORK=0; HOOK=0; REPOS=()
for a in "$@"; do
  case "$a" in
    --all) while IFS= read -r r; do REPOS+=("$r"); done < <(all_repos) ;;
    --network) NETWORK=1 ;;
    --hook) HOOK=1 ;;
    *) REPOS+=("$a") ;;
  esac
done
[ ${#REPOS[@]} -gt 0 ] || REPOS=("$PWD")

if [ "$HOOK" = 1 ]; then
  r=$(git -C "${REPOS[0]}" rev-parse --show-toplevel 2>/dev/null) || exit 0
  # A worktree inherits its main checkout's verdict; audit the checkout it belongs to.
  common=$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ "$(basename "$common")" = .git ] && r=$(dirname "$common")
  gaps=()
  for c in "${WALLS[@]}"; do [ "$(check "$r" "$c" 0)" = MISSING ] && gaps+=("$c"); done
  # A repo GitHub has never been asked about (a new one, usually): ask in the background,
  # so this session starts at once and the next one knows.
  s=$(slug "$r")
  if [ -n "$s" ] && [ "$(required_cached "$s")" = unknown ]; then
    ( required_live "$s" >/dev/null 2>&1 & ) 2>/dev/null
  fi
  [ ${#gaps[@]} -eq 0 ] && exit 0
  echo "$(basename "$r") is missing: ${gaps[*]}"
  exit 0
fi

printf '%-26s' repo; for c in "${CHECKS[@]}"; do printf '%-9s' "$c"; done; echo
gapcount=0
for r in "${REPOS[@]}"; do
  top=$(git -C "$r" rev-parse --show-toplevel 2>/dev/null) || { echo "$r: not a git repo" >&2; continue; }
  printf '%-26s' "$(basename "$top")"
  for c in "${CHECKS[@]}"; do
    v=$(check "$top" "$c" "$NETWORK"); [ "$v" = MISSING ] && gapcount=$((gapcount + 1))
    printf '%-9s' "$v"
  done
  echo
done
[ "$NETWORK" = 1 ] || echo "(required: from cache; --network asks GitHub)"
[ "$gapcount" -eq 0 ]
