#!/bin/bash
# Build OpenSSL with the legacy provider inside libcrypto.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
version=3.5.9
sha256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
url="https://github.com/openssl/openssl/releases/download/openssl-$version/openssl-$version.tar.gz"
deployment_target=26.0
recipe="$(shasum -a 256 scripts/build-openssl.sh | cut -d ' ' -f 1)"
cache="$root/.build/openssl"
archive="$root/.build/downloads/openssl-$version.tar.gz"
prefix="$cache/$recipe/$version"
if [ ! -f "$prefix/source.sha256" ]; then
  mkdir -p "$cache" "$(dirname "$archive")" "$(dirname "$prefix")"
  work="$(mktemp -d "$cache/build.XXXXXXXX")"
  trap 'rm -rf -- "$work"' EXIT
  if [ ! -f "$archive" ]; then
    printf 'Downloading pinned OpenSSL %s source\n' "$version" >&2
    curl --fail --silent --show-error --location --retry 2 --max-time 120 "$url" -o "$work/source.tar.gz"
    printf '%s  %s\n' "$sha256" "$work/source.tar.gz" | shasum -a 256 -c >&2
    mv "$work/source.tar.gz" "$archive"
  else
    printf '%s  %s\n' "$sha256" "$archive" | shasum -a 256 -c >&2
  fi
  tar -xzf "$archive" -C "$work"
  mkdir "$work/objects"
  (
    cd "$work/objects"
    export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
    # OpenSSL embeds its compiler flags. Use relative source paths so the
    # build metadata contains no developer checkout paths.
    perl "../openssl-$version/Configure" darwin64-arm64-cc \
      no-shared no-module no-dso no-tests no-apps \
      --prefix=/usr/local --openssldir=/etc/ssl --libdir=lib
    make -j4 build_libs
    make DESTDIR="$work/install" install_dev
  ) >&2
  install -m 644 "$work/openssl-$version/LICENSE.txt" "$work/install/usr/local/LICENSE.txt"
  printf '%s\n' "$sha256" > "$work/install/usr/local/source.sha256"
  mv "$work/install/usr/local" "$prefix"
fi
printf '%s\n' "$prefix"
