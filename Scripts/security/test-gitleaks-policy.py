#!/usr/bin/env python3
"""Prove exceptions match only the known public value in the exact source path."""
from pathlib import Path
import os
import secrets
import subprocess
import tempfile
import tomllib

root = Path(__file__).resolve().parents[2]
config = root / '.gitleaks.toml'
policy = tomllib.loads(config.read_text())
binary = os.environ.get('GITLEAKS_BIN', 'gitleaks')
exceptions = policy['allowlists']
assert len(exceptions) == 2
for item in exceptions:
    assert item['condition'] == 'AND'
    assert item['targetRules'] == ['generic-api-key']
    assert len(item['paths']) == len(item['regexes']) == 1

# Values are public protocol fixtures from the config; never account credentials.
def literal(regex):
    assert regex.startswith('^') and regex.endswith('$')
    value = regex[1:-1]
    # Only the exact escaped literals our checked-in configuration permits.
    return value.replace('\\/', '/').replace('\\.', '.').replace('\\+', '+').replace('\\=', '=')

cases = 0
for item in exceptions:
    path = literal(item['paths'][0])
    value = literal(item['regexes'][0])
    for name, file, content, expected in (
        ('public fixture', path, f'let api_key = "{value}"\n', 0),
        ('same file different credential', path, f'let api_key = "{secrets.token_urlsafe(32)}"\n', 1),
        ('same value different file', 'unexpected/credential.swift', f'let api_key = "{value}"\n', 1),
    ):
        with tempfile.TemporaryDirectory(prefix='iot-secret-policy-') as scratch:
            target = Path(scratch) / file
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
            for args in (['init', '-q'], ['add', '.'],
                         ['-c', 'user.name=Secret Policy Test', '-c', 'user.email=security-test@invalid.example',
                          'commit', '-q', '-m', 'synthetic policy fixture']):
                subprocess.run(['git', '-C', scratch, *args], check=True, capture_output=True)
            result = subprocess.run([binary, 'git', scratch, '--config', str(config),
                                     '--redact', '--no-banner', '--ignore-gitleaks-allow',
                                     '--gitleaks-ignore-path', '/dev/null'], capture_output=True, timeout=30)
            if result.returncode != expected:
                raise SystemExit(f'Gitleaks policy regression failed: {name}; contents suppressed')
            cases += 1
print(f'Gitleaks policy: {cases} contracts passed; no fixture values printed')
