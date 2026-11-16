#!/usr/bin/env node
// The base verification CLI: one tool for every repo, run from inside the repo.
// Same file on this Mac (~/.claude/kitchen) and in CI (the 3243dwon/kitchen action),
// so a laptop and GitHub run one sequence. The why: ~/.claude/KITCHEN.md.
//
//   node ~/.claude/kitchen/verify.mjs gates      the repo's own checks, pass / FAIL table
//   node ~/.claude/kitchen/verify.mjs map        what the repo contains, generated now
//   node ~/.claude/kitchen/verify.mjs where <words>
//
// A repo that has grown its own CLI (.claude/skills/verify/verify.{mjs,py}) gets it
// instead: this hands every command over, so the richer local version always wins.
// Node 20+, no dependencies.

import { readFileSync, existsSync } from 'node:fs'
import { join, extname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const git = (...a) => spawnSync('git', a, { encoding: 'utf8' }).stdout.trim()
const REPO = git('rev-parse', '--show-toplevel')
if (!REPO) {
  console.error('verify: not inside a git repo')
  process.exit(2)
}
const args = process.argv.slice(2)

// ———————————————————————————————————————————— hand over to a local CLI

const SELF = resolve(fileURLToPath(import.meta.url))
const localMjs = join(REPO, '.claude/skills/verify/verify.mjs')
const localPy = join(REPO, '.claude/skills/verify/verify.py')
if (!process.env.KITCHEN_BASE_ONLY) {
  let run = null
  if (existsSync(localMjs) && resolve(localMjs) !== SELF) run = [process.execPath, [localMjs, ...args]]
  else if (existsSync(localPy)) {
    const venv = join(REPO, '.venv/bin/python')
    run = [existsSync(venv) ? venv : 'python3', [localPy, ...args]]
  }
  if (run) {
    console.error(`verify: this repo has its own CLI — handing over to ${run[1][0].slice(REPO.length + 1)}`)
    process.exit(spawnSync(run[0], run[1], { cwd: REPO, stdio: 'inherit' }).status ?? 1)
  }
}

// ———————————————————————————————————————————— the repo, as git sees it

const has = (p) => existsSync(join(REPO, p))
const read = (p) => readFileSync(join(REPO, p), 'utf8')
const CODE = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.py', '.svelte', '.vue', '.swift', '.go', '.rs'])

/** Tracked plus new files, never ignored or generated ones. */
function files(prefix = '.') {
  const out = spawnSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '--', prefix], {
    cwd: REPO,
    encoding: 'utf8',
  }).stdout
  return out.split('\n').filter((f) => f && has(f)).sort()
}

const pkg = has('package.json') ? JSON.parse(read('package.json')) : null
const scripts = pkg?.scripts ?? {}
const python = has('pyproject.toml') || has('requirements.txt')

/** A check the repo opted out of, with a reason, in a tracked .claude/kitchen-skip. */
function skipped(check) {
  if (!has('.claude/kitchen-skip')) return null
  const m = read('.claude/kitchen-skip').match(new RegExp(`^${check}\\s+#\\s*(\\S.*)$`, 'm'))
  return m ? m[1] : null
}

// ———————————————————————————————————————————— gates
//
// Discovered from what the repo already declares, cheapest failure first. A gate this
// repo needs that is not discoverable becomes an npm script named gate:<something>
// (or a pytest test), so it is found here too — never a one-off command.

