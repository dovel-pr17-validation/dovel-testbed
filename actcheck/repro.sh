#!/usr/bin/env bash
# Reproduces the two act v0.2.89 host-mode bugs the patch fixes, with a given act binary.
# Usage: repro.sh <act-binary> <out-dir>. Prints one line per case: "<case> bug-present|bug-absent <detail>".
# Exit 0 always; the caller compares the outcomes of the stock and the patched binary.
set -uo pipefail
ACT="$1"; OUT="$2"; mkdir -p "$OUT"
GHCFG=$(mktemp -d)
run_act() { # <name> <repo-dir> <extra act args...>
  local name="$1" dir="$2"; shift 2
  ( cd "$dir" && env -i PATH="$PATH" HOME="$HOME" GH_CONFIG_DIR="$GHCFG" RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
      timeout 15m "$ACT" push -W .github/workflows/repro.yml \
      -P ubuntu-latest=-self-hosted --json --action-cache-path "$OUT/$name-cache" "$@" ) \
    > "$OUT/$name.jsonl" 2> "$OUT/$name.stderr"
  echo $?
}
job_result() { # <name> <jobID> -> success|failure|none
  python3 - "$OUT/$1.jsonl" "$2" <<'PY'
import json,sys
res="none"
for line in open(sys.argv[1], errors="replace"):
    try: e=json.loads(line)
    except Exception: continue
    if e.get("jobID")==sys.argv[2] and e.get("jobResult"): res=e["jobResult"]
print(res)
PY
}
mkrepo() { # <dir>
  rm -rf "$1"; mkdir -p "$1/.github/workflows"; git -C "$1" init -q -b main
  git -C "$1" remote add origin https://github.com/dovel-pr17-validation/dovel-testbed.git
}
commit() { git -C "$1" add -A && git -C "$1" -c user.name=r -c user.email=r@r commit -q -m repro; }

# 1. A job leaves read-only trees in its workspace (a Go module cache) and RUNNER_TEMP: act's removal of
#    <action-cache>/<rand>/ fails ("unlinkat ...: permission denied") and the job it needs never runs.
R1="$OUT/repo-readonly"; mkrepo "$R1"
cat > "$R1/.github/workflows/repro.yml" <<'YML'
on: push
jobs:
  fill:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Go module cache in the workspace
        run: |
          set -e
          mkdir -p "$RUNNER_TEMP/mod" && cd "$RUNNER_TEMP/mod" && go mod init example.com/repro >/dev/null 2>&1
          GOMODCACHE="$GITHUB_WORKSPACE/gomodcache" GOFLAGS= go mod download golang.org/x/sync@v0.20.0
          find "$GITHUB_WORKSPACE/gomodcache" -maxdepth 4 -type d ! -perm -u+w | head -3
      - name: Read-only tree in RUNNER_TEMP
        run: mkdir -p "$RUNNER_TEMP/ro/a" && echo x > "$RUNNER_TEMP/ro/a/f" && chmod -R a-w "$RUNNER_TEMP/ro"
  after:
    needs: fill
    runs-on: ubuntu-latest
    steps:
      - run: echo the needing job ran
