"""CLI integration tests: synthetic hardware and systemctl, no host fan writes."""
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
                 'fan1_target': '1799', 'fan1_input': '1800', 'fan2_min': '2317',
                 'fan2_max': '6550', 'fan2_target': '3000', 'fan2_input': '3000',
                 'temp3_label': 'Charge Regulator Temp', 'temp3_input': '33000'}
        for name, value in attrs.items():
            self.put(self.hw / name, value)
        self.put(self.root / 'sys/module/macsmc_hwmon/parameters/fan_control', 'Y')
        self.put(self.root / 'hwmon/hwmon0/name', 'other')
        self.put(self.root / 'hwmon/hwmon0/fan1_target', '123')
        self.stub = self.root / 'systemctl'
        self.put(self.stub, '#!/bin/sh\nprintf "%s\\n" "$*" >> "$AST_TEST_LOG"\n')
        self.stub.chmod(0o755)
        self.env = dict(os.environ, AST_HWMON_ROOT=str(self.root / 'hwmon'),
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

    def test_manual_clamps_each_fan_and_auto_releases(self):
        self.run_cli('set', '1')
        self.assertEqual((self.hw / 'fan1_target').read_text(), '1199')
        self.assertEqual((self.hw / 'fan2_target').read_text(), '2317')
        self.assertEqual(json.loads(self.run_cli('get').stdout)['mode'], 'manual')
        self.run_cli('set', 'auto')
        self.assertEqual((self.hw / 'fan1_target').read_text(), '0')
        self.assertEqual((self.hw / 'fan2_target').read_text(), '0')
        self.assertEqual((self.root / 'hwmon/hwmon0/fan1_target').read_text(), '123')
        self.assertEqual(json.loads(self.run_cli('get').stdout)['mode'], 'auto')

    def test_config_unit_and_manual_stop(self):
        self.run_cli('curve', 'config', 'missing', '50', '75', ok=False)
        self.run_cli('curve', 'config', 'Charge Regulator Temp', '75', '50', ok=False)
        self.run_cli('curve', 'on')
        data = json.loads(self.run_cli('get').stdout)
        self.assertEqual(data['curve'], {'sensor': 'Charge Regulator Temp', 'low': 50, 'high': 75})
        unit = self.root / 'config/systemd/user/applesiliconthermals-curve.service'
        self.assertIn('PartOf=graphical-session.target', unit.read_text())
        self.assertIn('ExecStopPost=/bin/sh', unit.read_text())
        self.run_cli('set', '4000')
        self.assertIn('--user disable --now applesiliconthermals-curve.service',
                      (self.root / 'systemctl.log').read_text())
        self.run_cli('curve', 'run', ok=False)

    def test_release_continues_after_one_fan_fails(self):
        target = self.hw / 'fan1_target'
        target.unlink()
        target.mkdir()
        self.run_cli('set', 'auto', ok=False)
        self.assertEqual((self.hw / 'fan2_target').read_text(), '0')

    def test_generated_release_shell_uses_current_targets(self):
        self.run_cli('curve', 'on')
        unit = (self.root / 'config/systemd/user/applesiliconthermals-curve.service').read_text()
        line = next(line for line in unit.splitlines() if line.startswith('ExecStopPost='))
        command = line.split('=', 1)[1].replace('$$', '$').replace('%%', '%')
        command = command.replace('/sys/class/hwmon', str(self.root / 'hwmon'))
        result = subprocess.run(command, shell=True, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.hw / 'fan1_target').read_text(), '0\n')
        self.assertEqual((self.hw / 'fan2_target').read_text(), '0\n')
        self.assertEqual((self.root / 'hwmon/hwmon0/fan1_target').read_text(), '123')


if __name__ == '__main__':
    unittest.main()
