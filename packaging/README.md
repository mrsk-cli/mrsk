# APT packaging

Packages support Debian 13 and Ubuntu 24.04 on amd64 and arm64. The CLI and
vendored open-code-review are built from source. The package keeps its binaries
under `/usr/lib/mrsk` and exposes only `/usr/bin/mrsk`, so another installation
of `ocr` can coexist with it.

The APT workflow builds and tests both architectures on every main push and
pull request. It installs each package through a signed test repository in
clean Debian and Ubuntu containers, checks worktree creation and removal,
previews a code review, and removes the package.

Pushing a `vX.Y.Z` tag publishes the tested packages as GitHub release assets
and deploys the signed APT repository to GitHub Pages. Existing release assets
are never overwritten. Use a new version for changed packages.

The repository uses GitHub Pages with GitHub Actions as its build source.
`APT_SIGNING_KEY` is a repository Actions secret containing an armored private
signing key. Its public certificate is tracked at `apt/mrsk.gpg`. Keep the
private key and its revocation certificate in a secure backup outside Git.
Renew or replace the key before its expiry, and publish the public certificate
with the matching key in the secret.

Current signing key: `BED0E914EDE626F8297974671132BEE9EEB901FF`.
It expires on 2028-09-30. GitHub Pages deployment is allowed for `v*` tags.

To build a package locally on Linux, install a C compiler, Make, Go 1.25.5 or
newer, and `dpkg-dev`, then run:

```sh
scripts/build-deb.sh 0.1.1
```

To generate repository metadata, also install `apt-utils` and GnuPG, import
the signing key, and run:

```sh
APT_SIGNING_KEY_ID=KEY_FINGERPRINT scripts/build-apt-repo.sh dist/apt dist/deb/*.deb
```
