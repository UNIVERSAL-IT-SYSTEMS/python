# Copyright 1999-2015 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: /var/cvsroot/gentoo-x86/dev-lang/python/python-3.2.5-r6.ebuild,v 1.11 2015/03/31 18:46:33 ulm Exp $

EAPI=5
WANT_AUTOMAKE="none"
WANT_LIBTOOL="none"

inherit autotools eutils flag-o-matic multilib pax-utils python-utils-r1 toolchain-funcs multiprocessing

MY_P="Python-${PV}"

DESCRIPTION="An interpreted, interactive, object-oriented programming language"
HOMEPAGE="http://www.python.org/"
SRC_URI="http://www.python.org/ftp/python/${PV}/${MY_P}.tar.xz"

LICENSE="PSF-2"
SLOT="3.2"
KEYWORDS=""
IUSE="build doc elibc_uclibc examples gdbm hardened ipv6 +ncurses +readline sqlite +ssl +threads tk +wide-unicode wininst +xml"

# Do not add a dependency on dev-lang/python to this ebuild.
# If you need to apply a patch which requires python for bootstrapping, please
# run the bootstrap code on your dev box and include the results in the
# patchset. See bug 447752.

RDEPEND="app-arch/bzip2
	>=sys-libs/zlib-1.1.3
	virtual/libffi
	virtual/libintl
	!build? (
		gdbm? ( sys-libs/gdbm[berkdb] )
		ncurses? (
			>=sys-libs/ncurses-5.2
			readline? ( >=sys-libs/readline-4.1 )
		)
		sqlite? ( >=dev-db/sqlite-3.3.8:3 )
		ssl? ( dev-libs/openssl )
		tk? (
			>=dev-lang/tk-8.0
			dev-tcltk/blt
			dev-tcltk/tix
		)
		xml? ( >=dev-libs/expat-2.1 )
	)"
DEPEND="${RDEPEND}
	virtual/pkgconfig
	>=sys-devel/autoconf-2.65
	!sys-devel/gcc[libffi]"
RDEPEND+=" !build? ( app-misc/mime-types )
	doc? ( dev-python/python-docs:${SLOT} )"

S="${WORKDIR}/${MY_P}"

src_prepare() {
	# Ensure that internal copies of expat, libffi and zlib are not used.
	rm -r Modules/expat || die
	rm -r Modules/_ctypes/libffi* || die
	rm -r Modules/zlib || die

	local excluded_patches
	if ! tc-is-cross-compiler; then
		excluded_patches="*_all_crosscompile.patch"
	fi

	EPATCH_EXCLUDE="${excluded_patches}" EPATCH_SUFFIX="patch" \
		epatch "${FILESDIR}/${SLOT}"

	sed -i -e "s:@@GENTOO_LIBDIR@@:$(get_libdir):g" \
		Lib/distutils/command/install.py \
		Lib/distutils/sysconfig.py \
		Lib/site.py \
		Lib/sysconfig.py \
		Lib/test/test_site.py \
		Makefile.pre.in \
		Modules/Setup.dist \
		Modules/getpath.c \
		setup.py || die "sed failed to replace @@GENTOO_LIBDIR@@"

	# Disable ABI flags.
	sed -e "s/ABIFLAGS=\"\${ABIFLAGS}.*\"/:/" -i configure.ac || die "sed failed"

	epatch_user

	eautoconf
	eautoheader
}

