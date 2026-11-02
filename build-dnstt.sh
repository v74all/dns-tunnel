#!/usr/bin/env bash
# Builds the dnstt release binaries from David Fifield's signed source zip.
# Same Go version + same zip = the same bytes, so anyone can check the release.
#   bash build-dnstt.sh [OUTDIR]
set -euo pipefail

DNSTT=dnstt-20260501
DNSTT_SHA=a7b21d3d787570d9127643e360e150d2da7b33aa8039d0546a04dcfe8ee1864f
GO_WANT=go1.26.8

here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "${1:-$here/dist}" && cd "${1:-$here/dist}" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

command -v go >/dev/null || { echo "go is required ($GO_WANT)" >&2; exit 1; }
[ "$(go env GOVERSION)" = "$GO_WANT" ] || { echo "need $GO_WANT for identical bytes, have $(go env GOVERSION)" >&2; exit 1; }

curl -fsSL --retry 3 -o "$work/$DNSTT.zip" "https://www.bamsoftware.com/software/dnstt/$DNSTT.zip"
[ "$(sha256sum "$work/$DNSTT.zip" | cut -d' ' -f1)" = "$DNSTT_SHA" ] || { echo "sha256 mismatch: $DNSTT.zip" >&2; exit 1; }
(cd "$work" && unzip -q "$DNSTT.zip")

export CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS=-mod=readonly
build() { # dir os arch name
	(cd "$work/$DNSTT/$1" && GOOS=$2 GOARCH=$3 go build -trimpath -ldflags='-s -w -buildid=' -o "$out/$4")
}
for arch in amd64 arm64; do
	build dnstt-server linux "$arch" "dnstt-server-linux-$arch"
	build dnstt-client linux "$arch" "dnstt-client-linux-$arch"
	build dnstt-client darwin "$arch" "dnstt-client-macos-$arch"
	build dnstt-client windows "$arch" "dnstt-client-windows-$arch.exe"
done
(cd "$out" && sha256sum dnstt-* > SHA256SUMS && cat SHA256SUMS)
