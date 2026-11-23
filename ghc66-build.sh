#!/bin/bash
# Cold bootstrap of GHC 6.6 from packaged MicroHs. No prebuilt Haskell
# compiler is an input. Repeatable order:
#   happy 1.19.5 (mhs) -> reproduce the 6.2.2 tree -> RTS -> stage1 ghc
#   -> libraries/base -> happy 1.16 and alex 2.1.0 -> GHC 6.6
# The kit is a git archive of the bootstrap repo plus ghc66-worktree.patch.
# GMP and the C compiler recorded by GHC 6.6 are the paths the rpm occupies.
set -euo pipefail

ROOT=${1:?usage: ghc66-build.sh ROOT LIBDIR}
LIBDIR=${2:?}
IN=$ROOT/incoming
R=$ROOT/build/ref-ghc-bootstrap
W=$R/build/ghc622-mhs
GMP_PREFIX=$LIBDIR/gmp612
HOST_GCC=$LIBDIR/ghc-6.6/bin/host-gcc
MHS=$LIBDIR/mhs

export STAGE=$ROOT
export GMP_PREFIX HOST_GCC
export TMPDIR=$ROOT/tmp
export GHC_BOOTSTRAP_ROOT=$R
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS RPM_OPT_FLAGS RPM_LD_FLAGS || true
ulimit -s unlimited 2>/dev/null || true

