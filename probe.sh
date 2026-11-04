#!/bin/bash
# Spike: does "atime older than mtime, then check" detect real reads by language loaders,
# on the workspace and inside overlays like Dovel's isolate.sh (default mount options)?
set -u
OUT=${OUT:-/tmp/probe-out}; mkdir -p "$OUT"
log(){ echo "$*" | tee -a "$OUT/result.txt"; }
mark(){ for f in "$@"; do touch -a -d '@1' "$f"; done; }        # atime=1970, mtime unchanged
readp(){ local f=$1; local a m; a=$(stat -c %X "$f"); m=$(stat -c %Y "$f"); [ "$a" -gt "$m" ] && echo READ || echo unread; }
where=$1   # label of the location under test
base=$2    # directory to create fixtures in
log "== location: $where ($base) mount: $(findmnt -no FSTYPE,OPTIONS -T "$base" | head -1)"
mkdir -p "$base/p" && cd "$base/p" || exit 1
if [ "${PHASE:-all}" != check ]; then
# Node
mkdir -p node_modules/dep && echo 'module.exports=()=>42' > node_modules/dep/index.js && echo '{"name":"dep","main":"index.js"}' > node_modules/dep/package.json
echo 'module.exports=1' > node_modules/dep/unused.js
# Python (+ precompiled pyc so the loader may read pyc instead of py)
mkdir -p site/dep && echo 'def f(): return 42' > site/dep/__init__.py && echo 'X=1' > site/dep/unused.py
PYTHONPATH=site python3 -c 'import dep' ; # creates __pycache__
# JVM jar
mkdir -p jv && cat > jv/Dep.java <<'J'
public class Dep { public static int f(){ return 42; } }
J
cat > jv/Main.java <<'J'
public class Main { public static void main(String[] a){ System.out.println(Dep.f()); } }
J
(cd jv && javac Dep.java && jar cf dep.jar Dep.class && rm Dep.class && javac -cp dep.jar Main.java)
# Cargo (path dependency stands in for a registry crate's source)
cargo new -q --lib depc && echo 'pub fn f()->i32{42}' > depc/src/lib.rs && echo 'pub fn g(){}' > depc/src/unused_mod.rs
cargo new -q app && echo 'depc = { path = "../depc" }' >> app/Cargo.toml && echo 'fn main(){ println!("{}", depc::f()); }' > app/src/main.rs
# Go module in a module cache style dir
mkdir -p gomod/dep && (cd gomod/dep && go mod init example.com/dep >/dev/null 2>&1 && echo 'package dep; func F() int { return 42 }' > dep.go)
mkdir -p gomod/app && (cd gomod/app && go mod init example.com/app >/dev/null 2>&1 && go mod edit -require example.com/dep@v0.0.0 -replace example.com/dep=../dep && printf 'package main\nimport ("fmt";"example.com/dep")\nfunc main(){fmt.Println(dep.F())}\n' > main.go)
[ "${PHASE:-all}" = setup ] && exit 0
fi
sleep 2
PYC=$(ls site/dep/__pycache__/__init__*.pyc)
mark node_modules/dep/index.js node_modules/dep/unused.js site/dep/__init__.py "$PYC" site/dep/unused.py jv/dep.jar depc/src/lib.rs depc/src/unused_mod.rs gomod/dep/dep.go
sleep 2
node -e 'require("./node_modules/dep")()' >/dev/null
PYTHONPATH=site python3 -c 'import dep; dep.f()'
(cd jv && java -cp dep.jar:. Main >/dev/null)
(cd app && cargo build -q 2>/dev/null)
(cd gomod/app && GOFLAGS=-mod=mod go build -o /dev/null . 2>&1 | tail -2)
log "node require index.js:   $(readp node_modules/dep/index.js)   (control unused.js: $(readp node_modules/dep/unused.js))"
log "python import __init__.py: $(readp site/dep/__init__.py)  pyc: $(readp "$PYC")  (control unused.py: $(readp site/dep/unused.py))"
log "jvm classload dep.jar:   $(readp jv/dep.jar)"
log "cargo build lib.rs:      $(readp depc/src/lib.rs)   (control unused_mod.rs: $(readp depc/src/unused_mod.rs))"
log "go build dep.go:         $(readp gomod/dep/dep.go)"
