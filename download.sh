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
rm -rf */sbuild/

# remove empty files (temporary fix for https://github.com/debuerreotype/debuerreotype/commit/d29dd5e030525d9a5d9bd925030d1c11a163380c)
find */ -type f -empty -delete

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
	# TODO cleverly detect whether "bash" exists in "rootfs.tar.xz" (and fall back to "sh" if not)
	# https://salsa.debian.org/debian/grow-your-ideas/-/issues/20
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
			rm -f "$suite/backports/InRelease" # delete the empty file "wget" creates
			wget -O "$suite/backports/Release" "$snapshotUrl/dists/${suite}-backports/Release"
			wget -O "$suite/backports/Release.gpg" "$snapshotUrl/dists/${suite}-backports/Release.gpg"
		fi
		# TODO else extract InRelease contents somehow (no keyring here)
	fi

	# TODO https://github.com/debuerreotype/docker-debian-artifacts/pull/186
	rm -f "$suite/oci.tar" "$suite/slim/oci.tar"
done

declare -A experimentalSuites=(
	[experimental]='unstable'
	[rc-buggy]='sid'
)
for suite in "${!experimentalSuites[@]}"; do
	base="${experimentalSuites[$suite]}"
	if [ -f "$base/rootfs.tar.xz" ]; then
		[ ! -d "$suite" ]
		[ -s "$base/rootfs.debian-sources" ]
		mirror="$(awk '$1 == "URIs:" { print $2; exit }' "$base/rootfs.debian-sources")"
		[ -n "$mirror" ]
		mkdir -p "$suite"
		if ! wget -O "$suite/InRelease" "$snapshotUrl/dists/$suite/InRelease"; then
			rm -f "$suite/InRelease" # delete the empty file "wget" creates
			if ! {
				wget -O "$suite/Release.gpg" "$snapshotUrl/dists/$suite/Release.gpg" &&
				wget -O "$suite/Release" "$snapshotUrl/dists/$suite/Release"
			}; then
				rm -rf "$suite"
				continue # this suite must not exist! (rc-buggy on debian-ports 😔)
			fi
		fi # TODO else extract InRelease contents somehow (no keyring here)
		cat > "$suite/Dockerfile" <<-EODF
			FROM debian:$base
			RUN echo 'deb $mirror $suite main' > /etc/apt/sources.list.d/experimental.list
		EODF
	fi
done

# add a bit of extra useful metadata (for easier scraping)
for suite in */; do
	suite="${suite%/}"
	echo "$suite" >> suites
done
