#!/bin/sh
# Build happy 1.16 and alex 2.1.0 with the MicroHs-hosted GHC 6.2.2.
# One stage-1 ghc at a time. Recipes: ghc66/happy116.nix, ghc66/alex210.nix.
# haskell98 is the non-hierarchical reexport library those tools import.
set -u

ROOT=/media/space/repos/GHC-MicroHs-bootstrap
REF=$ROOT/build/ref-ghc-bootstrap
W=$REF/build/ghc622-mhs
GHC=$W/ghc
TOP=$W/topdir
H98SRC=$ROOT/build/repro-622/src/ghc-6.2.2/libraries/haskell98
H98=$W/libraries/haskell98
INC=$ROOT/build/repro-622/ghc/includes
BASE=$W/libraries/base
GMP=$ROOT/build/gmp-6.1.2-prefix
WORK=$ROOT/build/happy116
HAPPY_SRC=$WORK/happy-1.16
ALEX_SRC=$ROOT/build/alex210/alex-2.1.0
SHIMS=$REF/ghc66/shims622
ALEX_SHIMS=$ROOT/build/alex210/shims
HAPPY119=$ROOT/build/bin/happy
FIX=$REF/ghc622/tools/fix-generated-parsers.sh
CMP=$REF/ghc66/cmp-generated.sh
CPP_TEMPLATE=$REF/ghc66/cpp-template.sh
HAPPY_PREFIX=$ROOT/build/happy-1.16-prefix
ALEX_PREFIX=$ROOT/build/alex-2.1.0-prefix
WRAP=$WORK/ghc
TMP=$WORK/tmp

export TMPDIR=$TMP
export LD_LIBRARY_PATH="$GMP/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
mkdir -p "$TMP" "$WORK/h98-logs" "$WORK/logs"
echo $$ > "$WORK/build.pid"
ulimit -s unlimited 2>/dev/null || ulimit -s 65536

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

if pgrep -f '/ghc622-mhs/ghc( |$)' >/dev/null 2>&1; then
	say "FAILED: another stage1 ghc is already running"
	exit 1
fi

say "STEP preflight"
"$GHC" +RTS -K8M -RTS -B"$TOP" --numeric-version
say "numeric-version above must be 6.2.2"

cat > "$WRAP" << EOF
#!/bin/sh
exec "$GHC" +RTS -K32M -H100M -RTS -B"$TOP" "\$@"
EOF
chmod +x "$WRAP"

# ---- parsers already produced by happy 1.19.5 (fix-generated-parsers applied)
if [ ! -f "$HAPPY_SRC/shipped/Parser.hs" ] || [ ! -f "$HAPPY_SRC/src/Parser.hs" ]; then
	say "FAILED: happy 1.16 parsers were not generated"
	exit 1
fi
say "STEP parsers present $(wc -l < "$HAPPY_SRC/src/Parser.hs") lines"

# ---- ghc -E, used by cpp-template.sh
say "STEP cpp smoke"
cat > "$TMP/cpp-smoke.hs" << 'EOF'
module CppSmoke where
x = 1
EOF
if ! "$WRAP" -o "$TMP/cpp-smoke.hspp" -E -cpp "$TMP/cpp-smoke.hs" > "$WORK/logs/cpp-smoke.log" 2>&1; then
	say "FAILED: ghc -E smoke failed"
	tail -20 "$WORK/logs/cpp-smoke.log"
	exit 1
fi
if ! grep -q 'x' "$TMP/cpp-smoke.hspp"; then
	say "FAILED: ghc -E produced no output"
	exit 1
fi
say "STEP cpp smoke OK"

