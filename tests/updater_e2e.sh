#!/bin/sh
set -eu

: "${MRSK_BIN:?MRSK_BIN is required}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

export HOME="$tmp/home"
export BUNDLE_LOG="$tmp/bundle.log"
export BUNDLE_FAIL_ONCE="$tmp/bundle.fail-once"
export RAILS_LOG="$tmp/rails.log"
export LAUNCHCTL_LOG="$tmp/launchctl.log"
export LAUNCHCTL_STATE="$tmp/launchctl.state"
project="$tmp/orient_sales_portal"
source="$tmp/source"
remote="$tmp/remote.git"
mkdir -p "$HOME/.mrsk" "$tmp/bin" "$project"

cat > "$tmp/bin/bundle" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$BUNDLE_LOG"
if [ -e "$BUNDLE_FAIL_ONCE" ]; then
    rm "$BUNDLE_FAIL_ONCE"
    exit 1
fi
EOF
cat > "$tmp/bin/launchctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
case "$1" in
    print) test -f "$LAUNCHCTL_STATE" ;;
    bootstrap) : > "$LAUNCHCTL_STATE" ;;
    bootout) rm -f "$LAUNCHCTL_STATE" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/bundle" "$tmp/bin/launchctl"
PATH="$tmp/bin:$(dirname "$MRSK_BIN"):$PATH"
export PATH

app="$(dirname "$MRSK_BIN")/dist/Worktree Target Branch Updater.app"
test "$(plutil -extract CFBundleDisplayName raw "$app/Contents/Info.plist")" = \
    "Worktree Target Branch Updater"
test -s "$app/Contents/Resources/WorktreeTargetBranchUpdater.icns"
codesign --verify --deep --strict "$app"

git init -q --bare "$remote"
git init -q -b rebuild "$source"
git -C "$source" config user.name Test
git -C "$source" config user.email test@example.com
mkdir -p "$source/bin" "$source/db/migrate"
cat > "$source/bin/rails" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RAILS_LOG"
EOF
chmod +x "$source/bin/rails"
printf 'source "https://rubygems.org"\n' > "$source/Gemfile"
printf 'GEM\n' > "$source/Gemfile.lock"
touch "$source/db/migrate/20260801000000_base.rb"
git -C "$source" add .
git -C "$source" commit -qm initial
git -C "$source" remote add ups "$remote"
git -C "$source" push -qu ups rebuild

git clone -q -b rebuild "$remote" "$project/rebuild"
git -C "$project/rebuild" remote rename origin ups

cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: orient_sales_portal
    project_root: "$project/rebuild"
    main_branch: rebuild
    default: true
EOF

if [ "$(uname -s)" = Darwin ]; then
    "$MRSK_BIN" orient_sales_portal updater start
    test -f "$LAUNCHCTL_STATE"
    plist="$HOME/Library/LaunchAgents/dev.matecube.worktree-target-branch-updater.plist"
    plutil -lint "$plist" >/dev/null
    grep -q '<integer>600</integer>' "$plist"
    grep -q '<string>.*/Worktree Target Branch Updater.app/Contents/MacOS/Worktree Target Branch Updater</string>' "$plist"
    grep -Fq "<string>$project/rebuild</string>" "$plist"
    grep -q '<string>__worktree-target-branch-updater-run</string>' "$plist"
    "$MRSK_BIN" orient_sales_portal updater status | grep -q 'Updater is running'
    "$MRSK_BIN" orient_sales_portal updater stop
    test ! -e "$plist"
    test ! -e "$LAUNCHCTL_STATE"
fi

printf 'GEM\nupdated\n' > "$source/Gemfile.lock"
touch "$source/db/migrate/20260812000000_new.rb"
git -C "$source" add Gemfile.lock db/migrate
git -C "$source" commit -qm update
git -C "$source" push -qu ups rebuild

git -C "$project/rebuild" rev-parse HEAD > "$project/rebuild/.git/work-updater-head"
touch "$BUNDLE_FAIL_ONCE"
if "$MRSK_BIN" orient_sales_portal updater run; then
    echo "expected the first bundle install to fail" >&2
    exit 1
fi
test ! -e "$RAILS_LOG"
test ! -e "$project/rebuild/.git/work-updater-head"
test -f "$project/rebuild/.git/mrsk-updater-head"

"$MRSK_BIN" orient_sales_portal updater run
test "$(wc -l < "$BUNDLE_LOG" | tr -d ' ')" = 2
test "$(cat "$RAILS_LOG")" = db:migrate
test "$(git -C "$project/rebuild" rev-parse HEAD)" = \
    "$(git -C "$source" rev-parse HEAD)"

"$MRSK_BIN" orient_sales_portal updater run
test "$(wc -l < "$BUNDLE_LOG" | tr -d ' ')" = 2
test "$(wc -l < "$RAILS_LOG" | tr -d ' ')" = 1

echo "updater e2e: ok"
