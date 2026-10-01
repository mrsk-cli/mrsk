#!/bin/sh
set -eu

: "${MRSK_BIN:?MRSK_BIN is required}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

real_git=$(command -v git)
original_path=$PATH
canonical=git@github.com:basecamp/fizzy.git
seed="$tmp/seed"
remotes="$tmp/remotes/basecamp"
export HOME="$tmp/fixture-home"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
mkdir -p "$HOME" "$seed" "$remotes"

export GIT_CONFIG_NOSYSTEM=1
export GIT_ALLOW_PROTOCOL=file
export GIT_TERMINAL_PROMPT=0

"$real_git" -C "$seed" init -q -b trunk
"$real_git" -C "$seed" config user.name Test
"$real_git" -C "$seed" config user.email test@example.com
printf 'fizzy\n' > "$seed/README.md"
"$real_git" -C "$seed" add README.md
"$real_git" -C "$seed" commit -qm initial

make_remote() {
    name=$1
    branch=$2
    "$real_git" clone -q --bare "$seed" "$remotes/$name.git"
    "$real_git" --git-dir="$remotes/$name.git" symbolic-ref HEAD "refs/heads/$branch"
}

"$real_git" -C "$seed" branch release/trunk
"$real_git" -C "$seed" update-ref refs/heads/-trunk HEAD
quoted_branch='"quoted"'
"$real_git" -C "$seed" update-ref "refs/heads/$quoted_branch" HEAD
make_remote fizzy trunk
make_remote my-api trunk
make_remote go trunk
make_remote provans.info trunk
make_remote release release/trunk
make_remote dash -trunk
make_remote quoted "$quoted_branch"

physical_directory() {
    mkdir -p "$1"
    (cd "$1" && pwd -P)
}

configure_mapping() {
    HOME=$1
    export HOME
    export XDG_CONFIG_HOME="$HOME/.config"
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    mkdir -p "$HOME"
    "$real_git" config --global url."$2".insteadOf git@github.com:basecamp/
}

configure_case() {
    configure_mapping "$1" "file://$remotes/"
}

file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

