# 󰈐 AppleSiliconThermals

Thermal monitoring and fan control for Apple Silicon Linux and the Omarchy shell.
This fork replaces the shell helper with a dependency-free Rust binary and adds a
configurable temperature curve. Inspired by [Stats](https://mac-stats.com/).

## Install

**Preview:** the Rust implementation is currently tested from source. The release
checksum is not pinned yet, so use [Development and validation](#development-and-validation)
until a release is published. The commands below describe the pinned release path.

```bash
git clone --branch feat/rust-temperature-curve https://github.com/cristim/AppleSiliconThermals.git \
  ~/.config/omarchy/plugins/io.github.lukasmoriarty.applesiliconthermals
~/.config/omarchy/plugins/io.github.lukasmoriarty.applesiliconthermals/setup.sh
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.lukasmoriarty.applesiliconthermals right
```

Run setup as your normal user. It downloads the prebuilt aarch64 musl binary,
checks the SHA256 pinned in `release.env`, installs it atomically, and restarts an
active curve service. It then uses sudo to enable `macsmc_hwmon.fan_control` at
runtime, persist it through tmpfiles, and install the fan-target permission rule.
No reboot or Rust compiler is needed. The existing upstream rule grants every
local user write access to fan targets (mode 0666).

The fork keeps the upstream plugin ID. Disable and back up an existing upstream
installation before replacing it. Do not enable two copies that control the same
fans. After a plugin update, rerun setup if the widget asks for it.

Release metadata is pinned in a follow-up commit after the release is built.
A checkout with a placeholder checksum refuses setup before any system changes;
use the pinned branch commit or the development installation below. A tag's source
archive may still contain the placeholder.

## Fan modes

- **Auto** hands control to Apple's SMC firmware and disables the curve service.
  Firmware may stop the fan or run it at maximum, including during a hardware fault.
- **Curve** follows a labelled temperature sensor. Select the sensor and the
  temperatures for minimum and maximum fan speed, then apply. Defaults: Charge
  Regulator Temp, 50°C to 75°C. Values must be whole degrees from 20 to 100, with
  low below high. Between thresholds the target rises linearly. Increases apply
  immediately; decreases are limited to about 300 RPM every two seconds.
- **Manual** offers a slider and Quiet, Regular, and Max presets. Targets are
  clamped separately to each fan's hardware limits. Manual also disables the curve.

**The exposed component sensors do not measure CPU/SoC die temperature and can lag
CPU load.** The tested M1 exposes NAND, battery, charge regulator, and Wi-Fi/BT
readings. A temperature curve does not repair a dead battery or other hardware fault.

The bar shows RPM, temperature, power, and the current mode. The popup shows curve
status and command errors. Fanless Macs retain telemetry without fan controls.
Hardware testing has been performed on a 13-inch M1 MacBook Pro; other models and
multiple physical fans still need hardware testing.

## Icon animation

To keep the fan icon still, add `"spinIcon": false` to its existing entry in
`~/.config/omarchy/shell.json` under `bar.layout`:

```json
{
  "id": "io.github.lukasmoriarty.applesiliconthermals",
  "spinIcon": false
}
```

The setting persists across restarts. Omit it or set it to `true` to animate while
the fan runs. RPM readings, temperature colors, and fan control work in either case.

## Service and command line

```bash
bin/apple-silicon-thermals get
bin/apple-silicon-thermals curve config 'Charge Regulator Temp' 50 75
bin/apple-silicon-thermals curve on
bin/apple-silicon-thermals set 1799
bin/apple-silicon-thermals set auto
bin/apple-silicon-thermals curve off
```

`curve on` creates and enables `applesiliconthermals-curve.service` under your
systemd user configuration. It starts with the graphical session and stops with
that session. It runs independently of the widget, so a shell reload does not
interrupt the curve. `curve run` is reserved for systemd.

The unit's binary-independent `ExecStopPost` releases fans on stop or crash. It
rewrites the current target, clamped to the fan's range, before writing zero to
force the driver's firmware-mode transition. It uses maximum only when the target
cannot be read. Firmware itself can still command maximum speed after release.
A failed hardware write exits the service so the release handler runs.

An invalid configuration or missing/implausible sensor releases control to firmware
until readings recover. Three consecutive firmware target overrides cause release
and a 60-second retry delay. Removing the binary also makes the loop release and
exit. Status older than six seconds is ignored. Runtime mode records are cleared
at logout; an out-of-band manual setting cannot be inferred reliably from the SMC
target alone, so Auto in the widget describes this helper's tracked state.

Configuration: `${XDG_CONFIG_HOME:-~/.config}/applesiliconthermals/curve.conf`.
It is strictly parsed data, never executed. Runtime state and the command lock live
under `$XDG_RUNTIME_DIR/applesiliconthermals`; that environment variable is required.

## Remove

Stop the curve before removing plugin files. To also undo system setup, run the
uninstaller while the plugin still exists:

```bash
~/.config/omarchy/plugins/io.github.lukasmoriarty.applesiliconthermals/bin/apple-silicon-thermals set auto
sudo ~/.config/omarchy/plugins/io.github.lukasmoriarty.applesiliconthermals/uninstall.sh
omarchy plugin disable io.github.lukasmoriarty.applesiliconthermals
omarchy plugin remove io.github.lukasmoriarty.applesiliconthermals
```

## Development and validation

Rust 1.89 or newer:

```bash
cargo build --release --locked
install -Dm755 target/release/apple-silicon-thermals bin/apple-silicon-thermals
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
python3 tests/cli.py
bash -n setup.sh uninstall.sh
```

Development installation still requires the kernel parameter and fan-target
permissions from setup. Tests use synthetic hwmon trees and a stub systemctl;
`AST_HWMON_ROOT`, `AST_SYS_ROOT`, and `AST_SYSTEMCTL` are test seams.
CI checks Rust and scripts. Release tags must match Cargo, manifest, and release.env
versions; GitHub Actions builds the static aarch64 musl artifact.

Live checks on the M1 cover curve ramping, service-unit validation, crash recovery,
and switching back to firmware. Suspend/resume, logout/login, and reboot validation
require a separate session that can interrupt desktop work; they are not yet verified.

## Packaging and releases

See [PACKAGING.md](PACKAGING.md) for native and musl builds, release artifacts,
versioning, checksum pinning, installation verification, downstream package layout,
and rollback. This fork currently distributes binaries from its own release
repository; upstream adoption needs the download URL and clone instructions updated.

## License

[MIT](LICENSE). Original plugin by LukasMoriarty; Rust curve work in the cristim fork.
