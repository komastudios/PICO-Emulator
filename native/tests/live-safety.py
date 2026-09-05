#!/usr/bin/env python3
"""Authorized candidate smoke test. Mutates native input only, always releases.
Run as android with generated pico_automation stubs on PYTHONPATH.
Does not print discovery/lease tokens. No HOME, recenter, or app RPCs.
"""
import glob
import math
import os
import subprocess
from pathlib import Path
import time
import grpc
from google.protobuf.empty_pb2 import Empty
import pico_automation_pb2 as p
import pico_automation_pb2_grpc as rpc

paths = glob.glob('/run/pico-emulator/avd/pico_running/pid_*.ini')
assert len(paths) == 1, 'expected exactly one current emulator discovery file'
info = {}
for line in open(paths[0]):
    key, sep, value = line.strip().partition('=')
    if sep:
        info[key] = value
channel = grpc.insecure_channel('127.0.0.1:' + info['grpc.port'])
stub = rpc.PicoAutomationStub(channel)
md = [('authorization', 'Bearer ' + info['grpc.token'])]

def call(name, req):
    return getattr(stub, name)(req, metadata=md, timeout=6)

def rejects(code, fn):
    try:
        fn()
    except grpc.RpcError as exc:
        assert exc.code() == code, (exc.code(), exc.details())
    else:
        raise AssertionError('expected ' + str(code))

rejects(grpc.StatusCode.UNAUTHENTICATED, lambda: stub.GetCapabilities(Empty(), timeout=3))
caps = call('GetCapabilities', Empty())
assert caps.api_version == 1 and caps.lease_ms == 5000
assert caps.native_xr and caps.guest_keyboard and caps.independent_hands
assert {28, 158, 30}.issubset(caps.supported_linux_key_codes)
state = call('GetState', Empty())
assert state.ready and not state.automation_owned, 'candidate must be ready and unleased'
lease = call('Acquire', p.AcquireRequest(input_epoch=state.input_epoch, timeout_ms=1000))
seq = 0
# Discover qwerty2 dynamically: event numbers can change across restarts.
adb = '/opt/android/PICO/sdk/platform-tools/adb'
devices = subprocess.check_output([adb, '-s', 'emulator-5554', 'shell', 'getevent', '-pl'], text=True)
node = None
for line in devices.splitlines():
    if line.startswith('add device '):
        candidate = line.split(':', 1)[1].strip()
    if 'name:' in line and 'qwerty2' in line:
        node = candidate
        break
assert node, 'qwerty2 guest device not found'
trace_path = Path('/tmp/pico-native-keytrace.txt')
trace_file = trace_path.open('w')
trace = subprocess.Popen([adb, '-s', 'emulator-5554', 'shell', 'getevent', '-lt', node], stdout=trace_file, stderr=subprocess.STDOUT)
all_trace_file = Path('/tmp/pico-native-inputtrace.txt').open('w')
all_trace = subprocess.Popen([adb, '-s', 'emulator-5554', 'shell', 'getevent', '-lt'], stdout=all_trace_file, stderr=subprocess.STDOUT)
time.sleep(0.15)

def command():
    global seq
    seq += 1
    return p.Command(input_epoch=lease.input_epoch, lease_token=lease.lease_token,
                     sequence=seq, timeout_ms=1000)
def capture_host(path):
    proc = subprocess.Popen(['scrot', '--overwrite', path], env=dict(os.environ, DISPLAY=':99'))
    deadline = time.monotonic() + 8
    while proc.poll() is None:
        if time.monotonic() >= deadline:
            proc.terminate(); proc.wait(timeout=3)
            raise TimeoutError('host capture exceeded 8 seconds')
        call('Renew', command())
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
    assert proc.returncode == 0

