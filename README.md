# mrsk

Small POSIX C CLI for managing Git worktrees beside a configured main checkout.

## Homebrew

```sh
brew install mrsk-cli/tap/mrsk
echo 'eval "$(mrsk shell-init)"' >> "$HOME/.zshrc"
```

Open a new zsh session after adding the shell integration. The Homebrew formula
also installs `ocr` for `mrsk review`.

## APT (Debian and Ubuntu)

Debian 13 and Ubuntu 24.04 are supported on amd64 and arm64. Add the signed
repository once:

```sh
sudo apt update
sudo apt install ca-certificates curl
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://mrsk-cli.github.io/mrsk/apt/mrsk.gpg | sudo tee /etc/apt/keyrings/mrsk.gpg > /dev/null
sudo chmod 0644 /etc/apt/keyrings/mrsk.gpg
curl -fsSL https://mrsk-cli.github.io/mrsk/apt/mrsk.sources | sudo tee /etc/apt/sources.list.d/mrsk.sources > /dev/null
sudo apt update
sudo apt install mrsk
```

The repository key is trusted only for this repository through `Signed-By`.
Future versions arrive through `sudo apt update && sudo apt upgrade`.
The package includes a private copy of `ocr` for `mrsk review`.

For zsh worktree navigation, add `eval "$(mrsk shell-init)"` to `~/.zshrc` and
open a new shell. The macOS-only `open` and `updater` commands remain unavailable
on Linux.

## Build and install

```sh
make
make test
make install PREFIX="$HOME/.local"
echo 'eval "$(command mrsk shell-init)"' >> "$HOME/.zshrc"
```

Ensure `$HOME/.local/bin` is in `PATH` when using that install prefix.

Building also compiles the vendored open-code-review sources, so it needs Go
1.21 or newer; an older Go than 1.25 fetches the 1.25 toolchain by itself.
`make install` puts the resulting `ocr` binary next to `mrsk`.

### Debian 13

Install the build tools and the programs `mrsk` runs:

```sh
sudo apt install git make gcc golang-go ca-certificates zsh ruby
sudo apt install vim postgresql-client xdg-utils
```

The second line is optional: `configure` opens Vim, the database commands run
`psql`, and `redmine` opens the browser through `xdg-open`.

Build, test and install as a regular user, not root. Set `REPOSITORY_URL`
to the new repository URL first:

```sh
git clone "$REPOSITORY_URL" mrsk
cd mrsk
make
make test
make install PREFIX="$HOME/.local"
```

Debian 13 ships Go 1.24, so the first `make` downloads the Go 1.25 toolchain
and needs network access. `make test` fails under root, because root ignores
the file permissions some tests rely on.

The shell integration is written for zsh, while Debian logs in with bash by
default. Switch the login shell, log in again, then add `mrsk` to zsh:

```sh
chsh -s "$(command -v zsh)"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
echo 'eval "$(command mrsk shell-init)"' >> "$HOME/.zshrc"
```

`mrsk open` (Terminal) and `mrsk updater` (launchd) need macOS and exit with an
error on Debian.

## Configuration

Create `~/.mrsk/config.yml`. When upgrading, copy the existing configuration:

```sh
install -d -m 700 "$HOME/.mrsk"
install -m 600 "$HOME/.work/config.yml" "$HOME/.mrsk/config.yml"
```

Example configuration:

```yaml
redmine_url: https://redmine.example.com
projects:
  - project_name: example_project
    project_root: /Users/user/projects/example_project/main
    main_branch: main
    default: true
    prefix: DEV
    copy_files:
      - .env
      - config/master.key
    copy_folders:
      - storage
  - project_name: another_project
    project_root: /Users/anton.i/projects/another_project/main
    main_branch: main
```

`redmine_url` is an optional global setting used by `mrsk redmine`.
Each project requires `project_name`, `project_root`, and `main_branch`.
At most one project may set `default: true`; it is selected when the current
directory does not match a configured project. An optional `prefix` is added to
numeric branch names, so `2491` becomes `DEV-2491`.
`rails_root` is an optional path, relative to the checkout, of the Rails app
inside the repository, such as `back-end`. Without it, `mrsk` uses the checkout
root when it has `config/database.yml`, otherwise the first top-level folder
that does.
`copy_files` and `copy_folders` are optional relative paths copied from the main
checkout after `new` creates a worktree. A missing `copy_folders` path is skipped
with a yellow warning; a missing `copy_files` path stops `new` before the
worktree is created. The parser deliberately supports only this YAML subset,
avoiding a YAML dependency. The old flat `project_root` and `main_branch` format
remains valid for a single project.

