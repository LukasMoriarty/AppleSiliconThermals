use std::fs::{self, File};
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

pub const UNIT: &str = "applesiliconthermals-curve.service";
const APP_DIR: &str = "applesiliconthermals";

// Runs from the unit rather than the binary so a removed plugin directory or a crashed daemon still
// hands every fan back to the SMC. Writing a valid target before 0 forces the driver to rewrite the
// mode key; reusing the current target (clamped, max if unreadable) avoids spinning the fan up.
const RELEASE_ALL_FANS: &str = r#"/bin/sh -c 'for d in /sys/class/hwmon/hwmon*; do [ "$$(cat "$$d/name" 2>/dev/null)" = macsmc_hwmon ] || continue; for t in "$$d"/fan*_target; do n="$${t%%_target}"; min=$$(cat "$${n}_min"); max=$$(cat "$${n}_max"); cur=$$(cat "$$t" 2>/dev/null) || cur=$$max; [ "$$cur" -ge "$$min" ] 2>/dev/null || cur=$$min; [ "$$cur" -le "$$max" ] 2>/dev/null || cur=$$max; echo "$$cur" > "$$t"; echo 0 > "$$t"; done; done'"#;

fn not_found(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, message.to_string())
}

pub fn runtime_dir() -> io::Result<PathBuf> {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| not_found("XDG_RUNTIME_DIR is not set"))?;
    let dir = PathBuf::from(base).join(APP_DIR);
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)?;
    Ok(dir)
}

/// Serialises commands that change fan state; released when the returned file is dropped.
pub fn lock() -> io::Result<File> {
    let file = File::create(runtime_dir()?.join("lock"))?;
    file.lock()?;
    Ok(file)
}

fn config_home() -> io::Result<PathBuf> {
    if let Some(dir) = std::env::var_os("XDG_CONFIG_HOME").filter(|value| !value.is_empty()) {
        return Ok(dir.into());
    }
    std::env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(|home| PathBuf::from(home).join(".config"))
        .ok_or_else(|| not_found("neither XDG_CONFIG_HOME nor HOME is set"))
}

pub fn config_path() -> io::Result<PathBuf> {
    Ok(config_home()?.join(APP_DIR).join("curve.conf"))
}

pub fn unit_path() -> io::Result<PathBuf> {
    Ok(config_home()?.join("systemd/user").join(UNIT))
}

pub fn write_atomic(path: &Path, contents: &str) -> io::Result<()> {
    let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is not a file path", path.display()),
        ));
    };
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{}.tmp", name.to_string_lossy()));
    fs::write(&tmp, contents)?;
    fs::rename(&tmp, path)
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

pub fn set_manual(manual: bool) -> io::Result<()> {
    let path = runtime_dir()?.join("manual");
    if manual {
        fs::write(path, "")
    } else {
        remove_if_present(&path)
    }
}

pub fn is_manual() -> bool {
    runtime_dir().is_ok_and(|dir| dir.join("manual").exists())
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

pub struct Status {
    pub state: String,
    pub millidegrees: Option<i64>,
    pub target: Option<u32>,
    pub age_secs: u64,
}

pub fn write_status(state: &str, millidegrees: Option<i64>, target: Option<u32>) -> io::Result<()> {
    let field = |value: Option<String>| value.unwrap_or_else(|| "-".to_string());
    let line = format!(
        "{state} {} {} {}\n",
        field(millidegrees.map(|value| value.to_string())),
        field(target.map(|value| value.to_string())),
        now_secs()
    );
    write_atomic(&runtime_dir()?.join("curve"), &line)
}

/// The daemon's last status, or None when it has not reported within `max_age_secs`.
pub fn read_status(max_age_secs: u64) -> Option<Status> {
    let contents = fs::read_to_string(runtime_dir().ok()?.join("curve")).ok()?;
    let mut fields = contents.split_whitespace();
    let state = fields.next()?.to_string();
    let millidegrees = fields.next()?.parse().ok();
    let target = fields.next()?.parse().ok();
    let stamp: u64 = fields.next()?.parse().ok()?;
    let age_secs = now_secs().saturating_sub(stamp);
    (age_secs <= max_age_secs).then_some(Status {
        state,
        millidegrees,
        target,
        age_secs,
    })
}

pub fn clear_status() -> io::Result<()> {
    remove_if_present(&runtime_dir()?.join("curve"))
}

pub fn systemctl(args: &[&str]) -> Result<(), String> {
    let program = std::env::var_os("AST_SYSTEMCTL").unwrap_or_else(|| "systemctl".into());
    let status = Command::new(&program)
        .arg("--user")
        .args(args)
        .status()
        .map_err(|err| format!("failed to run systemctl: {err}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "systemctl --user {} failed ({status})",
            args.join(" ")
        ))
    }
}

/// Quote a path as one systemd command-line word, escaping specifier and variable expansion.
fn systemd_word(path: &Path) -> String {
    let mut out = String::from("\"");
    for c in path.to_string_lossy().chars() {
        match c {
            '"' | '\\' => {
                out.push('\\');
                out.push(c);
            }
            '%' => out.push_str("%%"),
            '$' => out.push_str("$$"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn unit_text(binary: &Path) -> String {
    format!(
        "[Unit]\n\
         Description=AppleSiliconThermals temperature fan curve\n\
         PartOf=graphical-session.target\n\
         \n\
         [Service]\n\
         Type=simple\n\
         ExecStart={} curve run\n\
         ExecStopPost={}\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         \n\
         [Install]\n\
         WantedBy=graphical-session.target\n",
        systemd_word(binary),
        RELEASE_ALL_FANS
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unit_quotes_the_binary_and_releases_without_it() {
        let unit = unit_text(Path::new("/home/u/my plugins/100%/$bin"));
        assert!(unit.contains("ExecStart=\"/home/u/my plugins/100%%/$$bin\" curve run\n"));
        assert!(unit.contains("ExecStopPost=/bin/sh -c 'for d in /sys/class/hwmon/hwmon*;"));
        assert!(unit.contains("\nWantedBy=graphical-session.target\n"));
    }
}