YML
echo hi > "$R1/README"; commit "$R1"
rc=$(run_act readonly "$R1")
fill=$(job_result readonly fill); after=$(job_result readonly after)
unlink=$(grep -c "permission denied" "$OUT/readonly.stderr" "$OUT/readonly.jsonl" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
leftover=$(find "$OUT/readonly-cache" -mindepth 1 -maxdepth 1 -regextype egrep -regex '.*/[0-9a-f]{16}' 2>/dev/null | wc -l)
if [ "$rc" = 0 ] && [ "$fill" = success ] && [ "$after" = success ] && [ "$leftover" = 0 ]; then s=bug-absent; else s=bug-present; fi
echo "readonly $s exit=$rc fill=$fill after=$after permission-denied-lines=$unlink leftover-scratch-dirs=$leftover"
chmod -R u+w "$OUT/readonly-cache" 2>/dev/null || true

# 2. A checkout with a symbolic link copied twice (two actions/checkout steps, or a composite action that
#    checks out): the second copy fails with "symlink ...: file exists"; a regular file the job changed in
#    between keeps the tail of the longer content (no O_TRUNC).
R2="$OUT/repo-symlink"; mkrepo "$R2"
cat > "$R2/.github/workflows/repro.yml" <<'YML'
on: push
jobs:
  twice:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: test -L link && test "$(cat link)" = short && echo "a much longer content than before" > data.txt
      - uses: actions/checkout@v4
      - name: Second copy restored the checkout
        run: test -L link && test "$(cat data.txt)" = short
YML
echo short > "$R2/data.txt"; ln -s data.txt "$R2/link"; commit "$R2"
rc=$(run_act symlink "$R2")
twice=$(job_result symlink twice)
exists=$(grep -c "file exists" "$OUT/symlink.stderr" "$OUT/symlink.jsonl" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
if [ "$rc" = 0 ] && [ "$twice" = success ]; then s=bug-absent; else s=bug-present; fi
echo "symlink $s exit=$rc job=$twice file-exists-lines=$exists"

# 3. Every step runs on a pseudo-terminal whose stdin never ends: a step that prompts only on a terminal
#    (add-apt-repository without -y) waits forever. GitHub gives a step no terminal and an empty stdin.
R3="$OUT/repo-tty"; mkrepo "$R3"
cat > "$R3/.github/workflows/repro.yml" <<'YML'
on: push
jobs:
  prompt:
    runs-on: ubuntu-latest
    steps:
      - name: No terminal, stdin at EOF
        run: |
          if [ -t 0 ] || [ -t 1 ]; then echo "on a terminal"; exit 1; fi
          if timeout 10 sh -c 'read -r line'; then echo "read a line?"; else rc=$?; [ "$rc" = 124 ] && { echo "stdin never ended"; exit 1; }; fi
          echo "no terminal, empty stdin"
YML
echo hi > "$R3/README"; commit "$R3"
rc=$(run_act tty "$R3")
prompt=$(job_result tty prompt)
if [ "$rc" = 0 ] && [ "$prompt" = success ]; then s=bug-absent; else s=bug-present; fi
echo "tty $s exit=$rc job=$prompt"

# 4. ACT=true reaches every step's process (GitHub sets none; setup-php then takes the runner for self-hosted);
#    expressions must still see it.
R4="$OUT/repo-actenv"; mkrepo "$R4"
cat > "$R4/.github/workflows/repro.yml" <<'YML'
on: push
jobs:
  env:
    runs-on: ubuntu-latest
    steps:
      - name: The process has no ACT
        run: test -z "${ACT:-}"
      - name: Expressions still see ACT
        if: ${{ env.ACT }}
        run: echo "expression saw ACT"
YML
echo hi > "$R4/README"; commit "$R4"
rc=$(run_act actenv "$R4")
saw=$(grep -c "expression saw ACT" "$OUT/actenv.jsonl" 2>/dev/null || true)
if [ "$rc" = 0 ] && [ "$(job_result actenv env)" = success ] && [ "${saw:-0}" -gt 0 ]; then s=bug-absent; else s=bug-present; fi
echo "actenv $s exit=$rc expression-lines=${saw:-0}"

# 5. A docker:// step in host mode joined the network of a job container that does not exist.
R5="$OUT/repo-dockerstep"; mkrepo "$R5"
cat > "$R5/.github/workflows/repro.yml" <<'YML'
on: push
jobs:
  docker:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker://alpine:3.20
        with: { args: "sh -c 'echo docker-step-ok; ls /github/workspace'" }
YML
echo hi > "$R5/README"; commit "$R5"
rc=$(run_act dockerstep "$R5")
seen=$(grep -c "README" "$OUT/dockerstep.jsonl" 2>/dev/null || true)
if [ "$rc" = 0 ] && [ "$(job_result dockerstep docker)" = success ]; then s=bug-absent; else s=bug-present; fi
echo "dockerstep $s exit=$rc workspace-visible=${seen:-0}"

# 6. A local action in a job without a checkout (GitHub's $/, given to act as ./): act reads it from the job's
#    checkout copy, which is empty.
R6="$OUT/repo-selfaction"; mkrepo "$R6"
mkdir -p "$R6/.github/actions/leaf"
printf 'runs:\n  using: composite\n  steps:\n    - run: echo leaf-ok\n      shell: bash\n' > "$R6/.github/actions/leaf/action.yml"
cat > "$R6/.github/workflows/repro.yml" <<'YML'
on: push
jobs:
  self:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/leaf
YML
commit "$R6"
rc=$(run_act selfaction "$R6")
if [ "$rc" = 0 ] && [ "$(job_result selfaction self)" = success ]; then s=bug-absent; else s=bug-present; fi
echo "selfaction $s exit=$rc"