## Commands

```sh
mrsk configure
mrsk clone https://github.com/basecamp/fizzy
mrsk clone git@github.com:basecamp/fizzy.git
mrsk redmine
mrsk review
mrsk review --from main --to feature-auth
mrsk review --commit abc123
mrsk rails-schema-confl
mrsk bump-migration-version
mrsk dbst
mrsk dbst --full
mrsk 2491
mrsk DEV-2491
mrsk 2491 -d
mrsk DEV-2491 -d
mrsk new 2491
mrsk new -d 2491
mrsk new DEV-000
mrsk example_project new ORI-1234
mrsk example_project new feature/login
mrsk example_project open feature/login
mrsk example_project list
mrsk example_project remove ORI-1234
mrsk example_project remove feature/login
mrsk example_project remove --force ORI-1234
mrsk example_project delete_all
mrsk example_project delete_all --force
mrsk example_project updater start
mrsk example_project updater status
mrsk example_project updater stop
mrsk example_project updater run
```

The project name may be omitted when only one project is configured, when the
current directory matches a project's worktree directory, or when a default is
configured.

`configure` opens `~/.mrsk/config.yml` in Vim, creating `~/.mrsk` when needed.

`redmine` opens `<redmine_url>/issues/<number>` in the default browser, using
the issue number at the end of the current branch name. For example, branch
`DEV-3454` opens `https://redmine.example.com/issues/3454`. When `redmine_url`
has no scheme, `https://` is used.

