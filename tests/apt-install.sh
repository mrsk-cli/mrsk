#!/bin/sh
set -eu

repository=${1:?Usage: apt-install.sh REPOSITORY VERSION}
version=${2:?VERSION is required}
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl
install -d -m 0755 /etc/apt/keyrings
case "$repository" in
    file:*) cp "${repository#file:}/mrsk.gpg" /etc/apt/keyrings/mrsk.gpg ;;
    https:*) curl -fsSL "$repository/mrsk.gpg" -o /etc/apt/keyrings/mrsk.gpg ;;
    *) exit 1 ;;
esac
chmod 0644 /etc/apt/keyrings/mrsk.gpg
cat > /etc/apt/sources.list.d/mrsk.sources <<EOF
Types: deb
URIs: $repository
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/mrsk.gpg
EOF
apt-get update
apt-get install -y --no-install-recommends "mrsk=$version"
test "$(dpkg-query -W -f='${Version}' mrsk)" = "$version"
test -x /usr/lib/mrsk/ocr
test "$(command -v mrsk)" = /usr/bin/mrsk
mrsk shell-init | grep -q 'mrsk()'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/home/.mrsk" "$tmp/project/main"
git -C "$tmp/project/main" init -q -b main
git -C "$tmp/project/main" config user.name Test
git -C "$tmp/project/main" config user.email test@example.com
printf 'package main\n' > "$tmp/project/main/example.go"
git -C "$tmp/project/main" add example.go
git -C "$tmp/project/main" commit -qm initial
cat > "$tmp/home/.mrsk/config.yml" <<EOF
projects:
  - project_name: example
    project_root: $tmp/project/main
    main_branch: main
EOF
env HOME="$tmp/home" mrsk new apt-smoke
test -f "$tmp/project/apt-smoke/.git"
env HOME="$tmp/home" mrsk remove apt-smoke
test ! -d "$tmp/project/apt-smoke"
printf '\nfunc main() {}\n' >> "$tmp/project/main/example.go"
(cd "$tmp/project/main" && env HOME="$tmp/home" mrsk review --preview > "$tmp/review.out")
grep -q 'Will review (1)' "$tmp/review.out"
grep -q example.go "$tmp/review.out"
apt-get remove -y mrsk
test ! -e /usr/bin/mrsk
test ! -e /usr/lib/mrsk/ocr
test -f "$tmp/home/.mrsk/config.yml"
printf 'APT install, worktrees, review and removal passed (%s).\n' "$(dpkg --print-architecture)"
