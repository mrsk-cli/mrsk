# Arch and Omarchy packaging

[Back to mrsk](../../README.md#arch-linux-and-omarchy)

The [PKGBUILD](PKGBUILD) builds the stable v0.1.1 source archive with a verified
SHA256, including the vendored review helper and its recorded VERSION. Only
x86_64 is enabled; validate aarch64 before adding it. `base-devel` is required
by Arch packaging convention, and `makepkg -si` installs the declared build,
check and runtime dependencies. Go 1.25.5 or newer is required; the build uses
the installed toolchain and locked modules, with caches inside `src/`.

Run as a regular user on Arch or Omarchy:

```sh
cd packaging/arch
makepkg -si
```

The package uses the existing Debian wrapper: `/usr/bin/mrsk` runs the CLI
with `/usr/lib/mrsk` first in PATH. Both `mrsk` and `ocr`, plus the updater
helper, remain private there. Licenses go under `/usr/share/licenses/mrsk`,
and the release README under `/usr/share/doc/mrsk`. No shell files are edited;
the existing `mrsk shell-init` hook supplies optional zsh navigation.
Ruby, Vim, PostgreSQL's `psql`, and `xdg-open` are optional dependencies for
their respective commands. `open` and `updater` require macOS.

The [Arch workflow](../../.github/workflows/arch.yml) runs ordinary-user
`makepkg` and the release's existing tests in a disposable Arch container,
compares generated `.SRCINFO`, checks `namcap`, then installs the package and
tests worktree creation/removal, the shell hook and an offline review preview
with another `ocr` earlier in PATH. Package removal must preserve user files.
This tests the pinned release with the PR's packaging; the existing CI tests
the current checkout separately. The artifact is unsigned and is not published
to a package registry.

For a release update, change `pkgver`, download the matching source archive,
replace its SHA256, reset `pkgrel` to 1, and regenerate metadata on Arch:

```sh
makepkg --printsrcinfo > .SRCINFO
makepkg --cleanbuild
```

For packaging changes at the same release, increment `pkgrel`. Run `namcap`
on the recipe and package, and update the CI install test's expected version
and helper version when needed.

## Registry handoff

No AUR or Omarchy registry submission has been made. Before publishing,
recheck the `mrsk` name in both registries and review package ownership.

- **AUR:** submit `PKGBUILD` and the generated `.SRCINFO` through a maintainer's
  AUR account. After acceptance, Omarchy's **Install > AUR** menu,
  `omarchy pkg aur add mrsk`, or `yay -S mrsk` can install it.
- **Omarchy repository:** propose this recipe at `pkgbuilds/mrsk/PKGBUILD`
  with [.omarchy/package.json](.omarchy/package.json). The metadata follows
  Omarchy's [GitHub release watch format](https://github.com/omacom/omarchy-pkgs/blob/master/docs/upstream-sources.md).
  Acceptance, repository signing and publication belong to the Omarchy
  maintainers. Only after publication will `omarchy pkg add mrsk` work.

Omarchy's [package manual](https://omarchy.org/manual/other-packages/) documents
its normal Arch/AUR installation paths. No desktop plugin or shell wrapper
beyond the existing package launcher is needed.
