#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
version=${1:?Usage: build-deb.sh VERSION}
dpkg --validate-version "$version"
architecture=$(dpkg --print-architecture)
case "$architecture" in amd64|arm64) ;; *) exit 1 ;; esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
package="$tmp/package"
make mrsk dist/ocr
install -d "$package/DEBIAN" "$package/usr/bin" "$package/usr/lib/mrsk" \
    "$package/usr/share/doc/mrsk" "$tmp/debian" dist/deb
install -m 0755 packaging/deb/mrsk "$package/usr/bin/mrsk"
install -m 0755 mrsk dist/ocr worktree-target-branch-updater "$package/usr/lib/mrsk/"
strip "$package/usr/lib/mrsk/mrsk"
install -m 0644 LICENSE "$package/usr/share/doc/mrsk/copyright"
install -m 0644 third_party/open-code-review/LICENSE "$package/usr/share/doc/mrsk/open-code-review.LICENSE"
install -m 0644 README.md "$package/usr/share/doc/mrsk/README.md"
cat > "$tmp/debian/control" <<EOF
Source: mrsk

Package: mrsk
Architecture: $architecture
EOF
dependencies=$(cd "$tmp" && dpkg-shlibdeps -O -e "$package/usr/lib/mrsk/mrsk")
dependencies=${dependencies#shlibs:Depends=}
cat > "$package/DEBIAN/control" <<EOF
Package: mrsk
Version: $version
Section: devel
Priority: optional
Architecture: $architecture
Maintainer: Anton Ivanov <anton.i@hey.com>
Depends: $dependencies, git (>= 2.41), ruby, zsh, ca-certificates
Suggests: vim, postgresql-client, xdg-utils
Installed-Size: $(du -sk "$package/usr" | cut -f1)
Homepage: https://github.com/mrsk-cli/mrsk
Description: Manage Git worktrees beside a configured main checkout
 Includes a private copy of open-code-review for the mrsk review command.
EOF
dpkg-deb --root-owner-group --build "$package" "dist/deb/mrsk_${version}_${architecture}.deb"
