use std::path::Path;
use std::process::Command;

/// Root-owned helper installed by the README steps; the sudoers rule allows exactly this path.
pub const PATH: &str = "/usr/local/libexec/apple-silicon-fan-control";
const SUDO: &str = "/usr/bin/sudo";
// Test seam: replaces the sudo-wrapped broker so tests never write host fans.
const OVERRIDE_VAR: &str = "AST_BROKER";

pub fn installed() -> bool {
    std::env::var_os(OVERRIDE_VAR).map_or_else(
        || Path::new(PATH).is_file(),
        |path| Path::new(&path).is_file(),
    )
}

/// Ask the broker to set every fan to `action`: `auto` or an RPM.
pub fn run(action: &str) -> Result<(), String> {
    let mut command = match std::env::var_os(OVERRIDE_VAR) {
        Some(program) => Command::new(program),
        None => {
            let mut command = Command::new(SUDO);
            command.args(["-n", PATH]);
            command
        }
    };
    let output = command
        .arg(action)
        .output()
        .map_err(|err| format!("failed to run the fan broker: {err}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "fan broker {action}: {} ({})",
            String::from_utf8_lossy(&output.stderr).trim(),
            output.status
        ))
    }
}
