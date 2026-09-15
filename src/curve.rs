pub const MIN_CELSIUS: i64 = 20;
pub const MAX_CELSIUS: i64 = 100;
const SNAP_RPM: u32 = 50;
const MAX_DECREASE_PER_TICK: u32 = 300;
const MISMATCHES_BEFORE_OVERRIDE: u32 = 3;
const OVERRIDE_RETRY_TICKS: u32 = 30;

#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub sensor: String,
    pub low: i64,
    pub high: i64,
}

impl Config {
    pub fn parse(text: &str) -> Result<Self, String> {
        let mut sensor = None;
        let mut low = None;
        let mut high = None;
        for line in text.lines().filter(|line| !line.trim().is_empty()) {
            let (key, value) = line
                .split_once('=')
                .ok_or_else(|| format!("malformed line: {line:?}"))?;
            let duplicate = match key {
                "SENSOR" => sensor.replace(value.to_string()).is_some(),
                "LOW" => low.replace(parse_celsius(value)?).is_some(),
                "HIGH" => high.replace(parse_celsius(value)?).is_some(),
                _ => return Err(format!("unknown key: {key:?}")),
            };
            if duplicate {
                return Err(format!("duplicate key: {key}"));
            }
        }
        let config = Self {
            sensor: sensor.ok_or("missing SENSOR")?,
            low: low.ok_or("missing LOW")?,
            high: high.ok_or("missing HIGH")?,
        };
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.sensor.is_empty() || self.sensor.contains('\n') {
            return Err("the sensor must be a non-empty single line".into());
        }
        if ![self.low, self.high]
            .iter()
            .all(|value| (MIN_CELSIUS..=MAX_CELSIUS).contains(value))
        {
            return Err(format!(
                "temperatures must be within {MIN_CELSIUS}..={MAX_CELSIUS} C"
            ));
        }
        if self.low >= self.high {
            return Err("the low temperature must be below the high temperature".into());
        }
        Ok(())
    }

    pub fn render(&self) -> String {
        format!(
            "SENSOR={}\nLOW={}\nHIGH={}\n",
            self.sensor, self.low, self.high
        )
    }
}

pub fn parse_celsius(value: &str) -> Result<i64, String> {
    value
        .parse()
        .map_err(|_| format!("not a whole number of degrees: {value:?}"))
}

/// Readings outside this range come from a broken or disconnected sensor.
pub fn valid_reading(millidegrees: i64) -> bool {
    millidegrees > 0 && millidegrees < 130_000
}

fn desired_rpm(millidegrees: i64, config: &Config, min: u32, max: u32) -> u32 {
    let low = config.low * 1000;
    let high = config.high * 1000;
    if millidegrees <= low {
        return min;
    }
    if millidegrees >= high {
        return max;
    }
    let span = u64::from(max - min);
    min + (span * (millidegrees - low) as u64 / (high - low) as u64) as u32
}

/// Snap to 50 RPM steps counted from min, so max itself is never rounded past.
fn snap(rpm: u32, min: u32, max: u32) -> u32 {
    let rpm = rpm.clamp(min, max);
    (min + (rpm - min + SNAP_RPM / 2) / SNAP_RPM * SNAP_RPM).min(max)
}

/// Increases apply at once; decreases are limited per tick so the fan does not hunt.
fn next_target(millidegrees: i64, config: &Config, min: u32, max: u32, previous: u32) -> u32 {
    let desired = desired_rpm(millidegrees, config, min, max);
    snap(
        desired.max(previous.saturating_sub(MAX_DECREASE_PER_TICK)),
        min,
        max,
    )
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum State {
    Running,
    Released,
    FirmwareOverride,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Running => "running",
            State::Released => "released",
            State::FirmwareOverride => "firmware-override",
        }
    }
}

struct FanState {
    min: u32,
    max: u32,
    previous: u32,
    last_write: Option<u32>,
}

pub struct Tick {
    /// Values to write to each fan's target, in order.
    pub writes: Vec<Vec<u32>>,
    pub state: State,
}

pub struct Controller {
    fans: Vec<FanState>,
    state: State,
    mismatches: u32,
    retry_in: u32,
}

impl Controller {
    /// `limits` holds each fan's (min, max). Fans start under firmware control.
    pub fn new(limits: &[(u32, u32)]) -> Self {
        Self {
            fans: limits
                .iter()
                .map(|&(min, max)| FanState {
                    min,
                    max,
                    previous: max,
                    last_write: None,
                })
                .collect(),
            state: State::Running,
            mismatches: 0,
            retry_in: 0,
        }
    }

    /// `input` is the tracked temperature when both config and sensor are usable. `readbacks` and
    /// `speeds` hold each fan's current target and measured RPM as read from sysfs.
    pub fn tick(
        &mut self,
        input: Option<(i64, &Config)>,
        readbacks: &[Option<u32>],
        speeds: &[Option<u32>],
    ) -> Tick {
        let writes = match input {
            None if self.state == State::Running => {
                self.state = State::Released;
                self.release(readbacks)
            }
            None => self.idle(),
            Some(_) if self.state == State::FirmwareOverride && self.retry_in > 0 => {
                self.retry_in -= 1;
                self.idle()
            }
            Some((millidegrees, config)) => self.follow(millidegrees, config, readbacks, speeds),
        };
        Tick {
            writes,
            state: self.state,
        }
    }