happy="$tmp/happy"
configure_case "$happy/home"
workspace=$(physical_directory "$happy/workspace with spaces")
(cd "$workspace" && "$MRSK_BIN" clone https://github.com/basecamp/fizzy > "$happy/clone.out")

checkout="$workspace/fizzy/main"
test -f "$checkout/README.md"
test ! -f "$workspace/fizzy/README.md"
test "$("$real_git" -C "$checkout" branch --show-current)" = trunk
test "$("$real_git" -C "$checkout" remote)" = ups
test "$("$real_git" -C "$checkout" rev-parse --abbrev-ref '@{upstream}')" = ups/trunk
test "$("$real_git" -C "$checkout" config --get remote.ups.url)" = "$canonical"
test "$(file_mode "$HOME/.mrsk")" = 700
test "$(file_mode "$HOME/.mrsk/config.yml")" = 600
grep -Fq "project_name: fizzy" "$HOME/.mrsk/config.yml"
grep -Fq "project_root: $checkout" "$HOME/.mrsk/config.yml"
grep -Fq "main_branch: trunk" "$HOME/.mrsk/config.yml"
grep -Fq "prefix: FIZZ" "$HOME/.mrsk/config.yml"
! grep -Fq "default: true" "$HOME/.mrsk/config.yml"
grep -Fq "$checkout" "$happy/clone.out"
grep -Fq "trunk" "$happy/clone.out"
grep -Fq "ups" "$happy/clone.out"
grep -Fq "FIZZ" "$happy/clone.out"

"$MRSK_BIN" fizzy new 3456
test -d "$workspace/fizzy/FIZZ-3456"
test "$("$real_git" -C "$workspace/fizzy/FIZZ-3456" branch --show-current)" = FIZZ-3456

accepted_index=0
for url in \
    git@github.com:basecamp/fizzy \
    git@github.com:basecamp/fizzy.git \
    https://github.com/basecamp/fizzy.git \
    https://github.com/basecamp/fizzy/ \
    https://github.com/basecamp/fizzy.git/
do
    accepted_index=$((accepted_index + 1))
    accepted="$tmp/accepted-$accepted_index"
    configure_case "$accepted/home"
    accepted_workspace=$(physical_directory "$accepted/workspace")
    (cd "$accepted_workspace" && "$MRSK_BIN" clone "$url" > "$accepted/out")
    accepted_checkout="$accepted_workspace/fizzy/main"
    test "$("$real_git" -C "$accepted_checkout" config --get remote.ups.url)" = "$canonical"
    test "$("$real_git" -C "$accepted_checkout" branch --show-current)" = trunk
done

release="$tmp/release-default"
configure_case "$release/home"
release_workspace=$(physical_directory "$release/workspace")
(cd "$release_workspace" &&
    "$MRSK_BIN" clone https://github.com/basecamp/release > "$release/out")
release_checkout="$release_workspace/release/main"
test "$("$real_git" -C "$release_checkout" branch --show-current)" = release/trunk
test "$("$real_git" -C "$release_checkout" rev-parse --abbrev-ref '@{upstream}')" = ups/release/trunk
grep -Fq "main_branch: release/trunk" "$HOME/.mrsk/config.yml"

dash="$tmp/dash-default"
configure_case "$dash/home"
dash_workspace=$(physical_directory "$dash/workspace")
(cd "$dash_workspace" &&
    "$MRSK_BIN" clone https://github.com/basecamp/dash > "$dash/out")
dash_checkout="$dash_workspace/dash/main"
test "$("$real_git" -C "$dash_checkout" branch --show-current)" = -trunk
test "$("$real_git" -C "$dash_checkout" rev-parse --abbrev-ref '@{upstream}')" = ups/-trunk
grep -Fq "main_branch: -trunk" "$HOME/.mrsk/config.yml"

quoted="$tmp/quoted-default"
configure_case "$quoted/home"
quoted_workspace=$(physical_directory "$quoted/workspace")
quoted_status=0
(cd "$quoted_workspace" &&
    "$MRSK_BIN" clone https://github.com/basecamp/quoted > "$quoted/out" 2>&1) || quoted_status=$?
test "$quoted_status" -eq 1
grep -Fq "cannot be represented in configuration" "$quoted/out"
test ! -e "$quoted_workspace/quoted"
test ! -e "$HOME/.mrsk/config.yml"

prefix_case() {
    repository=$1
    expected=$2
    prefix_root="$tmp/prefix-$repository"
    configure_case "$prefix_root/home"
    prefix_workspace=$(physical_directory "$prefix_root/workspace")
    (cd "$prefix_workspace" &&
        "$MRSK_BIN" clone "https://github.com/basecamp/$repository" > "$prefix_root/out")
    grep -Fq "prefix: $expected" "$HOME/.mrsk/config.yml"
    grep -Fq "Prefix: $expected" "$prefix_root/out"
}

prefix_case my-api MYAP
prefix_case go GO
prefix_case provans.info PROV

numeric="$tmp/numeric"
configure_case "$numeric/home"
numeric_workspace=$(physical_directory "$numeric/workspace")
numeric_status=0
(cd "$numeric_workspace" &&
    "$MRSK_BIN" clone https://github.com/basecamp/1234 > "$numeric/out" 2>&1) || numeric_status=$?
test "$numeric_status" -eq 1
grep -Fq "must contain an ASCII letter" "$numeric/out"
test ! -e "$numeric_workspace/1234"
test ! -e "$HOME/.mrsk/config.yml"

reserved_index=0
for repository in \
    --help \
    -h \
    __worktree-target-branch-updater-run \
    configure \
    clone \
    rails-schema-confl \
    shell-init \
    new \
    open \
    remove \
    delete_all \
    updater \
    daemon \
    list
do
    reserved_index=$((reserved_index + 1))
    reserved="$tmp/reserved-$reserved_index"
    configure_case "$reserved/home"
    reserved_workspace=$(physical_directory "$reserved/workspace")
    reserved_status=0
    (cd "$reserved_workspace" &&
        "$MRSK_BIN" clone "https://github.com/basecamp/$repository" > "$reserved/out" 2>&1) ||
        reserved_status=$?
    test "$reserved_status" -eq 1
    grep -Fq "conflicts with an mrsk command" "$reserved/out"
    test ! -e "$reserved_workspace/$repository"
    test ! -e "$HOME/.mrsk/config.yml"
done

empty="$tmp/empty-config"
configure_case "$empty/home"
mkdir -p "$HOME/.mrsk"
: > "$HOME/.mrsk/config.yml"
chmod 0644 "$HOME/.mrsk/config.yml"
empty_workspace=$(physical_directory "$empty/workspace")
(cd "$empty_workspace" && "$MRSK_BIN" clone "$canonical" > "$empty/out")
grep -Fq "projects:" "$HOME/.mrsk/config.yml"
grep -Fq "project_name: fizzy" "$HOME/.mrsk/config.yml"
test "$(file_mode "$HOME/.mrsk/config.yml")" = 644

projects_empty="$tmp/projects-empty-config"
configure_case "$projects_empty/home"
mkdir -p "$HOME/.mrsk"
printf 'projects:\n' > "$HOME/.mrsk/config.yml"
projects_empty_workspace=$(physical_directory "$projects_empty/workspace")
(cd "$projects_empty_workspace" && "$MRSK_BIN" clone "$canonical" > "$projects_empty/out")
grep -Fq "project_name: fizzy" "$HOME/.mrsk/config.yml"
! grep -Fq "default: true" "$HOME/.mrsk/config.yml"

multi="$tmp/multi-config"
configure_case "$multi/home"
mkdir -p "$HOME/.mrsk"
multi_workspace=$(physical_directory "$multi/workspace")
cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: existing
    project_root: $multi/existing/main
    main_branch: rebuild
    prefix: DEV
    default: true
    copy_files:
      - .env
    copy_folders:
      - storage
EOF
chmod 0640 "$HOME/.mrsk/config.yml"
(cd "$multi_workspace" && "$MRSK_BIN" clone "$canonical" > "$multi/out")
cat > "$multi/expected" <<EOF
projects:
  - project_name: existing
    project_root: $multi/existing/main
    main_branch: rebuild
    prefix: DEV
    default: true
    copy_files:
      - .env
    copy_folders:
      - storage
  - project_name: fizzy
    project_root: $multi_workspace/fizzy/main
    main_branch: trunk
    prefix: FIZZ
EOF
cmp -s "$multi/expected" "$HOME/.mrsk/config.yml"
test "$(file_mode "$HOME/.mrsk/config.yml")" = 640
"$MRSK_BIN" fizzy list | grep -Fq "$multi_workspace/fizzy/main"

legacy="$tmp/legacy-config"
configure_case "$legacy/home"
mkdir -p "$HOME/.mrsk"
legacy_workspace=$(physical_directory "$legacy/workspace")
cat > "$HOME/.mrsk/config.yml" <<EOF
redmine_url: https://redmine.example.test
project_root: $legacy/legacy/main
main_branch: rebuild
prefix: DEV
rails_root: back-end
default: true
copy_files:
  - .env
copy_folders:
  - storage
EOF
(cd "$legacy_workspace" && "$MRSK_BIN" clone "$canonical" > "$legacy/out")
cat > "$legacy/expected" <<EOF
redmine_url: https://redmine.example.test
projects:
  - project_name: legacy
    project_root: $legacy/legacy/main
    main_branch: rebuild
    prefix: DEV
    rails_root: back-end
    default: true
    copy_files:
      - .env
    copy_folders:
      - storage
  - project_name: fizzy
    project_root: $legacy_workspace/fizzy/main
    main_branch: trunk
    prefix: FIZZ
EOF
cmp -s "$legacy/expected" "$HOME/.mrsk/config.yml"
"$MRSK_BIN" fizzy list | grep -Fq "$legacy_workspace/fizzy/main"

invalid_config="$tmp/invalid-config"
configure_case "$invalid_config/home"
mkdir -p "$HOME/.mrsk"
printf 'unknown: value\n' > "$HOME/.mrsk/config.yml"
cp "$HOME/.mrsk/config.yml" "$invalid_config/before"
invalid_workspace=$(physical_directory "$invalid_config/workspace")
invalid_config_status=0
(cd "$invalid_workspace" &&
    GIT_TRACE2="$invalid_config/git.log" \
        "$MRSK_BIN" clone "$canonical" > "$invalid_config/out" 2>&1) || invalid_config_status=$?
test "$invalid_config_status" -eq 1
cmp -s "$invalid_config/before" "$HOME/.mrsk/config.yml"
test ! -e "$invalid_workspace/fizzy"
test ! -s "$invalid_config/git.log"

invalid_index=0
invalid_url() {
    invalid_index=$((invalid_index + 1))
    invalid="$tmp/invalid-url-$invalid_index"
    HOME="$invalid/home"
    export HOME
    export XDG_CONFIG_HOME="$HOME/.config"
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    mkdir -p "$HOME"
    invalid_workspace=$(physical_directory "$invalid/workspace")
    invalid_status=0
    (cd "$invalid_workspace" &&
        "$MRSK_BIN" clone "$1" > "$invalid/out" 2>&1) || invalid_status=$?
    test "$invalid_status" -eq 1
    grep -Fq "invalid GitHub repository URL" "$invalid/out"
    test ! -e "$HOME/.mrsk/config.yml"
}

for url in \
    http://github.com/basecamp/fizzy \
    ssh://git@github.com/basecamp/fizzy.git \
    git://github.com/basecamp/fizzy.git \
    file:///tmp/fizzy.git \
    https://gitlab.com/basecamp/fizzy \
    https://github.com.evil/basecamp/fizzy \
    https://user:secret@github.com/basecamp/fizzy \
    'https://github.com/basecamp/fizzy?tab=readme' \
    'https://github.com/basecamp/fizzy#readme' \
    https://github.com/basecamp \
    https://github.com//fizzy \
    https://github.com/basecamp/ \
    https://github.com/basecamp/fizzy/extra \
    https://github.com/base--camp/fizzy \
    'https://github.com/basecamp/fizzy$' \
    git@github.com:basecamp/fizzy/ \
    user@github.com:basecamp/fizzy.git \
    https://github.com/basecamp/.git \
    https://github.com/basecamp/fizzy.git//
do
    invalid_url "$url"
done

arguments="$tmp/arguments"
HOME="$arguments/home"
export HOME
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
mkdir -p "$HOME" "$arguments/workspace"
missing_status=0
"$MRSK_BIN" clone > "$arguments/missing.out" 2>&1 || missing_status=$?
test "$missing_status" -eq 2
extra_status=0
"$MRSK_BIN" clone "$canonical" extra > "$arguments/extra.out" 2>&1 || extra_status=$?
test "$extra_status" -eq 2

wrapper="$tmp/git-wrapper"
mkdir -p "$wrapper"
cat > "$wrapper/git" <<'EOF'
#!/bin/sh
if [ -n "${GIT_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$GIT_LOG"
fi
if [ "${FAIL_CLONE:-0}" = 1 ] && [ "$1" = clone ]; then
    destination=
    for argument in "$@"; do
        destination=$argument
    done
    mkdir -p "$destination/partial"
    exit 73
fi
if [ "${MALFORMED_SYMREF:-0}" = 1 ] && [ "$1" = ls-remote ]; then
    printf 'ref: refs/heads/trunk HEAD\n'
    exit 0
fi
if [ -n "${CLONE_BARRIER:-}" ] && [ "$1" = clone ]; then
    : > "$CLONE_BARRIER/$CLONE_MARKER"
    attempts=0
    while [ ! -e "$CLONE_BARRIER/one" ] || [ ! -e "$CLONE_BARRIER/two" ]; do
        attempts=$((attempts + 1))
        if [ "$attempts" -eq 500 ]; then
            exit 74
        fi
        sleep 0.01
    done
fi
if [ "${LOCK_CONFIG_AFTER_CLONE:-0}" = 1 ] && [ "$1" = clone ]; then
    "$REAL_GIT" "$@"
    result=$?
    if [ "$result" -eq 0 ]; then
        chmod 0500 "$HOME/.mrsk"
    fi
    exit "$result"
fi
if [ "${UNREADABLE_CONFIG_AFTER_CLONE:-0}" = 1 ] && [ "$1" = clone ]; then
    "$REAL_GIT" "$@"
    result=$?
    if [ "$result" -eq 0 ]; then
        chmod 0000 "$HOME/.mrsk/config.yml"
    fi
    exit "$result"
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$wrapper/git"
export REAL_GIT="$real_git"

malformed="$tmp/malformed-symref"
configure_case "$malformed/home"
malformed_workspace=$(physical_directory "$malformed/workspace")
printf 'keep\n' > "$malformed_workspace/sentinel"
PATH="$wrapper:$original_path"
export PATH
MALFORMED_SYMREF=1
export MALFORMED_SYMREF
malformed_status=0
(cd "$malformed_workspace" &&
    "$MRSK_BIN" clone "$canonical" > "$malformed/out" 2>&1) || malformed_status=$?
unset MALFORMED_SYMREF
PATH=$original_path
export PATH
test "$malformed_status" -eq 1
grep -Fq "no valid symbolic default branch" "$malformed/out"
test ! -e "$malformed_workspace/fizzy"
test "$(cat "$malformed_workspace/sentinel")" = keep
test ! -e "$HOME/.mrsk/config.yml"

concurrent="$tmp/concurrent-clones"
configure_case "$concurrent/home"
concurrent_workspace=$(physical_directory "$concurrent/workspace")
CLONE_BARRIER="$concurrent/barrier"
export CLONE_BARRIER
mkdir "$CLONE_BARRIER"
PATH="$wrapper:$original_path"
export PATH
(cd "$concurrent_workspace" &&
    CLONE_MARKER=one "$MRSK_BIN" clone https://github.com/basecamp/my-api > "$concurrent/one.out" 2>&1) &
one_pid=$!
(cd "$concurrent_workspace" &&
    CLONE_MARKER=two "$MRSK_BIN" clone https://github.com/basecamp/go > "$concurrent/two.out" 2>&1) &
two_pid=$!
wait "$one_pid"
wait "$two_pid"
PATH=$original_path
export PATH
unset CLONE_BARRIER
test -f "$concurrent_workspace/my-api/main/README.md"
test -f "$concurrent_workspace/go/main/README.md"
test "$(grep -c 'project_name:' "$HOME/.mrsk/config.yml")" -eq 2
grep -Fq "project_name: my-api" "$HOME/.mrsk/config.yml"
grep -Fq "project_name: go" "$HOME/.mrsk/config.yml"
"$MRSK_BIN" my-api list | grep -Fq "$concurrent_workspace/my-api/main"
"$MRSK_BIN" go list | grep -Fq "$concurrent_workspace/go/main"

duplicate_case() {
    kind=$1
    duplicate="$tmp/duplicate-$kind"
    configure_case "$duplicate/home"
    mkdir -p "$HOME/.mrsk"
    duplicate_workspace=$(physical_directory "$duplicate/workspace")
    if [ "$kind" = existing-roots ]; then
        cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: first
    project_root: $duplicate/shared/main
    main_branch: main
  - project_name: second
    project_root: $duplicate/shared/./main
    main_branch: main
EOF
    elif [ "$kind" = name ]; then
        duplicate_name=fizzy
        duplicate_root="$duplicate/other/main"
    else
        duplicate_name=other
        ln -s "$duplicate_workspace" "$duplicate/workspace-link"
        duplicate_root="$duplicate/workspace-link/fizzy/main"
    fi
    if [ "$kind" != existing-roots ]; then
        cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: $duplicate_name
    project_root: $duplicate_root
    main_branch: main
EOF
    fi
    cp "$HOME/.mrsk/config.yml" "$duplicate/before"
    GIT_LOG="$duplicate/git.log"
    export GIT_LOG
    : > "$GIT_LOG"
    PATH="$wrapper:$original_path"
    export PATH
    duplicate_status=0
    (cd "$duplicate_workspace" &&
        "$MRSK_BIN" clone "$canonical" > "$duplicate/out" 2>&1) || duplicate_status=$?
    PATH=$original_path
    export PATH
    unset GIT_LOG
    test "$duplicate_status" -eq 1
    grep -Fq "duplicate project_" "$duplicate/out"
    test ! -s "$duplicate/git.log"
    test ! -e "$duplicate_workspace/fizzy"
    cmp -s "$duplicate/before" "$HOME/.mrsk/config.yml"
}

duplicate_case name
duplicate_case root
duplicate_case existing-roots

unwritable="$tmp/unwritable-config"
configure_case "$unwritable/home"
mkdir -p "$HOME/.mrsk"
cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: existing
    project_root: $unwritable/existing/main
    main_branch: main
EOF
cp "$HOME/.mrsk/config.yml" "$unwritable/before"
chmod 0500 "$HOME/.mrsk"
unwritable_workspace=$(physical_directory "$unwritable/workspace")
GIT_LOG="$unwritable/git.log"
export GIT_LOG
: > "$GIT_LOG"
PATH="$wrapper:$original_path"
export PATH
unwritable_status=0
(cd "$unwritable_workspace" &&
    "$MRSK_BIN" clone "$canonical" > "$unwritable/out" 2>&1) || unwritable_status=$?
PATH=$original_path
export PATH
unset GIT_LOG
chmod 0700 "$HOME/.mrsk"
test "$unwritable_status" -eq 1
test ! -s "$unwritable/git.log"
test ! -e "$unwritable_workspace/fizzy"
cmp -s "$unwritable/before" "$HOME/.mrsk/config.yml"

preexisting_case() {
    kind=$1
    existing="$tmp/preexisting-$kind"
    HOME="$existing/home"
    export HOME
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    mkdir -p "$HOME"
    existing_workspace=$(physical_directory "$existing/workspace")
    if [ "$kind" = file ]; then
        printf 'keep\n' > "$existing_workspace/fizzy"
    elif [ "$kind" = directory ]; then
        mkdir "$existing_workspace/fizzy"
        printf 'keep\n' > "$existing_workspace/fizzy/sentinel"
    else
        ln -s "$existing/missing-target" "$existing_workspace/fizzy"
    fi
    existing_status=0
    (cd "$existing_workspace" &&
        "$MRSK_BIN" clone "$canonical" > "$existing/out" 2>&1) || existing_status=$?
    test "$existing_status" -eq 1
    grep -Fq "destination already exists" "$existing/out"
    if [ "$kind" = file ]; then
        test "$(cat "$existing_workspace/fizzy")" = keep
    elif [ "$kind" = directory ]; then
        test "$(cat "$existing_workspace/fizzy/sentinel")" = keep
    else
        test -L "$existing_workspace/fizzy"
        test "$(readlink "$existing_workspace/fizzy")" = "$existing/missing-target"
    fi
    test ! -e "$HOME/.mrsk/config.yml"
}

preexisting_case file
preexisting_case directory
preexisting_case symlink

missing_remote="$tmp/missing-remote"
configure_mapping "$missing_remote/home" "file://$missing_remote/remotes/basecamp/"
mkdir -p "$HOME/.mrsk"
cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: existing
    project_root: $missing_remote/existing/main
    main_branch: main
EOF
chmod 0640 "$HOME/.mrsk/config.yml"
cp "$HOME/.mrsk/config.yml" "$missing_remote/before"
missing_workspace=$(physical_directory "$missing_remote/workspace")
printf 'keep\n' > "$missing_workspace/sentinel"
remote_status=0
(cd "$missing_workspace" &&
    "$MRSK_BIN" clone "$canonical" > "$missing_remote/out" 2>&1) || remote_status=$?
test "$remote_status" -eq 1
test ! -e "$missing_workspace/fizzy"
test "$(cat "$missing_workspace/sentinel")" = keep
cmp -s "$missing_remote/before" "$HOME/.mrsk/config.yml"
test "$(file_mode "$HOME/.mrsk/config.yml")" = 640

empty_remote="$tmp/empty-remote"
mkdir -p "$empty_remote/remotes/basecamp"
"$real_git" init -q --bare "$empty_remote/remotes/basecamp/fizzy.git"
configure_mapping "$empty_remote/home" "file://$empty_remote/remotes/basecamp/"
empty_remote_workspace=$(physical_directory "$empty_remote/workspace")
printf 'keep\n' > "$empty_remote_workspace/sentinel"
empty_remote_status=0
(cd "$empty_remote_workspace" &&
    "$MRSK_BIN" clone "$canonical" > "$empty_remote/out" 2>&1) || empty_remote_status=$?
test "$empty_remote_status" -eq 1
grep -Fq "no valid symbolic default branch" "$empty_remote/out"
test ! -e "$empty_remote_workspace/fizzy"
test "$(cat "$empty_remote_workspace/sentinel")" = keep
test ! -e "$HOME/.mrsk/config.yml"

detached="$tmp/detached-head"
mkdir -p "$detached/remotes/basecamp"
"$real_git" clone -q --bare "$seed" "$detached/remotes/basecamp/fizzy.git"
detached_head=$("$real_git" --git-dir="$detached/remotes/basecamp/fizzy.git" rev-parse refs/heads/trunk)
printf '%s\n' "$detached_head" > "$detached/remotes/basecamp/fizzy.git/HEAD"
configure_mapping "$detached/home" "file://$detached/remotes/basecamp/"
detached_workspace=$(physical_directory "$detached/workspace")
printf 'keep\n' > "$detached_workspace/sentinel"
detached_status=0
(cd "$detached_workspace" &&
    "$MRSK_BIN" clone "$canonical" > "$detached/out" 2>&1) || detached_status=$?
test "$detached_status" -eq 1
grep -Fq "no valid symbolic default branch" "$detached/out"
test ! -e "$detached_workspace/fizzy"
test "$(cat "$detached_workspace/sentinel")" = keep
test ! -e "$HOME/.mrsk/config.yml"

clone_failure="$tmp/clone-failure"
configure_case "$clone_failure/home"
mkdir -p "$HOME/.mrsk"
cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: existing
    project_root: $clone_failure/existing/main
    main_branch: main
EOF
chmod 0640 "$HOME/.mrsk/config.yml"
cp "$HOME/.mrsk/config.yml" "$clone_failure/before"
clone_failure_workspace=$(physical_directory "$clone_failure/workspace")
printf 'keep\n' > "$clone_failure_workspace/sentinel"
PATH="$wrapper:$original_path"
export PATH
FAIL_CLONE=1
export FAIL_CLONE
clone_failure_status=0
(cd "$clone_failure_workspace" &&
    "$MRSK_BIN" clone "$canonical" > "$clone_failure/out" 2>&1) || clone_failure_status=$?
unset FAIL_CLONE
PATH=$original_path
export PATH
test "$clone_failure_status" -eq 73
test ! -e "$clone_failure_workspace/fizzy"
test "$(cat "$clone_failure_workspace/sentinel")" = keep
cmp -s "$clone_failure/before" "$HOME/.mrsk/config.yml"
test "$(file_mode "$HOME/.mrsk/config.yml")" = 640

config_failure="$tmp/config-failure"
configure_case "$config_failure/home"
mkdir -p "$HOME/.mrsk"
cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: existing
    project_root: $config_failure/existing/main
    main_branch: main
EOF
chmod 0640 "$HOME/.mrsk/config.yml"
cp "$HOME/.mrsk/config.yml" "$config_failure/before"
config_failure_workspace=$(physical_directory "$config_failure/workspace")
printf 'keep\n' > "$config_failure_workspace/sentinel"
PATH="$wrapper:$original_path"
export PATH
LOCK_CONFIG_AFTER_CLONE=1
export LOCK_CONFIG_AFTER_CLONE
config_failure_status=0
(cd "$config_failure_workspace" &&
    "$MRSK_BIN" clone "$canonical" > "$config_failure/out" 2>&1) || config_failure_status=$?
unset LOCK_CONFIG_AFTER_CLONE
PATH=$original_path
export PATH
chmod 0700 "$HOME/.mrsk"
test "$config_failure_status" -eq 1
test ! -e "$config_failure_workspace/fizzy"
test "$(cat "$config_failure_workspace/sentinel")" = keep
cmp -s "$config_failure/before" "$HOME/.mrsk/config.yml"
test "$(file_mode "$HOME/.mrsk/config.yml")" = 640
test -z "$(find "$HOME/.mrsk" -name 'config.yml.tmp.*' -print)"

temp_failure="$tmp/temp-cleanup-failure"
configure_case "$temp_failure/home"
mkdir -p "$HOME/.mrsk"
cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: existing
    project_root: $temp_failure/existing/main
    main_branch: main
EOF
chmod 0640 "$HOME/.mrsk/config.yml"
cp "$HOME/.mrsk/config.yml" "$temp_failure/before"
temp_failure_workspace=$(physical_directory "$temp_failure/workspace")
printf 'keep\n' > "$temp_failure_workspace/sentinel"
PATH="$wrapper:$original_path"
export PATH
UNREADABLE_CONFIG_AFTER_CLONE=1
export UNREADABLE_CONFIG_AFTER_CLONE
temp_failure_status=0
(cd "$temp_failure_workspace" &&
    "$MRSK_BIN" clone "$canonical" > "$temp_failure/out" 2>&1) || temp_failure_status=$?
unset UNREADABLE_CONFIG_AFTER_CLONE
PATH=$original_path
export PATH
temp_failure_mode=$(file_mode "$HOME/.mrsk/config.yml")
chmod 0640 "$HOME/.mrsk/config.yml"
test "$temp_failure_status" -eq 1
test ! -e "$temp_failure_workspace/fizzy"
test "$(cat "$temp_failure_workspace/sentinel")" = keep
cmp -s "$temp_failure/before" "$HOME/.mrsk/config.yml"
test "$temp_failure_mode" = 0
test -z "$(find "$HOME/.mrsk" -name 'config.yml.tmp.*' -print)"

echo "clone e2e: ok"
