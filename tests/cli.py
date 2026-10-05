"""CLI integration tests: synthetic hardware, systemctl and fan broker, no host fan writes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = Path(__file__).resolve().parents[1] / 'target/release/apple-silicon-thermals'


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ast-cli-')
        self.root = Path(self.tmp.name)
        self.hw = self.root / 'hwmon/hwmon7'
        attrs = {'name': 'macsmc_hwmon', 'fan1_min': '1199', 'fan1_max': '7199',
                 'fan1_target': '1799', 'fan1_input': '1800', 'fan2_min': '1199',
                 'fan2_max': '7199', 'fan2_target': '3000', 'fan2_input': '3000',
                 'temp3_label': 'Charge Regulator Temp', 'temp3_input': '33000'}
        for name, value in attrs.items():
            self.put(self.hw / name, value)
        self.put(self.root / 'sys/module/macsmc_hwmon/parameters/fan_control', 'Y')
        self.put(self.root / 'hwmon/hwmon0/name', 'other')
        self.put(self.root / 'hwmon/hwmon0/fan1_target', '123')
        self.stub = self.root / 'systemctl'
        self.put(self.stub, '#!/bin/sh\nprintf "%s\\n" "$*" >> "$AST_TEST_LOG"\n')
        self.stub.chmod(0o755)
        self.broker = self.root / 'broker'
        self.put(self.broker, '#!/bin/sh\n[ ! -e "$AST_TEST_BROKER_FAIL" ] || { echo denied >&2; exit 1; }\n'
                 'printf "%s\\n" "$1" >> "$AST_TEST_BROKER_LOG"\n'
                 'for t in "$AST_HWMON_ROOT"/hwmon7/fan*_target; do\n'
                 '  if [ "$1" = auto ]; then echo 0 > "$t"; else echo "$1" > "$t"; fi\n'
                 'done\n')
        self.broker.chmod(0o755)
        self.env = dict(os.environ, AST_BROKER=str(self.broker),
                        AST_TEST_BROKER_LOG=str(self.root / 'broker.log'),
                        AST_TEST_BROKER_FAIL=str(self.root / 'broker-fail'), AST_HWMON_ROOT=str(self.root / 'hwmon'),
                        AST_SYS_ROOT=str(self.root), AST_SYSTEMCTL=str(self.stub),
                        AST_TEST_LOG=str(self.root / 'systemctl.log'),
                        XDG_RUNTIME_DIR=str(self.root / 'runtime'),
                        XDG_CONFIG_HOME=str(self.root / 'config'))
        self.env.pop('SYSTEMD_EXEC_PID', None)

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def run_cli(self, *args, ok=True):
        result = subprocess.run([str(BIN), *args], env=self.env, text=True,
                                capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        return result

    def broker_calls(self):
        log = self.root / 'broker.log'
        return log.read_text().split() if log.exists() else []

    def test_manual_clamps_and_auto_releases_through_the_broker(self):
        self.run_cli('set', '1')
        self.assertEqual(self.broker_calls(), ['1199'])
        self.assertEqual((self.hw / 'fan1_target').read_text().strip(), '1199')
        self.assertEqual(json.loads(self.run_cli('get').stdout)['mode'], 'manual')
        self.run_cli('set', 'auto')
        self.assertEqual(self.broker_calls(), ['1199', 'auto'])
        self.assertEqual((self.root / 'hwmon/hwmon0/fan1_target').read_text(), '123')
        self.assertEqual(json.loads(self.run_cli('get').stdout)['mode'], 'auto')

    def test_broker_failure_fails_the_command_and_keeps_the_mode(self):
        self.put(self.root / 'broker-fail', '')
        self.run_cli('set', '4000', ok=False)
        self.assertEqual(json.loads(self.run_cli('get').stdout)['mode'], 'auto')

    def test_fans_with_different_limits_are_refused(self):
        self.put(self.hw / 'fan2_max', '6550')
        result = self.run_cli('set', '4000', ok=False)
        self.assertIn('different RPM limits', result.stderr)
        self.assertEqual(self.broker_calls(), [])

    def test_missing_broker_means_fan_control_is_not_enabled(self):
        self.assertTrue(json.loads(self.run_cli('get').stdout)['fan_control_enabled'])
        self.env['AST_BROKER'] = str(self.root / 'absent')
        self.assertFalse(json.loads(self.run_cli('get').stdout)['fan_control_enabled'])

    def test_config_unit_and_manual_stop(self):
        self.run_cli('curve', 'config', 'missing', '50', '75', ok=False)
        self.run_cli('curve', 'config', 'Charge Regulator Temp', '75', '50', ok=False)
        self.run_cli('curve', 'on')
        data = json.loads(self.run_cli('get').stdout)
        self.assertEqual(data['curve'], {'sensor': 'Charge Regulator Temp', 'low': 50, 'high': 75})
        unit = (self.root / 'config/systemd/user/applesiliconthermals-curve.service').read_text()
        self.assertIn('PartOf=graphical-session.target', unit)
        self.assertIn('ExecStopPost=/usr/bin/sudo -n /usr/local/libexec/apple-silicon-fan-control auto\n',
                      unit)
        self.run_cli('set', '4000')
        self.assertIn('--user disable --now applesiliconthermals-curve.service',
                      (self.root / 'systemctl.log').read_text())
        self.run_cli('curve', 'run', ok=False)


if __name__ == '__main__':
    unittest.main()
