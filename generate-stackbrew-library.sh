#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

gitHubUrl='https://github.com/debuerreotype/docker-debian-artifacts'
rawGitUrl="$gitHubUrl/raw"

archMaps=( $(
	git ls-remote --heads "${gitHubUrl}.git" \
		| awk -F '[\t/]' '$4 ~ /^dist-/ { gsub(/^dist-/, "", $4); print $4 "=" $1 }' \
		| sort
) )
arches=()
declare -A archCommits=()
for archMap in "${archMaps[@]}"; do
	arch="${archMap%%=*}"
	commit="${archMap#${arch}=}"
	arches+=( "$arch" )
	archCommits[$arch]="$commit"
done

versions=( */ )
versions=( "${versions[@]%/}" )

_wget() {
	wget -qO- -o /dev/null "$@"
}

cat <<-EOH
# tarballs built by debuerreotype
# see https://github.com/debuerreotype/debuerreotype

Maintainers: Tianon Gravi <tianon@debian.org> (@tianon),
             Paul Tagliamonte <paultag@debian.org> (@paultag)
GitRepo: ${gitHubUrl}.git
GitCommit: $(git log --format='format:%H' -1)
EOH
suites=()
declare -A suiteArches=()
serial=
for arch in "${arches[@]}"; do
	commit="${archCommits[$arch]}"
	cat <<-EOA
		# $gitHubUrl/tree/dist-${arch}
		${arch}-GitFetch: refs/heads/dist-${arch}
		${arch}-GitCommit: $commit
	EOA

	archSuites="$(_wget "$rawGitUrl/$commit/suites")"
	for suite in $archSuites; do
		if [ -z "${suiteArches[$suite]:-}" ]; then
			suites+=( "$suite" )
		fi
		suiteArches[$suite]+=" $arch"
	done

	archSerial="$(_wget "$rawGitUrl/$commit/serial")"
	[ -n "$serial" ] || serial="$archSerial"
	if [ "$serial" != "$archSerial" ]; then
		echo >&2 "error: '$arch' has inconsistent serial '$serial'! (from '$archSerial')"
		exit 1
	fi
done

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

for version in "${suites[@]}"; do
	versionArches=( ${suiteArches[$version]} )
	tokenArch="${versionArches[0]}" # the arch we'll use to grab useful files like "$version/InRelease"
	tokenCommit="${archCommits[$tokenArch]}"
	tokenGitHubBase="$rawGitUrl/$tokenCommit/$version"

	versionAliases=(
		$version
		$version-$serial
	)

	releaseFile="$(_wget "$tokenGitHubBase/InRelease" || _wget "$tokenGitHubBase/Release")"
	codename="$(awk -F ': ' '$1 == "Codename" { print $2; exit }' <<<"$releaseFile")"
	if [ "$version" = "$codename" ]; then
		# "jessie", "stretch", etc.

		releaseVersion="$(awk -F ': ' '$1 == "Version" { print $2; exit }' <<<"$releaseFile")"
		if [ -n "$releaseVersion" ]; then
			while [ "${releaseVersion%.*}" != "$releaseVersion" ]; do
				versionAliases+=( "$releaseVersion" )
				releaseVersion="${releaseVersion%.*}"
			done
			versionAliases+=( "$releaseVersion" )
		fi

		suite="$(awk -F ': ' '$1 == "Suite" { print $2; exit }' <<<"$releaseFile")"
		if [ "$suite" = 'stable' ]; then
			# latest should always point to current stable
			versionAliases+=( latest )
		fi
	fi
	description="$(awk -F ': ' '$1 == "Description" { print $2; exit }' <<<"$releaseFile")"

	for variant in \
		'' \
		backports \
		slim \
	; do
		variantDir="$version${variant:+/$variant}"

		ociOrDockerfile= # 'oci' or 'Dockerfile'
		variantArches=()
		for arch in "${versionArches[@]}"; do
			archCommit="${archCommits[$arch]}"
			archOciOrDockerfile=
			if _wget --spider "$rawGitUrl/$archCommit/$variantDir/oci/index.json"; then
				archOciOrDockerfile='oci'
				variantArches+=( "$arch" )
			elif _wget --spider "$rawGitUrl/$archCommit/$variantDir/Dockerfile"; then
				archOciOrDockerfile='Dockerfile'
				variantArches+=( "$arch" )
			fi
			: "${ociOrDockerfile:="$archOciOrDockerfile"}"
			if [ "$archOciOrDockerfile" != "$ociOrDockerfile" ]; then
				echo >&2 "error: '$arch' has a mismatching layout for '$variantDir' from '${variantArches[0]}' ('$archOciOrDockerfile' vs '$ociOrDockerfile')"
				exit 1
			fi
		done
		[ "${#variantArches[@]}" -gt 0 ] || continue

		variantAliases=()
		case "$variant" in
			'')
				variantAliases+=( "${versionAliases[@]}" )
				;;
			slim)
				for versionAlias in "${versionAliases[@]}"; do
					case "$versionAlias" in
						latest) ;;
						*)
							variantAliases+=( "$versionAlias-$variant" )
							;;
					esac
				done
				;;
			*)
				variantAliases+=( "$version-$variant" )
				;;
		esac

		echo
		if [ -z "$variant" ]; then
			echo "# $version -- $description"
		fi
		cat <<-EOE
			Tags: $(join ', ' "${variantAliases[@]}")
			Architectures: $(join ', ' "${variantArches[@]}")
		EOE
		if [ "$ociOrDockerfile" = 'oci' ]; then
			cat <<-EOE
				Builder: oci-import
				Directory: $variantDir/oci
				File: index.json
			EOE
		elif [ "$ociOrDockerfile" = 'Dockerfile' ]; then
			cat <<-EOE
				Directory: $variantDir
			EOE
		else
			echo >&2 "error: unknown 'ociOrDockerfile' value: '$ociOrDockerfile'"
			exit 1
		fi
	done
done
