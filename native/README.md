# Native automation v1

The canonical protocol mirror is `proto/pico_automation.proto`. It is served as
`pico.automation.v1.PicoAutomation` on the existing authenticated emulator gRPC
endpoint and installed as `picoemulator/lib/pico_automation.proto`. The
android-studio issuer's authenticated allowlist names all eight RPCs; no
unprotected methods are added.

The implementation is pinned as public qemu base `27ee429e` plus the SHA-256
locked `patches/pico-native-automation.patch` overlay in `native/patch.lock`.
The restored source tree is `.cache/src/external/qemu`. `build-compile.sh`
verifies/applies the overlay and records `PATCH pico-native-automation <sha>` in
`.pico-provenance`; it never labels these binaries as an unchanged base build.
The original qemu/gfxstream revision locks remain the base inputs. Both release
and debug builds receive the same native overlay. The source/cache key includes
the overlay and its application script.

Protocol rules:

- Fixed exclusive 5-second lease; callers renew every 2 seconds only while the
  originating client is alive. Epoch, opaque token and increasing sequence
  fence mutations. State never discloses the owner's token.
- timeout_ms is a remaining duration, 1..5000 ms. The emulator starts a local
  monotonic deadline at receipt, respects the gRPC deadline, and rechecks on Qt
  dispatch. Cross-host monotonic timestamps are never accepted.
- Apply changes only present HMD/hand/keyboard messages. Present hand controls
  replace that hand's entire control state; omitted pose preserves its pose.
  Present keyboard replaces all automation-held evdev keys. Analog and digital
  XR click controls remain independent. No command implicitly renews.
- TimedPress is asynchronous: acknowledgment means down was applied and up
  scheduled. It ends at the earlier of press deadline and current lease expiry.
  Clients wanting full duration must not immediately Release. Applying that
  hand/keyboard state replaces its pending timed presses.
- ReleaseAll clears controls but retains ownership; Release also returns Qt
  ownership. A retry of the last identical cleanup is a no-op only within its
  original epoch/owner. ReleaseAll requires the last successful sequence while
  still owned; Release requires the last release token/sequence while unowned
  with no subsequent Acquire. Both still validate timeout/deadline and readiness
  and return current State without renewal. All other duplicate sequences,
  including zero on a new lease, fail. Cleanup never presses HOME or recenters. It re-emits
  neutral state after queue clearing even if the cache is already neutral;
  previously touched HOME/APP may receive release-only cleanup.
- PICO service-start, pipe loss and reconnect invalidate input_epoch independently
  of process/systemd generation. Epoch invalidation cancels outstanding timers
  and queued commands before human ownership resumes.
- Position metres, +X right/+Y up/-Z forward; unit xyzw quaternion (norm tolerance
  0.001, normalized on application); position safety bound +/-100000 metres.
  Independent hand poses, sticks [-1,1], trigger/grip [0,1]. State reflects host
  simulator values; native analog values are quantized to the vendor 0..255 ABI.
- Keyboard is Linux evdev codes, not Android/Qt codes; GetCapabilities returns
  the explicit supported set, including Enter 28 and Back 158. It bypasses Qt
  shortcuts and uses the same lease/release path. This does not prove the app
  receives an event: capabilities describe host support, State.ready describes
  open guest pipes, and application consumption requires acceptance evidence.
- Connection chooses left/right/both only. No disconnect, recenter, pixel-aiming
  guarantee, Unity action bridge, or dedicated standard Android gamepad in v1.

Validation: `native/tests/verify-contract.py <qemu-source-or-picoemulator-dir>`
checks protocol and access-policy entries; the standalone AutomationPolicy test
checks timeout/lease/epoch fencing. Qemu's hardware unit tests include
PicoemuPipeQueueTest coverage of FIFO button edges, per-device pose coalescing,
forced release after queue clearing, and epoch locking. Live acceptance remains
separate from source tests and is coordinated with pico-ctl's owner.

Reconnect cleanup is independent of lease ownership: every pipe/service epoch change arms a pending neutral baseline. The first ready input frame clears stale queued work and force-emits neutral ordinary controls and release-only for previously touched HOME/APP, even after Release or epoch revocation already cleared the token. Another epoch rearms this recovery. Poses/tracking remain preserved.

Candidate validation (2026-09-05): final native build exited 0; 9,910 policy
assertions, five hardware queue/epoch tests, exact-base overlay replay, package
checksums/proto/auth policy, and live authenticated smoke passed. Live qwerty2
KEY_A DOWN/UP includes watchdog UP captured before a follow-up GetState. Host
window captures prove headset yaw reaches the rendered app; ADB screencap showed
a different/incomplete XR view. Vendor pipe-service restart via its documented
property was denied by the guest, so live epoch restart acceptance remains open.
The native trigger sequence entered Cookie Ride; isolated app action acceptance
and Astrosmash movement/fire coverage remain the coordinator's gate. No Unity
setter or dedicated Android gamepad was added. No independent clean double-build
reproducibility comparison has been performed for this candidate.

Run live tests only in a coordinated mutation window as android, copying the
scripts to /tmp if its account cannot traverse the repository. Generate Python
stubs from the packaged proto. `live-safety.py` takes and renews a lease, changes
head/hands, uses guest KEY_A and trigger, records guest events/host screenshots,
and checks autonomous expiry. `live-epoch.py` uses only the vendor-defined
`sys.emu_pipe_service.state=2` restart property; it fails honestly if denied.
The tests do not restore app navigation caused by a real trigger. Present Pose
messages require both position and orientation, including position:{} at origin.

Axis correction (2026-09-06): stick_x/State.stick_x now map to guest XR X
(wire rocker 16), and stick_y to guest XR Y (wire rocker 15), with unchanged
sign and quantization. Explicit Apply connection selection also updates Qt's
controller tracking selection, so subsequent START_CONTROLLER_TRACKING uses
both hands for CONNECT_BOTH. This is not a guest connection acknowledgment;
live left-controller acceptance remains pending. This candidate is not deployed.
