#!/usr/bin/env python3
"""Authorized live vendor pipe restart acceptance. Run only in coordinated window.
Uses vendor init property; no process kill, reboot, or Unity commands.
"""
import glob
from pathlib import Path
import subprocess
import time
import grpc
from google.protobuf.empty_pb2 import Empty
import pico_automation_pb2 as p
import pico_automation_pb2_grpc as rpc

paths = glob.glob('/run/pico-emulator/avd/pico_running/pid_*.ini')
assert len(paths) == 1
info = dict(line.strip().split('=', 1) for line in open(paths[0]) if '=' in line)
stub = rpc.PicoAutomationStub(grpc.insecure_channel('127.0.0.1:' + info['grpc.port']))
md = [('authorization', 'Bearer ' + info['grpc.token'])]
adb = ['/opt/android/PICO/sdk/platform-tools/adb', '-s', 'emulator-5554', 'shell']
def call(name, value):
    return getattr(stub, name)(value, metadata=md, timeout=3)
def shell(*args):
    return subprocess.check_output(adb + list(args), text=True, timeout=10).strip()
state = call('GetState', Empty())
assert state.ready and not state.automation_owned
pid_before = shell('pidof', 'EmulatorPipeService')
assert pid_before, 'vendor service must already be running'
lease = call('Acquire', p.AcquireRequest(input_epoch=state.input_epoch, timeout_ms=1000))
seq = 0
trace_file = Path('/tmp/pico-native-epochtrace.txt').open('w')
trace = subprocess.Popen(adb + ['getevent', '-lt'], stdout=trace_file, stderr=subprocess.STDOUT)
time.sleep(0.15)
def command():
    global seq
    seq += 1
    return p.Command(input_epoch=lease.input_epoch, lease_token=lease.lease_token, sequence=seq, timeout_ms=1000)
try:
    call('TimedPress', p.TimedPressRequest(command=command(), duration_ms=3000, linux_key_code=30))
    call('TimedPress', p.TimedPressRequest(command=command(), duration_ms=3000, hand_button=p.HandButton(hand=p.RIGHT, button=p.TRIGGER)))
    shell('setprop', 'sys.emu_pipe_service.state', '2')
    limit = time.monotonic() + 10
    while time.monotonic() < limit:
        current = call('GetState', Empty())
        if current.input_epoch != state.input_epoch and current.ready:
            break
        time.sleep(0.1)
    assert current.input_epoch != state.input_epoch, 'property did not produce an observed pipe epoch change'
    assert current.ready and not current.automation_owned
    assert not current.keyboard.linux_key_codes_down
    assert not current.left.buttons_down and not current.right.buttons_down
    assert current.left.trigger == current.right.trigger == 0
    assert current.left.grip == current.right.grip == 0
    assert current.hmd == state.hmd
    pid_after = shell('pidof', 'EmulatorPipeService')
    assert pid_after and pid_before != pid_after, (pid_before, pid_after)
    try:
        call('Renew', command())
        raise AssertionError('old epoch mutation accepted')
    except grpc.RpcError as exc:
        assert exc.code() == grpc.StatusCode.FAILED_PRECONDITION, exc.code()
    time.sleep(3.2)
    current = call('GetState', Empty())
    assert not current.automation_owned and not current.keyboard.linux_key_codes_down
    print('PASS: vendor property restart PID', pid_before, '->', pid_after,
          '; epoch revoked lease and timed key, ready neutral state, old epoch rejected, pose preserved')
finally:
    trace.terminate(); trace.wait(timeout=5); trace_file.close()
    current = call('GetState', Empty())
    if current.automation_owned and current.input_epoch == lease.input_epoch:
        call('Release', command())
