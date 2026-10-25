#!/usr/bin/env bash
# Runs one repository job with nektos/act on this runner. Input: ENTRY (one JSON object of act-repos.json).
set -uo pipefail
J() { python3 -c 'import json,os,sys;v=json.loads(os.environ["ENTRY"])[sys.argv[1]];print(v if not isinstance(v,list) else "\n".join(v))' "$1"; }
ID=$(J id); SRC=$(J source); SHA=$(J sha); BRANCH=$(J branch); WF=$(J workflow); JOB=$(J job); EVENT=$(J event); MODE=$(J mode)
OUT="$GITHUB_WORKSPACE/out/$ID"; mkdir -p "$OUT"
echo "$ENTRY" > "$OUT/entry.json"
SRCDIR="$HOME/spike-src"; rm -rf "$SRCDIR"
t0=$(date +%s)
if [ -z "$SRC" ]; then
  cp -r "$GITHUB_WORKSPACE/spike/probe" "$SRCDIR"; cd "$SRCDIR"
  git init -q -b main && git add -A
  for m in probe1 probe2; do git -c user.email=p@p -c user.name=p commit -q --allow-empty -m "$m"; done
  git remote add origin https://github.com/dovel-pr17-validation/dovel-testbed.git
  SHA=$(git rev-parse HEAD); SRC=dovel-pr17-validation/dovel-testbed
else
  git clone -q --filter=blob:none --no-checkout "https://github.com/$SRC.git" "$SRCDIR" && cd "$SRCDIR" && git checkout -q -B "$BRANCH" "$SHA" || { echo '{"harness_error":"clone"}' > "$OUT/summary.json"; exit 0; }
  if [ -f .gitmodules ]; then git submodule update -q --init --recursive || echo "submodule fetch failed" >> "$OUT/harness.log"; fi
fi
PARENT=$(git rev-parse "$SHA^" 2>/dev/null || echo 0000000000000000000000000000000000000000)
t1=$(date +%s)
python3 - "$EVENT" "$SRC" "$SHA" "$PARENT" "$BRANCH" > "$OUT/event.json" <<'PY'
import json,sys
ev,src,sha,parent,branch=sys.argv[1:]
owner,name=src.split('/')
repo={"full_name":src,"name":name,"owner":{"login":owner,"name":owner},"default_branch":branch,"private":False,"fork":False,"html_url":f"https://github.com/{src}","clone_url":f"https://github.com/{src}.git"}
if ev=="push":
    e={"ref":f"refs/heads/{branch}","before":parent,"after":sha,"repository":repo,"head_commit":{"id":sha,"message":"spike"},"commits":[{"id":sha}],"pusher":{"name":"spike"},"sender":{"login":"spike"}}
else:
    e={"action":"synchronize","number":1,"pull_request":{"number":1,"draft":False,"state":"open","title":"spike","labels":[],"head":{"sha":sha,"ref":"spike","repo":repo},"base":{"sha":parent,"ref":branch,"repo":repo},"user":{"login":"spike"}},"repository":repo,"sender":{"login":"spike"}}
print(json.dumps(e))
PY
MATRIX_ARGS=(); while IFS= read -r m; do [ -n "$m" ] && MATRIX_ARGS+=(--matrix "${m/=/:}"); done < <(J matrix)
if [ "$MODE" = container ]; then IMG=catthehacker/ubuntu:act-24.04; else IMG=-self-hosted; fi
PLAT=(); for l in ubuntu-latest ubuntu-24.04 ubuntu-22.04 ubuntu-20.04; do PLAT+=(-P "$l=$IMG"); done
# Environment for act: the runner image's environment minus anything credential-like or runner-internal.
ENVARGS=()
while IFS= read -r kv; do ENVARGS+=("$kv"); done < <(python3 - <<'PY'
import os,re
drop=re.compile(r'^(GITHUB_|ACTIONS_|INPUT_|STATE_|RUNNER_|ENTRY$|CI$)|TOKEN|SECRET|PASSWORD|CREDENTIAL|_KEY$')
for k,v in os.environ.items():
    if k in ('RUNNER_TOOL_CACHE','RUNNER_OS','RUNNER_ARCH') or not drop.search(k):
        if '\n' not in v: print(f"{k}={v}")
PY
)
printf '%s\n' "${ENVARGS[@]}" | cut -d= -f1 | sort > "$OUT/act-env-names.txt"
echo "act $EVENT -W $WF -j $JOB ${MATRIX_ARGS[*]} ${PLAT[*]}" > "$OUT/cmd.txt"
env -i "${ENVARGS[@]}" timeout 105m act "$EVENT" -W "$WF" -j "$JOB" "${MATRIX_ARGS[@]}" "${PLAT[@]}" \
  -e "$OUT/event.json" --json --artifact-server-path "$HOME/act-artifacts" \
  --action-cache-path "$HOME/act-action-cache" --env RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
  > "$OUT/act.jsonl" 2> "$OUT/act.stderr"
rc=$?
t2=$(date +%s)
cd "$GITHUB_WORKSPACE"
python3 spike/summarize.py "$OUT" "$rc" "$((t1-t0))" "$((t2-t1))" > "$OUT/summary.json" || echo '{"harness_error":"summarize"}' > "$OUT/summary.json"
cat "$OUT/summary.json" | head -c 4000
gzip -9 "$OUT/act.jsonl" 2>/dev/null || true
exit 0
