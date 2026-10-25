// Runs the product's act CI module on one upstream repository, as Dovel would: selectCiJobs picks the jobs
// (nothing hand-picked), runCiJob runs each on the unmodified checkout (baseline), then on a no-op candidate
// (an empty commit on top: new sha, same tree), and compareRuns judges the candidate.
// Usage: node driver.mjs <product-dir> <repo-dir> <out-dir>   (env: ACT_VARIANT patched|release, JOB_LIMIT, JOB_TIMEOUT_MIN)
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { gzipSync } from "node:zlib";
import { readFileSync } from "node:fs";

const [productDir, repoDir, outDir] = process.argv.slice(2);
const m = await import(pathToFileURL(path.join(productDir, "packages/part-a/dist/replay/actCi/index.js")).href);
mkdirSync(outDir, { recursive: true });
const json = value => JSON.stringify(value, (_, v) => typeof v === "bigint" ? v.toString() : v, 1);
const write = (name, value) => writeFileSync(path.join(outDir, name), json(value));
const log = (...args) => console.log(new Date().toISOString().slice(11, 19), ...args);
const cacheDir = path.join(homedir(), "dovel-act");
const result = { repoDir, startedAt: new Date().toISOString(), act: undefined, selection: undefined, jobs: [], errors: [] };

const t0 = Date.now();
try {
  result.act = process.env.ACT_BINARY ? { binary: process.env.ACT_BINARY, variant: "given" }
    : await m.provisionAct({ cacheDir, variant: process.env.ACT_VARIANT || "patched", fallbackToRelease: true });
} catch (error) { result.errors.push(`provisionAct: ${error.message}`); write("result.json", result); process.exit(0); }
result.act.provisionMs = Date.now() - t0;
log("act", JSON.stringify(result.act));

const selection = await m.selectCiJobs(repoDir, { limit: Number(process.env.JOB_LIMIT || 3) });
write("selection.json", selection);
result.selection = {
  selected: selection.selected.map(s => ({ workflow: s.workflow, job: s.job, event: s.event, matrixFilter: s.matrixFilter, needs: s.needs, services: s.services.length, usesDocker: s.usesDocker, score: s.score, testSteps: s.testSteps.map(t => `${t.jobId}/${t.stepId}: ${t.command}`), warnings: s.warnings })),
  ranked: selection.ranked.length, skipped: selection.skipped.length, problems: selection.problems,
};
log("selected", json(result.selection.selected.map(s => `${s.workflow} -j ${s.job} ${s.event} ${s.matrixFilter.join(" ")}`)));

const brief = run => run === undefined ? undefined : {
  exitCode: run.exitCode, timedOut: run.timedOut, minutes: +(run.durationMs / 60000).toFixed(2), errors: run.summary.errors, notes: run.notes,
  stderrTail: run.stderrTail.split("\n").slice(-15), services: run.services.map(s => `${s.spec.jobId}/${s.spec.id}: ${s.status}`), cleanupFailed: run.cleanup.failed,
  jobs: run.summary.jobs.map(job => ({ jobId: job.jobId, matrix: job.matrix, result: job.result, outputTail: job.result === "success" ? undefined : job.outputTail.slice(-10),
    steps: job.steps.filter(step => step.stage === "Main" && step.stepPath.length === 1).map(step => ({ stepId: step.stepId, name: step.name, result: step.result, test: step.isTestStep || undefined, testsRan: step.testsRan, testPackages: step.testPackages, injected: step.injected || undefined, minutes: step.durationMs === undefined ? undefined : +(step.durationMs / 60000).toFixed(2), tail: step.result === "failure" ? step.outputTail.slice(-25) : undefined })) })),
};

async function run(selected, phase, index) {
  log(`${phase} ${index}: ${selected.workflow} -j ${selected.job}`);
  let out;
  try {
    out = await m.runCiJob({ repoDir, workflow: selected.workflow, job: selected.job, event: selected.event, selection: selected, timeoutMs: Number(process.env.JOB_TIMEOUT_MIN || 60) * 60000, actBinary: result.act.binary, cacheDir, keepRunDir: true });
  } catch (error) { log(`${phase} ${index} threw`, error.stack); return { thrown: error.message }; }
  try {
    writeFileSync(path.join(outDir, `${phase}-${index}.act.jsonl.gz`), gzipSync(readFileSync(path.join(out.runDir, "act.jsonl"))));
  } catch (error) { log("no act.jsonl", error.message); }
  write(`${phase}-${index}.summary.json`, out.summary);
  await m.removeTree(out.runDir);
  log(`${phase} ${index}: exit ${out.exitCode} in ${(out.durationMs / 60000).toFixed(1)} min; jobs ${out.summary.jobs.map(j => `${j.jobId}=${j.result}`).join(", ")}`);
  return out;
}

const baselines = [];
for (const [index, selected] of selection.selected.entries()) baselines.push(await run(selected, "baseline", index));
// The candidate: an empty commit (new sha and event, same tree).
execFileSync("git", ["-C", repoDir, "-c", "user.name=Dovel", "-c", "user.email=dovel@users.noreply.github.com", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "--no-verify", "-m", "Dovel act check: no-op candidate"]);
for (const [index, selected] of selection.selected.entries()) {
  const baseline = baselines[index];
  const entry = { workflow: selected.workflow, job: selected.job, event: selected.event, matrixFilter: selected.matrixFilter, needs: selected.needs, testSteps: selected.testSteps.length };
  const usable = baseline.summary === undefined ? undefined : m.compareRuns(baseline.summary, baseline.summary);
  entry.baselineUsable = usable?.verdict !== "unusable" && usable !== undefined;
  entry.baseline = baseline.summary === undefined ? baseline : brief(baseline);
  if (entry.baselineUsable) {
    const candidate = await run(selected, "candidate", index);
    entry.candidate = candidate.summary === undefined ? candidate : brief(candidate);
    if (candidate.summary !== undefined) {
      const c = m.compareRuns(baseline.summary, candidate.summary);
      entry.comparison = { verdict: c.verdict, summary: c.summary, evidenceSteps: c.evidenceSteps, baselineTestsRan: c.baselineTestsRan, candidateTestsRan: c.candidateTestsRan, unusableReasons: c.unusableReasons, regressions: c.steps.filter(s => s.verdict === "regression").map(s => ({ jobId: s.jobId, name: s.name, reason: s.reason, tail: s.outputTail?.slice(-20) })), otherFailures: c.otherFailures.map(s => `${s.jobId}/${s.name}`) };
    }
  } else {
    entry.comparison = usable === undefined ? { verdict: "unusable", summary: "baseline run threw" } : { verdict: usable.verdict, summary: usable.summary, unusableReasons: usable.unusableReasons };
  }
  result.jobs.push(entry);
  write("result.json", result);
}
result.minutes = +((Date.now() - t0) / 60000).toFixed(1);
write("result.json", result);
log("done", result.minutes, "min");
