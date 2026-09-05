#!/usr/bin/env python3
"""Read-only source/package contract checks. No emulator RPCs."""
import json
import re
import sys
from pathlib import Path
root = Path(sys.argv[1])
source = root / 'android/android-grpc'
if source.exists():
    proto = source / 'services/pico-automation/proto/pico_automation.proto'
    policy = source / 'security/src/android/emulation/control/secure/emulator_access.json'
else:
    proto = root / 'lib/pico_automation.proto'
    policy = root / 'lib/emulator_access.json'
text = proto.read_text()
methods = re.findall(r'rpc\s+(\w+)\(', text)
assert len(methods) == 8, methods
access = json.loads(re.sub(r'//[^\n]*', '', policy.read_text()))
assert not access['unprotected'], 'new endpoint must remain authenticated'
issuer = next(x for x in access['allowlist'] if x['iss'] == 'android-studio')
for method in methods:
    route = '/pico.automation.v1.PicoAutomation/' + method
    assert any(re.fullmatch(pattern, route) for pattern in issuer['allowed']), route
print('contract: 8 RPCs packaged and authenticated policy entries present')
