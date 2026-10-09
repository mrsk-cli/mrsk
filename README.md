# mrsk

[![CI](https://github.com/mrsk-cli/mrsk/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mrsk-cli/mrsk/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/mrsk-cli/mrsk)](https://github.com/mrsk-cli/mrsk/releases/latest)
[![License](https://img.shields.io/github/license/mrsk-cli/mrsk)](LICENSE)

Work on more than one Git branch without leaving your current work behind.
`mrsk` creates and manages worktrees beside your main checkout, with short
commands for common tasks.

- Keep each task in its own directory, without a second clone
- Copy selected local files, such as `.env`, into new worktrees
- Jump to numbered task branches with an optional zsh shortcut
- Add a separate PostgreSQL database for Rails work, or run an AI code review,
  when you need those features

The core CLI is written in POSIX C and runs on macOS and Linux.

[Install](#install) · [First worktree](#first-worktree) ·
[Configuration](#configuration) · [Commands](#commands) ·
[Chrome extension](chrome-redmine-links/README.md) · [Packaging](packaging/README.md) ·
[Contribute](CONTRIBUTING.md) · [Licenses](#licenses)

## Requirements

| Use | What you need |
| --- | --- |
| Create, list, and remove worktrees | macOS or Linux, and Git 2.36 or newer |
| Clone a GitHub repository with `mrsk clone` | GitHub SSH authentication; HTTPS inputs also use SSH |
| Change directory with `mrsk 2491` | zsh and the shell integration below; explicit commands work without it |
| AI review | `ocr`, Git 2.41 or newer, and an LLM provider and model configured for a full review |
| Build from source | Make, a C11 compiler, and Go 1.25.5 or newer for the bundled `ocr` |
| Run the test suite | Build tools above, zsh, and Ruby; run as a regular user |
| Extra commands | Vim for `configure`; Ruby for Rails migration helpers and `redmine --show`; `psql` for database features; `xdg-open` for `redmine` on Linux |
| macOS-only commands | `open` uses Terminal; `updater` uses launchd and may run Bundler and Rails |

Homebrew and APT install the review helper too. APT requires Git 2.41 or newer
for the package as a whole. Rails, PostgreSQL, and an LLM account are not needed
for the first-worktree guide.

## Install

Choose one method, then continue to [First worktree](#first-worktree).

### Homebrew

```sh
brew install mrsk-cli/tap/mrsk
```

The Homebrew formula also installs `ocr` for `mrsk review`. For the optional
zsh shortcut, add the hook once and open a new zsh session:

```sh
echo 'eval "$(command mrsk shell-init)"' >> "$HOME/.zshrc"
```

### APT (Debian and Ubuntu)

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

Configure its LLM provider and model with:

```sh
/usr/lib/mrsk/ocr config provider
/usr/lib/mrsk/ocr config model
```

For zsh worktree navigation, add `eval "$(mrsk shell-init)"` to `~/.zshrc` and
open a new shell. The macOS-only `open` and `updater` commands remain unavailable
on Linux.

### Arch Linux and Omarchy

On x86_64 Arch or Omarchy, build and install the pinned release package as a
regular user (review the recipe before running `makepkg`):

```sh
sudo pacman -Syu --needed base-devel git
git clone https://github.com/mrsk-cli/mrsk.git
cd mrsk/packaging/arch
makepkg -si
```

The package includes a private `ocr`. Configure its provider and model using
`/usr/lib/mrsk/ocr config provider` and `/usr/lib/mrsk/ocr config model`.
For the optional zsh shortcut, install `zsh`, add
`eval "$(command mrsk shell-init)"` to `~/.zshrc`, and open a new shell.
Installation does not edit your shell configuration.

`mrsk` is not yet published in the AUR or Omarchy package repositories.
After AUR publication, Omarchy's **Install > AUR** menu or
`omarchy pkg aur add mrsk` (equivalently `yay -S mrsk`) can install it.
`omarchy pkg add mrsk` needs separate acceptance and publication in Omarchy's
package repository. See the [Arch maintainer guide](packaging/arch/README.md).

### Build from source

```sh
git clone https://github.com/mrsk-cli/mrsk.git
cd mrsk
make
make test
make install PREFIX="$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
```

Keep `$HOME/.local/bin` in your shell's `PATH` when using that install prefix.
Run the build, tests, and install as a regular user, not root: permission tests
can fail under root. See [CONTRIBUTING.md](CONTRIBUTING.md) for test details.

`make` and `make install` also build the vendored open-code-review sources.
Their [Go module](third_party/open-code-review/go.mod) requires Go 1.25.5.
Go 1.21 or newer can download the required toolchain when automatic toolchain
selection is enabled. Allow network access for toolchain and module downloads,
or provide them in advance. `make install` puts `ocr` next to `mrsk`.
On macOS, installation also builds and signs the updater app with `codesign`.

For the optional zsh shortcut, add this line to `~/.zshrc` once and open a new
zsh session:

```sh
eval "$(command mrsk shell-init)"
```

#### Debian 13 source build

Install the build tools and the programs `mrsk` runs:

```sh
sudo apt install git make gcc golang-go ca-certificates zsh ruby
sudo apt install vim postgresql-client xdg-utils
```

The second line is optional: `configure` opens Vim, the database commands run
`psql`, and `redmine` opens the browser through `xdg-open`.

Build, test and install as a regular user, not root:

```sh
git clone https://github.com/mrsk-cli/mrsk.git
cd mrsk
make
make test
make install PREFIX="$HOME/.local"
```

Debian 13 ships Go 1.24, so with automatic toolchain selection enabled the
first `make` downloads the required Go 1.25.5 toolchain and needs network access.
`make test` fails under root, because root ignores the file permissions some
tests rely on.

The shell integration is written for zsh. If you use bash, the explicit
`new`, `list`, and `remove` commands still work. To use zsh as your login shell,
switch it, log in again, then add `mrsk` to zsh:

```sh
chsh -s "$(command -v zsh)"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
echo 'eval "$(command mrsk shell-init)"' >> "$HOME/.zshrc"
```

`mrsk open` (Terminal) and `mrsk updater` (launchd) need macOS and exit with an
error on Debian.

## First worktree

Start with an existing local Git checkout that has at least one commit.
Choose a main checkout and note its absolute path and base branch, for example
`/home/you/projects/example/main` and `main`. On macOS, use your actual path
under `/Users/you` instead. The folder does not have to be named `main`.

Create the configuration directory:

```sh
install -d -m 700 "$HOME/.mrsk"
```

With your editor, create `~/.mrsk/config.yml` with the following content.
Replace `project_root` with the absolute checkout path and `main_branch` with
an existing local branch. Do not use `~` or `$HOME` inside the YAML path.
If you already have a config, add a project to its `projects` list instead of
replacing the file; each project name must be unique.

```yaml
projects:
  - project_name: example
    project_root: /home/you/projects/example/main
    main_branch: main
```

Use a new branch name and a sibling directory that do not already exist:

```sh
mrsk example new first-task
mrsk example list
cd /home/you/projects/example/first-task
```

Adjust the `cd` path to match your checkout. `new` creates `first-task` from
`main_branch` in a sibling directory; it does not change your current shell's
directory. `list` shows the registered worktrees. No shell hook, database, or
review setup is needed for these commands.

When you no longer need this worktree, first save your work and return to the
main checkout:

```sh
cd /home/you/projects/example/main
mrsk example remove first-task
mrsk example list
```

`remove` deletes the worktree directory but keeps the branch and its commits.
It refuses a dirty worktree. Do not add `--force` just to get past that check:
review and save any local changes first. For this guide, leave the optional
`copy_files`, `copy_folders`, and database settings out.

## Configuration

The config lives at `~/.mrsk/config.yml`. Start with the minimal example above,
or use `mrsk configure` to open the file in Vim.

### Upgrading from `work`

Only use this step if you have the old `~/.work/config.yml`. Back up any
existing `~/.mrsk/config.yml` first; the copy below overwrites it. New users
should use [First worktree](#first-worktree) instead.

```sh
install -d -m 700 "$HOME/.mrsk"
install -m 600 "$HOME/.work/config.yml" "$HOME/.mrsk/config.yml"
```

### Optional settings and multiple projects

Example configuration:

```yaml
redmine_url: https://redmine.example.com
projects:
  - project_name: example_project
    project_root: /home/you/projects/example_project/main
    main_branch: main
    default: true
    prefix: DEV
    copy_files:
      - .env
      - config/master.key
    copy_folders:
      - storage
  - project_name: another_project
    project_root: /home/you/projects/another_project/main
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

| Command | Purpose |
| --- | --- |
| `mrsk configure` | Edit the configuration in Vim |
| `mrsk clone https://github.com/basecamp/fizzy` | Clone a GitHub repository and register the project; SSH URLs work too |
| `mrsk [project] new [-d] <branch>` | Create a sibling worktree; optionally copy the development database |
| `mrsk [project] list` | List registered worktrees and database/migration state |
| `mrsk [project] remove [--force] <branch>` | Remove one worktree, keeping its branch |
| `mrsk [project] delete_all [--force] [--merged]` | Remove other worktrees **and their local branches**; see [deletion details](#worktrees) |
| `mrsk [project] prune [--force]` | List databases left behind by deleted worktrees; drop them with `--force` |
| `mrsk 2491` or `mrsk DEV-2491` | Create or enter a task worktree with the [zsh hook](#shell-shortcuts); accepts `-d` |
| `mrsk review [options]` | Review changes, a branch range, or a commit with [open-code-review](#ai-review) |
| `mrsk rails-schema-confl` | Resolve a standard Rails schema version conflict |
| `mrsk bump-migration-version` | Re-timestamp migrations added by the branch |
| `mrsk dbst [--full]` | Show migration status; the default is the last 20 migrations |
| `mrsk redmine [--show]` | Open the current branch's issue in the browser, or print its title and description |
| `mrsk [project] open <branch>` | Open the worktree in macOS Terminal |
| `mrsk [project] updater <action>` | Manage the [macOS updater](#macos-updater) |

`[project]` and bracketed options are optional; replace angle-bracketed values
with your own. Updater actions are `start`, `status`, `stop`, and `run`. Database copies and their
removal are described under [Rails and database tools](#rails-and-database-tools).

The project name may be omitted when only one project is configured, when the
current directory matches a project's worktree directory, or when a default is
configured.

`configure` opens `~/.mrsk/config.yml` in Vim, creating `~/.mrsk` when needed.

### Worktrees

`clone` accepts one GitHub HTTPS or SSH repository URL. A `.git` suffix is
optional, and HTTPS URLs may have a trailing slash. Both forms are normalized
to SSH, so both URL forms use `git@github.com:basecamp/fizzy.git` for Git
operations. Set up [GitHub SSH authentication](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)
first, even for public repositories. If Git reports `Permission denied (publickey)`,
check your SSH key setup.

Before creating files, `git ls-remote --symref` discovers and
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

`new` creates a sibling directory of `project_root`. Slashes in a branch name
become dashes in the directory name, so `feature/login` uses
`example_project/feature-login`. An existing local branch is checked out;
otherwise it is created from `main_branch`.

`remove` calls `git worktree remove`, which removes the registered worktree and
its directory but keeps the Git branch. It refuses dirty worktrees unless
`--force` is explicitly supplied.

`delete_all` preserves the configured main checkout and removes every other
registered worktree and its checked-out local branch. It also refuses dirty
worktrees unless `--force` is explicitly supplied. Set
`GIT_PROTECTED_BRANCHES` to comma- or whitespace-separated branch names whose
worktrees and local branches must be preserved.
`--merged` limits `delete_all` to worktrees whose branch is already merged into
`main_branch` (the same check as `git branch --merged`). Squash-merged or
rebased branches are not detected and stay.

### Shell shortcuts

With the Zsh hook installed, `mrsk 2491` or `mrsk DEV-2491` creates `DEV-2491`
when needed and changes the current shell to that worktree. The shortcut also
accepts `-d`/`--database`: a new worktree is created with its own database, and
an existing worktree without one gets its own database copy on the spot.

### AI review

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

#### Updating the vendored review tool

The vendored release is recorded in `third_party/open-code-review/VERSION`.
To move to another one, run `third_party/update-open-code-review.sh <tag>`. It
replaces the vendored copy with that release's Go sources (tests excluded) and
checks that they build.

### Rails and database tools

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

A worktree deleted another way (`git worktree remove`, `rm -rf`) leaves its
database behind. `prune` lists every `<db>_*` database whose worktree folder no
longer exists, and `prune --force` drops them. Names that appear in the main
checkout's `config/database.yml` (such as Rails 8's `<db>_cache`) are never
listed.

After the database copy, if the worktree's `db/migrate` contains files the main
checkout does not have, `bin/rails db:migrate` starts in the background so the
shell can enter the worktree immediately. Output goes to
`tmp/mrsk-migrate.log` in the worktree, and `list` shows the state as
`[migrating]`, `[migrated]`, `[migrate failed]`, or `[migrate interrupted]`.
This only happens for worktrees created with their own database; a worktree on
the shared database is never migrated automatically.

`rails-schema-confl` resolves a standard `db/schema.rb` version conflict using
the newest timestamp from `db/migrate`. Run it from the Rails project root.

`bump-migration-version` re-timestamps the migrations this branch added so they
sort after everything already in `db/migrate`. Run it anywhere in a checkout
after rebasing on `main_branch`; it works in the checkout's Rails root.
Migrations added since the merge base with `main_branch` (committed, staged,
or untracked) are renamed to consecutive seconds starting at the current UTC
time, or at one second past the newest foreign migration when that is later,
keeping their relative order. Tracked
files move with `git mv`, so the rename is staged. When the worktree `.env`
defines `DATABASE_URL`, matching `schema_migrations` rows are updated through
`psql` in one transaction before the files move, so an applied migration is not
re-run; a failing `psql` only prints a yellow warning. Nothing is renamed when a
target file already exists.

`dbst` is a fast `bin/rails db:migrate:status`. It prints the last 20
migrations (all of them with `--full`) with their up/down state, ID, name, and
the committer: the part before `@` in the email of whoever added the migration
file in git. The state comes from `schema_migrations` through `psql`, using the
same database lookup as [`new -d`](#rails-and-database-tools) in the Rails root of the checkout
you are in; outside `project_root` and its worktrees it exits with an error.
Versions applied in the database without a file show as
`********** NO FILE **********`, like Rails. When `db/schema.rb` writes its
version with underscores (`2026_09_29_125131`), IDs are shown the same way.
When the current branch has an upstream (`git branch --set-upstream-to=ups/rebuild`),
IDs of migrations whose files are not on that upstream yet are shown in yellow.

### Redmine

`redmine` opens `<redmine_url>/issues/<number>` in the default browser, using
the issue number at the end of the current branch name. For example, branch
`DEV-3454` opens `https://redmine.example.com/issues/3454`. When `redmine_url`
has no scheme, `https://` is used.

`redmine --show` prints the issue's title, a blank line, and its description
instead of opening the browser. It reads `<redmine_url>/issues/<number>.json`
through Ruby, so the Redmine REST API must be enabled. When Redmine needs a
login, set `REDMINE_API_KEY` to your API key (shown under **My account**).

### macOS updater

`open` launches macOS Terminal in the selected worktree.

On macOS, `updater start` installs and starts **Worktree Target Branch Updater**,
a user LaunchAgent that runs at
login and every 10 minutes. It updates the configured `project_root` with
`git pull --rebase`, using the checked-out `main_branch` and its Git tracking
remote. After a successful pull it runs `bundle install` when `Gemfile` or
`Gemfile.lock` changed, then `bin/rails db:migrate` when new files appeared in
`db/migrate`. Both steps run in the Rails root: the repo root when it has
`config/database.yml`, else the first top-level folder that has one (the
`rails_root` setting is not read here). The captured `PATH` lets launchd find
the same Ruby and Bundler as the shell that ran `updater start`. The helper is
packaged as a background macOS app so Login Items shows its proper name and icon.

`updater stop` unloads the LaunchAgent and removes its plist. `updater run`
executes one update immediately. Output is written to `~/.mrsk/updater.log` and
errors to `~/.mrsk/updater.error.log`. A failed Bundler or migration step is
retried on the next run. Only one project updater runs per user.

## Licenses

The mrsk CLI is covered by the [MIT license](LICENSE). The bundled
open-code-review has its own [Apache 2.0 license](third_party/open-code-review/LICENSE).