`review` runs an AI code review of the current repository with
[open-code-review](https://github.com/alibaba/open-code-review), whose source
is vendored in `third_party/open-code-review`. Without options it reviews the
staged, unstaged, and untracked changes; `--from main --to feature-auth`
reviews what `feature-auth` changed since it diverged from `main`; and
`--commit abc123` reviews one commit against its parent. Every argument is
passed unchanged to `ocr review`, so its other options work too, for example
`--preview`, `--format json --output result.json`, or `--resume <session-id>`.
Configure an LLM once with `ocr config provider` and `ocr config model`.
open-code-review needs Git 2.41 or newer.

The vendored release is recorded in `third_party/open-code-review/VERSION`.
To move to another one, run `third_party/update-open-code-review.sh <tag>`. It
replaces the vendored copy with that release's Go sources (tests excluded) and
checks that they build.

`clone` accepts one GitHub HTTPS or SSH repository URL. A `.git` suffix is
optional, and HTTPS URLs may have a trailing slash. Both forms are normalized
to SSH, so the examples above use `git@github.com:basecamp/fizzy.git` for Git
operations. Before creating files, `git ls-remote --symref` discovers and
validates the remote default branch instead of assuming `main` or `master`.
The repository is then cloned to the absolute path `<current-directory>/fizzy/main`
with only an `ups` remote, and the detected branch tracks `ups`.

After cloning, `clone` appends a project entry to `~/.mrsk/config.yml`. The
prefix is the first four ASCII letters of the repository name in uppercase,
so `fizzy` receives `FIZZ`. Missing and empty configurations are initialized;
the supported legacy flat configuration is migrated without losing its
values. Configuration replacement is atomic. Invalid URLs, duplicate projects,
an existing `<current-directory>/fizzy`, Git failures, and configuration write
failures leave the previous configuration and destination unchanged.

```yaml
projects:
  - project_name: fizzy
    project_root: /absolute/current-directory/fizzy/main
    main_branch: trunk
    prefix: FIZZ
```

The generated entry does not set `default: true`.

`rails-schema-confl` resolves a standard `db/schema.rb` version conflict using
the newest timestamp from `db/migrate`. Run it from the Rails project root.

`bump-migration-version` re-timestamps the migrations this branch added so they
sort after everything already in `db/migrate`. Run it from a worktree root after
rebasing on `main_branch`. Migrations added since the merge base with
`main_branch` (committed, staged, or untracked) are renamed to consecutive
seconds starting at the current UTC time, or at one second past the newest
foreign migration when that is later, keeping their relative order. Tracked
files move with `git mv`, so the rename is staged. When the worktree `.env`
defines `DATABASE_URL`, matching `schema_migrations` rows are updated through
`psql` in one transaction before the files move, so an applied migration is not
re-run; a failing `psql` only prints a yellow warning. Nothing is renamed when a
target file already exists.

`dbst` is a fast `bin/rails db:migrate:status`. It prints the last 20
migrations (all of them with `--full`) with their up/down state, ID, name, and
the committer: the part before `@` in the email of whoever added the migration
file in git. The state comes from `schema_migrations` through `psql`, using the
same database lookup as `new -d` (see below) in the Rails root of the checkout
you are in; outside `project_root` and its worktrees it exits with an error.
Versions applied in the database without a file show as
`********** NO FILE **********`, like Rails. When `db/schema.rb` writes its
version with underscores (`2026_09_29_125131`), IDs are shown the same way.
When the current branch has an upstream (`git branch --set-upstream-to=ups/rebuild`),
IDs of migrations whose files are not on that upstream yet are shown in yellow.

`new` creates a sibling directory of `project_root`. Slashes in a branch name
become dashes in the directory name, so `feature/login` uses
`example_project/feature-login`. An existing local branch is checked out;
otherwise it is created from `main_branch`.

`new -d` (or `--database`) additionally gives the worktree an isolated copy of
the development database. It takes the source database from the
`DATABASE_URL` environment variable, then `DATABASE_URL` in the main
checkout's `.env`, then the `development` section of the main checkout's
`config/database.yml` (its `url`, or `database` with `username`, `password`,
`host` and `port`, following one `<<: *anchor` merge; ERB values are ignored).
`.env`, `config/database.yml`, `db/migrate` and `tmp/` are read in the Rails
root (see `rails_root`). It runs
`CREATE DATABASE "<db>_<worktree-name>" TEMPLATE "<db>"` through `psql`, and
rewrites `DATABASE_URL` in the worktree's `.env` to point at the copy. The template copy fails while the source database has active
connections, so stop Rails servers on the main checkout first. `remove` and
`delete_all` drop a worktree's own database after the worktree is removed, and
`list` marks such worktrees with `[database: <name>]`.

After the database copy, if the worktree's `db/migrate` contains files the main
checkout does not have, `bin/rails db:migrate` starts in the background so the
shell can enter the worktree immediately. Output goes to
`tmp/mrsk-migrate.log` in the worktree, and `list` shows the state as
`[migrating]`, `[migrated]`, `[migrate failed]`, or `[migrate interrupted]`.
This only happens for worktrees created with their own database; a worktree on
the shared database is never migrated automatically.

With the Zsh hook installed, `mrsk 2491` or `mrsk DEV-2491` creates `DEV-2491`
when needed and changes the current shell to that worktree. The shortcut also
accepts `-d`/`--database`: a new worktree is created with its own database, and
an existing worktree without one gets its own database copy on the spot.

`open` launches macOS Terminal in the selected worktree.

`remove` calls `git worktree remove`, which removes the registered worktree and
its directory but keeps the Git branch. It refuses dirty worktrees unless
`--force` is explicitly supplied.

`delete_all` preserves the configured main checkout and removes every other
registered worktree and its checked-out local branch. It also refuses dirty
worktrees unless `--force` is explicitly supplied. Set
`GIT_PROTECTED_BRANCHES` to comma- or whitespace-separated branch names whose
worktrees and local branches must be preserved.

On macOS, `updater start` installs and starts **Worktree Target Branch Updater**,
a user LaunchAgent that runs at
login and every 10 minutes. It updates the configured `project_root` with
`git pull --rebase`, using the checked-out `main_branch` and its Git tracking
remote. After a successful pull it runs `bundle install` when `Gemfile` or
`Gemfile.lock` changed, then `bin/rails db:migrate` when new files appeared in
`db/migrate`. The captured `PATH` lets launchd find the same Ruby and Bundler
as the shell that ran `updater start`. The helper is packaged as a background
macOS app so Login Items shows its proper name and icon.

`updater stop` unloads the LaunchAgent and removes its plist. `updater run`
executes one update immediately. Output is written to `~/.mrsk/updater.log` and
errors to `~/.mrsk/updater.error.log`. A failed Bundler or migration step is
retried on the next run. Only one project updater runs per user.