    pub fn target(&self, fan: usize) -> Option<u32> {
        self.fans.get(fan).and_then(|fan| fan.last_write)
    }

    fn follow(
        &mut self,
        millidegrees: i64,
        config: &Config,
        readbacks: &[Option<u32>],
        speeds: &[Option<u32>],
    ) -> Vec<Vec<u32>> {
        let rewritten = |fan: &FanState, readback: &Option<u32>| matches!((fan.last_write, readback), (Some(written), Some(read)) if written != *read);
        if self
            .fans
            .iter()
            .zip(readbacks)
            .any(|(fan, readback)| rewritten(fan, readback))
        {
            // The SMC stores these integers exactly, so a different read-back means firmware
            // rewrote the target: after resume, or its own thermal protection. Re-assert briefly,
            // then stop fighting it.
            self.mismatches += 1;
            if self.mismatches >= MISMATCHES_BEFORE_OVERRIDE {
                self.state = State::FirmwareOverride;
                self.retry_in = OVERRIDE_RETRY_TICKS;
                return self.release(readbacks);
            }
        } else {
            self.mismatches = 0;
        }

        self.state = State::Running;
        let mut writes = Vec::with_capacity(self.fans.len());
        for ((fan, readback), speed) in self.fans.iter_mut().zip(readbacks).zip(speeds) {
            let mut fan_writes = Vec::with_capacity(2);
            // Taking over from firmware starts at the speed the fan is actually turning at, so the
            // fan neither surges to max nor drops faster than the decrease limit.
            if let (None, Some(speed)) = (fan.last_write, *speed) {
                fan.previous = speed.clamp(fan.min, fan.max);
            }
            if rewritten(fan, readback) {
                if let Some(read) = *readback {
                    fan.previous = read.clamp(fan.min, fan.max);
                }
                // Resets the driver's cached manual flag so the next write re-enters manual mode.
                fan_writes.push(0);
            }
            let target = next_target(millidegrees, config, fan.min, fan.max, fan.previous);
            fan_writes.push(target);
            fan.previous = target;
            fan.last_write = Some(target);
            writes.push(fan_writes);
        }
        writes
    }

    fn release(&mut self, readbacks: &[Option<u32>]) -> Vec<Vec<u32>> {
        self.mismatches = 0;
        self.fans
            .iter_mut()
            .enumerate()
            .map(|(index, fan)| {
                // Rewriting the current target before 0 forces the mode-key write without spinning
                // the fan up on the way out.
                let current = readbacks
                    .get(index)
                    .copied()
                    .flatten()
                    .map_or(fan.max, |rpm| rpm.clamp(fan.min, fan.max));
                fan.previous = fan.max;
                fan.last_write = None;
                vec![current, 0]
            })
            .collect()
    }