src_configure() {
	if use build; then
		# Disable extraneous modules with extra dependencies.
		export PYTHON_DISABLE_MODULES="gdbm _curses _curses_panel readline _sqlite3 _tkinter _elementtree pyexpat"
		export PYTHON_DISABLE_SSL="1"
	else
		local disable
		use gdbm     || disable+=" gdbm"
		use ncurses  || disable+=" _curses _curses_panel"
		use readline || disable+=" readline"
		use sqlite   || disable+=" _sqlite3"
		use ssl      || export PYTHON_DISABLE_SSL="1"
		use tk       || disable+=" _tkinter"
		use xml      || disable+=" _elementtree pyexpat" # _elementtree uses pyexpat.
		export PYTHON_DISABLE_MODULES="${disable}"

		if ! use xml; then
			ewarn "You have configured Python without XML support."
			ewarn "This is NOT a recommended configuration as you"
			ewarn "may face problems parsing any XML documents."
		fi
	fi

	if [[ -n "${PYTHON_DISABLE_MODULES}" ]]; then
		einfo "Disabled modules: ${PYTHON_DISABLE_MODULES}"
	fi

	if [[ "$(gcc-major-version)" -ge 4 ]]; then
		append-flags -fwrapv
	fi

	filter-flags -malign-double

	[[ "${ARCH}" == "alpha" ]] && append-flags -fPIC

	# https://bugs.gentoo.org/show_bug.cgi?id=50309
	if is-flagq -O3; then
		is-flagq -fstack-protector-all && replace-flags -O3 -O2
		use hardened && replace-flags -O3 -O2
	fi

	# Run the configure scripts in parallel.
	multijob_init

	mkdir -p "${WORKDIR}"/{${CBUILD},${CHOST}} || die

	if tc-is-cross-compiler; then
		(
			multijob_child_init
			cd "${WORKDIR}"/${CBUILD} >/dev/null || die
			OPT="-O1" CFLAGS="" CPPFLAGS="" LDFLAGS="" CC="" \
			"${S}"/configure \
				--{build,host}=${CBUILD} \
				|| die "cross-configure failed"
		) &
		multijob_post_fork

		# The configure script assumes it's buggy when cross-compiling.
		export ac_cv_buggy_getaddrinfo=no
		export ac_cv_have_long_long_format=yes
	fi

	# Export CXX so it ends up in /usr/lib/python3.X/config/Makefile.
	tc-export CXX
	# The configure script fails to use pkg-config correctly.
	# http://bugs.python.org/issue15506
	export ac_cv_path_PKG_CONFIG=$(tc-getPKG_CONFIG)

	# Set LDFLAGS so we link modules with -lpython3.2 correctly.
	# Needed on FreeBSD unless Python 3.2 is already installed.
	# Please query BSD team before removing this!
	append-ldflags "-L."

	local dbmliborder
	if use gdbm; then
		dbmliborder+="${dbmliborder:+:}gdbm"
	fi

	cd "${WORKDIR}"/${CHOST} || die
	ECONF_SOURCE=${S} OPT="" \
	econf \
		--with-fpectl \
		--enable-shared \
		$(use_enable ipv6) \
		$(use_with threads) \
		$(use_with wide-unicode) \
		--infodir='${prefix}/share/info' \
		--mandir='${prefix}/share/man' \
		--with-computed-gotos \
		--with-dbmliborder="${dbmliborder}" \
		--with-libc="" \
		--enable-loadable-sqlite-extensions \
		--with-system-expat \
		--with-system-ffi

	if use threads && grep -q "#define POSIX_SEMAPHORES_NOT_ENABLED 1" pyconfig.h; then
		eerror "configure has detected that the sem_open function is broken."
		eerror "Please ensure that /dev/shm is mounted as a tmpfs with mode 1777."
		die "Broken sem_open function (bug 496328)"
	fi

	if tc-is-cross-compiler; then
		# Modify the Makefile.pre so we don't regen for the host/ one.
		# We need to link the host python programs into $PWD and run
		# them from here because the distutils sysconfig module will
		# parse Makefile/etc... from argv[0], and we need it to pick
		# up the target settings, not the host ones.
		sed -i \
			-e '1iHOSTPYTHONPATH = ./hostpythonpath:' \
			-e '/^HOSTPYTHON/s:=.*:= ./hostpython:' \
			-e '/^HOSTPGEN/s:=.*:= ./Parser/hostpgen:' \
			Makefile{.pre,} || die "sed failed"
	fi

	multijob_finish
}

src_compile() {
	if tc-is-cross-compiler; then
		cd "${WORKDIR}"/${CBUILD}
		# Disable as many modules as possible -- but we need a few to install.
		PYTHON_DISABLE_MODULES=$(
			sed -n "/Extension('/{s:^.*Extension('::;s:'.*::;p}" "${S}"/setup.py | \
				egrep -v '(unicodedata|time|cStringIO|_struct|binascii)'
		) \
		PTHON_DISABLE_SSL="1" \
		SYSROOT= \
		emake
		# See comment in src_configure about these.
		ln python ../${CHOST}/hostpython || die
		ln Parser/pgen ../${CHOST}/Parser/hostpgen || die
		ln -s ../${CBUILD}/build/lib.*/ ../${CHOST}/hostpythonpath || die
	fi

	cd "${WORKDIR}"/${CHOST} || die
	emake CPPFLAGS="" CFLAGS="" LDFLAGS=""

	# Work around bug 329499. See also bug 413751 and 457194.
	if has_version "dev-libs/libffi[pax_kernel]"; then
		pax-mark E python
	else
		pax-mark m python
	fi
}

