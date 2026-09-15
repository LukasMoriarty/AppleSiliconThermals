mod curve;
mod hwmon;
mod json;
mod state;

use std::io;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::thread::sleep;
use std::time::Duration;

use curve::{Config, Controller};
use hwmon::{Fan, Paths};
use json::Object;

type Result<T = ()> = std::result::Result<T, String>;

const TICK: Duration = Duration::from_secs(2);
const STATUS_MAX_AGE_SECS: u64 = 6;
const DEFAULT_SENSOR: &str = "Charge Regulator Temp";
const DEFAULT_LOW: i64 = 50;
const DEFAULT_HIGH: i64 = 75;
const USAGE: &str = "usage: apple-silicon-thermals get | set <rpm|auto> | \
                     curve config <sensor> <low-C> <high-C> | curve on | curve off";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let paths = Paths::from_env();
    let result = match args.as_slice() {
        [] | ["get"] => get(&paths),
        ["set", target] => set(&paths, target),
        ["curve", "config", sensor, low, high] => curve_config(&paths, sensor, low, high),
        ["curve", "on"] => curve_on(&paths),
        ["curve", "off"] => curve_off(),
        ["curve", "run"] => curve_run(&paths),
        _ => Err(USAGE.to_string()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("apple-silicon-thermals: {message}");
            ExitCode::FAILURE
        }
    }
}

fn text(err: impl std::fmt::Display) -> String {
    err.to_string()
}

fn is_apple_silicon(paths: &Paths, has_macsmc: bool) -> bool {
    has_macsmc
        || std::fs::read(paths.device_tree("compatible"))
            .is_ok_and(|raw| raw.windows(6).any(|window| window == b"apple,"))
        || hwmon::read_text(&paths.device_tree("model"))
            .is_ok_and(|model| model.starts_with("Apple"))
}

fn macsmc_fans(paths: &Paths) -> Result<(PathBuf, Vec<Fan>)> {
    let dir = hwmon::find_macsmc(paths)
        .map_err(text)?
        .ok_or("the macsmc_hwmon driver was not found")?;
    let fans = hwmon::fans(&dir).map_err(text)?;
    Ok((dir, fans))
}

fn controllable_fans(paths: &Paths) -> Result<(PathBuf, Vec<Fan>)> {
    let (dir, fans) = macsmc_fans(paths)?;
    if fans.is_empty() {
        return Err("no controllable fans (fanless or unsupported Mac)".into());
    }
    Ok((dir, fans))
}