    fn idle(&self) -> Vec<Vec<u32>> {
        vec![Vec::new(); self.fans.len()]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // fan1_min/fan1_max of a 13-inch M1 MacBook Pro and a 14-inch MacBook Pro.
    const GEOMETRIES: [(u32, u32); 2] = [(1199, 7199), (2317, 6550)];

    fn config() -> Config {
        Config {
            sensor: "Charge Regulator Temp".into(),
            low: 50,
            high: 75,
        }
    }

    #[test]
    fn parses_what_it_renders() {
        assert_eq!(Config::parse(&config().render()), Ok(config()));
    }

    #[test]
    fn rejects_malformed_configs() {
        for text in [
            "SENSOR=a\nLOW=50\nHIGH=75\nEXTRA=1\n",
            "SENSOR=a\nSENSOR=b\nLOW=50\nHIGH=75\n",
            "SENSOR=a\nLOW=10\nHIGH=75\n",
            "SENSOR=a\nLOW=75\nHIGH=50\n",
            "SENSOR=a\nLOW=5O\nHIGH=75\n",
            "LOW=50\nHIGH=75\n",
            "SENSOR=\nLOW=50\nHIGH=75\n",
            "SENSOR=a\nLOW=50\nHIGH=75\n$(reboot)\n",
        ] {
            assert!(Config::parse(text).is_err(), "{text:?}");
        }
    }

    #[test]
    fn maps_temperature_linearly_between_thresholds() {
        assert_eq!(desired_rpm(40_000, &config(), 1199, 7199), 1199);
        assert_eq!(desired_rpm(62_500, &config(), 1199, 7199), 4199);
        assert_eq!(desired_rpm(80_000, &config(), 1199, 7199), 7199);
    }

    #[test]
    fn every_target_is_one_the_kernel_accepts() {
        for (min, max) in GEOMETRIES {
            for previous in [min, (min + max) / 2, max] {
                for millidegrees in (-10_000..140_000).step_by(250) {
                    let rpm = next_target(millidegrees, &config(), min, max, previous);
                    assert!((min..=max).contains(&rpm), "{millidegrees} gave {rpm}");
                }
            }
            for rpm in 0..=max + 100 {
                let snapped = snap(rpm, min, max);
                assert!((min..=max).contains(&snapped));
                assert!(snapped == max || (snapped - min).is_multiple_of(SNAP_RPM));
            }
        }
    }

    #[test]
    fn limits_decreases_but_not_increases() {
        assert_eq!(next_target(40_000, &config(), 1199, 7199, 7199), 6899);
        assert_eq!(next_target(80_000, &config(), 1199, 7199, 1199), 7199);
    }

    #[test]
    fn unusable_input_releases_once_and_resumes() {
        let mut controller = Controller::new(&[(1199, 7199)]);
        let cfg = config();

        let tick = controller.tick(None, &[Some(7199)], &[None]);
        assert_eq!(tick.writes, vec![vec![7199, 0]]);

        let tick = controller.tick(Some((80_000, &cfg)), &[Some(7199)], &[None]);
        assert_eq!(
            (tick.writes, tick.state),
            (vec![vec![7199]], State::Running)
        );

        let tick = controller.tick(None, &[Some(7199)], &[None]);
        assert_eq!(
            (tick.writes, tick.state),
            (vec![vec![7199, 0]], State::Released)
        );
        let tick = controller.tick(None, &[Some(7199)], &[None]);
        assert_eq!(tick.writes, vec![Vec::<u32>::new()]);

        let tick = controller.tick(Some((40_000, &cfg)), &[Some(7000)], &[None]);
        assert_eq!(
            (tick.writes, tick.state),
            (vec![vec![6899]], State::Running)
        );
    }

    #[test]
    fn takes_over_from_the_speed_the_fan_is_turning_at() {
        let cfg = config();

        // Firmware had the fan stopped while cool: go to minimum at once, no surge.
        let mut controller = Controller::new(&[(1199, 7199)]);
        let tick = controller.tick(Some((40_000, &cfg)), &[Some(0)], &[Some(0)]);
        assert_eq!(tick.writes, vec![vec![1199]]);

        // A fast fan still slows at the decrease limit.
        let mut controller = Controller::new(&[(1199, 7199)]);
        let tick = controller.tick(Some((40_000, &cfg)), &[Some(7199)], &[Some(5000)]);
        assert_eq!(tick.writes, vec![vec![4699]]);

        // A hot reading overrides a slow fan immediately.
        let mut controller = Controller::new(&[(1199, 7199)]);
        let tick = controller.tick(Some((80_000, &cfg)), &[Some(0)], &[Some(0)]);
        assert_eq!(tick.writes, vec![vec![7199]]);
    }

    #[test]
    fn a_firmware_rewrite_is_reasserted_from_the_firmware_value() {
        let mut controller = Controller::new(&[(1199, 7199)]);
        let cfg = config();
        let cool = Some((40_000, &cfg));
        assert_eq!(
            controller.tick(cool, &[None], &[None]).writes,
            vec![vec![6899]]
        );
        assert_eq!(
            controller.tick(cool, &[Some(6899)], &[None]).writes,
            vec![vec![6599]]
        );
        assert_eq!(
            controller.tick(cool, &[Some(5000)], &[None]).writes,
            vec![vec![0, 4699]]
        );
        assert_eq!(
            controller.tick(cool, &[Some(4699)], &[None]).writes,
            vec![vec![4399]]
        );
    }

    #[test]
    fn persistent_rewrites_hand_control_to_firmware_then_retry() {
        let mut controller = Controller::new(&[(1199, 7199)]);
        let cfg = config();
        let hot = Some((80_000, &cfg));
        controller.tick(hot, &[None], &[None]);

        assert_eq!(
            controller.tick(hot, &[Some(3000)], &[None]).writes,
            vec![vec![0, 7199]]
        );
        assert_eq!(
            controller.tick(hot, &[Some(3000)], &[None]).writes,
            vec![vec![0, 7199]]
        );
        let tick = controller.tick(hot, &[Some(3000)], &[None]);
        assert_eq!(
            (tick.writes, tick.state),
            (vec![vec![3000, 0]], State::FirmwareOverride)
        );

        for _ in 0..OVERRIDE_RETRY_TICKS {
            let tick = controller.tick(hot, &[Some(3000)], &[None]);
            assert_eq!(
                (tick.writes, tick.state),
                (vec![vec![]], State::FirmwareOverride)
            );
        }
        let tick = controller.tick(hot, &[Some(3000)], &[None]);
        assert_eq!(
            (tick.writes, tick.state),
            (vec![vec![7199]], State::Running)
        );
    }

    #[test]
    fn only_the_rewritten_fan_is_reset() {
        let mut controller = Controller::new(&[(1199, 7199), (2317, 6550)]);
        let cfg = config();
        let hot = Some((80_000, &cfg));
        controller.tick(hot, &[None, None], &[None, None]);
        assert_eq!(
            controller
                .tick(hot, &[Some(7199), Some(2317)], &[None, None])
                .writes,
            vec![vec![7199], vec![0, 6550]]
        );
    }
}
