#!/bin/bash
# Present the in-chain GHC 6.2.2 as a bootstrap compiler and build GHC 6.6
# unregisterised via C. One MicroHs-hosted ghc at a time. Re-runnable.
set -euo pipefail

ROOT=/media/space/repos/GHC-MicroHs-bootstrap
R=$ROOT/build/ref-ghc-bootstrap
W=$R/build/ghc622-mhs
WORK=$ROOT/build/ghc66-work
INST=$WORK/ghc622-inst
BASE=$W/libraries/base
H98=$W/libraries/haskell98
INC=$R/build/ghc-6.2.2-run1/ghc/includes
GMP=$ROOT/build/gmp-6.1.2-prefix
GHC=$W/ghc
TOP=$W/topdir
HAPPY=$ROOT/build/happy-1.16-prefix/bin/happy
ALEX=$ROOT/build/alex-2.1.0-prefix/bin/alex
TREE=$WORK/src/ghc-6.6
PREFIX=$WORK/ghc66-prefix

export GHC_BOOTSTRAP_ROOT=$R
export MHSDIR=$ROOT/build/mhs-hugs-src
export TMPDIR=$WORK/tmp
export LD_LIBRARY_PATH="$GMP/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
mkdir -p "$TMPDIR" "$WORK/logs" "$WORK/bin" "$INST/bin" "$INST/libraries/parsec"

exec 9>"$WORK/bootstrap.lock"
flock -n 9 || { printf 'GHC66_FAILED: another bootstrap holds %s\n' "$WORK/bootstrap.lock"; exit 1; }

