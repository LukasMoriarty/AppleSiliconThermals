# Packaging and release maintenance

## Deliverables

The plugin combines QML UI files with one Rust executable. Users of a published
release do not need Cargo. The helper has no third-party Rust dependencies.

| Item | Location or name |
| --- | --- |
| Linux target | `aarch64-unknown-linux-musl` |
| Release executable | `apple-silicon-thermals-aarch64-linux-musl` |
| Checksum asset | `apple-silicon-thermals-aarch64-linux-musl.sha256` |
| Installed executable | `<plugin>/bin/apple-silicon-thermals` (0755) |
| Plugin entry point | `<plugin>/BarWidget.qml` |
| Version and checksum pin | `<plugin>/release.env` |
| Generated user service | `$XDG_CONFIG_HOME/systemd/user/applesiliconthermals-curve.service` |

The config directory defaults to `~/.config`. The service is generated when the
user enables Curve, with the installed executable's absolute path. Do not ship a
unit containing a build machine's path or start fan control during packaging.

## Build from source

For a local development build, run `cargo build --release --locked`, then install
`target/release/apple-silicon-thermals` into the plugin's `bin/` directory as shown
in the README. This native build can depend on the host's libc.

To reproduce the release build, use an aarch64 Ubuntu 24.04 build environment with
Rustup installed. The workflow pins Rust 1.89.0 and uses an aarch64 hosted runner:

```bash
sudo apt-get update
sudo apt-get install -y musl-tools
rustup toolchain install 1.89.0 --profile minimal
rustup target add --toolchain 1.89.0 aarch64-unknown-linux-musl
cargo +1.89.0 test --locked
cargo +1.89.0 build --release --locked --target aarch64-unknown-linux-musl
mkdir -p dist
cp target/aarch64-unknown-linux-musl/release/apple-silicon-thermals \
  dist/apple-silicon-thermals-aarch64-linux-musl
(cd dist && sha256sum apple-silicon-thermals-aarch64-linux-musl \
  > apple-silicon-thermals-aarch64-linux-musl.sha256)
```

These commands assume native aarch64; an x86 build host additionally needs a
suitable cross linker and musl sysroot. Verify the packaged executable with `file`
and `readelf -l`, and run it on a 16 KiB-page Asahi kernel before calling that
artifact hardware-tested. A successful native build alone does not validate the
musl release artifact.

## Publish and pin a release

1. Run the README validation commands and check the CI run. Set the same version
   in `Cargo.toml`, `Cargo.lock`, `manifest.json`, and `release.env`. For a new
   artifact, reset SHA256 to a placeholder so setup cannot install unverified bytes.
2. Commit the version changes. Create a version tag on the reviewed commit and
   push it to the repository that will distribute binaries:

   ```bash
   git tag -a v1.1.0 -m 'AppleSiliconThermals 1.1.0'
   git push origin v1.1.0
   ```

   Use a new version for subsequent releases; do not move a published tag.
   `.github/workflows/release.yml` validates version agreement, runs Rust tests,
   builds the musl executable, smoke-tests `get`, and uploads the executable and
   checksum. GitHub Actions needs `contents: write` for this job.
3. Download both assets from the completed release into a clean directory. Example
   for the fork currently configured by `setup.sh`:

   ```bash
   mkdir -p /tmp/ast-release-1.1.0
   gh release download v1.1.0 --repo cristim/AppleSiliconThermals \
     --pattern 'apple-silicon-thermals-aarch64-linux-musl*' \
     --dir /tmp/ast-release-1.1.0
   (cd /tmp/ast-release-1.1.0 && sha256sum -c \
     apple-silicon-thermals-aarch64-linux-musl.sha256)
   ```

4. Copy the verified executable's SHA256 into `release.env`. Commit and push that
   pin to the installation branch. The tag necessarily precedes the pin commit;
   its source archive may retain the placeholder. Direct users to the pinned
   branch, and do not advertise setup as ready while its checksum is a placeholder.
5. On Apple Silicon, run `setup.sh` as the normal desktop user. Confirm the download
   checksum, `bin/apple-silicon-thermals get` version, and a working widget. Test an
   update while Curve is active: atomic replacement should restart the existing
   service. Never execute the privileged installer from a package build function.

The current PR contains release infrastructure but no published/pinned v1.1.0
binary. The native development build is the locally tested installation.

## Upstream adoption and distribution packages

`setup.sh` currently downloads from `cristim/AppleSiliconThermals`. The release
workflow publishes to whichever repository runs it. If upstream adopts this work,
change `RELEASES_URL` to the upstream release repository and update README clone
instructions before publishing there. Keep the plugin ID stable to replace an
existing installation; never enable two copies against the same fans.

A distribution package should stage the QML, manifest, license, README, and
`release.env` with the binary at the relative `bin/` location. Build from a pinned
source commit or verify a pinned release checksum. Do not bundle `target/`, `.git/`,
user configuration, runtime locks, or a generated user unit. The `.github/` and
`tests/` directories are build/review inputs, not runtime requirements.

System configuration, when managed by the package, should use package-owned
files rather than run the interactive installer. The current setup installs:

- `/etc/tmpfiles.d/macsmc-fan.conf` to enable the module parameter at boot.
- `/etc/udev/rules.d/99-macsmc-fan.rules` to grant fan-target access.

The inherited rule permits all local users (0666); downstreams should decide
access policy explicitly. This repository does not yet include a PKGBUILD or the
deferred first-party Omarchy mx-mac integration.

## Updates and rollback

The widget compares `get.version` with `release.env` and asks for setup when they
differ. Setup replaces the binary atomically and only restarts an existing active
curve unit. It does not enable Curve on a new install.

For rollback, first run `bin/apple-silicon-thermals set auto`, then restore the
previous plugin checkout and its matching binary/checksum. Re-enable Curve only
when the restored version has been checked. If uninstalling system setup, run the
uninstaller before deleting plugin files; see the README removal order.
