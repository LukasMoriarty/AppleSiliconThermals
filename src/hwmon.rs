use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub struct Paths {
    pub hwmon_root: PathBuf,
    pub sys_root: PathBuf,
}

impl Paths {
    pub fn from_env() -> Self {
        let var = |name: &str, default: &str| {
            std::env::var_os(name).map_or_else(|| PathBuf::from(default), PathBuf::from)
        };
        Self {
            hwmon_root: var("AST_HWMON_ROOT", "/sys/class/hwmon"),
            sys_root: var("AST_SYS_ROOT", "/"),
        }
    }

    pub fn fan_control_enabled(&self) -> bool {
        read_text(
            &self
                .sys_root
                .join("sys/module/macsmc_hwmon/parameters/fan_control"),
        )
        .is_ok_and(|value| value == "Y" || value == "1")
    }

    pub fn device_tree(&self, node: &str) -> PathBuf {
        self.sys_root.join("proc/device-tree").join(node)
    }
}

pub fn read_text(path: &Path) -> io::Result<String> {
    let raw = fs::read(path)?;
    Ok(String::from_utf8_lossy(&raw)
        .trim_matches(|c: char| c == '\0' || c.is_whitespace())
        .to_string())
}

fn invalid(path: &Path, detail: impl std::fmt::Display) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("{}: {detail}", path.display()),
    )
}

fn read_number(path: &Path) -> io::Result<i64> {
    read_text(path)?.parse().map_err(|err| invalid(path, err))
}

fn read_rpm(path: &Path) -> io::Result<u32> {
    u32::try_from(read_number(path)?).map_err(|err| invalid(path, err))
}

pub fn find_macsmc(paths: &Paths) -> io::Result<Option<PathBuf>> {
    let entries = match fs::read_dir(&paths.hwmon_root) {
        Ok(entries) => entries,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err),
    };
    let mut dirs: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .collect();
    dirs.sort();
    Ok(dirs
        .into_iter()
        .find(|dir| read_text(&dir.join("name")).is_ok_and(|name| name == "macsmc_hwmon")))
}

/// Indices of attributes named `<prefix><N><suffix>`, ascending. Labels are not always contiguous.
fn indices(dir: &Path, prefix: &str, suffix: &str) -> io::Result<Vec<u32>> {
    let mut found: Vec<u32> = fs::read_dir(dir)?
        .filter_map(|entry| {
            let name = entry.ok()?.file_name().into_string().ok()?;
            name.strip_prefix(prefix)?
                .strip_suffix(suffix)?
                .parse()
                .ok()
        })
        .collect();
    found.sort_unstable();
    Ok(found)
}

pub struct Fan {
    pub index: u32,
    pub min: u32,
    pub max: u32,
    dir: PathBuf,
}

impl Fan {
    fn attr(&self, name: &str) -> PathBuf {
        self.dir.join(format!("fan{}_{name}", self.index))
    }

    pub fn input(&self) -> io::Result<u32> {
        read_rpm(&self.attr("input"))
    }

    pub fn target(&self) -> io::Result<u32> {
        read_rpm(&self.attr("target"))
    }

    pub fn write_target(&self, rpm: u32) -> io::Result<()> {
        fs::write(self.attr("target"), rpm.to_string())
    }

    /// Hand the fan back to the SMC. Writing a valid target first makes the driver rewrite the SMC
    /// mode key even when its cached manual flag is stale (after resume or a warm reboot), so the 0
    /// takes effect. Reusing the current target avoids spinning the fan up on the way out.
    pub fn release(&self) -> io::Result<()> {
        self.write_target(self.release_rpm())?;
        self.write_target(0)
    }

    fn release_rpm(&self) -> u32 {
        self.target().map_or(self.max, |target| self.clamp(target))
    }

    pub fn clamp(&self, rpm: u32) -> u32 {
        rpm.clamp(self.min, self.max)
    }
}

