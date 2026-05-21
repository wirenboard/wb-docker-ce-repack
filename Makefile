PACKAGE := wb-docker

.PHONY: check build clean

check:
	sh -n libexec/wb-docker-reconcile
	sh -n debian/wb-docker.preinst
	sh -n debian/wb-docker.postinst
	sh -n debian/wb-docker.prerm
	sh -n debian/wb-docker.postrm

build: check
	@if [ ! -r /etc/debian_version ]; then \
		echo "make build requires a Debian build environment with debhelper-compat (= 13)." >&2; \
		echo "On macOS, run make check locally and build the package inside Debian." >&2; \
		exit 2; \
	fi
	dpkg-buildpackage -us -uc -b

clean:
	@if command -v dh_clean >/dev/null 2>&1; then \
		dh_clean; \
	else \
		echo "dh_clean is not available; install debhelper in a Debian build environment." >&2; \
	fi