phase() { printf 'GHC66_PHASE %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { printf 'GHC66_FAILED: %s\n' "$*"; exit 1; }
errline() {
	grep -E 'ERR:|error:|Error:|unrecognised|not in scope|Not in scope|Failed' "$1" 2>/dev/null | tail -4 | tr '\n' ' ' | cut -c1-400
}

if pgrep -f '/ghc622-mhs/ghc( |$)' >/dev/null 2>&1; then
	fail "stage1 ghc already running"
fi
printf '%s\n' "$$" > "$WORK/bootstrap.pid"
ulimit -s unlimited 2>/dev/null || true
phase "start pid $$"

# The bootstrap compiler is the MicroHs-hosted 6.2.2. +RTS sizes are cells
# (decimal K/M), not the GHC RTS. -Onot is appended so a later -O from
# 6.6's makefiles cannot turn demand analysis back on.
ghc_run() {
	timeout "${1:?timeout}" "$GHC" +RTS -K64M -H200M -RTS -B"$TOP" "${@:2}"
}

ver=$(ghc_run 60 --numeric-version | tr -d '[:space:]')
[ "$ver" = "6.2.2" ] || fail "numeric-version is '$ver'"
phase "compiler 6.2.2"

# ---- hsc2hs (mhs; do not overlap with stage1 ghc) ------------------------
if [ ! -x "$R/build/hsc2hs-mhs/hsc2hs-bin" ]; then
	phase "hsc2hs build"
	mkdir -p "$R/build/hsc2hs-mhs/ghc"
	ln -sfn "$INC" "$R/build/hsc2hs-mhs/ghc/includes"
	if ! sh "$R/build/hsc2hs-mhs/build.sh" > "$WORK/logs/hsc2hs-build.log" 2>&1; then
		fail "hsc2hs build: $(errline "$WORK/logs/hsc2hs-build.log")"
	fi
fi
[ -f "$R/build/hsc2hs-mhs/template-hsc.h" ] || fail "template-hsc.h missing"
phase "hsc2hs $($R/build/hsc2hs-mhs/hsc2hs-bin --version | tr '\n' ' ')"

# ---- generate the four .hsc modules --------------------------------------
phase "hsc generate"
(
	cd "$BASE"
	for src in System/CPUTime.hsc System/Time.hsc System/Posix/Signals.hsc Text/Regex/Posix.hsc; do
		out="${src%.hsc}.hs"
		if [ -f "$out" ] && [ "$out" -nt "$src" ]; then
			continue
		fi
		if ! GHC_BOOTSTRAP_ROOT="$R" "$R/build/hsc2hs-mhs/hsc2hs" \
			-Iinclude -I"$INC" -I. "$src" > "$WORK/logs/hsc-$(basename "$src" .hsc).log" 2>&1
		then
			fail "hsc2hs $src: $(errline "$WORK/logs/hsc-$(basename "$src" .hsc).log")"
		fi
		[ -s "$out" ] || fail "hsc2hs wrote empty $out"
	done
)
phase "hsc generate done"

# ---- compile the seven base modules with stage1 --------------------------
compile_base() {
	mod=$1
	rel=$(printf '%s' "$mod" | tr . /)
	src=""
	if [ -f "$BASE/$rel.hs" ]; then src="$rel.hs"; else fail "no source for $mod"; fi
	obj="$W/hcobj/$(printf '%s' "$mod" | tr . _).o"
	log="$WORK/logs/base-$mod.log"
	if [ -f "$BASE/$rel.hi" ] && [ -f "$obj" ] && [ "$BASE/$rel.hi" -nt "$BASE/$src" ]; then
		phase "base $mod cached"
		return 0
	fi
	phase "base $mod"
	try() {
		# shellcheck disable=SC2086
		( cd "$BASE" && ghc_run 2400 -v1 -C \
			-fglasgow-exts -cpp -Iinclude '-#include' HsBase.h -funbox-strict-fields \
			-package-name base "$@" "$src" > "$log" 2>&1 )
	}
	rm -f "$BASE/$rel.hc" "$BASE/$rel.hi"
	if ! try -O; then
		if grep -q -e 'ERR: stack overflow' -e 'ERR: heap exhausted' "$log"; then
			phase "base $mod retry -fno-strictness"
			rm -f "$BASE/$rel.hc" "$BASE/$rel.hi"
			if ! try -O -fno-strictness; then
				phase "base $mod retry -Onot"
				rm -f "$BASE/$rel.hc" "$BASE/$rel.hi"
				try -Onot || fail "base $mod: $(errline "$log")"
			fi
		else
			fail "base $mod: $(errline "$log")"
		fi
	fi
	[ -f "$BASE/$rel.hc" ] && [ -f "$BASE/$rel.hi" ] || fail "base $mod produced no .hc/.hi"
	if ! gcc -c -x c -std=gnu89 -O -fwrapv -w -fmax-errors=20 \
		-DNO_REGS -DUSE_MINIINTERPRETER -D__GLASGOW_HASKELL__=622 \
		-I"$INC" -I"$BASE/include" -I"$BASE" -include "$INC/Stg.h" \
		"$BASE/$rel.hc" -o "$obj" > "$WORK/logs/base-$mod.gcc" 2>&1
	then
		fail "gcc $mod: $(errline "$WORK/logs/base-$mod.gcc")"
	fi
	ar r "$W/lib/libHSbase.a" "$obj" > /dev/null
	ranlib "$W/lib/libHSbase.a"
	phase "base $mod object $(wc -c < "$obj") bytes"
}

while read -r mod; do
	[ -n "$mod" ] || continue
	compile_base "$mod"
done < "$R/build/hsc2hs-mhs/hsc-order.txt"

# ---- haskell98 reexports ---------------------------------------------------
# 6.6's compiler imports the Haskell 98 names (Time, Directory). 6.2.2's
# base only has the hierarchical modules, so the reexport has to be compiled
# into the auto haskell98 package before stage 1.
compile_h98() {
	mod=$1
	log="$WORK/logs/h98-$mod.log"
	if [ -f "$H98/$mod.hi" ] && [ -f "$H98/obj/$mod.o" ]; then
		phase "h98 $mod cached"
		return 0
	fi
	phase "h98 $mod"
	rm -f "$H98/$mod.hc" "$H98/$mod.hi"
	if ! ( cd "$H98" && ghc_run 1800 -v1 -C -O -fglasgow-exts \
		-package-name haskell98 -package base -i. "$mod.hs" > "$log" 2>&1 )
	then
		if grep -q -e 'ERR: stack overflow' -e 'ERR: heap exhausted' "$log"; then
			phase "h98 $mod retry -Onot"
			rm -f "$H98/$mod.hc" "$H98/$mod.hi"
			( cd "$H98" && ghc_run 1800 -v1 -C -Onot -fglasgow-exts \
				-package-name haskell98 -package base -i. "$mod.hs" > "$log" 2>&1 ) \
				|| fail "h98 $mod: $(errline "$log")"
		else
			fail "h98 $mod: $(errline "$log")"
		fi
	fi
	mkdir -p "$H98/obj"
	gcc -c -x c -std=gnu89 -O -fwrapv -fno-pie -w \
		-DNO_REGS -DUSE_MINIINTERPRETER -D__GLASGOW_HASKELL__=602 \
		-I"$INC" -I"$BASE/include" -I"$BASE" -include "$INC/Stg.h" \
		"$H98/$mod.hc" -o "$H98/obj/$mod.o" > "$WORK/logs/h98-$mod.gcc" 2>&1 \
		|| fail "gcc $mod: $(errline "$WORK/logs/h98-$mod.gcc")"
	ar r "$H98/libHShaskell98.a" "$H98/obj/$mod.o" > /dev/null
	ranlib "$H98/libHShaskell98.a"
	/bin/cp -f "$H98/libHShaskell98.a" "$W/lib/libHShaskell98.a"
	phase "h98 $mod in archive"
}

for mod in Directory Time Random CPUTime; do
	compile_h98 "$mod"
done

# ---- side packages, parsec, ghc-pkg, wrapper -----------------------------
sh "$R/ghc622/tools/side-package-conf.sh" "$INST" > "$INST/package.conf"
grep -q "$INST/libraries/parsec" "$INST/package.conf"

cat > "$INST/bin/ghc" <<EOF
#!/bin/bash
ulimit -s unlimited 2>/dev/null || true
export LD_LIBRARY_PATH="$GMP/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$GHC" +RTS -K64M -H200M -RTS -B"$TOP" -package-conf "$INST/package.conf" "\$@" -Onot -fno-strictness
EOF
chmod +x "$INST/bin/ghc"
ln -sfn ghc "$INST/bin/ghc-6.2.2"

phase "parsec"
PO=$INST/libraries/parsec
PSRC=$R/build/repro-622/src/ghc-6.2.2/libraries/parsec
nhi=$(find "$PO" -name '*.hi' 2>/dev/null | wc -l)
if [ ! -f "$PO/libHSparsec.a" ] || [ "$nhi" -ne 10 ]; then
	rm -rf "$PO"
	mkdir -p "$PO"
	plog="$WORK/logs/parsec.log"
	if ! ( cd "$PSRC" && ghc_run 2400 -v1 --make -O -fglasgow-exts -package-name parsec \
		-odir "$PO" -hidir "$PO" \
		Text/ParserCombinators/Parsec.hs Text/ParserCombinators/Parsec/*.hs \
		> "$plog" 2>&1 )
	then
		if grep -q -e 'ERR: stack overflow' -e 'ERR: heap exhausted' "$plog"; then
			phase "parsec retry -fno-strictness"
			rm -rf "$PO"; mkdir -p "$PO"
			( cd "$PSRC" && ghc_run 2400 -v1 --make -O -fno-strictness -fglasgow-exts \
				-package-name parsec -odir "$PO" -hidir "$PO" \
				Text/ParserCombinators/Parsec.hs Text/ParserCombinators/Parsec/*.hs \
				> "$plog" 2>&1 ) || fail "parsec: $(errline "$plog")"
		else
			fail "parsec: $(errline "$plog")"
		fi
	fi
	( cd "$PO" && find . -name '*.o' | sort | xargs ar rcs libHSparsec.a && find . -name '*.o' -delete )
fi
nhi=$(find "$PO" -name '*.hi' | wc -l)
[ "$nhi" -eq 10 ] || fail "parsec hi count $nhi"
phase "parsec 10 modules"

phase "ghc-pkg"
PKGSRC=$R/build/repro-622/src/ghc-6.2.2/ghc/utils/ghc-pkg
if [ ! -x "$INST/bin/ghc-pkg.bin" ]; then
	rm -rf "$WORK/ghc-pkg-obj"
	mkdir -p "$WORK/ghc-pkg-obj"
	glog="$WORK/logs/ghc-pkg.log"
	if ! ghc_run 2400 -v1 --make -cpp -DPKG_TOOL -DWANT_PRETTY -O -I"$PKGSRC" -i"$PKGSRC" \
		-odir "$WORK/ghc-pkg-obj" -hidir "$WORK/ghc-pkg-obj" \
		-o "$INST/bin/ghc-pkg.bin" "$PKGSRC/Main.hs" > "$glog" 2>&1
	then
		if grep -q -e 'ERR: stack overflow' -e 'ERR: heap exhausted' "$glog"; then
			phase "ghc-pkg retry -fno-strictness"
			rm -rf "$WORK/ghc-pkg-obj"; mkdir -p "$WORK/ghc-pkg-obj"
			ghc_run 2400 -v1 --make -cpp -DPKG_TOOL -DWANT_PRETTY -O -fno-strictness \
				-I"$PKGSRC" -i"$PKGSRC" \
				-odir "$WORK/ghc-pkg-obj" -hidir "$WORK/ghc-pkg-obj" \
				-o "$INST/bin/ghc-pkg.bin" "$PKGSRC/Main.hs" > "$glog" 2>&1 \
				|| fail "ghc-pkg: $(errline "$glog")"
		else
			fail "ghc-pkg: $(errline "$glog")"
		fi
	fi
fi
cat > "$INST/bin/ghc-pkg" <<EOF
#!/bin/bash
export LD_LIBRARY_PATH="$GMP/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$INST/bin/ghc-pkg.bin" -f "$TOP/package.conf" -f "$INST/package.conf" "\$@"
EOF
chmod +x "$INST/bin/ghc-pkg"
ln -sfn ghc-pkg "$INST/bin/ghc-pkg-6.2.2"
"$INST/bin/ghc-pkg" -l > "$WORK/logs/ghc-pkg-list.log" 2>&1 || fail "ghc-pkg -l: $(errline "$WORK/logs/ghc-pkg-list.log")"
grep -q parsec "$WORK/logs/ghc-pkg-list.log" || fail "ghc-pkg -l has no parsec"
phase "ghc-pkg lists packages"

# ---- smoke: driver links Directory, Signals, Time, Regex -----------------
phase "smoke"
SM=$WORK/smoke
rm -rf "$SM"
mkdir -p "$SM"
cat > "$SM/Main.hs" <<'EOF'
module Main where
import Directory (doesFileExist)
import System.Posix.Signals (sigINT)
import Text.Regex (mkRegex, matchRegex)
import System.Time (getClockTime)
main = do
  b <- doesFileExist "Main.hs"
  _ <- getClockTime
  let m = matchRegex (mkRegex "(ab+)") "xxabb"
  if b && sigINT == 2 && m == Just ["abb"]
    then putStrLn "smoke-ok"
    else print (b, sigINT, m)
EOF
(
	cd "$SM"
	# The installed wrapper appends -Onot. Smoke still goes through --make.
	"$INST/bin/ghc" -v1 --make Main.hs -o smoke > "$WORK/logs/smoke-compile.log" 2>&1
) || fail "smoke compile: $(errline "$WORK/logs/smoke-compile.log")"
# doesFileExist is relative to the process cwd, which must be the source dir.
out=$(cd "$SM" && ./smoke) || fail "smoke run failed"
printf '%s\n' "$out" > "$WORK/logs/smoke.out"
[ "$out" = "smoke-ok" ] || fail "smoke output '$out'"
phase "smoke-ok"

# ---- GHC 6.6 tree --------------------------------------------------------
phase "patch 6.6"
if [ ! -f "$TREE/mk/build.mk" ]; then
	( cd "$WORK/src" && patch -p0 < "$R/ghc66/ghc-6.6-by-622.patch" ) > "$WORK/logs/patch.log" 2>&1 \
		|| fail "patch: $(tail -20 "$WORK/logs/patch.log" | tr '\n' ' ')"
fi
if ! grep -q 'MicroHs-hosted 6.2.2' "$TREE/mk/build.mk"; then
	cat >> "$TREE/mk/build.mk" <<'EOF'

# MicroHs-hosted 6.2.2: stage 1 is the only compiler this ghc builds.
# -Onot is also forced by the ghc wrapper; these opts cover make's own
# stage-1 variable. Non-PIE and the private GMP 6.1.2 are injected by
# the gcc wrapper on PATH, because this build.mk is read too early to
# replace every later -O on individual modules.
SRC_HAPPY_OPTS=+RTS -K64M -H128M -RTS
SRC_ALEX_OPTS=+RTS -K64M -RTS
SRC_CC_OPTS += -fno-pie
SRC_HC_OPTS += -optc-fno-pie -optl-no-pie
EOF
	# marker so the guard above matches
	printf '\n# MicroHs-hosted 6.2.2 stage-1 opts appended\n' >> "$TREE/mk/build.mk"
fi

shipped=$WORK/shipped
mkdir -p "$shipped"
for f in \
	compiler/parser/Parser.y \
	compiler/parser/Parser.hs \
	compiler/parser/ParserCore.hs \
	compiler/parser/Lexer.hs \
	compiler/cmm/CmmParse.hs \
	compiler/cmm/CmmLex.hs \
	compiler/main/ParsePkgConf.hs
do
	# Keep the tarball original in shipped/. A re-run must not replace it
	# with a file make already regenerated.
	if [ -f "$TREE/$f" ] && [ ! -f "$shipped/$f" ]; then
		mkdir -p "$shipped/$(dirname "$f")"
		/bin/mv -f "$TREE/$f" "$shipped/$f"
		phase "moved $f"
	fi
done

cat > "$WORK/bin/gcc" <<EOF
#!/bin/bash
GMP="$GMP"
link=1
for a in "\$@"; do
	case "\$a" in
	-c|-E|-S|-M|-MM|-shared|--version|-dumpversion) link=0 ;;
	esac
done
args=(-I"\$GMP/include" -fno-pie "\$@")
if [ "\$link" = 1 ]; then
	args+=(-L"\$GMP/lib" -no-pie -Wl,-rpath,"\$GMP/lib")
fi
exec /usr/bin/gcc "\${args[@]}"
EOF
chmod +x "$WORK/bin/gcc"

clean=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '\.ghcup' -e '\.cabal' -e '/ghc66-work/' | paste -sd: -)
export PATH="$INST/bin:$ROOT/build/happy-1.16-prefix/bin:$ROOT/build/alex-2.1.0-prefix/bin:$WORK/bin:$clean"
export CC="$WORK/bin/gcc"
export CFLAGS="-std=gnu89 -fpermissive -w"
export CPPFLAGS="-I$GMP/include"
export LDFLAGS="-L$GMP/lib -Wl,-rpath,$GMP/lib"
hash -r
command -v happy | grep -q happy-1.16-prefix || fail "PATH happy is $(command -v happy)"
command -v alex | grep -q alex-2.1.0-prefix || fail "PATH alex is $(command -v alex)"
command -v gcc | grep -q '/ghc66-work/bin/gcc' || fail "PATH gcc is $(command -v gcc)"

phase "configure"
cd "$TREE"
if [ ! -f mk/config.mk ]; then
	if ! ./configure --prefix="$PREFIX" --with-ghc="$INST/bin/ghc" --with-gcc="$WORK/bin/gcc" \
		CFLAGS="-std=gnu89 -fpermissive -w" > "$WORK/logs/configure.log" 2>&1
	then
		fail "configure: $(errline "$WORK/logs/configure.log")"
	fi
fi
happy_mk=$(grep -E '^HAPPY[[:space:]]*=' mk/config.mk | head -1)
alex_mk=$(grep -E '^ALEX[[:space:]]*=' mk/config.mk | head -1)
phase "config $happy_mk"
phase "config $alex_mk"
printf '%s\n' "$happy_mk" | grep -q happy-1.16-prefix || fail "config.mk HAPPY is $happy_mk"
printf '%s\n' "$alex_mk" | grep -q alex-2.1.0-prefix || fail "config.mk ALEX is $alex_mk"

phase "make"
if ! stdbuf -oL -eL make -j1 > "$WORK/logs/make.log" 2>&1; then
	fail "make: $(tail -8 "$WORK/logs/make.log" | tr '\n' ' ' | cut -c1-500)"
fi
phase "make rc=0"

phase "install"
if ! make install > "$WORK/logs/install.log" 2>&1; then
	fail "install: $(errline "$WORK/logs/install.log")"
fi
iver=$("$PREFIX/bin/ghc" --numeric-version | tr -d '[:space:]')
[ "$iver" = "6.6" ] || fail "installed numeric-version '$iver'"
# twice, from a fresh process
iver2=$("$PREFIX/bin/ghc" --numeric-version | tr -d '[:space:]')
[ "$iver2" = "6.6" ] || fail "second numeric-version '$iver2'"
printf '%s\n%s\n' "$iver" "$iver2" > "$WORK/logs/ghc66-version.log"
phase "installed 6.6"

phase "T2"
T2=$WORK/test-t2
rm -rf "$T2"
mkdir -p "$T2"
/bin/cp -f "$R/ghc66/test/T2.hs" "$T2/T2.hs"
/bin/cp -f "$R/common/test/GmpZero.hs" "$T2/GmpZero.hs"
(
	cd "$T2"
	"$PREFIX/bin/ghc" -v0 --make T2.hs -o t2 > "$WORK/logs/t2-compile.log" 2>&1
	./t2 > "$WORK/logs/t2.out"
) || fail "T2: $(errline "$WORK/logs/t2-compile.log") $(tail -5 "$WORK/logs/t2.out" 2>/dev/null | tr '\n' ' ')"
cat > "$T2/expected.txt" <<'EOF'
hello from ghc 6.6 built by 6.2.2
([1,2,3],[(1,"a"),(2,"b")])
(1606938044258990275541962092341162602522202993782792835301376,-9223372036854775808,9223372036854775807)
("1.5",2.25,2)
Left divide by zero
2568
EOF
cmp -s "$T2/expected.txt" "$WORK/logs/t2.out" || fail "T2 output mismatch"
phase "T2 ok"

phase "GmpZero"
(
	cd "$T2"
	"$PREFIX/bin/ghc" -v0 -O --make GmpZero.hs -o gz > "$WORK/logs/gmpzero-compile.log" 2>&1
	./gz > "$WORK/logs/gmpzero.out"
) || fail "GmpZero: $(errline "$WORK/logs/gmpzero-compile.log")"
printf '(2400000,0)\n' | cmp -s - "$WORK/logs/gmpzero.out" || fail "GmpZero output $(cat "$WORK/logs/gmpzero.out")"
phase "GmpZero ok"

phase "cmp generated"
for f in \
	compiler/parser/Parser.y \
	compiler/parser/Parser.hs \
	compiler/parser/ParserCore.hs \
	compiler/parser/Lexer.hs \
	compiler/cmm/CmmParse.hs \
	compiler/cmm/CmmLex.hs \
	compiler/main/ParsePkgConf.hs
do
	sh "$R/ghc66/cmp-generated.sh" "$TREE/$f" "$shipped/$f" \
		|| fail "generated $f differs from shipped"
done
phase "parsers match shipped"

printf 'GHC66_DONE installed %s numeric-version %s\n' "$PREFIX/bin/ghc" "$iver"
