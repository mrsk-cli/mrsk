#!/bin/sh
# Replaces third_party/open-code-review with the Go sources of an upstream
# open-code-review release: only what `go build ./cmd/opencodereview` needs.
set -eu

[ "$#" -eq 1 ] || { echo "Usage: $0 <tag>  (for example v1.12.9)" >&2; exit 2; }

tag=$1
destination=$(cd "$(dirname "$0")" && pwd)/open-code-review
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" https://github.com/alibaba/open-code-review.git "$tmp/src"
rm -rf "$destination"
mkdir -p "$destination"
cp -R "$tmp/src/LICENSE" "$tmp/src/go.mod" "$tmp/src/go.sum" \
    "$tmp/src/cmd" "$tmp/src/internal" "$destination/"
find "$destination" -name '*_test.go' -exec rm -f {} +
# Remove directories left empty by the test cleanup.
find "$destination" -depth -type d -empty -exec rmdir {} +
printf '%s\n' "$tag" > "$destination/VERSION"
(cd "$destination" && go build -o /dev/null ./cmd/opencodereview)
echo "Vendored open-code-review $tag ($(git -C "$tmp/src" rev-parse HEAD))"
