#!/usr/bin/env bash
set -Eeuo pipefail

arch="$(< arch)"
[ -n "$arch" ]

wget -O artifacts.zip "https://doi-janky.infosiftr.net/job/tianon/job/debuerreotype/job/${arch}/lastSuccessfulBuild/artifact/*zip*/archive.zip"
unzip artifacts.zip
rm -v artifacts.zip

# --strip-components 1
mv archive/* ./
rmdir archive

# remove "sbuild" tarballs
# we don't use these in Docker, and as of 2017-09-07 unstable/testing are larger than GitHub's maximum file size of 100MB (~140MB)
# they're still available in the Jenkins artifacts directly for folks who want them (and buildable reproducibly via debuerreotype)
rm -r */sbuild/

snapshotUrl="$(cat snapshot-url 2>/dev/null || echo 'https://deb.debian.org/debian')"
dpkgArch="$(< dpkg-arch)"

for suite in */; do
	suite="${suite%/}"

	[ -f "$suite/rootfs.tar.xz" ]
	cat > "$suite/Dockerfile" <<-'EODF'
		FROM scratch
		ADD rootfs.tar.xz /
		CMD ["bash"]
	EODF
	cat > "$suite/.dockerignore" <<-'EODI'
		**
		!rootfs.tar.xz
	EODI

	[ -f "$suite/slim/rootfs.tar.xz" ]
	cp -a "$suite/Dockerfile" "$suite/.dockerignore" "$suite/slim/"

	# check whether xyz-backports exists at this epoch
	if wget --quiet --spider "$snapshotUrl/dists/${suite}-backports/main/binary-$dpkgArch/Release"; then
		mkdir -p "$suite/backports"
		cat > "$suite/backports/Dockerfile" <<-EODF
			FROM debian:$suite
			RUN echo 'deb http://deb.debian.org/debian ${suite}-backports main' > /etc/apt/sources.list.d/backports.list
		EODF
		if ! wget -O "$suite/backports/InRelease" "$snapshotUrl/dists/${suite}-backports/InRelease"; then
			# TODO extract InRelease contents somehow (no keyring here)
			wget -O "$suite/backports/Release" "$snapshotUrl/dists/${suite}-backports/Release"
			wget -O "$suite/backports/Release.gpg" "$snapshotUrl/dists/${suite}-backports/Release.gpg"
		fi
	fi
done

declare -A experimentalSuites=(
	[experimental]='unstable'
	[rc-buggy]='sid'
)
for suite in "${!experimentalSuites[@]}"; do
	base="${experimentalSuites[$suite]}"
	if [ -f "$base/rootfs.tar.xz" ]; then
		[ ! -d "$suite" ]
		mkdir -p "$suite"
		cat > "$suite/Dockerfile" <<-EODF
			FROM debian:$base
			RUN echo 'deb http://deb.debian.org/debian $suite main' > /etc/apt/sources.list.d/experimental.list
		EODF
		if ! wget -O "$suite/InRelease" "$snapshotUrl/dists/$suite/InRelease"; then
			# TODO extract InRelease contents somehow (no keyring here)
			wget -O "$suite/Release" "$snapshotUrl/dists/$suite/Release"
			wget -O "$suite/Release.gpg" "$snapshotUrl/dists/$suite/Release.gpg"
		fi
	fi
done

# add a bit of extra useful metadata (for easier scraping)
for suite in */; do
	suite="${suite%/}"
	echo "$suite" >> suites
done