fn get(paths: &Paths) -> Result {
    let version = env!("CARGO_PKG_VERSION");
    let dir = hwmon::find_macsmc(paths).map_err(text)?;
    if !is_apple_silicon(paths, dir.is_some()) {
        let out = Object::default()
            .raw("is_apple_silicon", false)
            .raw("has_fan", false)
            .raw("fan_count", 0)
            .str("error", "unsupported_hardware")
            .str("device_model", "Non-Apple Hardware")
            .str("version", version);
        println!("{out}");
        return Ok(());
    }
    let model = hwmon::read_text(&paths.device_tree("model"))
        .unwrap_or_else(|_| "Apple Silicon Mac".to_string());
    let Some(dir) = dir else {
        let out = Object::default()
            .raw("is_apple_silicon", true)
            .raw("has_fan", false)
            .raw("fan_count", 0)
            .str("error", "macsmc_hwmon_missing")
            .str("device_model", &model)
            .str("version", version);
        println!("{out}");
        return Ok(());
    };

    let fans = hwmon::fans(&dir).map_err(text)?;
    let temps = hwmon::readings(&dir, "temp").map_err(text)?;
    let power = hwmon::readings(&dir, "power").map_err(text)?;
    let status = state::read_status(STATUS_MAX_AGE_SECS);
    let mode = match &status {
        Some(_) => "curve",
        None if state::is_manual() => "manual",
        None => "auto",
    };

    let fan = fans.first();
    let rpm = |read: fn(&Fan) -> io::Result<u32>| fan.and_then(|fan| read(fan).ok()).unwrap_or(0);
    let labelled = |needle: &str| {
        temps
            .iter()
            .find(|reading| reading.label.contains(needle))
            .map_or_else(|| "0".to_string(), |reading| json::celsius(reading.value))
    };
    let null = || "null".to_string();

    let sensors = Object::default()
        .raw("nand", labelled("NAND"))
        .raw("battery", labelled("Battery"))
        .raw("regulator", labelled("Regulator"))
        .raw("wifi", labelled("WiFi"));
    let temps_json = json::array(temps.iter().map(|reading| {
        Object::default()
            .str("label", &reading.label)
            .raw("celsius", json::celsius(reading.value))
            .to_string()
    }));
    let curve = std::fs::read_to_string(state::config_path().map_err(text)?)
        .ok()
        .and_then(|contents| Config::parse(&contents).ok())
        .map_or_else(null, |config| {
            Object::default()
                .str("sensor", &config.sensor)
                .raw("low", config.low)
                .raw("high", config.high)
                .to_string()
        });
    let curve_status = status.map_or_else(null, |status| {
        Object::default()
            .str("state", &status.state)
            .raw(
                "celsius",
                status.millidegrees.map_or_else(null, json::celsius),
            )
            .raw(
                "target",
                status.target.map_or_else(null, |target| target.to_string()),
            )
            .raw("age_s", status.age_secs)
            .to_string()
    });
    let max_temp = temps
        .iter()
        .map(|reading| reading.value)
        .max()
        .map_or_else(|| "0".to_string(), json::celsius);
    let power_watts = power.first().map_or_else(
        || "0".to_string(),
        |reading| format!("{:.2}", reading.value as f64 / 1_000_000.0),
    );

    let out = Object::default()
        .raw("is_apple_silicon", true)
        .raw("has_fan", !fans.is_empty())
        .raw("fan_count", fans.len())
        .raw("fan_rpm", rpm(Fan::input))
        .raw("fan_min", fan.map_or(0, |fan| fan.min))
        .raw("fan_max", fan.map_or(0, |fan| fan.max))
        .raw("fan_target", rpm(Fan::target))
        .raw("fan_control_enabled", paths.fan_control_enabled())
        .str("mode", mode)
        .raw("manual_mode", mode == "manual")
        .raw("max_temp", max_temp)
        .raw("power_watts", power_watts)
        .str("device_model", &model)
        .raw("sensors", sensors)
        .raw("temps", temps_json)
        .raw("curve", curve)
        .raw("curve_status", curve_status)
        .str("version", version);
    println!("{out}");
    Ok(())
}

/// Stop and disable the curve; the unit's ExecStopPost returns the fans to the SMC.
fn stop_curve() -> Result {
    if state::unit_path().map_err(text)?.exists() {
        state::systemctl(&["disable", "--now", state::UNIT])?;
    }
    state::clear_status().map_err(text)
}

fn set(paths: &Paths, target: &str) -> Result {
    let rpm = match target {
        "auto" | "0" => None,
        value => Some(
            value
                .parse::<u32>()
                .map_err(|_| format!("invalid target {value:?}: use an RPM or auto"))?,
        ),
    };
    let _lock = state::lock().map_err(text)?;
    stop_curve()?;
    let (_, fans) = controllable_fans(paths)?;
    let mut errors = Vec::new();
    for fan in &fans {
        let result = match rpm {
            None => fan.release(),
            Some(rpm) => fan.write_target(fan.clamp(rpm)),
        };
        if let Err(err) = result {
            errors.push(format!("fan{}: {err}", fan.index));
        }
    }
    if !errors.is_empty() {
        return Err(errors.join("; "));
    }
    state::set_manual(rpm.is_some()).map_err(text)?;
    match rpm {
        None => println!("Fan control reset to automatic SMC mode"),
        Some(rpm) => println!(
            "Fan speed set to {} RPM across {} fan(s)",
            fans[0].clamp(rpm),
            fans.len()
        ),
    }
    Ok(())
}

fn require_sensor(dir: &Path, label: &str) -> Result {
    let temps = hwmon::readings(dir, "temp").map_err(text)?;
    if temps.iter().any(|reading| reading.label == label) {
        Ok(())
    } else {
        Err(format!("no temperature sensor labelled {label:?}"))
    }
}

fn curve_config(paths: &Paths, sensor: &str, low: &str, high: &str) -> Result {
    let config = Config {
        sensor: sensor.to_string(),
        low: curve::parse_celsius(low)?,
        high: curve::parse_celsius(high)?,
    };
    config.validate()?;
    let (dir, _) = macsmc_fans(paths)?;
    require_sensor(&dir, &config.sensor)?;
    let _lock = state::lock().map_err(text)?;
    state::write_atomic(&state::config_path().map_err(text)?, &config.render()).map_err(text)
}

