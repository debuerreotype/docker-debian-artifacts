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

	for variant in '' slim; do
		dir="$suite${variant:+/$variant}"
		[ -d "$dir" ]
		[ -s "$dir/oci.tar" ]

		mkdir "$dir/oci"
		tar -xf "$dir/oci.tar" -C "$dir/oci"
		rm -f "$dir/oci.tar" "$dir/rootfs.tar.xz"
		rootfs='oci/blobs/rootfs.tar.gz'

		[ -s "$dir/$rootfs" ]

		cmd="$(jq -c '.config.Cmd' "$dir/oci/blobs/image-config.json")"
		[[ "$cmd" = '["'*'"]' ]]

		cat > "$dir/Dockerfile" <<-EODF
			# this isn't used for the official published images anymore, but is included for backwards compatibility
			# see https://github.com/docker-library/bashbrew/issues/51
			FROM scratch
			ADD $rootfs /
			CMD $cmd
		EODF

		cat > "$dir/.dockerignore" <<-EODI
			**
			!$rootfs
		EODI
	done

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
done

declare -A experimentalSuites=(
	[experimental]='unstable'
	[rc-buggy]='sid'
)
for suite in "${!experimentalSuites[@]}"; do
	base="${experimentalSuites[$suite]}"
	if [ -s "$base/Dockerfile" ]; then
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
