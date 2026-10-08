#!/usr/bin/env python3
"""Source guard, no credentials, provider, app, or system Keychain access."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
for directory in ('apps', 'services'):
    for file in (root / directory).rglob('*'):
        if file.suffix not in ('.swift', '.rs', '.m', '.mm', '.h', '.cs', '.cpp'):
            continue
        if any(p in ('target', 'Tests', 'Library', 'obj', 'Temp', 'build') for p in file.parts):
            continue
        text = file.read_text(errors='replace')
        for forbidden in ('SecItemCopyMatching', 'SecItemAdd', 'SecItemUpdate', 'SecItemDelete', 'find-generic-password', 'add-generic-password', 'keyring::'):
            assert forbidden not in text, (str(file.relative_to(root)), forbidden)
host = (root / 'apps/macos/UnityHost/UnityProductSettings.swift').read_text()
assert re.search(r'RustProductSettingsClient\(root: root\.appendingPathComponent\("gmgn radio/TaskService", isDirectory: true\), allowsLaunching: true\)', host)
print('PASS production credential-storage Keychain API guard + same-root helper bootstrap; RSA/TLS certificate primitives retained')
