%global debug_package %{nil}
Summary:	GHC 6.6 compiled from source by MicroHs
Name:		ghc66
Version:	6.6
Release:	1
License:	BSD
Group:		Development/Other
Url:		https://www.haskell.org/ghc/
# Cold start of the source-only chain. MicroHs compiles GHC 6.2.2, which
# compiles GHC 6.6. Happy 1.16, alex 2.1.0 and the MicroHs happy are built
# in this package because nothing earlier has a GHC that can build them.
# Complement of distro ghc: binaries are ghc66 and ghc-pkg66, so no Epoch.
ExclusiveArch:	x86_64 znver1
Source0:	ghc-6.2.2-src.tar.bz2
Source1:	ghc-6.6-src.tar.bz2
Source2:	happy-1.19.5.tar.gz
Source3:	happy-1.16.tar.gz
Source4:	alex-2.1.0.tar.gz
Source5:	ghc66-bootstrap-kit.tar.gz
Source6:	ghc66-build.sh
Source7:	happy116-build.sh
Source8:	ghc66-bootstrap.sh
Source9:	ghc66-worktree.patch
Source10:	alex-Directory.hs
Source11:	T2.out
Source12:	%{name}.rpmlintrc

BuildRequires:	microhs
BuildRequires:	cpphs-mhs
BuildRequires:	gmp612
BuildRequires:	gcc
BuildRequires:	make
BuildRequires:	patch
BuildRequires:	perl
BuildRequires:	python
BuildRequires:	diffutils
BuildRequires:	binutils
BuildRequires:	file
BuildRequires:	findutils
BuildRequires:	coreutils
BuildRequires:	util-linux
BuildRequires:	gawk
BuildRequires:	grep
BuildRequires:	sed
BuildRequires:	tar
BuildRequires:	bzip2
BuildRequires:	gzip
BuildRequires:	procps

%description
GHC 6.6 compiled from its Haskell sources by a GHC 6.2.2 that MicroHs
compiled from source. No upstream bindist and no GHCup compiler.

The package also installs happy 1.16 (happy116), alex 2.1.0 (alex210)
and happy 1.19.5 built by MicroHs (happy1195-mhs). Later hops in the
chain build against those names.

Installed as ghc66 so it does not replace the distribution ghc package.

%prep
set -eu
cd %{_builddir}
rm -rf ghc66-root
mkdir -p ghc66-root/incoming
cp -a %{SOURCE0} ghc66-root/incoming/ghc-6.2.2-src.tar.bz2
cp -a %{SOURCE1} ghc66-root/incoming/ghc-6.6-src.tar.bz2
cp -a %{SOURCE2} ghc66-root/incoming/happy-1.19.5.tar.gz
cp -a %{SOURCE3} ghc66-root/incoming/happy-1.16.tar.gz
cp -a %{SOURCE4} ghc66-root/incoming/alex-2.1.0.tar.gz
cp -a %{SOURCE5} ghc66-root/incoming/ghc66-bootstrap-kit.tar.gz
cp -a %{SOURCE6} ghc66-root/incoming/ghc66-build.sh
cp -a %{SOURCE7} ghc66-root/incoming/happy116-build.sh
cp -a %{SOURCE8} ghc66-root/incoming/ghc66-bootstrap.sh
cp -a %{SOURCE9} ghc66-root/incoming/ghc66-worktree.patch
cp -a %{SOURCE10} ghc66-root/incoming/alex-Directory.hs
cp -a %{SOURCE11} ghc66-root/incoming/T2.out
chmod 755 ghc66-root/incoming/ghc66-build.sh
set +u

%build
set -eu
bash %{_builddir}/ghc66-root/incoming/ghc66-build.sh "%{_builddir}/ghc66-root" "%{_libdir}"
set +u

%install
set -eu
dest=%{_builddir}/ghc66-root/dest
if [ -d "$dest/lib/ghc-6.6" ]; then
	src=$dest/lib/ghc-6.6
else
	echo "ghc66: install tree has no lib/ghc-6.6" >&2
	exit 1
fi
mkdir -p %{buildroot}%{_libdir} %{buildroot}%{_bindir} %{buildroot}%{_libexecdir} %{buildroot}%{_datadir}
cp -a "$src" %{buildroot}%{_libdir}/ghc-6.6
cp -a "$dest/bin/." %{buildroot}%{_bindir}/
cp -a "$dest/libexec/." %{buildroot}%{_libexecdir}/
cp -a "$dest/share/." %{buildroot}%{_datadir}/
top=%{buildroot}%{_libdir}/ghc-6.6
if [ -x "$top/ghc-6.6" ] && file "$top/ghc-6.6" | grep -q ELF; then
	rel=ghc-6.6
elif [ -x "$top/bin/ghc" ] && file "$top/bin/ghc" | grep -q ELF; then
	rel=bin/ghc
elif [ -x "$top/ghc" ] && file "$top/ghc" | grep -q ELF; then
	rel=ghc
else
	echo "ghc66: no compiler ELF in $top" >&2
	exit 1
fi
if [ -x "$top/ghc-pkg.bin" ]; then
	pkgrel=ghc-pkg.bin
elif [ -x "$top/bin/ghc-pkg" ] && file "$top/bin/ghc-pkg" | grep -q ELF; then
	pkgrel=bin/ghc-pkg
