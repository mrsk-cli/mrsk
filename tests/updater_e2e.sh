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
export LAUNCHCTL_FAILURES="$tmp/launchctl.failures"
mkdir -p "$LAUNCHCTL_STATE" "$LAUNCHCTL_FAILURES"
project="$tmp/example_project"
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
set -eu
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
case "$1" in
    print|bootout) service=$2 ;;
    bootstrap)
        label=$(plutil -extract Label raw "$3")
        service="$2/$label"
        ;;
    *) exit 1 ;;
esac
key=$(printf '%s' "$service" | tr / _)
if [ -e "$LAUNCHCTL_FAILURES/$1-$key" ]; then
    rm "$LAUNCHCTL_FAILURES/$1-$key"
    exit 1
fi
case "$1" in
    print) test -f "$LAUNCHCTL_STATE/$key" ;;
    bootstrap)
        test ! -e "$LAUNCHCTL_STATE/$key"
        printf '%s\n' "$3" > "$LAUNCHCTL_STATE/$key"
        ;;
    bootout)
        test -f "$LAUNCHCTL_STATE/$key"
        rm "$LAUNCHCTL_STATE/$key"
        ;;
esac
EOF
chmod +x "$tmp/bin/bundle" "$tmp/bin/launchctl"
PATH="$tmp/bin:$(dirname "$MRSK_BIN"):$PATH"
export PATH

app="$(dirname "$MRSK_BIN")/dist/Worktree Target Branch Updater.app"
test "$(plutil -extract CFBundleDisplayName raw "$app/Contents/Info.plist")" = \
    "Worktree Target Branch Updater"
test "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = \
    io.github.mrsk-cli.worktree-target-branch-updater
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
  - project_name: example_project
    project_root: "$project/rebuild"
    main_branch: rebuild
    default: true
EOF

label=io.github.mrsk-cli.worktree-target-branch-updater
domain="gui/$(id -u)"
agents="$HOME/Library/LaunchAgents"
plist="$agents/$label.plist"

updater()
{
    "$MRSK_BIN" example_project updater "$1"
}

expect_failure()
{
    if "$@"; then
        echo "expected failure: $*" >&2
        exit 1
    fi
}

is_loaded()
{
    test -f "$LAUNCHCTL_STATE/$(printf '%s' "$domain/$1" | tr / _)"
}

fail_once()
{
    touch "$LAUNCHCTL_FAILURES/$1-$(printf '%s' "$domain/$2" | tr / _)"
}

expect_failure updater status
updater start
is_loaded "$label"
plutil -lint "$plist" >/dev/null
grep -q '<integer>600</integer>' "$plist"
grep -q '<string>.*/Worktree Target Branch Updater.app/Contents/MacOS/Worktree Target Branch Updater</string>' "$plist"
grep -Fq "<string>$project/rebuild</string>" "$plist"
grep -q '<string>__worktree-target-branch-updater-run</string>' "$plist"
updater status | grep -q 'Updater is running'
updater start # Idempotent: fake launchctl rejects duplicate bootstraps.
updater stop
test ! -e "$plist"
! is_loaded "$label"
expect_failure updater status

# Validate installation before writing a plist. Use an isolated helper copy
# with no app alongside it, without altering the built app.
mkdir "$tmp/missing-app"
cp "$(dirname "$MRSK_BIN")/worktree-target-branch-updater" "$tmp/missing-app/"
expect_failure env PATH="$tmp/missing-app:$PATH" \
    "$tmp/missing-app/worktree-target-branch-updater" start "$project/rebuild" rebuild
test ! -e "$plist"

# A failed bootstrap leaves no plist behind.
fail_once bootstrap "$label"
expect_failure updater start
! is_loaded "$label"
test ! -e "$plist"

# A failed bootout keeps the service and its plist.
updater start
fail_once bootout "$label"
expect_failure updater stop
is_loaded "$label"
test -f "$plist"
updater stop
test ! -e "$plist"
! is_loaded "$label"

printf 'GEM\nupdated\n' > "$source/Gemfile.lock"
touch "$source/db/migrate/20260812000000_new.rb"
git -C "$source" add Gemfile.lock db/migrate
git -C "$source" commit -qm update
git -C "$source" push -qu ups rebuild

touch "$BUNDLE_FAIL_ONCE"
if "$MRSK_BIN" example_project updater run; then
    echo "expected the first bundle install to fail" >&2
    exit 1
fi
test ! -e "$RAILS_LOG"
test -f "$project/rebuild/.git/mrsk-updater-head"

"$MRSK_BIN" example_project updater run
test "$(wc -l < "$BUNDLE_LOG" | tr -d ' ')" = 2
test "$(cat "$RAILS_LOG")" = db:migrate
test "$(git -C "$project/rebuild" rev-parse HEAD)" = \
    "$(git -C "$source" rev-parse HEAD)"

"$MRSK_BIN" example_project updater run
test "$(wc -l < "$BUNDLE_LOG" | tr -d ' ')" = 2
test "$(wc -l < "$RAILS_LOG" | tr -d ' ')" = 1

echo "updater e2e: ok"
