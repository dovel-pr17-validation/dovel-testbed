#!/usr/bin/env node
// The product's scripts/migration-bench/run-case.mjs, as a testbed leg must run it:
//   - the model key reaches the flow over stdin (--secrets-stdin), never through the environment: the flow refuses
//     to start with OPENROUTER_API_KEY inherited ("credential environment is unsafe for repository execution"),
//     and run-case.mjs passes process.env through with stdin closed;
//   - the product is an unpacked snapshot without .git, so its sha comes from --product-sha, not `git rev-parse`.
// Everything else is run-case.mjs's: its case check, --only spec, resolution cutoff, checkout and flow arguments,
// and the same <out>/<id>/{case-run.json,flow.log,output,publication}.
//
//   node run-case-stdin.mjs <product root> <case.json> --out <dir> --product-sha <sha> [--ci-runner act] [--act-binary <path>] <<< '{"OPENROUTER_API_KEY":"..."}'
import { execFile, spawn } from 'node:child_process'
import { createWriteStream, readFileSync } from 'node:fs'
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const argv = process.argv.slice(2)
const option = flag => { const index = argv.indexOf(flag); return index === -1 ? undefined : argv[index + 1] }
const [productArg, caseFile] = argv
const out = option('--out')
const productSha = option('--product-sha')
if (!productArg || !caseFile || !out || !productSha) {
  console.error('usage: run-case-stdin.mjs <product root> <case.json> --out <dir> --product-sha <sha> [--ci-runner act|emulate] [--act-binary <path>]')
  process.exit(2)
}
const productRoot = path.resolve(productArg)
const ciRunner = option('--ci-runner') ?? 'act'
const actBinary = option('--act-binary')
const secrets = readFileSync(0, 'utf8')
const { checkedCase, onlySpec, cutoffEnvironment, repositoryName } = await import(pathToFileURL(path.join(productRoot, 'scripts/migration-bench/run-case.mjs')).href)

async function checkout(url, commit, directory) {
  await rm(directory, { recursive: true, force: true })
  await mkdir(directory, { recursive: true })
  await execFileAsync('git', ['init', '-q'], { cwd: directory })
  await execFileAsync('git', ['remote', 'add', 'origin', url], { cwd: directory })
  await execFileAsync('git', ['fetch', '-q', '--depth', '50', 'origin', commit], { cwd: directory, maxBuffer: 64 * 1024 * 1024 })
  await execFileAsync('git', ['checkout', '-q', '--detach', commit], { cwd: directory })
}

const benchCase = checkedCase(JSON.parse(await readFile(caseFile, 'utf8')), caseFile)
const root = path.resolve(out, benchCase.id)
const repository = path.join(root, 'checkout')
const outputDir = path.join(root, 'output')
const publicationDir = path.join(root, 'publication')
await mkdir(root, { recursive: true })
const { owner, name } = repositoryName(benchCase.repository.url)
const startedAt = new Date()
// A provisional record, replaced at the end: a leg killed by its job timeout still scores (NOT-JUDGED), instead
// of score.mjs skipping a directory without case-run.json.
await writeFile(path.join(root, 'case-run.json'), `${JSON.stringify({ schemaVersion: 1, case: benchCase, productSha, startedAt: startedAt.toISOString(), exitCode: null, minutes: null, via: 'dovel-testbed bench/run-case-stdin.mjs (provisional: the run did not finish)' }, null, 2)}\n`)
console.log(`${benchCase.id}: ${owner}/${name}@${benchCase.repository.commit.slice(0, 12)}, ${onlySpec(benchCase.update)} (from ${benchCase.update.from})`)
await checkout(benchCase.repository.url, benchCase.repository.commit, repository)
const args = [
  '--import', pathToFileURL(path.join(productRoot, 'packages/part-a/node_modules/tsx/dist/loader.mjs')).href,
  path.join(productRoot, 'scripts/run-dovel-flow.mjs'),
  '--repository', repository, '--owner', owner, '--name', name,
  '--only', onlySpec(benchCase.update), '--catch-up', 'false',
  '--ci-runner', ciRunner, ...(actBinary === undefined ? [] : ['--act-binary', actBinary]),
  '--open-pr', 'true', '--publication-out', publicationDir, '--skip-ci-verdict-sweep',
  '--output-dir', outputDir,
  '--secrets-stdin',
]
const flowLog = createWriteStream(path.join(root, 'flow.log'))
const exitCode = await new Promise((resolve, reject) => {
  const child = spawn(process.execPath, args, {
    cwd: productRoot,
    env: { ...process.env, ...cutoffEnvironment(benchCase.resolutionCutoff), DOVEL_PRODUCT_SHA: productSha },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  child.stdout.pipe(flowLog, { end: false })
  child.stderr.pipe(flowLog, { end: false })
  child.on('error', reject)
  child.on('close', code => resolve(code ?? 1))
  child.stdin.end(secrets)
})
flowLog.end()
const run = { schemaVersion: 1, case: benchCase, productSha, startedAt: startedAt.toISOString(), endedAt: new Date().toISOString(), exitCode,
  minutes: Math.round((Date.now() - startedAt.getTime()) / 6_000) / 10, via: 'dovel-testbed bench/run-case-stdin.mjs' }
await writeFile(path.join(root, 'case-run.json'), `${JSON.stringify(run, null, 2)}\n`)
console.log(`${benchCase.id}: flow exited ${exitCode} after ${run.minutes} min`)
process.exit(exitCode === 0 ? 0 : 1)