src_test() {
	# Tests will not work when cross compiling.
	if tc-is-cross-compiler; then
		elog "Disabling tests due to crosscompiling."
		return
	fi

	cd "${WORKDIR}/${CHOST}" || die

	# Skip failing tests.
	local skipped_tests="gdb"

	for test in ${skipped_tests}; do
		mv "${S}"/Lib/test/test_${test}.py "${T}"
	done

	# Rerun failed tests in verbose mode (regrtest -w).
	PYTHONDONTWRITEBYTECODE="" emake test EXTRATESTOPTS="-w" CPPFLAGS="" CFLAGS="" LDFLAGS="" < /dev/tty
	local result="$?"

	for test in ${skipped_tests}; do
		mv "${T}/test_${test}.py" "${S}"/Lib/test || die
	done

	elog "The following tests have been skipped:"
	for test in ${skipped_tests}; do
		elog "test_${test}.py"
	done

	elog "If you would like to run them, you may:"
	elog "cd '${EPREFIX}/usr/$(get_libdir)/python${SLOT}/test'"
	elog "and run the tests separately."

	if [[ "${result}" -ne 0 ]]; then
		die "emake test failed"
	fi
}

src_install() {
	local libdir=${ED}/usr/$(get_libdir)/python${SLOT}

	cd "${WORKDIR}"/${CHOST} || die
	emake DESTDIR="${D}" altinstall

	sed \
		-e "s/\(CONFIGURE_LDFLAGS=\).*/\1/" \
		-e "s/\(PY_LDFLAGS=\).*/\1/" \
		-i "${libdir}/config-${SLOT}/Makefile" || die "sed failed"

	# Fix collisions between different slots of Python.
	rm "${ED}usr/$(get_libdir)/libpython3.so" || die

	if use build; then
		rm -fr "${ED}usr/bin/idle${SLOT}" "${libdir}/"{idlelib,sqlite3,test,tkinter} || die
	else
		use elibc_uclibc && { rm -fr "${libdir}/test" || die; }
		use sqlite || { rm -fr "${libdir}/"{sqlite3,test/test_sqlite*} || die; }
		use tk || { rm -fr "${ED}usr/bin/idle${SLOT}" "${libdir}/"{idlelib,tkinter,test/test_tk*} || die; }
	fi

	use threads || { rm -fr "${libdir}/multiprocessing" || die; }
	use wininst || { rm -f "${libdir}/distutils/command/"wininst-*.exe || die; }

	dodoc "${S}"/Misc/{ACKS,HISTORY,NEWS}

	if use examples; then
		docinto examples
		find "${S}"/Tools -name __pycache__ -exec rm -fr {} + || die
		dodoc -r "${S}"/Tools/.
	fi
	insinto /usr/share/gdb/auto-load/usr/$(get_libdir) #443510
	local libname=$(printf 'e:\n\t@echo $(INSTSONAME)\ninclude Makefile\n' | \
		emake --no-print-directory -s -f - 2>/dev/null)
	newins "${S}"/Tools/gdb/libpython.py "${libname}"-gdb.py

	newconfd "${FILESDIR}/pydoc.conf" pydoc-${SLOT}
	newinitd "${FILESDIR}/pydoc.init" pydoc-${SLOT}
	sed \
		-e "s:@PYDOC_PORT_VARIABLE@:PYDOC${SLOT/./_}_PORT:" \
		-e "s:@PYDOC@:pydoc${SLOT}:" \
		-i "${ED}etc/conf.d/pydoc-${SLOT}" "${ED}etc/init.d/pydoc-${SLOT}" || die "sed failed"

	# for python-exec
	python_export python${SLOT} EPYTHON PYTHON PYTHON_SITEDIR

	# if not using a cross-compiler, use the fresh binary
	if ! tc-is-cross-compiler; then
		local PYTHON=./python \
			LD_LIBRARY_PATH=${LD_LIBRARY_PATH+${LD_LIBRARY_PATH}:}.
		export LD_LIBRARY_PATH
	fi

	echo "EPYTHON='${EPYTHON}'" > epython.py
	python_domodule epython.py
}

pkg_postinst() {
	ewarn "Please note that Python ${SLOT} is no longer supported in Gentoo."
	ewarn "The interpreter is not well maintained, and may contain security"
	ewarn "vulnerabilities. Gentoo ebuilds will no longer be built with support"
	ewarn "for Python ${SLOT}."
	ewarn
	ewarn "If you wish to use Python ${SLOT} for your own purposes (development,"
	ewarn "testing), we suggest establishing a virtualenv for this interpreter,"
	ewarn "and installing the necessary dependencies inside it. However, we also"
	ewarn "strongly discourage using Python ${SLOT} on production systems."
}
