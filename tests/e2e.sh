#!/bin/sh
set -eu

: "${MRSK_BIN:?MRSK_BIN is required}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

export HOME="$tmp/home"
export OPEN_LOG="$tmp/open.log"
export VIM_LOG="$tmp/vim.log"
project="$tmp/example_project"
second_project="$tmp/another_project"
mkdir -p "$HOME" "$tmp/bin" "$project/rebuild" "$second_project/main"

cat > "$tmp/bin/open" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$OPEN_LOG"
EOF
cat > "$tmp/bin/vim" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$VIM_LOG"
EOF
cp "$tmp/bin/open" "$tmp/bin/xdg-open"
chmod +x "$tmp/bin/open" "$tmp/bin/xdg-open" "$tmp/bin/vim"
ln -s "$MRSK_BIN" "$tmp/bin/mrsk"
PATH="$tmp/bin:$PATH"
export PATH

"$MRSK_BIN" --help | grep -q "  mrsk configure"
"$MRSK_BIN" configure
test -d "$HOME/.mrsk"
test "$(cat "$VIM_LOG")" = "$HOME/.mrsk/config.yml"

git -C "$project/rebuild" init -q -b rebuild
git -C "$project/rebuild" config user.name Test
git -C "$project/rebuild" config user.email test@example.com
touch "$project/rebuild/README"
printf '.env\nstorage/\n' > "$project/rebuild/.gitignore"
printf 'secret\n' > "$project/rebuild/.env"
mkdir -p "$project/rebuild/storage/cache"
printf 'cached\n' > "$project/rebuild/storage/cache/data"
git -C "$project/rebuild" add README .gitignore
git -C "$project/rebuild" commit -qm initial
mkdir -p "$project/rebuild/db/migrate"
touch "$project/rebuild/db/migrate/20260709120000_old.rb"
touch "$project/rebuild/db/migrate/20260710153045_new.rb"
printf '%s\n' \
    '<<<<<<< HEAD' \
    'ActiveRecord::Schema[8.0].define(version: 2026_07_09_120000) do' \
    '=======' \
    'ActiveRecord::Schema[8.0].define(version: 2026_07_10_100000) do' \
    '>>>>>>> feature' \
    'end' > "$project/rebuild/db/schema.rb"
(cd "$project/rebuild" && "$MRSK_BIN" rails-schema-confl)
test "$(cat "$project/rebuild/db/schema.rb")" = 'ActiveRecord::Schema[8.0].define(version: 2026_07_10_153045) do
end'

git -C "$second_project/main" init -q -b main
git -C "$second_project/main" config user.name Test
git -C "$second_project/main" config user.email test@example.com
touch "$second_project/main/README"
git -C "$second_project/main" add README
git -C "$second_project/main" commit -qm initial

cat > "$HOME/.mrsk/config.yml" <<EOF
redmine_url: redmine.example.test/
projects:
  - project_name: example_project
    project_root: "$project/rebuild"
    main_branch: rebuild
    copy_files:
      - .env
    copy_folders:
      - storage
  - project_name: another_project
    project_root: "$second_project/main"
    main_branch: main
EOF

git -C "$project/rebuild" switch -qc DEV-3454
(cd "$project/rebuild" && "$MRSK_BIN" redmine)
test "$(cat "$OPEN_LOG")" = "https://redmine.example.test/issues/3454"

git -C "$project/rebuild" switch -qc feature/no-issue
if (cd "$project/rebuild" && "$MRSK_BIN" redmine >"$tmp/redmine-branch.out" 2>&1); then
    echo "expected redmine to reject a branch without an issue ID" >&2
    exit 1
fi
grep -q "current branch does not end with an issue number" "$tmp/redmine-branch.out"
git -C "$project/rebuild" switch -q rebuild

"$MRSK_BIN" example_project new feature/login
test -d "$project/feature-login"
test "$(git -C "$project/feature-login" branch --show-current)" = feature/login
test "$(cat "$project/feature-login/.env")" = secret
test "$(cat "$project/feature-login/storage/cache/data")" = cached
"$MRSK_BIN" example_project list | grep -q feature/login
if [ "$(uname -s)" = Darwin ]; then
    "$MRSK_BIN" example_project open feature/login
    test "$(sed -n '1p' "$OPEN_LOG")" = -a
    test "$(sed -n '2p' "$OPEN_LOG")" = Terminal
    test "$(sed -n '3p' "$OPEN_LOG")" = "$project/feature-login"
