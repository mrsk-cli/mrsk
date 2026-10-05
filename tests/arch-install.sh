#!/bin/sh
set -eu

# Run only in the disposable Arch CI container, after makepkg has finished.
package=${1:?Usage: arch-install.sh PACKAGE}
version=${2:?VERSION is required}
pacman -U --noconfirm "$package"
test "$(pacman -Q mrsk)" = "mrsk $version"
test "$(command -v mrsk)" = /usr/bin/mrsk
test ! -e /usr/bin/ocr
test -x /usr/lib/mrsk/mrsk
test -x /usr/lib/mrsk/ocr
test -f /usr/share/licenses/mrsk/LICENSE
test -f /usr/share/licenses/mrsk/open-code-review.LICENSE
test -f /usr/share/licenses/mrsk/open-code-review.icons.NOTICE
test -f /usr/share/doc/mrsk/README.md

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
chmod 755 "$tmp"
mkdir -p "$tmp/home/.mrsk" "$tmp/project/main" "$tmp/bin"
printf '# existing shell configuration\n' > "$tmp/home/.zshrc"
cp "$tmp/home/.zshrc" "$tmp/zshrc.before"
# A public ocr earlier in PATH must not be used by the mrsk wrapper.
printf '#!/bin/sh\necho unrelated-ocr\nexit 99\n' > "$tmp/bin/ocr"
chmod 755 "$tmp/bin/ocr"
chown -R builder:builder "$tmp/home" "$tmp/project"
runuser -u builder -- env HOME="$tmp/home" PATH="$tmp/bin:$PATH" sh -eu -c '
    tmp=$1
    git -C "$tmp/project/main" init -q -b main
    git -C "$tmp/project/main" config user.name Test
    git -C "$tmp/project/main" config user.email test@example.com
    printf "package main\n" > "$tmp/project/main/example.go"
    git -C "$tmp/project/main" add example.go
    git -C "$tmp/project/main" commit -qm initial
    cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: example
    project_root: $tmp/project/main
    main_branch: main
EOF
    mrsk --help >/dev/null
    mrsk shell-init | grep -q "mrsk()"
    zsh -c '\''eval "$(command mrsk shell-init)"; mrsk --help >/dev/null'\''
    /usr/lib/mrsk/ocr --version | grep -q v1.12.9
    mrsk new arch-smoke
    test -f "$tmp/project/arch-smoke/.git"
    mrsk list | grep -q arch-smoke
    mrsk remove arch-smoke
    test ! -d "$tmp/project/arch-smoke"
    printf "\nfunc main() {}\n" >> "$tmp/project/main/example.go"
    cd "$tmp/project/main"
    mrsk review --preview > "$HOME/review.out"
    grep -q "Will review (1)" "$HOME/review.out"
    grep -q example.go "$HOME/review.out"
' sh "$tmp"
cp "$tmp/home/.mrsk/config.yml" "$tmp/config.before"
pacman -R --noconfirm mrsk
test ! -e /usr/bin/mrsk
test ! -e /usr/lib/mrsk
cmp "$tmp/config.before" "$tmp/home/.mrsk/config.yml"
cmp "$tmp/zshrc.before" "$tmp/home/.zshrc"
grep -q unrelated-ocr "$tmp/bin/ocr"
printf 'Arch install, worktrees, private review and removal passed (%s).\n' "$(uname -m)"
