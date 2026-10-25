"""Markdown table of act-module-check results: one row per selected job. Usage: summarize.py <dir with <name>/result.json>"""
import json, os, sys
root = sys.argv[1]
rows, repos = [], 0
usable_jobs = total_jobs = passes = 0
for name in sorted(os.listdir(root)):
    f = os.path.join(root, name, "result.json")
    if not os.path.exists(f):
        rows.append(f"| {name} | (no result) | | | | | |"); continue
    repos += 1
    r = json.load(open(f))
    act = r.get("act") or {}
    if not r.get("jobs"):
        rows.append(f"| {name} | (none selected; {(r.get('selection') or {}).get('skipped','?')} skipped) {'; '.join(r.get('errors', []))} | | | | | |")
    for j in r.get("jobs", []):
        total_jobs += 1
        b = j.get("baseline") or {}
        c = j.get("candidate") or {}
        cmp = j.get("comparison") or {}
        tests = [s for job in b.get("jobs", []) for s in job.get("steps", []) if s.get("test")]
        tp = sum(1 for s in tests if s.get("result") == "success")
        if j.get("baselineUsable"): usable_jobs += 1
        if cmp.get("verdict") == "pass": passes += 1
        why = cmp.get("summary", "")
        if cmp.get("verdict") != "pass":
            fails = [f"{job['jobId']}/{s['name']}" for job in b.get("jobs", []) for s in job.get("steps", []) if s.get("result") == "failure" and not s.get("injected")]
            if fails: why += " — failed: " + ", ".join(fails[:3])
            if b.get("errors"): why += " — act: " + b["errors"][-1][:160]
        mins = f"{b.get('minutes','?')}+{c.get('minutes','-')}"
        leg = " ".join(j.get("matrixFilter") or [])
        rows.append(f"| {name} | `{j['workflow'].split('/')[-1]}` -j {j['job']} {j['event']} {leg} | {'yes' if j.get('baselineUsable') else 'no'} | {tp}/{j.get("testSteps", len(tests))} | {cmp.get('verdict','?')} | {mins} | {why.replace('|','/')[:400]} |")
print(f"**{repos} repos, {total_jobs} selected jobs, {usable_jobs} usable baselines, {passes} pass verdicts**\n")
print("| repo | job | usable | test steps passed (baseline) | verdict | min (base+cand) | notes |")
print("|---|---|---|---|---|---|---|")
print("\n".join(rows))
