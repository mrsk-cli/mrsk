#!/bin/sh
set -eu

: "${APT_SIGNING_KEY_ID:?APT_SIGNING_KEY_ID is required}"
output=${1:?Usage: build-apt-repo.sh OUTPUT PACKAGE.deb...}
shift
test "$#" -gt 0
if [ -e "$output" ]; then
    printf 'Output already exists: %s\n' "$output" >&2
    exit 1
fi
mkdir -p "$output/pool/main/m/mrsk"
architectures=""
version=""
for package in "$@"; do
    test "$(dpkg-deb -f "$package" Package)" = mrsk
    architecture=$(dpkg-deb -f "$package" Architecture)
    case "$architecture" in amd64|arm64) ;; *) exit 1 ;; esac
    package_version=$(dpkg-deb -f "$package" Version)
    dpkg --validate-version "$package_version"
    test -z "$version" || test "$version" = "$package_version"
    version=$package_version
    install -m 0644 "$package" "$output/pool/main/m/mrsk/mrsk_${version}_${architecture}.deb"
    architectures="$architectures $architecture"
done
install -m 0644 packaging/apt/mrsk.sources "$output/mrsk.sources"
cd "$output"
architectures=$(printf '%s\n' $architectures | sort -u | tr '\n' ' ')
for architecture in $architectures; do
    index="dists/stable/main/binary-$architecture"
    mkdir -p "$index"
    dpkg-scanpackages --arch "$architecture" pool /dev/null > "$index/Packages"
    gzip -n -9 -c "$index/Packages" > "$index/Packages.gz"
done
release=$(mktemp)
trap 'rm -f "$release"' EXIT INT TERM
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=mrsk \
    -o APT::FTPArchive::Release::Label=mrsk \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o "APT::FTPArchive::Release::Architectures=$architectures" \
    -o APT::FTPArchive::Release::Components=main \
    release dists/stable > "$release"
mv "$release" dists/stable/Release
gpg --batch --yes --local-user "$APT_SIGNING_KEY_ID" --digest-algo SHA256 \
    --clearsign --output dists/stable/InRelease dists/stable/Release
gpg --batch --yes --local-user "$APT_SIGNING_KEY_ID" --digest-algo SHA256 \
    --armor --detach-sign --output dists/stable/Release.gpg dists/stable/Release
gpg --export-options export-minimal --export "$APT_SIGNING_KEY_ID" > mrsk.gpg
