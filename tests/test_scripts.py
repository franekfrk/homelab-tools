#!/usr/bin/env python3
"""Integration checks with fake system commands; no network or shutdown."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class Scripts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.log = self.base / 'calls'
        self.payload = self.base / 'payload'
        self.conf = self.base / 'config'
        self.thermal = self.base / 'thermal' / 'thermal_zone0'
        self.thermal.mkdir(parents=True)
        (self.thermal / 'temp').write_text('40000')
        self.battery = self.base / 'power' / 'BAT1'
        self.battery.mkdir(parents=True)
        (self.battery / 'capacity').write_text('24')
        (self.battery / 'status').write_text('Discharging')
        self.conf.write_text(f'''WEBHOOK_URL="https://invalid.example/webhook"
STATE_DIR="{self.base}/state"
THERMAL_ROOT="{self.base}/thermal"
POWER_SUPPLY_ROOT="{self.base}/power"
SMART_DEVICES=(/dev/test)
''')
        self.env = dict(os.environ, HOMELAB_CONFIG=str(self.conf),
                        PATH=f'{self.bin}:' + os.environ['PATH'],
                        CALLS=str(self.log), PAYLOAD_FILE=str(self.payload),
                        BAT=str(self.battery), COUNT=str(self.base/'count'))
        self.mock('curl', '''printf 'curl\n' >> "$CALLS"
while (( $# )); do
 if [[ "$1" == --data-binary ]]; then printf '%s' "$2" > "$PAYLOAD_FILE"; fi
 shift
done
exit "${CURL_RC:-0}"
''')
        self.mock('docker', '''printf 'docker %s\n' "$*" >> "$CALLS"
case "$1" in
 inspect) exit 1;;
 ps) printf 'fake-container\n';;
 exec) exit "${SAVE_RC:-0}";;
esac
''')
        self.mock('systemctl', 'exit 0\n')
        self.mock('dig', "printf ';; status: SERVFAIL,\\n'\n")
        self.mock('shutdown', 'printf "shutdown\\n" >> "$CALLS"\nexit 0\n')
        self.mock('smartctl', 'printf \'{"smart_status":{"passed":true}}\\n\'\nexit "${SMART_RC:-0}"\n')

    def mock(self, name, body):
        f = self.bin / name
        f.write_text('#!/bin/bash\n' + body)
        f.chmod(0o755)

    def run_script(self, name):
        return subprocess.run(['bash', str(ROOT/name)], env=self.env,
                              capture_output=True, text=True, timeout=8)

    def test_discord_json_and_failure_status(self):
        message = 'quote " slash \\ tab\t newline\n@everyone'
        self.env['CURL_RC'] = '22'
        result = subprocess.run(['bash', str(ROOT/'discord-alert.sh'), message],
                                env=self.env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 22)
        data = json.loads(self.payload.read_text())
        self.assertTrue(data['content'].endswith(message))
        self.assertEqual(data['allowed_mentions'], {'parse': []})

    def test_failed_alert_is_retried_and_missing_pihole_detected(self):
        self.env['CURL_RC'] = '22'
        self.assertEqual(self.run_script('homelab-checks.sh').returncode, 1)
        state = self.base/'state'
        self.assertFalse((state/'state_pihole_container').exists())
        first = self.log.read_text().count('curl')
        self.env['CURL_RC'] = '0'
        self.assertEqual(self.run_script('homelab-checks.sh').returncode, 0)
        self.assertGreater(self.log.read_text().count('curl'), first)
        self.assertEqual((state/'state_pihole_container').read_text().strip(), 'bad')
        # SERVFAIL with a successful dig process is an outage.
        self.assertEqual((state/'state_pihole_dns').read_text().strip(), 'bad')
        before = self.log.read_text().count('curl')
        self.run_script('homelab-checks.sh')
        self.assertEqual(self.log.read_text().count('curl'), before)

    def test_smart_nonzero_status_is_not_silenced(self):
        self.assertEqual(self.run_script('smart-check.sh').returncode, 0)
        self.env['SMART_RC'] = '8'
        self.assertEqual(self.run_script('smart-check.sh').returncode, 1)
        self.assertIn('SMART', json.loads(self.payload.read_text())['content'])

    def test_battery_resets_after_ac_and_retries_failed_save(self):
        self.env['SAVE_RC'] = '1'
        self.mock('sleep', '''n=0
[[ ! -f "$COUNT" ]] || n=$(cat "$COUNT")
n=$((n+1)); echo "$n" > "$COUNT"
case "$n" in
 2) echo Charging > "$BAT/status";;
 3) echo Discharging > "$BAT/status";;
 4) kill -TERM "$PPID";;
esac
''')
        result = self.run_script('battery-monitor.sh')
        self.assertEqual(result.returncode, -signal.SIGTERM)
        self.assertEqual(self.log.read_text().count('docker exec'), 3)
        self.assertNotIn('shutdown', self.log.read_text())

    def test_successful_save_resets_on_power_return(self):
        self.mock('sleep', '''n=0
[[ ! -f "$COUNT" ]] || n=$(cat "$COUNT")
n=$((n+1)); echo "$n" > "$COUNT"
case "$n" in
 1) echo Charging > "$BAT/status";;
 2) echo Discharging > "$BAT/status";;
 3) kill -TERM "$PPID";;
esac
''')
        self.assertEqual(self.run_script('battery-monitor.sh').returncode, -signal.SIGTERM)
        self.assertEqual(self.log.read_text().count('docker exec'), 2)

    def test_emergency_flush_and_shutdown_even_if_save_fails(self):
        (self.thermal/'temp').write_text('81000')
        self.env['SAVE_RC'] = '1'
        self.assertEqual(self.run_script('temp-monitor.sh').returncode, 0)
        calls = self.log.read_text()
        self.assertIn('docker exec minecraft rcon-cli save-all flush', calls)
        self.assertIn('docker stop --time 30 fake-container', calls)
        self.assertTrue(calls.endswith('shutdown\n'))

    def test_no_sensor_is_not_a_safe_temperature(self):
        (self.thermal/'temp').unlink()
        self.mock('sleep', 'kill -TERM "$PPID"\n')
        result = self.run_script('temp-monitor.sh')
        self.assertIn('No readable temperature sensor', result.stderr)
        self.assertFalse(self.log.exists())

if __name__ == '__main__':
    unittest.main()