phase() { printf 'GHC66PKG_PHASE %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { printf 'GHC66PKG_FAILED: %s\n' "$*" >&2; exit 1; }

sha_ok() {
	local file=$1 expect=$2 got
	got=$(sha256sum "$file" | awk '{print $1}')
	[ "$got" = "$expect" ] || fail "sha256 $file is $got"
}

[ -f "$MHS/lib/Prelude.hs" ] || fail "mhs Prelude missing under $MHS/lib"
[ -f "$MHS/mhs.conf" ] || fail "mhs.conf missing under $MHS"
[ -x "$MHS/bin/mhs" ] || fail "mhs binary missing"
[ -d "$MHS/src/runtime" ] || fail "mhs runtime missing"
[ -x /usr/bin/cpphs-mhs ] || fail "cpphs-mhs missing"
[ -f "$GMP_PREFIX/lib/libgmp.a" ] || fail "static libgmp.a missing"
[ -f "$GMP_PREFIX/include/gmp.h" ] || fail "gmp.h missing"
[ ! -e "$LIBDIR/ghc-6.6/ghc-6.6" ] && [ ! -e "$LIBDIR/ghc-6.6/bin/ghc" ] && [ ! -e "$LIBDIR/ghc-6.6/ghc" ] || fail "live $LIBDIR/ghc-6.6 already has a compiler"
if [ -d "$LIBDIR/ghc-6.6" ] && [ ! -f "$LIBDIR/ghc-6.6/.omv-bootstrap-hostgcc" ]; then
	fail "live $LIBDIR/ghc-6.6 exists and is not a bootstrap marker directory"
fi

rm -rf "$ROOT/build" "$ROOT/dest"
mkdir -p "$ROOT/tmp" "$ROOT/build/bin" "$ROOT/dest/bin" "$ROOT/dest/libexec" "$ROOT/dest/share" "$R"

phase "unpack kit"
tar -xzf "$IN/ghc66-bootstrap-kit.tar.gz" -C "$R"
[ -f "$R/ghc622/reproduce-6.2.2.sh" ] || fail "kit missing reproduce-6.2.2.sh"
[ -f "$R/build/ghc622-mhs/build.sh" ] || fail "kit missing stage1 build.sh"
phase "apply worktree patch"
(
	cd "$R"
	out=$(patch -p1 -N -i "$IN/ghc66-worktree.patch" 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
	case "$out" in
	*fuzz*|*offset*) printf '%s\n' "$out" >&2; exit 1 ;;
	esac
)
grep -q '@GMP_LIB@' "$R/ghc622/base/topdir/package.conf" || fail "package.conf lost @GMP_LIB@"
sed -i "s|@GMP_LIB@|$GMP_PREFIX/lib|g" "$R/ghc622/base/topdir/package.conf"
grep -q '@GMP_LIB@' "$R/ghc622/base/topdir/package.conf" && fail "@GMP_LIB@ remains"
chmod 755 "$R/ghc622/reproduce-6.2.2.sh" "$R/build/ghc622-mhs/build.sh" \
	"$R/build/ghc622-mhs/run-base.sh" "$R/build/ghc622-mhs/build-hc.sh" \
	"$R/build/ghc622-mhs/build-cbits.sh" "$R/build/ghc622-mhs/build-libbase.sh" \
	"$R/build/hsc2hs-mhs/build.sh" "$R/build/hsc2hs-mhs/hsc2hs" \
	"$R/ghc622/tools/"*.sh "$R/ghc66/"*.sh

# Packaged mhs is inplace. A real directory so bin/cpphs can be linked
# beside the compiler without writing into the rpm tree.
mkdir -p "$R/MicroHs/bin"
ln -sfn "$MHS/bin/mhs" "$R/MicroHs/bin/mhs"
ln -sfn /usr/bin/cpphs-mhs "$R/MicroHs/bin/cpphs"
ln -sfn "$MHS/src" "$R/MicroHs/src"
ln -sfn "$MHS/lib" "$R/MicroHs/lib"
ln -sfn "$MHS/mhs.conf" "$R/MicroHs/mhs.conf"
ln -sfn "$R/MicroHs" "$ROOT/build/mhs-hugs-src"
unset MHSDIR || true
export MHSDIR=$R/MicroHs

cat > "$ROOT/build/bin/cc" << 'EOF'
#!/bin/sh
exec /usr/bin/gcc "$@"
EOF
chmod 755 "$ROOT/build/bin/cc"
export PATH="$ROOT/build/bin:$R/MicroHs/bin:$PATH"
hash -r

sha_ok "$IN/ghc-6.2.2-src.tar.bz2" a0fe7eb8d447f25fbc616cdbce2bb4e03961a884c2c37969d1e23588b588a852
sha_ok "$IN/ghc-6.6-src.tar.bz2" 79b2a29136d56c8120a526188297603304dc80d3093cda76fde939df7d4dcc7e
sha_ok "$IN/happy-1.19.5.tar.gz" 62f03ac11d7b4b9913f212f5aa2eee1087f3b46dc07d799d41e1854ff02843da
sha_ok "$IN/happy-1.16.tar.gz" 4da47f4904dbdddfb58140edb0395383feba72dfc77759e57587a526dd9496c5
sha_ok "$IN/alex-2.1.0.tar.gz" 0b9c1246ca6ef27df4bfcb16d13cf7525d943ba2edc897d628605e1c9bd7d58b
/bin/cp -f "$IN/ghc-6.2.2-src.tar.bz2" "$R/ghc-6.2.2-src.tar.bz2"

phase "happy 1.19.5 via mhs"
HM=$ROOT/build/happy-mhs-src
rm -rf "$HM"
mkdir -p "$HM"
tar -xzf "$IN/happy-1.19.5.tar.gz" -C "$HM"
HS=$HM/happy-1.19.5
mkdir -p "$HS/datadir"
cpphs --noline "$HS/templates/GenericTemplate.hs" > "$HS/datadir/HappyTemplate"
/bin/cp -f "$R/happy/happy-seed/"*.hs "$HS/src/"
(
	cd "$HS"
	export HAPPY_DATADIR=$HS/datadir
	mhs -XCPP -i"$R/happy/noglr" -i"$R/common/shims" -i"$R/happy/shim" -isrc Main -ohappy.c
	/usr/bin/gcc -w -O1 -I"$MHSDIR/src/runtime" -I"$MHSDIR/src/runtime/unix" \
		"$MHSDIR/src/runtime/main.c" "$MHSDIR/src/runtime/eval.c" happy.c -lm -o happy-mhs2
	mkdir -p regen
	for p in Parser AttrGrammarParser; do
		( cd src && ../happy-mhs2 "$p.ly" -o "../regen/$p.hs" )
		cmp "regen/$p.hs" "src/$p.hs"
	done
)
mkdir -p "$R/build/happy-mhs/datadir" "$ROOT/dest/share/happy1195-mhs"
/bin/cp -f "$HS/happy-mhs2" "$R/build/happy-mhs/happy-mhs2"
/bin/cp -f "$HS/datadir/HappyTemplate" "$R/build/happy-mhs/datadir/HappyTemplate"
/bin/cp -f "$HS/happy-mhs2" "$ROOT/dest/libexec/happy1195-mhs"
/bin/cp -f "$HS/datadir/HappyTemplate" "$ROOT/dest/share/happy1195-mhs/HappyTemplate"
chmod 755 "$R/build/happy-mhs/happy-mhs2" "$ROOT/dest/libexec/happy1195-mhs"
ln -sfn "$R/build/happy-mhs/happy-mhs2" "$ROOT/build/bin/happy"
phase "happy-mhs fixpoint ok"

phase "reproduce ghc 6.2.2"
# Do not create build/ghc-6.2.2-run1 before this returns. Step 10 diffs
# against that tree when it already exists.
sh "$R/ghc622/reproduce-6.2.2.sh" "$R/build/repro-622"
[ -d "$R/build/repro-622/ghc/compiler" ] || fail "reproduce left no compiler tree"
[ -x "$R/build/repro-622/tools/genprimopcode/genprimopcode" ] || fail "genprimopcode missing"
mkdir -p "$R/build/ghc-6.2.2-run1"
ln -sfn "$R/build/repro-622/ghc" "$R/build/ghc-6.2.2-run1/ghc"
ln -sfn "$R/build/repro-622" "$ROOT/build/repro-622"
phase "reproduce done"

phase "rts"
RTS=$R/build/rts622/ghc-6.2.2
rm -rf "$R/build/rts622"
mkdir -p "$RTS/ghc"
/bin/cp -a "$R/build/repro-622/src/ghc-6.2.2/ghc/rts" "$R/build/repro-622/src/ghc-6.2.2/ghc/includes" "$RTS/ghc/"
chmod -R u+w "$RTS"
(
	cd "$RTS"
	for p in "$R"/ghc622/rts/patches/*.patch; do
		out=$(patch -p1 -N -i "$p" 2>&1) || { printf '%s\n' "$out" >&2; echo "FAILED: $p" >&2; exit 1; }
		case "$out" in *fuzz*|*offset*) printf '%s\n' "$out" >&2; echo "INEXACT: $p" >&2; exit 1 ;; esac
	done
)
GA=$R/build/rts622/genapply-work
rm -rf "$GA"
mkdir -p "$GA"
(
	cd "$GA"
	/bin/cp -f "$R/build/repro-622/src/ghc-6.2.2/ghc/utils/genapply/GenApply.hs" GenApply.hs
	# mhs takes -I and -i glued to the path. A bare -I is passed to
	# cpphs with no directory, and a bare -i clears the module path,
	# so the following arguments become extra modules and mhs prints
	# its usage. Same form as build/rts622/genapply/build-genapply.sh.
	mhs -XCPP -D__GLASGOW_HASKELL__=622 -DNO_REGS \
		-I"$R/build/repro-622/src/ghc-6.2.2/ghc/utils/genapply" \
		-i. -i"$R/ghc622/rts/genapply-shim" \
		GenApply.hs -ogenapply
	./genapply > "$RTS/AutoApply.hc"
)
[ -s "$RTS/AutoApply.hc" ] || fail "AutoApply.hc empty"
obj=$R/build/rts622/obj
mkdir -p "$obj"
rts_flags=(-std=gnu89 -O -w -fno-pie -DNO_REGS -DUSE_MINIINTERPRETER -DCOMPILING_RTS \
	-D__GLASGOW_HASKELL__=622 -I"$RTS/ghc/includes" -I"$RTS/ghc/rts" -I"$RTS/ghc/rts/parallel" \
	-I"$GMP_PREFIX/include")
count=0
shopt -s nullglob
for src in "$RTS"/ghc/rts/*.c "$RTS"/ghc/rts/hooks/*.c "$RTS"/ghc/rts/parallel/*.c; do
	base=$(basename "$src" .c)
	case "$base" in
	RtsDllMain|SysMan|Vis*) continue ;;
	esac
	gcc -c "${rts_flags[@]}" "$src" -o "$obj/$base.o"
	count=$((count + 1))
done
for src in "$RTS"/ghc/rts/*.hc "$RTS"/ghc/rts/parallel/*.hc "$RTS/AutoApply.hc"; do
	base=$(basename "$src" .hc)
	gcc -c -x c "${rts_flags[@]}" -include "$RTS/ghc/includes/Stg.h" "$src" -o "$obj/$base.o"
	count=$((count + 1))
done
shopt -u nullglob
count=$(find "$obj" -name '*.o' | wc -l)
count=$(printf '%s' "$count" | tr -d '[:space:]')
[ "$count" = 78 ] || fail "RTS object count $count, want 78"
mkdir -p "$W/topdir/rts"
ar rcs "$W/topdir/rts/libHSrts.a" "$obj"/*.o
phase "rts 78 objects"

phase "stage1"
export TREE622=$R/build/repro-622/src/ghc-6.2.2
sh "$R/build/ghc622-mhs/build.sh" all
[ -x "$W/ghc" ] || fail "stage1 ghc missing"

phase "topdir and base"
mkdir -p "$W/topdir" "$W/libraries" "$W/lib" "$W/tmp"
/bin/cp -f "$R/ghc622/base/topdir/package.conf" "$W/topdir/package.conf"
/bin/cp -f "$R/ghc622/base/topdir/ghc-usage.txt" "$W/topdir/ghc-usage.txt"
gcc -std=gnu89 -Wno-implicit-int -Wno-implicit-function-declaration -include string.h \
	"$R/build/repro-622/src/ghc-6.2.2/ghc/utils/unlit/unlit.c" -o "$W/topdir/unlit"
ln -sfn "$R/build/ghc-6.2.2-run1/ghc/includes" "$W/topdir/includes"
ln -sfn ../libraries "$W/topdir/libraries"
ln -sfn ../lib "$W/topdir/lib"
rm -rf "$W/libraries/base"
/bin/cp -a "$R/build/repro-622/src/ghc-6.2.2/libraries/base" "$W/libraries/base"
chmod -R u+w "$W/libraries/base"
"$R/build/repro-622/tools/genprimopcode/genprimopcode" --make-haskell-wrappers \
	< "$R/build/repro-622/src/ghc-6.2.2/ghc/compiler/prelude/primops.txt" \
	> "$W/libraries/base/GHC/PrimopWrappers.hs"
[ -s "$W/libraries/base/GHC/PrimopWrappers.hs" ] || fail "PrimopWrappers empty"

mkdir -p "$R/build/hsc2hs-mhs/ghc"
ln -sfn "$R/build/ghc-6.2.2-run1/ghc/includes" "$R/build/hsc2hs-mhs/ghc/includes"
sh "$R/build/hsc2hs-mhs/build.sh"
[ -x "$R/build/hsc2hs-mhs/hsc2hs-bin" ] || fail "hsc2hs-bin missing"
[ -f "$R/build/hsc2hs-mhs/template-hsc.h" ] || fail "template-hsc.h missing"
(
	cd "$W/libraries/base"
	for src in System/CPUTime.hsc System/Time.hsc System/Posix/Signals.hsc Text/Regex/Posix.hsc; do
		GHC_BOOTSTRAP_ROOT=$R "$R/build/hsc2hs-mhs/hsc2hs" \
			-Iinclude -I"$R/build/ghc-6.2.2-run1/ghc/includes" -I. "$src"
		[ -s "${src%.hsc}.hs" ] || fail "hsc2hs wrote empty $src"
	done
)

sh "$R/ghc622/tools/base-rebuild-order.sh" "$W/libraries/base" \
	"$R/build/ghc-6.2.2-run1/ghc/includes" \
	"$R/ghc622/base/after-hsc2hs.txt" > "$W/base-order.txt"
order_n=$(grep -c . "$W/base-order.txt")
[ "$order_n" = 147 ] || fail "base order has $order_n lines, want 147"

base_status() {
	BASE=$W/libraries/base TSV=$W/base-results.tsv FAILS=$W/base-fails.txt python - << 'PY'
import os, sys
base = os.environ["BASE"]
last = {}
for line in open(os.environ["TSV"], encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 2 and parts[1]:
        last[parts[1]] = parts[0]
fails = [m for m, s in last.items() if s != "OK"]
print("base_mods %s" % len(last))
print("base_fail %s" % len(fails))
open(os.environ["FAILS"], "w").write("".join(m + "\n" for m in fails))
for m in fails:
    rel = os.path.join(base, m.replace(".", "/"))
    for ext in (".hc", ".hi"):
        p = rel + ext
        if os.path.exists(p):
            os.remove(p)
sys.exit(0 if len(last) == 147 else 2)
PY
}

phase "run-base -O"
MHSRTS="+RTS -K64M -H64M -RTS" FRESH=1 OPT=-O MODTIMEOUT=7200 \
	sh "$R/build/ghc622-mhs/run-base.sh" "$W/base-order.txt"
base_status
fail_n=$(grep -c . "$W/base-fails.txt" || true)
if [ "${fail_n:-0}" != 0 ]; then
	phase "run-base -Onot for $fail_n modules"
	MHSRTS="+RTS -K64M -H64M -RTS" FRESH=0 OPT=-Onot MODTIMEOUT=7200 \
		sh "$R/build/ghc622-mhs/run-base.sh" "$W/base-order.txt"
	base_status
	fail_n=$(grep -c . "$W/base-fails.txt" || true)
	[ "${fail_n:-0}" = 0 ] || fail "base still failing: $(tr '\n' ' ' < "$W/base-fails.txt")"
fi
phase "base 147 ok"

# build-hc and build-cbits exit 0 on a partial failure. Reject that.
cat > "$ROOT/build/bin/cc-gmp" << EOF
#!/bin/bash
link=1
for a in "\$@"; do
	case "\$a" in
	-c|-E|-S|-M|-MM|-shared|--version|-dumpversion) link=0 ;;
	esac
done
args=(-I"$GMP_PREFIX/include" -fno-pie "\$@")
if [ "\$link" = 1 ]; then
	args+=(-L"$GMP_PREFIX/lib" -no-pie -Wl,-rpath,"$GMP_PREFIX/lib")
fi
exec /usr/bin/gcc "\${args[@]}"
EOF
chmod 755 "$ROOT/build/bin/cc-gmp"
phase "build-hc"
CC=$ROOT/build/bin/cc-gmp sh "$R/build/ghc622-mhs/build-hc.sh" > "$ROOT/tmp/build-hc.out"
cat "$ROOT/tmp/build-hc.out"
if grep -q '^failed:' "$ROOT/tmp/build-hc.out"; then
	fail "build-hc reported failures"
fi
phase "build-cbits"
CC=$ROOT/build/bin/cc-gmp sh "$R/build/ghc622-mhs/build-cbits.sh" > "$ROOT/tmp/build-cbits.out"
cat "$ROOT/tmp/build-cbits.out"
if grep -q '^failed:' "$ROOT/tmp/build-cbits.out"; then
	fail "build-cbits reported failures"
fi
sh "$R/build/ghc622-mhs/build-libbase.sh"
[ -f "$W/lib/libHSbase.a" ] || fail "libHSbase.a missing"
[ -f "$W/lib/libHSbase_cbits.a" ] || fail "libHSbase_cbits.a missing"
ver=$("$W/ghc" +RTS -K64M -RTS -B"$W/topdir" --numeric-version | tr -d '[:space:]')
[ "$ver" = "6.2.2" ] || fail "stage1 numeric-version '$ver'"
phase "stage1 6.2.2"

phase "prep happy 1.16 and alex 2.1.0"
rm -rf "$ROOT/build/happy116" "$ROOT/build/alex210"
mkdir -p "$ROOT/build/happy116" "$ROOT/build/alex210/shims/System"
tar -xzf "$IN/happy-1.16.tar.gz" -C "$ROOT/build/happy116"
tar -xzf "$IN/alex-2.1.0.tar.gz" -C "$ROOT/build/alex210"
HAPPY_SRC=$ROOT/build/happy116/happy-1.16
mkdir -p "$HAPPY_SRC/shipped"
/bin/cp -f "$HAPPY_SRC/src/Parser.hs" "$HAPPY_SRC/src/AttrGrammarParser.hs" "$HAPPY_SRC/shipped/"
for p in Parser AttrGrammarParser; do
	HAPPY_DATADIR=$R/build/happy-mhs/datadir \
		"$R/build/happy-mhs/happy-mhs2" "$HAPPY_SRC/src/$p.ly" -o "$HAPPY_SRC/src/$p.hs"
done
sh "$R/ghc622/tools/fix-generated-parsers.sh" \
	"$HAPPY_SRC/src/Parser.hs" "$HAPPY_SRC/src/AttrGrammarParser.hs"
/bin/cp -f "$IN/alex-Directory.hs" "$ROOT/build/alex210/shims/System/Directory.hs"
[ -f "$HAPPY_SRC/shipped/Parser.hs" ] && [ -f "$HAPPY_SRC/src/Parser.hs" ] || fail "happy parsers missing"

python - "$IN/happy116-build.sh" "$ROOT/build/happy116-build.sh" << 'PY'
import sys
src, dst = sys.argv[1:]
text = open(src, encoding="utf-8").read()
repls = [
    ("ROOT=/media/space/repos/GHC-MicroHs-bootstrap\n", "ROOT=${STAGE:?}\n"),
    ("GMP=$ROOT/build/gmp-6.1.2-prefix\n", "GMP=${GMP_PREFIX:?}\n"),
    ('getDataDir = return "$HAPPY_PREFIX/share/happy-1.16"\n',
     'getDataDir = return "/usr/share/happy-1.16"\n'),
    ('getDataDir = return "$ALEX_PREFIX/share/alex-2.1.0"\n',
     'getDataDir = return "/usr/share/alex-2.1.0"\n'),
]
for old, new in repls:
    n = text.count(old)
    if n != 1:
        sys.exit("happy116 adapt count %s for %r" % (n, old[:40]))
    text = text.replace(old, new, 1)
if "/media/space" in text:
    sys.exit("happy116 still mentions /media/space")
open(dst, "w", encoding="utf-8").write(text)
PY
chmod 755 "$ROOT/build/happy116-build.sh"
phase "happy116"
bash "$ROOT/build/happy116-build.sh"
[ -x "$ROOT/build/happy-1.16-prefix/bin/happy" ] || fail "happy 1.16 missing"
[ -x "$ROOT/build/alex-2.1.0-prefix/bin/alex" ] || fail "alex 2.1.0 missing"

plant_share() {
	local src=$1 live=$2 rel=$3
	if [ -e "$live" ]; then
		if [ -f "$live/.omv-bootstrap-datadir" ]; then
			rm -rf "$live"
		else
			fail "refusing to replace $live without the bootstrap marker"
		fi
	fi
	mkdir -p "$live" "$ROOT/dest/$rel"
	/bin/cp -a "$src"/. "$live"/
	/bin/cp -a "$src"/. "$ROOT/dest/$rel"/
	touch "$live/.omv-bootstrap-datadir"
	rm -f "$ROOT/dest/$rel/.omv-bootstrap-datadir"
}
plant_share "$ROOT/build/happy-1.16-prefix/share/happy-1.16" /usr/share/happy-1.16 share/happy-1.16
plant_share "$ROOT/build/alex-2.1.0-prefix/share/alex-2.1.0" /usr/share/alex-2.1.0 share/alex-2.1.0
/bin/cp -f "$ROOT/build/happy-1.16-prefix/bin/happy" "$ROOT/dest/bin/happy116"
/bin/cp -f "$ROOT/build/alex-2.1.0-prefix/bin/alex" "$ROOT/dest/bin/alex210"
chmod 755 "$ROOT/dest/bin/happy116" "$ROOT/dest/bin/alex210"
file "$ROOT/dest/bin/happy116" | grep -q ELF || fail "happy116 is not an ELF"
file "$ROOT/dest/bin/alex210" | grep -q ELF || fail "alex210 is not an ELF"

phase "adapt ghc 6.6 bootstrap"
mkdir -p "$LIBDIR/ghc-6.6"
touch "$LIBDIR/ghc-6.6/.omv-bootstrap-hostgcc"
mkdir -p "$ROOT/build/ghc66-work/src"
tar -xjf "$IN/ghc-6.6-src.tar.bz2" -C "$ROOT/build/ghc66-work/src"
[ -d "$ROOT/build/ghc66-work/src/ghc-6.6" ] || fail "ghc 6.6 unpack failed"
python - "$IN/ghc66-bootstrap.sh" "$ROOT/build/ghc66-bootstrap.sh" << 'PY'
import sys
src, dst = sys.argv[1:]
text = open(src, encoding="utf-8").read()
repls = [
    ("ROOT=/media/space/repos/GHC-MicroHs-bootstrap\n", "ROOT=${STAGE:?}\n"),
    ("GMP=$ROOT/build/gmp-6.1.2-prefix\n", "GMP=${GMP_PREFIX:?}\n"),
    ('export CC="$WORK/bin/gcc"\n', 'export CC="${HOST_GCC:?}"\n'),
    ('--with-gcc="$WORK/bin/gcc"', '--with-gcc="${HOST_GCC:?}"'),
    ('chmod +x "$WORK/bin/gcc"\n',
     'chmod +x "$WORK/bin/gcc"\n'
     'mkdir -p "$(dirname "$HOST_GCC")"\n'
     '/bin/cp -f "$WORK/bin/gcc" "$HOST_GCC"\n'
     'chmod 755 "$HOST_GCC"\n'),
]
for old, new in repls:
    n = text.count(old)
    if n != 1:
        sys.exit("bootstrap adapt count %s for %r" % (n, old[:48]))
    text = text.replace(old, new, 1)
if "/media/space" in text:
    sys.exit("bootstrap still mentions /media/space")
open(dst, "w", encoding="utf-8").write(text)
PY
chmod 755 "$ROOT/build/ghc66-bootstrap.sh"
phase "ghc 6.6"
bash "$ROOT/build/ghc66-bootstrap.sh"

PREFIX=$ROOT/build/ghc66-work/ghc66-prefix
python - "$ROOT" "$PREFIX" "$HOST_GCC" "$ROOT/dest" << 'PY'
import os, shutil, sys
root, prefix, host_gcc, dest = sys.argv[1:]
lib = os.path.join(prefix, "lib", "ghc-6.6")
if not os.path.isdir(lib):
    sys.exit("no lib/ghc-6.6 under %s" % prefix)
os.makedirs(os.path.join(lib, "bin"), exist_ok=True)
shutil.copy(host_gcc, os.path.join(lib, "bin", "host-gcc"))
os.chmod(os.path.join(lib, "bin", "host-gcc"), 0o755)
work = os.path.join(root, "build", "ghc66-work")
work_gcc = os.path.join(work, "bin", "gcc")
for dirpath, dirnames, filenames in os.walk(lib):
    for name in filenames:
        path = os.path.join(dirpath, name)
        if name == "package.cache":
            os.remove(path)
            continue
        if not (name.endswith(".conf") or name in ("package.conf", "settings") or name.endswith(".hs") or name.endswith(".sh")):
            continue
        try:
            text = open(path, encoding="utf-8", errors="surrogateescape").read()
        except IsADirectoryError:
            continue
        if lib not in text and prefix not in text and work_gcc not in text and work not in text:
            continue
        text = text.replace(work_gcc, host_gcc)
        text = text.replace(lib, "$topdir")
        text = text.replace(prefix, "/usr")
        text = text.replace(work, "/usr")
        open(path, "w", encoding="utf-8", errors="surrogateescape").write(text)
bad = []
needles = (prefix, work, "/media/space", "@GMP_LIB@")
for dirpath, dirnames, filenames in os.walk(lib):
    for name in filenames:
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        try:
            data = open(path, "rb").read()
        except IsADirectoryError:
            continue
        hit = [n for n in needles if n.encode() in data]
        if hit:
            bad.append("%s (%s)" % (path, ",".join(hit)))
if bad:
    sys.exit("build path remains:\n" + "\n".join(bad[:20]))
out = os.path.join(dest, "lib", "ghc-6.6")
if os.path.isdir(out):
    shutil.rmtree(out)
shutil.copytree(lib, out, symlinks=True)
PY
[ -x "$ROOT/dest/lib/ghc-6.6/bin/host-gcc" ] || fail "dest host-gcc missing"
[ -x "$ROOT/dest/lib/ghc-6.6/ghc-6.6" ] || fail "dest ghc ELF missing"
file "$ROOT/dest/lib/ghc-6.6/ghc-6.6" | grep -q ELF || fail "ghc-6.6 is not an ELF"
# The stock bin/ghc-6.6 shell script bakes the build prefix. Do not ship it.
rm -rf "$ROOT/dest/bin/ghc-6.6" "$ROOT/dest/bin/ghc" || true
phase "GHC66PKG_DONE"
printf 'GHC66PKG_DONE %s\n' "$ROOT/dest/lib/ghc-6.6/ghc-6.6"