# ---- haskell98 ----------------------------------------------------------
say "STEP haskell98 copy"
rm -rf "$H98"
mkdir -p "$H98/obj" "$WORK/h98-logs"
/bin/cp -f "$H98SRC"/*.hs "$H98/"

compile_h98() {
	mod=$1
	src=$H98/$mod.hs
	log=$WORK/h98-logs/$mod.log
	try_one() {
		: > "$log"
		timeout 1800 "$WRAP" -v1 -C -O -fglasgow-exts \
			-package-name haskell98 -package base -i. \
			"$@" "$src" > "$log" 2>&1
	}
	(
		cd "$H98" || exit 1
		try_one
		rc=$?
		if [ "$rc" -ne 0 ] && grep -q -e 'ERR: stack overflow' -e 'ERR: heap exhausted' "$log"; then
			say "STEP h98 $mod retry -fno-strictness"
			rm -f "$H98/$mod.hc" "$H98/$mod.hi"
			try_one -fno-strictness
			rc=$?
		fi
		if [ "$rc" -ne 0 ] && grep -q -e 'ERR: stack overflow' -e 'ERR: heap exhausted' "$log"; then
			say "STEP h98 $mod retry -Onot"
			rm -f "$H98/$mod.hc" "$H98/$mod.hi"
			timeout 1800 "$WRAP" -v1 -C -Onot -fglasgow-exts \
				-package-name haskell98 -package base -i. \
				"$src" > "$log" 2>&1
			rc=$?
		fi
		exit "$rc"
	)
}

skip_mod() {
	case "$1" in
	Directory|Time|CPUTime|Random) return 0 ;;
	*) return 1 ;;
	esac
}

say "STEP haskell98 compile"
cd "$H98"
for src in Ix.hs $(ls *.hs | grep -v '^Ix\.hs$'); do
	mod=${src%.hs}
	say "STEP h98 $mod start"
	start=$(date +%s)
	if compile_h98 "$mod"; then
		if [ -f "$H98/$mod.hc" ] && [ -f "$H98/$mod.hi" ]; then
			say "STEP h98 $mod hsOK $(( $(date +%s) - start ))s"
		else
			say "FAILED: h98 $mod produced no .hc/.hi"
			exit 1
		fi
	else
		if skip_mod "$mod"; then
			say "STEP h98 $mod SKIP (base dependency not built)"
			rm -f "$H98/$mod.hc" "$H98/$mod.hi"
			continue
		fi
		say "FAILED: h98 $mod compile"
		tail -30 "$WORK/h98-logs/$mod.log"
		exit 1
	fi
done

say "STEP haskell98 gcc"
okc=0
failc=0
for hc in "$H98"/*.hc; do
	[ -f "$hc" ] || continue
	base=$(basename "$hc" .hc)
	o="$H98/obj/$base.o"
	if gcc -c -x c -std=gnu89 -O -fwrapv -fno-pie -w \
		-DNO_REGS -DUSE_MINIINTERPRETER -D__GLASGOW_HASKELL__=602 \
		-I"$INC" -I"$BASE/include" -I"$BASE" \
		-include "$INC/Stg.h" "$hc" -o "$o" > "$WORK/h98-logs/$base.gcc" 2>&1
	then
		okc=$((okc + 1))
	else
		say "FAILED: gcc $base"
		tail -20 "$WORK/h98-logs/$base.gcc"
		exit 1
	fi
done
say "STEP haskell98 objects $okc"

for req in Ix Array Char List Maybe Monad System IO; do
	if [ ! -f "$H98/$req.hi" ] || [ ! -f "$H98/obj/$req.o" ]; then
		say "FAILED: required haskell98 module $req missing"
		exit 1
	fi
done

rm -f "$H98/libHShaskell98.a" "$W/lib/libHShaskell98.a"
ar rcs "$H98/libHShaskell98.a" "$H98"/obj/*.o
/bin/cp -f "$H98/libHShaskell98.a" "$W/lib/libHShaskell98.a"
say "STEP haskell98 ar $(ar t "$H98/libHShaskell98.a" | wc -l) objects"

# ---- package.conf -------------------------------------------------------
say "STEP package.conf"
python - "$TOP/package.conf" "$W/package.conf.with-h98" << 'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(os.path.realpath(src)).read()
if 'name           = "haskell98"' in text:
    open(dst, "w").write(text)
    sys.exit(0)
idx = text.rfind("]")
head = text[:idx].rstrip()
if not head.endswith("}"):
    sys.stderr.write("package.conf does not end with a package\n")
    sys.exit(1)
extra = '''
,
Package {
        name           = "haskell98",
        auto           = True,
        import_dirs    = [ "$libdir/libraries/haskell98" ],
        source_dirs    = [],
        library_dirs   = [ "$libdir/lib", "$libdir/libraries/haskell98" ],
        hs_libraries   = [ "HShaskell98" ],
        extra_libraries = [],
        include_dirs   = [],
        c_includes     = [],
        package_deps   = [ "base" ],
        extra_ghc_opts = [],
        extra_cc_opts  = ["-std=gnu89", "-fpermissive", "-w", "-fwrapv", "-fno-pie", "-include", "Stg.h"],
        extra_ld_opts  = ["-no-pie"]
}
'''
open(dst, "w").write(head + extra + "]\n")
PY
rm -f "$TOP/package.conf"
ln -s "$W/package.conf.with-h98" "$TOP/package.conf"
say "STEP package.conf linked"

# ---- smoke: List.intersperse, the name Data.Version's shim uses ----------
say "STEP h98 smoke"
SM=$WORK/smoke
rm -rf "$SM"
mkdir -p "$SM"
cat > "$SM/Main.hs" << 'EOF'
module Main where
import List (nub, intersperse)
main = do
  print (nub [1, 1, 2 :: Int])
  putStrLn (intersperse '.' "ab")
EOF
if ! ( cd "$SM" && "$WRAP" -v1 --make -o smoke Main.hs > "$WORK/logs/h98-smoke-compile.log" 2>&1 ); then
	say "FAILED: haskell98 smoke compile"
	tail -40 "$WORK/logs/h98-smoke-compile.log"
	exit 1
fi
if ! "$SM/smoke" > "$WORK/logs/h98-smoke.out" 2> "$WORK/logs/h98-smoke.err"; then
	say "FAILED: haskell98 smoke run"
	cat "$WORK/logs/h98-smoke.out" "$WORK/logs/h98-smoke.err"
	exit 1
fi
if ! grep -q '\[1,2\]' "$WORK/logs/h98-smoke.out" || ! grep -q 'a\.b' "$WORK/logs/h98-smoke.out"; then
	say "FAILED: haskell98 smoke output"
	cat "$WORK/logs/h98-smoke.out"
	exit 1
fi
say "STEP h98 smoke OK"

# ---- one --make, retrying the demand-analyser overflow -------------------
# $1 log  $2 srcdir  $3 objdir  $4 outfile  $5 main  remaining: ghc args
make_with() {
	log=$1
	dir=$2
	obj=$3
	out=$4
	main=$5
	shift 5
	mkdir -p "$obj"
	(
		cd "$dir" && timeout 21600 "$WRAP" -v1 --make \
			-cpp -fglasgow-exts "$@" \
			-odir "$obj" -hidir "$obj" \
			-o "$out" "$main"
	) > "$log" 2>&1
}

make_retry() {
	log=$1
	dir=$2
	obj=$3
	out=$4
	main=$5
	shift 5
	say "STEP make $(basename "$out") -O"
	if make_with "$log" "$dir" "$obj" "$out" "$main" -O "$@"; then
		return 0
	fi
	if grep -q -e 'ERR: stack overflow' -e 'ERR: heap exhausted' "$log"; then
		say "STEP make $(basename "$out") retry -fno-strictness"
		rm -rf "$obj"
		rm -f "$out"
		mkdir -p "$obj"
		if make_with "$log" "$dir" "$obj" "$out" "$main" -O -fno-strictness "$@"; then
			return 0
		fi
	fi
	if grep -q -e 'ERR: stack overflow' -e 'ERR: heap exhausted' "$log"; then
		say "STEP make $(basename "$out") retry -Onot"
		rm -rf "$obj"
		rm -f "$out"
		mkdir -p "$obj"
		if make_with "$log" "$dir" "$obj" "$out" "$main" -Onot "$@"; then
			return 0
		fi
	fi
	say "FAILED: make $(basename "$out")"
	tail -40 "$log"
	exit 1
}

# ---- happy templates ----------------------------------------------------
say "STEP happy templates"
(
	set -e
	cd "$HAPPY_SRC/templates"
	t() { sh "$CPP_TEMPLATE" "$WRAP" GenericTemplate.hs "$@"; }
	t HappyTemplate
	t HappyTemplate-ghc -DHAPPY_GHC
	t HappyTemplate-coerce -DHAPPY_GHC -DHAPPY_COERCE
	t HappyTemplate-arrays -DHAPPY_ARRAY
	t HappyTemplate-arrays-ghc -DHAPPY_ARRAY -DHAPPY_GHC
	t HappyTemplate-arrays-coerce -DHAPPY_ARRAY -DHAPPY_GHC -DHAPPY_COERCE
	t HappyTemplate-arrays-debug -DHAPPY_ARRAY -DHAPPY_DEBUG
	t HappyTemplate-arrays-ghc-debug -DHAPPY_ARRAY -DHAPPY_GHC -DHAPPY_DEBUG
	t HappyTemplate-arrays-coerce-debug -DHAPPY_ARRAY -DHAPPY_GHC -DHAPPY_COERCE -DHAPPY_DEBUG
) > "$WORK/logs/happy-templates.log" 2>&1 || {
	say "FAILED: happy templates"
	tail -30 "$WORK/logs/happy-templates.log"
	exit 1
}
n=$(ls "$HAPPY_SRC/templates"/HappyTemplate* | wc -l)
say "STEP happy templates $n"

cat > "$HAPPY_SRC/src/Paths_happy.hs" << EOF
module Paths_happy (version, getDataDir) where
import Data.Version
version :: Version
version = Version [1,16] []
getDataDir :: IO FilePath
getDataDir = return "$HAPPY_PREFIX/share/happy-1.16"
EOF

say "STEP happy build 1"
rm -rf "$HAPPY_SRC/obj-1"
mkdir -p "$HAPPY_SRC/obj-1"
make_retry "$WORK/logs/happy-build-1.log" "$HAPPY_SRC/src" "$HAPPY_SRC/obj-1" \
	"$HAPPY_SRC/happy-1" Main.lhs -i"$SHIMS" -i.
say "STEP happy build 1 OK"

say "STEP happy regen 1"
rm -rf "$HAPPY_SRC/gen1"
mkdir -p "$HAPPY_SRC/gen1"
for p in Parser AttrGrammarParser; do
	"$HAPPY_SRC/happy-1" -agc -t "$HAPPY_SRC/templates" \
		"$HAPPY_SRC/src/$p.ly" -o "$HAPPY_SRC/gen1/$p.hs" \
		> "$WORK/logs/happy-regen1-$p.log" 2>&1 || {
		say "FAILED: happy-1 regen $p"
		tail -20 "$WORK/logs/happy-regen1-$p.log"
		exit 1
	}
done
/bin/cp -f "$HAPPY_SRC/gen1/Parser.hs" "$HAPPY_SRC/gen1/AttrGrammarParser.hs" "$HAPPY_SRC/src/"

say "STEP happy build 2"
rm -rf "$HAPPY_SRC/obj-2"
mkdir -p "$HAPPY_SRC/obj-2"
make_retry "$WORK/logs/happy-build-2.log" "$HAPPY_SRC/src" "$HAPPY_SRC/obj-2" \
	"$HAPPY_SRC/happy-2" Main.lhs -i"$SHIMS" -i.
say "STEP happy build 2 OK"

say "STEP happy regen 2"
rm -rf "$HAPPY_SRC/gen2"
mkdir -p "$HAPPY_SRC/gen2"
for p in Parser AttrGrammarParser; do
	"$HAPPY_SRC/happy-2" -agc -t "$HAPPY_SRC/templates" \
		"$HAPPY_SRC/src/$p.ly" -o "$HAPPY_SRC/gen2/$p.hs" \
		> "$WORK/logs/happy-regen2-$p.log" 2>&1 || {
		say "FAILED: happy-2 regen $p"
		tail -20 "$WORK/logs/happy-regen2-$p.log"
		exit 1
	}
done

say "STEP happy fixed point"
sh "$CMP" "$HAPPY_SRC/gen1/Parser.hs" "$HAPPY_SRC/shipped/Parser.hs" \
	> "$WORK/logs/happy-cmp-shipped.log" 2>&1 || {
	say "FAILED: happy Parser.hs differs from the shipped file"
	cat "$WORK/logs/happy-cmp-shipped.log"
	exit 1
}
cmp "$HAPPY_SRC/gen1/Parser.hs" "$HAPPY_SRC/gen2/Parser.hs" || {
	say "FAILED: happy Parser fixed point"
	exit 1
}
cmp "$HAPPY_SRC/gen1/AttrGrammarParser.hs" "$HAPPY_SRC/gen2/AttrGrammarParser.hs" || {
	say "FAILED: happy AttrGrammarParser fixed point"
	exit 1
}
say "STEP happy fixed point OK"

rm -rf "$HAPPY_PREFIX"
mkdir -p "$HAPPY_PREFIX/bin" "$HAPPY_PREFIX/share/happy-1.16/generated"
/bin/cp -f "$HAPPY_SRC/happy-2" "$HAPPY_PREFIX/bin/happy"
chmod +x "$HAPPY_PREFIX/bin/happy"
/bin/cp -f "$HAPPY_SRC/templates"/HappyTemplate* "$HAPPY_PREFIX/share/happy-1.16/"
/bin/cp -f "$HAPPY_SRC/gen2"/*.hs "$HAPPY_PREFIX/share/happy-1.16/generated/"
if ! "$HAPPY_PREFIX/bin/happy" --version > "$WORK/logs/happy-version.log" 2>&1; then
	say "FAILED: happy --version"
	cat "$WORK/logs/happy-version.log"
	exit 1
fi
if ! grep -q 'Happy Version 1.16' "$WORK/logs/happy-version.log"; then
	say "FAILED: happy version string"
	cat "$WORK/logs/happy-version.log"
	exit 1
fi
say "STEP happy install OK"

# ---- alex ----------------------------------------------------------------
say "STEP alex templates"
(
	set -e
	cd "$ALEX_SRC/templates"
	t() { sh "$CPP_TEMPLATE" "$WRAP" "$@"; }
	t GenericTemplate.hs AlexTemplate
	t GenericTemplate.hs AlexTemplate-ghc -DALEX_GHC
	t GenericTemplate.hs AlexTemplate-ghc-debug -DALEX_GHC -DALEX_DEBUG
	t GenericTemplate.hs AlexTemplate-debug -DALEX_DEBUG
	t wrappers.hs AlexWrapper-basic -DALEX_BASIC
	t wrappers.hs AlexWrapper-posn -DALEX_POSN
	t wrappers.hs AlexWrapper-monad -DALEX_MONAD
	t wrappers.hs AlexWrapper-gscan -DALEX_GSCAN
) > "$WORK/logs/alex-templates.log" 2>&1 || {
	say "FAILED: alex templates"
	tail -30 "$WORK/logs/alex-templates.log"
	exit 1
}
say "STEP alex templates OK"

cat > "$ALEX_SRC/src/Paths_alex.hs" << EOF
module Paths_alex (version, getDataDir) where
import Data.Version
version :: Version
version = Version [2,1,0] []
getDataDir :: IO FilePath
getDataDir = return "$ALEX_PREFIX/share/alex-2.1.0"
EOF

mkdir -p "$ALEX_SRC/shipped"
if [ ! -f "$ALEX_SRC/shipped/Parser.hs" ]; then
	/bin/mv -f "$ALEX_SRC/src/Parser.hs" "$ALEX_SRC/src/Scan.hs" "$ALEX_SRC/shipped/"
fi
say "STEP alex happy parser"
"$HAPPY_PREFIX/bin/happy" -agc "$ALEX_SRC/src/Parser.y" -o "$ALEX_SRC/src/Parser.hs" \
	> "$WORK/logs/alex-happy.log" 2>&1 || {
	say "FAILED: happy 1.16 on alex Parser.y"
	tail -30 "$WORK/logs/alex-happy.log"
	exit 1
}
/bin/cp -f "$ALEX_SRC/shipped/Scan.hs" "$ALEX_SRC/src/Scan.hs"

say "STEP alex build 1"
rm -rf "$ALEX_SRC/obj-1"
mkdir -p "$ALEX_SRC/obj-1"
make_retry "$WORK/logs/alex-build-1.log" "$ALEX_SRC/src" "$ALEX_SRC/obj-1" \
	"$ALEX_SRC/alex-1" Main.hs -i"$SHIMS" -i"$ALEX_SHIMS" -i. -I"$INC"
say "STEP alex build 1 OK"

say "STEP alex regen 1"
rm -rf "$ALEX_SRC/gen1"
mkdir -p "$ALEX_SRC/gen1"
(
	cd "$ALEX_SRC/src" && ../alex-1 -t ../templates Scan.x -o ../gen1/Scan.hs
) > "$WORK/logs/alex-regen1.log" 2>&1 || {
	say "FAILED: alex-1 regen"
	tail -30 "$WORK/logs/alex-regen1.log"
	exit 1
}
/bin/cp -f "$ALEX_SRC/gen1/Scan.hs" "$ALEX_SRC/src/Scan.hs"

say "STEP alex build 2"
rm -rf "$ALEX_SRC/obj-2"
mkdir -p "$ALEX_SRC/obj-2"
make_retry "$WORK/logs/alex-build-2.log" "$ALEX_SRC/src" "$ALEX_SRC/obj-2" \
	"$ALEX_SRC/alex-2" Main.hs -i"$SHIMS" -i"$ALEX_SHIMS" -i. -I"$INC"
say "STEP alex build 2 OK"

say "STEP alex regen 2"
rm -rf "$ALEX_SRC/gen2"
mkdir -p "$ALEX_SRC/gen2"
(
	cd "$ALEX_SRC/src" && ../alex-2 -t ../templates Scan.x -o ../gen2/Scan.hs
) > "$WORK/logs/alex-regen2.log" 2>&1 || {
	say "FAILED: alex-2 regen"
	tail -30 "$WORK/logs/alex-regen2.log"
	exit 1
}

say "STEP alex fixed point"
sh "$CMP" "$ALEX_SRC/src/Parser.hs" "$ALEX_SRC/shipped/Parser.hs" \
	> "$WORK/logs/alex-cmp-parser.log" 2>&1 || {
	say "FAILED: alex Parser.hs differs from shipped"
	cat "$WORK/logs/alex-cmp-parser.log"
	exit 1
}
sh "$CMP" "$ALEX_SRC/gen1/Scan.hs" "$ALEX_SRC/shipped/Scan.hs" \
	> "$WORK/logs/alex-cmp-scan.log" 2>&1 || {
	say "FAILED: alex Scan.hs differs from shipped"
	cat "$WORK/logs/alex-cmp-scan.log"
	exit 1
}
cmp "$ALEX_SRC/gen1/Scan.hs" "$ALEX_SRC/gen2/Scan.hs" || {
	say "FAILED: alex Scan fixed point"
	exit 1
}
say "STEP alex fixed point OK"

rm -rf "$ALEX_PREFIX"
mkdir -p "$ALEX_PREFIX/bin" "$ALEX_PREFIX/share/alex-2.1.0/generated"
/bin/cp -f "$ALEX_SRC/alex-2" "$ALEX_PREFIX/bin/alex"
chmod +x "$ALEX_PREFIX/bin/alex"
/bin/cp -f "$ALEX_SRC/templates"/AlexTemplate* "$ALEX_SRC/templates"/AlexWrapper* \
	"$ALEX_PREFIX/share/alex-2.1.0/"
/bin/cp -f "$ALEX_SRC/gen2/Scan.hs" "$ALEX_SRC/src/Parser.hs" \
	"$ALEX_PREFIX/share/alex-2.1.0/generated/"
if ! "$ALEX_PREFIX/bin/alex" --version > "$WORK/logs/alex-version.log" 2>&1; then
	say "FAILED: alex --version"
	cat "$WORK/logs/alex-version.log"
	exit 1
fi
if ! grep -q 'Alex version 2.1.0' "$WORK/logs/alex-version.log"; then
	say "FAILED: alex version string"
	cat "$WORK/logs/alex-version.log"
	exit 1
fi
say "STEP alex install OK"
say "TOOLS_OK happy 1.16 and alex 2.1.0"
