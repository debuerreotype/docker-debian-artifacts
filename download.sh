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
	if wget --quiet --spider "$snapshotUrl/dists/${suite}-backports/main/binary-$dpkgArch/Packages.gz"; then
		mkdir -p "$suite/backports"
		cat > "$suite/backports/Dockerfile" <<-EODF
			FROM debian:$suite
			RUN echo 'deb http://deb.debian.org/debian ${suite}-backports main' > /etc/apt/sources.list.d/backports.list
		EODF
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
	fi
done