/// Fans that expose a target. A minimum of 0 would make the release value a manual stop.
pub fn fans(dir: &Path) -> io::Result<Vec<Fan>> {
    indices(dir, "fan", "_target")?
        .into_iter()
        .map(|index| {
            let min = read_rpm(&dir.join(format!("fan{index}_min")))?;
            let max = read_rpm(&dir.join(format!("fan{index}_max")))?;
            if min == 0 || min > max {
                return Err(invalid(
                    &dir.join(format!("fan{index}_min")),
                    format!("invalid speed range {min}..{max}"),
                ));
            }
            Ok(Fan {
                index,
                min,
                max,
                dir: dir.to_path_buf(),
            })
        })
        .collect()
}

pub struct Reading {
    pub label: String,
    /// Raw hwmon units: millidegrees Celsius for temps, microwatts for power.
    pub value: i64,
}

/// Every labelled `<kind>N` attribute whose input is readable.
pub fn readings(dir: &Path, kind: &str) -> io::Result<Vec<Reading>> {
    Ok(indices(dir, kind, "_label")?
        .into_iter()
        .filter_map(|index| {
            let label = read_text(&dir.join(format!("{kind}{index}_label"))).ok()?;
            let value = read_number(&dir.join(format!("{kind}{index}_input"))).ok()?;
            Some(Reading { label, value })
        })
        .collect())
}

#[cfg(test)]
pub mod tests {
    use super::*;

    pub fn fake_tree(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("ast-test-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let files = [
            ("hwmon0/name", "other\n"),
            ("hwmon0/fan1_target", "5\n"),
            ("hwmon0/fan1_min", "1\n"),
            ("hwmon0/fan1_max", "9\n"),
            ("hwmon3/name", "macsmc_hwmon\n"),
            ("hwmon3/fan1_input", "7202\n"),
            ("hwmon3/fan1_target", "7199\n"),
            ("hwmon3/fan1_min", "1199\n"),
            ("hwmon3/fan1_max", "7199\n"),
            ("hwmon3/temp1_label", "NAND Flash Temperature\n"),
            ("hwmon3/temp1_input", "44864\n"),
            ("hwmon3/temp3_label", "Charge Regulator Temp\n"),
            ("hwmon3/temp3_input", "46093\n"),
            ("hwmon3/temp4_label", "Unreadable\n"),
            ("hwmon3/power1_label", "Total System Power\n"),
            ("hwmon3/power1_input", "16615781\n"),
        ];
        for (path, contents) in files {
            let path = root.join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, contents).unwrap();
        }
        root
    }

    #[test]
    fn reads_the_macsmc_device_by_name() {
        let root = fake_tree("read");
        let paths = Paths {
            hwmon_root: root.clone(),
            sys_root: root.clone(),
        };
        let dir = find_macsmc(&paths).unwrap().unwrap();
        assert!(dir.ends_with("hwmon3"));

        let fans = fans(&dir).unwrap();
        assert_eq!(fans.len(), 1);
        assert_eq!((fans[0].min, fans[0].max), (1199, 7199));
        assert_eq!(fans[0].input().unwrap(), 7202);
        assert_eq!(fans[0].clamp(100), 1199);

        let temps = readings(&dir, "temp").unwrap();
        let labels: Vec<&str> = temps.iter().map(|r| r.label.as_str()).collect();
        assert_eq!(labels, ["NAND Flash Temperature", "Charge Regulator Temp"]);

        fans[0].release().unwrap();
        assert_eq!(fans[0].target().unwrap(), 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn release_rewrites_the_current_target_before_handing_back() {
        let root = fake_tree("release");
        let dir = root.join("hwmon3");
        let fans = fans(&dir).unwrap();
        for (current, expected) in [
            ("3000\n", 3000),
            ("0\n", 1199),
            ("9000\n", 7199),
            ("junk\n", 7199),
        ] {
            fs::write(dir.join("fan1_target"), current).unwrap();
            assert_eq!(fans[0].release_rpm(), expected, "target {current:?}");
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rejects_a_fan_without_a_usable_range() {
        let root = fake_tree("range");
        fs::write(root.join("hwmon3/fan1_min"), "0\n").unwrap();
        assert!(fans(&root.join("hwmon3")).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_hwmon_root_means_no_device() {
        let paths = Paths {
            hwmon_root: PathBuf::from("/nonexistent/ast-hwmon"),
            sys_root: PathBuf::from("/nonexistent"),
        };
        assert!(find_macsmc(&paths).unwrap().is_none());
        assert!(!paths.fan_control_enabled());
    }
}
