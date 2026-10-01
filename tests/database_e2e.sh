#!/bin/sh
set -eu

: "${MRSK_BIN:?MRSK_BIN is required}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

export HOME="$tmp/home"
export PSQL_LOG="$tmp/psql.log"
export PSQL_VERSIONS="$tmp/versions"
unset DATABASE_URL
project="$tmp/example_project"
mkdir -p "$HOME/.mrsk" "$tmp/bin" "$project/main"

cat > "$tmp/bin/psql" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$PSQL_LOG"
case "$*" in *"SELECT version FROM schema_migrations"*) cat "$PSQL_VERSIONS" ;; esac
EOF
chmod +x "$tmp/bin/psql"
ln -s "$MRSK_BIN" "$tmp/bin/mrsk"
PATH="$tmp/bin:$PATH"
export PATH

git -C "$project/main" init -q -b main
git -C "$project/main" config user.name Test
git -C "$project/main" config user.email test@example.com
printf '.env\ntmp/\n' > "$project/main/.gitignore"
printf 'KEY=value\nDATABASE_URL=postgresql://postgres:postgres@localhost:5400/app_development\n' \
    > "$project/main/.env"
mkdir -p "$project/main/bin" "$project/main/db/migrate"
cat > "$project/main/bin/rails" <<'EOF'
#!/bin/sh
echo "rails $@"
EOF
chmod +x "$project/main/bin/rails"
touch "$project/main/db/migrate/20260801000000_base.rb"
git -C "$project/main" add .gitignore bin/rails db/migrate
git -C "$project/main" commit -qm initial
git -C "$project/main" branch base
touch "$project/main/db/migrate/20260802000000_extra.rb"
git -C "$project/main" add db/migrate
git -C "$project/main" commit -qm extra
git -C "$project/main" branch feature/mig
git -C "$project/main" reset -q --hard base

cat > "$HOME/.mrsk/config.yml" <<EOF
project_root: "$project/main"
main_branch: main
copy_files:
  - .env
EOF

"$MRSK_BIN" new --database feature/db
test -d "$project/feature-db"
grep -q '^DATABASE_URL=postgresql://postgres:postgres@localhost:5400/app_development_feature_db$' \
    "$project/feature-db/.env"
grep -q '^KEY=value$' "$project/feature-db/.env"
grep -q '^postgresql://postgres:postgres@localhost:5400/postgres$' "$PSQL_LOG"
grep -q 'CREATE DATABASE "app_development_feature_db" TEMPLATE "app_development"' "$PSQL_LOG"

test ! -e "$project/feature-db/tmp/mrsk-migrate.pid"

"$MRSK_BIN" new feature/plain
grep -q '^DATABASE_URL=postgresql://postgres:postgres@localhost:5400/app_development$' \
    "$project/feature-plain/.env"