function gates() {
  const g = []
  const npm = (s) => [s, 'npm', ['run', s]]
  for (const s of ['lint', 'typecheck', 'test', 'build']) if (scripts[s]) g.push(npm(s))
  for (const s of Object.keys(scripts).sort()) if (/^(gate|check)(:|$)/.test(s)) g.push(npm(s))
  if (python) {
    const py = has('.venv/bin/python') ? '.venv/bin/python' : 'python3'
    const pyproject = has('pyproject.toml') ? read('pyproject.toml') : ''
    if (has('ruff.toml') || /\[tool\.ruff/.test(pyproject)) g.push(['ruff', py, ['-m', 'ruff', 'check', '.']])
    if (files().some((f) => /(^|\/)test_[^/]*\.py$|_test\.py$/.test(f))) g.push(['pytest', py, ['-m', 'pytest', '-q']])
  }
  return g
}

function cmdGates() {
  const list = gates()
  if (!list.length) {
    const why = skipped('gates')
    if (why) {
      console.log(`gates: none declared — opted out in .claude/kitchen-skip (${why})`)
      return 0
    }
    console.error(
      'GATES: NONE — this repo declares no lint / typecheck / test / build, so a green run would prove nothing.\n' +
        'Add the cheapest true check (an npm `test` or `gate:*` script, or a pytest test), or opt out with a\n' +
        'reason in a tracked .claude/kitchen-skip:  gates  # <why nothing here can be checked>',
    )
    return 1
  }
  const results = []
  for (const [name, cmd, a] of list) {
    console.log(`\n$ ${[cmd, ...a].join(' ')}`)
    results.push([name, spawnSync(cmd, a, { cwd: REPO, stdio: 'inherit' }).status === 0 ? 'pass' : 'FAIL'])
  }
  console.log('\n— gates')
  for (const [name, status] of results) console.log(`  ${status.padEnd(6)} ${name}`)
  return results.some(([, s]) => s === 'FAIL') ? 1 : 0
}

// ———————————————————————————————————————————— map
//
// Generated every time it is asked for, from the code as it is now, so it cannot be
// stale and nothing has to be committed.

/** What a file is: the first sentence of its first comment or docstring. */
function describe(file) {
  let text = ''
  for (const line of read(file).split('\n').slice(0, 40)) {
    const m = line.match(/^\s*(?:\/\/+|#(?!!)|\*|\/\*\*?|"""|''')\s?(.*?)(?:\*\/|"""|''')?\s*$/)
    if (!m) { if (text) break; continue }
    const part = m[1].replace(/^[—\-=*\s]+|[—\-=*\s]+$/g, '').trim()
    if (!part) { if (text) break; continue }
    text = `${text} ${part}`.trim()
    if (/[.:]$/.test(part)) break
  }
  if (text.length > 140) text = `${text.slice(0, 140).replace(/\s+\S*$/, '')} …`
  return text ? text.replace(/\|/g, '\\|') : '—'
}

function buildMap() {
  const L = []
  const row = (...c) => L.push(`| ${c.join(' | ')} |`)
  L.push(`# ${pkg?.name ?? REPO.split('/').pop()} — generated ${git('-C', REPO, 'rev-parse', '--short', 'HEAD') || 'no commits'}`, '')
  const code = files().filter(
    (f) => !f.startsWith('.claude/') && CODE.has(extname(f)) && !/(^|\/)(tests?|__tests__)\/|\.(test|spec)\./.test(f),
  )
  if (code.length) {
    L.push('## Code', '')
    row('file', 'what it is')
    row('---', '---')
    for (const f of code.slice(0, 300)) row(`\`${f}\``, describe(f))
    if (code.length > 300) L.push('', `… and ${code.length - 300} more`)
  }
  if (Object.keys(scripts).length) L.push('', '## npm scripts', '', Object.keys(scripts).map((s) => `\`${s}\``).join(' · '))
  const g = gates()
  L.push('', '## Gates (`verify gates`)', '', g.length ? g.map(([n]) => `\`${n}\``).join(' → ') : 'none declared')
  const wf = files('.github/workflows').filter((f) => /\.ya?ml$/.test(f))
  if (wf.length) {
    L.push('', '## Workflows', '')
    for (const f of wf) L.push(`- \`${f}\` — ${read(f).match(/^name: (.+)$/m)?.[1] ?? '—'}`)
  }
  L.push('')
  return L.join('\n')
}

// ———————————————————————————————————————————— where

function cmdWhere(words) {
  const needle = words.join(' ').trim().toLowerCase()
  if (!needle) return console.error('usage: verify.mjs where <words>'), 2
  const hits = buildMap().split('\n').filter((l) => l.startsWith('|') && l.toLowerCase().includes(needle))
  console.log(`— map (${hits.length})`)
  for (const h of hits) console.log(`  ${h}`)
  console.log('— source')
  let n = 0
  for (const f of files().filter((f) => CODE.has(extname(f)) || /\.(css|html|md)$/.test(f))) {
    read(f).split('\n').forEach((line, i) => {
      if (n < 40 && line.toLowerCase().includes(needle)) {
        console.log(`  ${f}:${i + 1}  ${line.trim().slice(0, 110)}`)
        n++
      }
    })
  }
  if (n === 40) console.log('  … more; narrow the words')
  return 0
}

const [cmd, ...rest] = args
const commands = {
  gates: cmdGates,
  map: () => (process.stdout.write(buildMap()), 0),
  where: () => cmdWhere(rest),
}
if (!commands[cmd]) {
  console.error('usage: verify.mjs gates | map | where <words>')
  process.exit(2)
}
process.exit(commands[cmd]())