elif [ -x "$top/ghc-pkg" ] && file "$top/ghc-pkg" | grep -q ELF; then
	pkgrel=ghc-pkg
else
	echo "ghc66: no ghc-pkg ELF in $top" >&2
	exit 1
fi
if [ -f "$top/package.conf" ]; then
	db=package.conf
elif [ -d "$top/package.conf.d" ]; then
	db=package.conf.d
else
	echo "ghc66: no package database" >&2
	exit 1
fi
if "$top/$pkgrel" --help 2>&1 | grep -q -- '--global-package-db'; then
	dbflag=--global-package-db
else
	dbflag=--global-conf
fi
test -x "$top/bin/host-gcc"
test -x %{buildroot}%{_bindir}/happy116
test -x %{buildroot}%{_bindir}/alex210
test -x %{buildroot}%{_libexecdir}/happy1195-mhs
test -f %{buildroot}%{_datadir}/happy1195-mhs/HappyTemplate
test -f %{buildroot}%{_datadir}/happy-1.16/HappyTemplate
test -f %{buildroot}%{_datadir}/alex-2.1.0/AlexTemplate
libname=$(basename %{_libdir})
cat > %{buildroot}%{_bindir}/ghc66 << EOF
#!/bin/sh
if [ -x "\$0" ] && [ "\$0" != "\${0#*/}" ]; then
	arg0=\$0
else
	arg0=\$(command -v "\$0") || exit 1
fi
here=\$(CDPATH= cd -- "\$(dirname "\$arg0")" && pwd)
root=\$(dirname "\$here")
exec "\$root/$libname/ghc-6.6/$rel" -B"\$root/$libname/ghc-6.6" "\$@"
EOF
cat > %{buildroot}%{_bindir}/ghc-pkg66 << EOF
#!/bin/sh
if [ -x "\$0" ] && [ "\$0" != "\${0#*/}" ]; then
	arg0=\$0
else
	arg0=\$(command -v "\$0") || exit 1
fi
here=\$(CDPATH= cd -- "\$(dirname "\$arg0")" && pwd)
root=\$(dirname "\$here")
top="\$root/$libname/ghc-6.6"
exec "\$top/$pkgrel" $dbflag "\$top/$db" "\$@"
EOF
cat > %{buildroot}%{_bindir}/happy1195-mhs << 'EOF'
#!/bin/sh
if [ -x "$0" ] && [ "$0" != "${0#*/}" ]; then
	arg0=$0
else
	arg0=$(command -v "$0") || exit 1
fi
here=$(CDPATH= cd -- "$(dirname "$arg0")" && pwd)
root=$(dirname "$here")
export HAPPY_DATADIR=$root/share/happy1195-mhs
exec "$root/libexec/happy1195-mhs" "$@"
EOF
chmod 755 %{buildroot}%{_bindir}/ghc66 %{buildroot}%{_bindir}/ghc-pkg66 %{buildroot}%{_bindir}/happy1195-mhs
ln -sfn ghc66 %{buildroot}%{_bindir}/ghc-6.6
ln -sfn ghc-pkg66 %{buildroot}%{_bindir}/ghc-pkg-6.6
set +u

%files
%{_bindir}/ghc66
%{_bindir}/ghc-pkg66
%{_bindir}/ghc-6.6
%{_bindir}/ghc-pkg-6.6
%{_bindir}/happy116
%{_bindir}/alex210
%{_bindir}/happy1195-mhs
%{_libexecdir}/happy1195-mhs
%{_datadir}/happy1195-mhs/
%{_datadir}/happy-1.16/
%{_datadir}/alex-2.1.0/
%{_libdir}/ghc-6.6/

%check
set -eu
export PATH=%{buildroot}%{_bindir}:$PATH
hash -r
b=$(command -v ghc66)
test "$("$b" --numeric-version | tr -d '[:space:]')" = "6.6"
test "$("$b" --numeric-version | tr -d '[:space:]')" = "6.6"
rm -rf t2check
mkdir t2check
cp -a %{_builddir}/ghc66-root/build/ref-ghc-bootstrap/ghc66/test/T2.hs t2check/T2.hs
cp -a %{_builddir}/ghc66-root/build/ref-ghc-bootstrap/common/test/GmpZero.hs t2check/GmpZero.hs
( cd t2check && "$b" -v0 --make T2.hs -o t2 && ./t2 ) > t2.out
cmp -s %{_builddir}/ghc66-root/incoming/T2.out t2.out
( cd t2check && "$b" -v0 -O --make GmpZero.hs -o gz && ./gz ) > gz.out
printf '(2400000,0)\n' | cmp -s - gz.out
happy116 --version | grep -q 'Happy Version 1.16'
alex210 --version | grep -q 'Alex version 2.1.0'
happy1195-mhs --version | grep -q '1.19.5'
live=%{_libdir}/ghc-6.6
if [ -f "$live/.omv-bootstrap-hostgcc" ] && [ ! -e "$live/bin/ghc" ] && [ ! -e "$live/ghc" ] && [ ! -e "$live/ghc-6.6" ]; then
	rm -rf "$live"
fi
for d in %{_datadir}/happy-1.16 %{_datadir}/alex-2.1.0; do
	if [ -f "$d/.omv-bootstrap-datadir" ]; then
		rm -rf "$d"
	fi
done
set +u
