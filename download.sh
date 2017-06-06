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
