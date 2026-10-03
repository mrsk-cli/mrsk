# Contributing to mrsk

Small, focused changes are welcome. For a larger change, open an issue first
so the goal and approach can be discussed before you spend time on it.

## Set up

Clone the source and create a branch for your change:

```sh
git clone https://github.com/mrsk-cli/mrsk.git
cd mrsk
git switch -c my-change
```

See the [README](README.md#requirements) for dependencies and platform limits.
The build needs Make, a C11 compiler, and Go 1.25.5 for the bundled review tool.
The shell tests also need Git, zsh, and Ruby. Run tests as a regular user:
some tests rely on file permissions and can fail under root.
Go may need network access to download its toolchain and modules.

## Build and test

From the repository root:

```sh
make
make test
```

The [Makefile](Makefile) runs these checks with the built binaries:

- `tests/e2e.sh`: config, commands, worktrees, and the zsh hook
- `tests/clone_e2e.sh`: cloning and config updates
- `tests/missing_copy_sources_e2e.sh`: missing files and folders
- `tests/database_e2e.sh`: database behavior with test helpers
- `tests/review_e2e.sh`: review previews without calling an LLM
- `tests/updater_e2e.sh`: updater behavior on macOS only

The tests use temporary directories and test repositories. Database tests use
fake `psql` and Rails commands; they do not prove a real database setup works.
On macOS, `make test` also builds and signs the updater app.

For a focused check after building, use the same binary paths as the Makefile:

```sh
MRSK_BIN="$PWD/mrsk" tests/e2e.sh
MRSK_BIN="$PWD/mrsk" OCR_BIN="$PWD/dist/ocr" tests/review_e2e.sh
```

For Chrome extension changes, install Node.js and run:

```sh
make chrome-extension-build
```

This runs the extension tests and rebuilds `dist/chrome-redmine-links`.
[CI](.github/workflows/ci.yml) covers macOS, Ubuntu, and Debian 13. It also
checks the extension and installation. A Linux test run does not cover the
macOS updater. For packaging changes, see [packaging/README.md](packaging/README.md)
and the [APT workflow](.github/workflows/apt.yml).

## Make a change

- Keep the patch focused on one goal
- Follow the style of the nearby code; the C build treats warnings as errors
- Add or update a test when command behavior changes
- Update the README when commands, config, or requirements change
- Do not edit the vendored review code for an unrelated fix; its update process
  is described in the [vendored review update guide](README.md#updating-the-vendored-review-tool)

Before opening a pull request, inspect your diff and run:

```sh
git diff --check
make test
```

For docs-only changes, check examples against the code, check links, and run
`git diff --check`. State which checks you ran and which you did not run.
The main CI workflow skips Markdown-only changes; that is not a test result.

## Report a bug or propose a feature

Search [existing issues](https://github.com/mrsk-cli/mrsk/issues) first. Include
small steps that someone else can follow, what you expected, and what happened.
For a feature, explain the task you want to make easier and how you do it now.

Remove tokens, passwords, private URLs, database connection strings, and other
private data from logs and config before posting. Share only the smallest
example needed to show the problem.
