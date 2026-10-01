#!/usr/bin/env python3
"""Run CocoaMQTT over real loopback sockets, without broker installation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
scratch = os.environ.get('LORISIOT_TEST_SCRATCH', '/private/tmp/lorisiot-mqtt-wire')
build = subprocess.run(['xcrun', 'swift', 'build', '--build-tests', '--scratch-path', scratch],
                       cwd=root, timeout=900)
if build.returncode:
    sys.exit(build.returncode)

with tempfile.TemporaryFile() as errors:
    broker = subprocess.Popen([sys.executable, str(root / 'Scripts/mqtt/loopback-broker.py')],
                              stdout=subprocess.PIPE, stderr=errors, text=True)
    try:
        line = broker.stdout.readline()
        if not line:
            errors.seek(0)
            print(errors.read().decode(), file=sys.stderr)
            raise RuntimeError('Loopback broker did not start')
        ready = json.loads(line)
        env = dict(os.environ, LORISIOT_MQTT_LOOPBACK='1', LORISIOT_MQTT_BROKER='127.0.0.1',
                   LORISIOT_MQTT_PORT=str(ready['port']))
        command = ['xcrun', 'swift', 'test', '--skip-build', '--scratch-path', scratch,
                   '--filter', 'LoopbackWireTests|CocoaMQTTLiveBrokerTests']
        result = subprocess.run(command, cwd=root, env=env, timeout=150)
        errors.seek(0)
        protocol_errors = errors.read()
        if protocol_errors:
            print('Loopback fixture rejected a protocol packet', file=sys.stderr)
        sys.exit(result.returncode or (1 if protocol_errors else 0))
    finally:
        broker.terminate()
        broker.wait(timeout=5)