fn default_config(dir: &Path) -> Result<Config> {
    let temps = hwmon::readings(dir, "temp").map_err(text)?;
    let sensor = temps
        .iter()
        .find(|reading| reading.label == DEFAULT_SENSOR)
        .or(temps.first())
        .ok_or("no labelled temperature sensors")?;
    Ok(Config {
        sensor: sensor.label.clone(),
        low: DEFAULT_LOW,
        high: DEFAULT_HIGH,
    })
}

fn curve_on(paths: &Paths) -> Result {
    let _lock = state::lock().map_err(text)?;
    if !paths.fan_control_enabled() {
        return Err("fan control is disabled in the kernel; run setup.sh first".into());
    }
    let (dir, _) = controllable_fans(paths)?;
    let config_path = state::config_path().map_err(text)?;
    let config = match std::fs::read_to_string(&config_path) {
        Ok(contents) => Config::parse(&contents)?,
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            let config = default_config(&dir)?;
            state::write_atomic(&config_path, &config.render()).map_err(text)?;
            config
        }
        Err(err) => return Err(text(err)),
    };
    require_sensor(&dir, &config.sensor)?;

    let binary = std::env::current_exe()
        .and_then(|path| path.canonicalize())
        .map_err(text)?;
    state::write_atomic(
        &state::unit_path().map_err(text)?,
        &state::unit_text(&binary),
    )
    .map_err(text)?;
    state::systemctl(&["daemon-reload"])?;
    state::systemctl(&["enable", "--now", state::UNIT])?;
    state::set_manual(false).map_err(text)?;
    println!(
        "Temperature curve on: {} {}-{} C",
        config.sensor, config.low, config.high
    );
    Ok(())
}

fn curve_off() -> Result {
    let _lock = state::lock().map_err(text)?;
    stop_curve()?;
    println!("Temperature curve off; fans returned to automatic SMC mode");
    Ok(())
}

fn sensor_millidegrees(dir: &Path, label: &str) -> Option<i64> {
    hwmon::readings(dir, "temp")
        .ok()?
        .into_iter()
        .find(|reading| reading.label == label)
        .map(|reading| reading.value)
}

fn curve_run(paths: &Paths) -> Result {
    // Only systemd guarantees the unit's ExecStopPost release; a manual run killed with Ctrl-C
    // would leave the fans on their last target. SYSTEMD_EXEC_PID names the exact process systemd
    // started, unlike INVOCATION_ID, which every process in the desktop session inherits.
    let started_by_systemd =
        std::env::var("SYSTEMD_EXEC_PID").is_ok_and(|pid| pid == std::process::id().to_string());
    if !started_by_systemd {
        return Err(format!(
            "`curve run` only runs inside {}; use `curve on`",
            state::UNIT
        ));
    }
    let binary = std::env::current_exe().map_err(text)?;
    let (dir, fans) = controllable_fans(paths)?;
    let config_path = state::config_path().map_err(text)?;
    let limits: Vec<(u32, u32)> = fans.iter().map(|fan| (fan.min, fan.max)).collect();
    let mut controller = Controller::new(&limits);

    loop {
        if !binary.exists() {
            for fan in &fans {
                if let Err(err) = fan.release() {
                    eprintln!("fan{}: release: {err}", fan.index);
                }
            }
            return Ok(());
        }

        let config = std::fs::read_to_string(&config_path)
            .ok()
            .and_then(|contents| Config::parse(&contents).ok());
        let reading = config
            .as_ref()
            .and_then(|config| sensor_millidegrees(&dir, &config.sensor))
            .filter(|&value| curve::valid_reading(value));
        let input = config
            .as_ref()
            .zip(reading)
            .map(|(config, value)| (value, config));
        let readbacks: Vec<Option<u32>> = fans.iter().map(|fan| fan.target().ok()).collect();
        let speeds: Vec<Option<u32>> = fans.iter().map(|fan| fan.input().ok()).collect();

        let tick = controller.tick(input, &readbacks, &speeds);
        for (fan, writes) in fans.iter().zip(&tick.writes) {
            for &rpm in writes {
                if let Err(err) = fan.write_target(rpm) {
                    // A failed write invalidates the controller's assumed target. Exiting makes
                    // systemd release every fan before restarting the controller.
                    return Err(format!("fan{}: writing {rpm}: {err}", fan.index));
                }
            }
        }
        if let Err(err) = state::write_status(tick.state.as_str(), reading, controller.target(0)) {
            eprintln!("status: {err}");
        }
        sleep(TICK);
    }
}
