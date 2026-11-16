# kitchen

The base every repo shares, so an agent can work in any of them unwatched:

- `verify.mjs`: one verification CLI for every repo. `gates` runs the repo's own lint,
  typecheck, test, build, `gate:*` scripts and pytest with a pass / FAIL table; `map` generates a
  feature map of the repo on demand; `where` finds which file owns something. A repo that has
  grown its own `.claude/skills/verify` CLI is handed over to.
- `action.yml`: the same `verify.mjs gates` as a GitHub Action. A repo's whole CI is
  `uses: 3243dwon/kitchen@v1`, so a laptop and CI run one sequence.
- `audit.sh` / `install.sh`: what a repo still lacks (a PR check, `gates` required on the
  default branch), and the one command that adds the check.

Run `bash audit.cases.sh` before changing anything here; it proves every check can fail.

## Credit

Inspired by **Lauren Tan ([@poteto](https://github.com/poteto))** and her talk *"how I shipped
2,500 PRs last month to production"*: trust is the whole game; run a kitchen, not a factory;
put every correction as high on the ladder as it can go (codebase, then lint/CI, then rules,
then skills); the codebase is memory; verify by running the real thing, with a CLI the agent
uses every time and a feature map as materialized memory. Any mistakes in how it is applied
here are mine, not hers.