"$MRSK_BIN" new -d feature/mig
test -d "$project/feature-mig"
i=0
while [ ! -f "$project/feature-mig/tmp/mrsk-migrate.status" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
test "$(cat "$project/feature-mig/tmp/mrsk-migrate.status")" = 0
grep -q 'rails db:migrate' "$project/feature-mig/tmp/mrsk-migrate.log"
"$MRSK_BIN" list > "$tmp/migrate-list.out"
grep 'feature-mig' "$tmp/migrate-list.out" | grep -q '\[migrated\]'
if grep 'feature-db' "$tmp/migrate-list.out" | grep -q 'migrat'; then
    echo "unexpected migration marker for feature-db" >&2
    exit 1
fi
"$MRSK_BIN" remove feature/mig
grep -q 'DROP DATABASE IF EXISTS "app_development_feature_mig"' "$PSQL_LOG"

"$MRSK_BIN" list > "$tmp/list.out"
grep 'feature-db' "$tmp/list.out" | grep -q '\[database: app_development_feature_db\]'
grep -q 'feature-plain' "$tmp/list.out"
if grep 'feature-plain' "$tmp/list.out" | grep -q 'database:'; then
    echo "unexpected database marker for feature-plain" >&2
    exit 1
fi

"$MRSK_BIN" remove feature/db
test ! -e "$project/feature-db"
grep -q 'DROP DATABASE IF EXISTS "app_development_feature_db"' "$PSQL_LOG"

"$MRSK_BIN" remove feature/plain
test ! -e "$project/feature-plain"
if grep -q 'feature_plain' "$PSQL_LOG"; then
    echo "unexpected psql call for feature-plain" >&2
    exit 1
fi

"$MRSK_BIN" 123 -d
test -d "$project/123"
grep -q 'CREATE DATABASE "app_development_123" TEMPLATE "app_development"' "$PSQL_LOG"
grep -q '^DATABASE_URL=postgresql://postgres:postgres@localhost:5400/app_development_123$' \
    "$project/123/.env"

creates_before=$(grep -c 'CREATE DATABASE' "$PSQL_LOG")
"$MRSK_BIN" 123 -d
creates_after=$(grep -c 'CREATE DATABASE' "$PSQL_LOG")
test "$creates_before" = "$creates_after"

"$MRSK_BIN" 124
if grep -q 'app_development_124' "$PSQL_LOG"; then
    echo "unexpected database for plain shortcut" >&2
    exit 1
fi
"$MRSK_BIN" -d 124
grep -q 'CREATE DATABASE "app_development_124" TEMPLATE "app_development"' "$PSQL_LOG"
grep -q '^DATABASE_URL=postgresql://postgres:postgres@localhost:5400/app_development_124$' \
    "$project/124/.env"

"$MRSK_BIN" remove 123
grep -q 'DROP DATABASE IF EXISTS "app_development_123"' "$PSQL_LOG"
"$MRSK_BIN" remove 124
grep -q 'DROP DATABASE IF EXISTS "app_development_124"' "$PSQL_LOG"

HOME="$HOME" PROJECT="$project" zsh -c '
    eval "$(command mrsk shell-init)"
    cd "$HOME"
    mrsk 200 -d
    test "$PWD" = "$PROJECT/200"
    cd "$HOME"
    mrsk 200
    test "$PWD" = "$PROJECT/200"
'
grep -q 'CREATE DATABASE "app_development_200" TEMPLATE "app_development"' "$PSQL_LOG"
"$MRSK_BIN" remove 200

"$MRSK_BIN" new bump/version
touch "$project/bump-version/db/migrate/20260803000000_mine.rb"
git -C "$project/bump-version" add db/migrate
git -C "$project/bump-version" commit -qm mine
touch "$project/main/db/migrate/20261231235959_teammate.rb"
git -C "$project/main" add db/migrate
git -C "$project/main" commit -qm teammate
git -C "$project/bump-version" rebase -q main
(cd "$project/bump-version" && "$MRSK_BIN" bump-migration-version)
test ! -e "$project/bump-version/db/migrate/20260803000000_mine.rb"
version=$(ls "$project/bump-version/db/migrate" | sed -n 's/_mine\.rb$//p')
test "$version" -gt 20261231235959
grep -q "UPDATE schema_migrations SET version = '$version' WHERE version = '20260803000000'" "$PSQL_LOG"
git -C "$project/bump-version" status --porcelain |
    grep -q "^R  db/migrate/20260803000000_mine.rb -> db/migrate/${version}_mine.rb"
if (cd "$project/main" && "$MRSK_BIN" bump-migration-version) 2>"$tmp/bump.out"; then
    echo "expected bump-migration-version to fail without branch migrations" >&2
    exit 1
fi
grep -q "no migrations added on this branch" "$tmp/bump.out"
"$MRSK_BIN" remove --force bump/version

i=1
while [ "$i" -le 21 ]; do
    touch "$project/main/db/migrate/202609010000$(printf %02d "$i")_fill_missing_port_codes.rb"
    i=$((i + 1))
done
git -C "$project/main" add db/migrate
git -C "$project/main" commit -qm ports --author='Test Contributor <test.author@example.com>'
touch "$project/main/db/migrate/20270101000000_uncommitted.rb"
printf '20250101000000\n20260801000000\n20260901000001\n' > "$PSQL_VERSIONS"
(cd "$project/main/db" && "$MRSK_BIN" dbst) > "$tmp/dbst.out"
test "$(wc -l < "$tmp/dbst.out" | tr -d ' ')" = 22
sed -n 1p "$tmp/dbst.out" | grep -q '^ Status   Migration ID    Migration Name *  Committer$'
grep -q '^---*$' "$tmp/dbst.out"
grep -Eq '^  down    20260901000021  Fill missing port codes +test\.author$' "$tmp/dbst.out"
grep -Eq '^  down    20261231235959  Teammate +test$' "$tmp/dbst.out"
grep -Eq '^  down    20270101000000  Uncommitted *$' "$tmp/dbst.out"
if grep -q '20260901000002' "$tmp/dbst.out"; then
    echo "expected dbst to show only the last 20 migrations" >&2
    exit 1
fi
(cd "$project/main" && "$MRSK_BIN" dbst --full) > "$tmp/dbst-full.out"
test "$(wc -l < "$tmp/dbst-full.out" | tr -d ' ')" = 27
grep -Eq '^   up     20250101000000  \*+ NO FILE \*+ *$' "$tmp/dbst-full.out"
grep -Eq '^   up     20260801000000  Base +test$' "$tmp/dbst-full.out"
grep -Eq '^   up     20260901000001  Fill missing port codes +test\.author$' "$tmp/dbst-full.out"
rm "$project/main/db/migrate/20270101000000_uncommitted.rb"
git -C "$project/main" worktree add -q "$project/dbst-wt"
cp "$project/main/.env" "$project/dbst-wt/.env"
printf 'ActiveRecord::Schema[7.2].define(version: 2026_12_31_235959) do\nend\n' \
    > "$project/dbst-wt/db/schema.rb"
touch "$project/dbst-wt/db/migrate/20270201000000_branch_only.rb"
git -C "$project/dbst-wt" add db/migrate
git -C "$project/dbst-wt" commit -qm branch
git -C "$project/dbst-wt" branch -q --set-upstream-to=main
(cd "$project/dbst-wt/db" && "$MRSK_BIN" dbst) > "$tmp/dbst-wt.out"
grep -Eq '^  down    2026_12_31_235959  Teammate +test$' "$tmp/dbst-wt.out"
yellow=$(printf '\033[33m')
reset=$(printf '\033[0m')
grep -qF "  down    ${yellow}2027_02_01_000000${reset}  Branch only " "$tmp/dbst-wt.out"
test "$(grep -cF "$yellow" "$tmp/dbst-wt.out")" = 1
git -C "$project/main" worktree remove --force "$project/dbst-wt"
git init -q "$tmp/other"
for dir in "$HOME" "$tmp/other"; do
    if (cd "$dir" && "$MRSK_BIN" dbst) 2>"$tmp/dbst-outside.out"; then
        echo "expected dbst to fail outside the project" >&2
        exit 1
    fi
    grep -q 'dbst must run inside a checkout of' "$tmp/dbst-outside.out"
done

printf 'KEY=value\n' > "$project/main/.env"
if "$MRSK_BIN" new -d lookup/none 2>"$tmp/none.out"; then
    echo "expected new -d to fail without a database" >&2
    exit 1
fi
grep -q 'needs a database name in DATABASE_URL' "$tmp/none.out"
test ! -e "$project/lookup-none"

DATABASE_URL=postgresql://env@localhost/env_development "$MRSK_BIN" new -d lookup/env
grep -q 'CREATE DATABASE "env_development_lookup_env" TEMPLATE "env_development"' "$PSQL_LOG"
grep -q '^DATABASE_URL=postgresql://env@localhost/env_development_lookup_env$' \
    "$project/lookup-env/.env"
DATABASE_URL=postgresql://env@localhost/env_development "$MRSK_BIN" remove lookup/env
grep -q 'DROP DATABASE IF EXISTS "env_development_lookup_env"' "$PSQL_LOG"

mkdir -p "$project/main/config"
cat > "$project/main/config/database.yml" <<'EOF'
default: &default
  adapter: postgresql
  username: dev
  password: p@ss/w0rd
  host: localhost # local server
  port: 5433

development: &dev
  <<: *default
  database: "yml_development" # main copy
  host: <%= ENV["DB_HOST"] %>

test:
  <<: *default
  database: yml_test
EOF
"$MRSK_BIN" new -d lookup/yml
grep -q '^postgresql://dev:p%40ss%2Fw0rd@localhost:5433/postgres$' "$PSQL_LOG"
grep -q 'CREATE DATABASE "yml_development_lookup_yml" TEMPLATE "yml_development"' "$PSQL_LOG"
grep -q '^DATABASE_URL=postgresql://dev:p%40ss%2Fw0rd@localhost:5433/yml_development_lookup_yml$' \
    "$project/lookup-yml/.env"
"$MRSK_BIN" remove lookup/yml
grep -q 'DROP DATABASE IF EXISTS "yml_development_lookup_yml"' "$PSQL_LOG"

mono="$tmp/mono"
mkdir -p "$mono/main/front-end" "$mono/main/back-end/config" "$mono/main/back-end/db/migrate" \
    "$mono/main/back-end/bin"
git -C "$mono/main" init -q -b main
git -C "$mono/main" config user.name Test
git -C "$mono/main" config user.email test@example.com
printf '.env\ntmp/\n' > "$mono/main/.gitignore"
touch "$mono/main/front-end/package.json"
printf 'development:\n  host: /var/run/postgresql\n  database: mono_development\n' \
    > "$mono/main/back-end/config/database.yml"
cp "$project/main/bin/rails" "$mono/main/back-end/bin/rails"
touch "$mono/main/back-end/db/migrate/20260801000000_base.rb"
git -C "$mono/main" add .
git -C "$mono/main" commit -qm initial
touch "$mono/main/back-end/db/migrate/20260802000000_extra.rb"
git -C "$mono/main" add .
git -C "$mono/main" commit -qm extra
git -C "$mono/main" branch mono/mig
git -C "$mono/main" reset -q --hard HEAD~1
cat > "$HOME/.mrsk/config.yml" <<EOF
project_root: "$mono/main"
main_branch: main
EOF

"$MRSK_BIN" new -d mono/mig
grep -q '^postgresql:///postgres?host=%2Fvar%2Frun%2Fpostgresql$' "$PSQL_LOG"
grep -q 'CREATE DATABASE "mono_development_mono_mig" TEMPLATE "mono_development"' "$PSQL_LOG"
grep -q '^DATABASE_URL=postgresql:///mono_development_mono_mig?host=%2Fvar%2Frun%2Fpostgresql$' \
    "$mono/mono-mig/back-end/.env"
test ! -e "$mono/mono-mig/.env"
i=0
while [ ! -f "$mono/mono-mig/back-end/tmp/mrsk-migrate.status" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
grep -q 'rails db:migrate' "$mono/mono-mig/back-end/tmp/mrsk-migrate.log"
"$MRSK_BIN" list | grep 'mono-mig' | grep '\[database: mono_development_mono_mig\]' |
    grep -q '\[migrated\]'
"$MRSK_BIN" remove mono/mig
grep -q 'DROP DATABASE IF EXISTS "mono_development_mono_mig"' "$PSQL_LOG"

mkdir -p "$mono/main/config"
printf 'development:\n  database: root_development\n' > "$mono/main/config/database.yml"
cat > "$HOME/.mrsk/config.yml" <<EOF
project_root: "$mono/main"
main_branch: main
rails_root: back-end
EOF
"$MRSK_BIN" new -d mono/pinned
grep -q 'CREATE DATABASE "mono_development_mono_pinned" TEMPLATE "mono_development"' "$PSQL_LOG"
"$MRSK_BIN" remove mono/pinned

cat > "$HOME/.mrsk/config.yml" <<EOF
project_root: "$mono/main"
main_branch: main
rails_root: ../elsewhere
EOF
if "$MRSK_BIN" list 2>"$tmp/rails-root.out"; then
    echo "expected invalid rails_root to fail" >&2
    exit 1
fi
grep -q "invalid rails_root '../elsewhere'" "$tmp/rails-root.out"

echo "database e2e passed"