else
    open_status=0
    "$MRSK_BIN" example_project open feature/login >"$tmp/open.out" 2>&1 || open_status=$?
    test "$open_status" -eq 1
    grep -q 'macOS only' "$tmp/open.out"
    updater_status=0
    PATH="$(dirname "$MRSK_BIN"):$PATH" "$MRSK_BIN" example_project updater status \
        >"$tmp/updater.out" 2>&1 || updater_status=$?
    test "$updater_status" -eq 1
    grep -q 'macOS only' "$tmp/updater.out"
fi
"$MRSK_BIN" example_project remove feature/login
test ! -e "$project/feature-login"

"$MRSK_BIN" another_project new feature/api
test -d "$second_project/feature-api"
test "$(git -C "$second_project/feature-api" branch --show-current)" = feature/api
"$MRSK_BIN" another_project remove feature/api
test ! -e "$second_project/feature-api"

if "$MRSK_BIN" list >"$tmp/ambiguous.out" 2>&1; then
    echo "expected project selection to be required" >&2
    exit 1
fi
grep -q "multiple projects configured" "$tmp/ambiguous.out"

for directory in "$project" "$project/rebuild" "$project/rebuild/db/migrate"; do
    branch="auto-$(basename "$directory")"
    (cd "$directory" && "$MRSK_BIN" new "$branch")
    test -d "$project/$branch"
    "$MRSK_BIN" example_project remove "$branch"
done

cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: example_project
    project_root: "$project/rebuild"
    main_branch: rebuild
    default: true
    prefix: DEV
  - project_name: another_project
    project_root: "$second_project/main"
    main_branch: main
EOF

(cd "$HOME" && "$MRSK_BIN" new DEV-000)
test -d "$project/DEV-000"
"$MRSK_BIN" example_project remove DEV-000

(cd "$HOME" && "$MRSK_BIN" new 2490)
test -d "$project/DEV-2490"
"$MRSK_BIN" example_project remove DEV-2490

HOME="$HOME" PROJECT="$project" zsh -c '
    eval "$(command mrsk shell-init)"
    cd "$HOME"
    mrsk 2491
    test "$PWD" = "$PROJECT/DEV-2491"
    mrsk 2491
    test "$PWD" = "$PROJECT/DEV-2491"
    cd "$HOME"
    mrsk DEV-2491
    test "$PWD" = "$PROJECT/DEV-2491"
'
"$MRSK_BIN" example_project remove DEV-2491

"$MRSK_BIN" example_project new delete/one
"$MRSK_BIN" example_project new delete/two
GIT_PROTECTED_BRANCHES="delete/two,other" "$MRSK_BIN" example_project delete_all
test -d "$project/rebuild"
test ! -e "$project/delete-one"
test -d "$project/delete-two"
! git -C "$project/rebuild" show-ref --verify --quiet refs/heads/delete/one
git -C "$project/rebuild" show-ref --verify --quiet refs/heads/delete/two
"$MRSK_BIN" example_project delete_all
test ! -e "$project/delete-two"
if git -C "$project/rebuild" show-ref --verify --quiet refs/heads/delete/one ||
    git -C "$project/rebuild" show-ref --verify --quiet refs/heads/delete/two; then
    echo "expected delete_all to remove related branches" >&2
    exit 1
fi
test "$("$MRSK_BIN" example_project list | wc -l | tr -d ' ')" = 1

cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: example_project
    project_root: "$project/rebuild"
    main_branch: rebuild
    default: true
  - project_name: another_project
    project_root: "$second_project/main"
    main_branch: main
    default: true
EOF
if "$MRSK_BIN" list >"$tmp/default.out" 2>&1; then
    echo "expected duplicate defaults to be rejected" >&2
    exit 1
fi
grep -q "only one project can be default" "$tmp/default.out"

cat > "$HOME/.mrsk/config.yml" <<EOF
project_root: "$project/rebuild"
main_branch: rebuild
EOF
"$MRSK_BIN" list | grep -q '\[rebuild\]'
git -C "$project/rebuild" switch -q DEV-3454
if (cd "$project/rebuild" && "$MRSK_BIN" redmine >"$tmp/redmine-config.out" 2>&1); then
    echo "expected redmine to require redmine_url" >&2
    exit 1
fi
grep -q "redmine_url is not configured" "$tmp/redmine-config.out"

echo "e2e: ok"
