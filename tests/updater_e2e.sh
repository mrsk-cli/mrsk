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
legacy_new=org.example.worktree-target-branch-updater
legacy_old=org.example.work.updater

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

legacy_fixture()
{
    cp "$tmp/template.plist" "$agents/$1.plist"
    plutil -replace Label -string "$1" "$agents/$1.plist"
}

load_fixture()
{
    launchctl bootstrap "$domain" "$agents/$1.plist"
}

assert_legacy_removed()
{
    test ! -e "$agents/$legacy_new.plist"
    test ! -e "$agents/$legacy_old.plist"
    ! is_loaded "$legacy_new"
    ! is_loaded "$legacy_old"
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
cp "$plist" "$tmp/template.plist"
updater start # Idempotent: fake launchctl rejects duplicate bootstraps.
updater stop
test ! -e "$plist"
! is_loaded "$label"
expect_failure updater status

# Matching filenames alone, mismatched labels, and command lookalikes are not owned.
unrelated=org.unrelated.work.updater
legacy_fixture "$unrelated"
plutil -replace ProgramArguments.0 -string /usr/bin/true "$agents/$unrelated.plist"
load_fixture "$unrelated"
mismatch=org.mismatch.worktree-target-branch-updater
legacy_fixture "$mismatch"
plutil -replace Label -string org.other.service "$agents/$mismatch.plist"
load_fixture "$mismatch"
override=org.override.work.updater
legacy_fixture "$override"
plutil -insert Program -string /usr/bin/true "$agents/$override.plist"
load_fixture "$override"
extra=org.extra.work.updater
legacy_fixture "$extra"
plutil -insert ProgramArguments.4 -string extra "$agents/$extra.plist"
load_fixture "$extra"
linked=org.linked.work.updater
legacy_fixture "$linked"
mv "$agents/$linked.plist" "$tmp/linked.plist"
ln -s "$tmp/linked.plist" "$agents/$linked.plist"
load_fixture "$linked"
expect_failure updater status

# Both legacy label variants are detected and migrated when actually loaded.
legacy_fixture "$legacy_new"
legacy_fixture "$legacy_old"
load_fixture "$legacy_new"
load_fixture "$legacy_old"
updater status | grep -q 'running (legacy'
updater start
is_loaded "$label"
assert_legacy_removed

# Already-current services must still clean up loaded and unloaded legacy plists.
legacy_fixture "$legacy_new"
legacy_fixture "$legacy_old"
load_fixture "$legacy_old"
updater start
is_loaded "$label"
assert_legacy_removed
updater stop

# Unloaded legacy files also migrate, and stop handles legacy-only installations.
legacy_fixture "$legacy_new"
legacy_fixture "$legacy_old"
updater start
assert_legacy_removed
updater stop
legacy_fixture "$legacy_new"
legacy_fixture "$legacy_old"
load_fixture "$legacy_old"
updater stop
assert_legacy_removed

# Validate installation before touching a working legacy service. Use an isolated
# helper copy with no app alongside it, without altering the built app.
mkdir "$tmp/missing-app"
cp "$(dirname "$MRSK_BIN")/worktree-target-branch-updater" "$tmp/missing-app/"
legacy_fixture "$legacy_new"
load_fixture "$legacy_new"
expect_failure env PATH="$tmp/missing-app:$PATH" \
    "$tmp/missing-app/worktree-target-branch-updater" start "$project/rebuild" rebuild
is_loaded "$legacy_new"
test -f "$agents/$legacy_new.plist"

# A failed new bootstrap restores all previously loaded legacy services and
# preserves their plists plus any existing (unloaded) current plist.
legacy_fixture "$legacy_old"
load_fixture "$legacy_old"
cp "$tmp/template.plist" "$plist"
plutil -replace StartInterval -integer 900 "$plist"
cp "$plist" "$tmp/previous.plist"
fail_once bootstrap "$label"
expect_failure updater start
! is_loaded "$label"
is_loaded "$legacy_new"
is_loaded "$legacy_old"
cmp "$plist" "$tmp/previous.plist"
test -f "$agents/$legacy_new.plist"
test -f "$agents/$legacy_old.plist"
rm "$plist"
fail_once bootstrap "$label"
expect_failure updater start
test ! -e "$plist"
is_loaded "$legacy_new"
is_loaded "$legacy_old"

# Failure on the second legacy bootout restores the first and leaves both files.
fail_once bootout "$legacy_old"
expect_failure updater start
! is_loaded "$label"
is_loaded "$legacy_new"
is_loaded "$legacy_old"
test -f "$agents/$legacy_new.plist"
test -f "$agents/$legacy_old.plist"
updater start
assert_legacy_removed

# Current bootout failure preserves its plist and rolls back legacy shutdown.
legacy_fixture "$legacy_old"
load_fixture "$legacy_old"
fail_once bootout "$label"
expect_failure updater stop
is_loaded "$label"
is_loaded "$legacy_old"
test -f "$plist"
test -f "$agents/$legacy_old.plist"

# Already-running migration and stop also report legacy bootout failures.
fail_once bootout "$legacy_old"
expect_failure updater start
is_loaded "$label"
is_loaded "$legacy_old"
fail_once bootout "$legacy_old"
expect_failure updater stop
is_loaded "$label"
is_loaded "$legacy_old"
updater stop
assert_legacy_removed
test ! -e "$plist"
! is_loaded "$label"

# Every unrelated agent and file survived all lifecycle/migration operations.
for other in "$unrelated" "$override" "$extra" "$linked"; do
    is_loaded "$other"
    test -f "$agents/$other.plist"
done
is_loaded org.other.service
test -f "$agents/$mismatch.plist"
test -L "$agents/$linked.plist"
expect_failure updater status

printf 'GEM\nupdated\n' > "$source/Gemfile.lock"
touch "$source/db/migrate/20260812000000_new.rb"
git -C "$source" add Gemfile.lock db/migrate
git -C "$source" commit -qm update
git -C "$source" push -qu ups rebuild

git -C "$project/rebuild" rev-parse HEAD > "$project/rebuild/.git/work-updater-head"
touch "$BUNDLE_FAIL_ONCE"
if "$MRSK_BIN" example_project updater run; then
    echo "expected the first bundle install to fail" >&2
    exit 1
fi
test ! -e "$RAILS_LOG"
test ! -e "$project/rebuild/.git/work-updater-head"
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
