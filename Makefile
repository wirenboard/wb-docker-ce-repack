PACKAGE := wb-docker

.PHONY: build clean

build:
	dpkg-buildpackage -us -uc -b

clean:
	dh_clean