try:
    rejects(grpc.StatusCode.ABORTED, lambda: call('ReleaseAll', p.Command(input_epoch=lease.input_epoch, lease_token=lease.lease_token, sequence=0, timeout_ms=1000)))
    # Exact Release retry is accepted only until another Acquire succeeds.
    released = command()
    assert not call('Release', released).automation_owned
    assert not call('Release', released).automation_owned
    lease = call('Acquire', p.AcquireRequest(input_epoch=state.input_epoch, timeout_ms=1000))
    seq = 0
    rejects(grpc.StatusCode.PERMISSION_DENIED, lambda: call('Release', released))
    rejects(grpc.StatusCode.RESOURCE_EXHAUSTED,
            lambda: call('Acquire', p.AcquireRequest(input_epoch=state.input_epoch, timeout_ms=1000)))
    bad = command(); bad.lease_token = 'invalid'
    rejects(grpc.StatusCode.PERMISSION_DENIED, lambda: call('Renew', bad))
    bad = command(); bad.input_epoch = 'old-epoch'
    rejects(grpc.StatusCode.FAILED_PRECONDITION, lambda: call('Renew', bad))
    # Validation must not partially apply the keyboard when the pose is invalid.
    bad = p.ApplyRequest(command=command(), hmd=p.Pose(orientation=p.Quaternion(w=2)),
                         keyboard=p.KeyboardState(linux_key_codes_down=[30]))
    rejects(grpc.StatusCode.INVALID_ARGUMENT, lambda: call('Apply', bad))
    assert not call('GetState', Empty()).keyboard.linux_key_codes_down
    renewed = call('Renew', command()); assert renewed.remaining_ms >= 4900
    call('Apply', p.ApplyRequest(command=command(), connection=p.CONNECT_BOTH))
    Path('/tmp/pico-native-head-before.png').write_bytes(subprocess.check_output([adb, '-s', 'emulator-5554', 'exec-out', 'screencap', '-p']))
    capture_host('/tmp/pico-native-host-before.png')
    moved = p.Pose(); moved.CopyFrom(state.hmd); moved.position.x += 0.05
    q = state.hmd.orientation; sy, cy = math.sin(math.radians(10)), math.cos(math.radians(10))
    moved.orientation.CopyFrom(p.Quaternion(x=cy*q.x+sy*q.z, y=cy*q.y+sy*q.w, z=cy*q.z-sy*q.x, w=cy*q.w-sy*q.y))
    applied_head = call('Apply', p.ApplyRequest(command=command(), hmd=moved))
    assert abs(applied_head.hmd.position.x - moved.position.x) < 0.0001
    time.sleep(0.25)
    Path('/tmp/pico-native-head-after.png').write_bytes(subprocess.check_output([adb, '-s', 'emulator-5554', 'exec-out', 'screencap', '-p']))
    capture_host('/tmp/pico-native-host-after.png')
    assert abs(call('GetState', Empty()).hmd.position.x - moved.position.x) < 0.0001
    call('Apply', p.ApplyRequest(command=command(), hmd=state.hmd))
    call('Renew', command())
    # Independent hand state and axis quantization are host state checks only.
    left = p.HandState(pose=p.Pose(position=p.Vec3(x=-0.2, y=-0.2, z=-0.4), orientation=p.Quaternion(w=1)), stick_x=0.5)
    right = p.HandState(pose=p.Pose(position=p.Vec3(x=0.2, y=-0.2, z=-0.4), orientation=p.Quaternion(w=1)), grip=0.25)
    applied = call('Apply', p.ApplyRequest(command=command(), left=left, right=right))
    assert applied.left.pose.position.x < 0 < applied.right.pose.position.x
    assert abs(applied.left.stick_x - 0.5) < 0.01 and abs(applied.right.grip - 0.25) < 0.01
    cleanup = command(); clean = call('ReleaseAll', cleanup)
    assert clean.automation_owned and clean.left.stick_x == 0 and clean.right.grip == 0
    assert call('ReleaseAll', cleanup).automation_owned  # exact retry is harmless
    before = call('GetState', Empty())
    down = call('TimedPress', p.TimedPressRequest(command=command(), duration_ms=150, linux_key_code=30))
    assert 30 in down.keyboard.linux_key_codes_down
    time.sleep(0.25)
    assert not call('GetState', Empty()).keyboard.linux_key_codes_down
    call('TimedPress', p.TimedPressRequest(command=command(), duration_ms=150,
                                          hand_button=p.HandButton(hand=p.RIGHT, button=p.TRIGGER)))
    time.sleep(0.25)
    after = call('GetState', Empty()); assert p.TRIGGER not in after.right.buttons_down and after.right.trigger == 0
    assert after.hmd == before.hmd, 'cleanup must preserve headset pose'
    call('Apply', p.ApplyRequest(command=command(), left=p.HandState(pose=state.left.pose), right=p.HandState(pose=state.right.pose), keyboard=p.KeyboardState(linux_key_codes_down=[30])))
    # No renewal: prove the emulator's own watchdog releases without a service.
    time.sleep(5.15)
    # Freeze/read guest evidence BEFORE any RPC can run synchronize() itself.
    trace.terminate(); trace.wait(timeout=5); trace_file.close()
    events = trace_path.read_text()
    downs = sum('KEY_A' in line and 'DOWN' in line for line in events.splitlines())
    ups = sum('KEY_A' in line and 'UP' in line for line in events.splitlines())
    assert downs >= 2 and ups >= 2, ('guest key trace missing DOWN/UP', downs, ups)
    print('Guest watchdog UP observed in closed trace before post-expiry GetState')
    expired = call('GetState', Empty())
    assert not expired.automation_owned and not expired.keyboard.linux_key_codes_down
    assert expired.hmd == before.hmd
    print('PASS: authenticated capability/state, exclusivity, validation, head/hands, timed key/trigger, cleanup retry, expiry; guest KEY_A DOWN/UP pairs:', downs, ups)
    print('Guest trace:', trace_path)
finally:
    if all_trace.poll() is None:
        all_trace.terminate(); all_trace.wait(timeout=5)
    all_trace_file.close()
    if trace.poll() is None:
        trace.terminate(); trace.wait(timeout=5)
    trace_file.close()
    current = call('GetState', Empty())
    if current.automation_owned and current.input_epoch == lease.input_epoch:
        call('Apply', p.ApplyRequest(command=command(), hmd=state.hmd, left=p.HandState(pose=state.left.pose), right=p.HandState(pose=state.right.pose), keyboard=p.KeyboardState()))
        call('Release', command())
