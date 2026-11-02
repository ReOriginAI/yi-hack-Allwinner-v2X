# Atomic service ownership and bounded recovery

Implemented for the shared y623 and y28ga firmware payload. Native temporary
validation passed on y623 `192.168.1.150` and y28ga `192.168.1.199` on
2026-11-02. The installed firmware was not changed.

## Ownership

`src/busybox/yi-lock.patch` adds `yi_lock RESOURCE` and `yi_lock -u RESOURCE`
to the packaged BusyBox ash. The shell binds a namespaced abstract AF_UNIX
socket. Bind is atomic; contention returns 75, invalid arguments return 2,
and runtime failures return 1. Callers never proceed unlocked on an error.

The kernel releases a socket after its last reference closes. No PID record,
stale directory, timestamp expiration, or cleanup trap is needed for ownership.
`flock` returned ENOSYS on these cameras, and the earlier y28ga probes also
rejected F_SETLK and SysV semget. Abstract socket binding and ownership tests
passed on both models.

Lock descriptors are close-on-exec and tracked as ash internal descriptors:
redirection collisions relocate them, and scripts cannot duplicate them through
normal shell redirections. Foreground shell pipelines/subshells retain references,
so a surviving queue shell still excludes replacement work after parent death.
Ash's final-command exec optimization is disabled while it owns locks. Explicit
`exec` deliberately ends that shell's ownership.

Background shell jobs drop inherited locks before executing their body. This
prevents a delayed watchdog starter or background daemon from retaining a
lifecycle lock indefinitely. Protected continuous job loops therefore run in the
owning foreground shell. External programs also lose descriptors on exec. There
can be a short scheduling interval before a background child drops its reference;
a contender remains excluded safely during that handoff.

## Protected paths

- FTP uploader, thumbnail worker and timelapse jobs have separate resource locks.
- FTP/thumb start and stop requests also share a short control lock. Stop creates
  a request; the current bounded file operation finishes before the worker exits.
  Restart remains excluded while it owns the job lock. A fresh owner clears an
  old request only after acquiring ownership. `stop` reports request acceptance
  when work is still active, rather than claiming it has already stopped.
- service.sh serializes mutating operations per service. Its all command delegates
  through those same paths rather than bypassing ownership. Repeated ONVIF, WSD,
  FTP and MQTT starts do not create a second known running daemon. Process checks
  match the executable field rather than words in the service command arguments.
  The lock is held through a bounded check of observed start/stop state.
- Motion lifecycle and shared event collector locks cover both camera variants.
  Lock order is motion -> recorder service -> motion-events. ONVIF service also
  enters motion-events. Acquisition never waits, so nested callers cannot deadlock.
- Watchdog ownership no longer depends on a stale PID-directory lock.
- Primary Wi-Fi recovery and maintenance handoff use the same wifi-recovery lock.
  A busy primary worker defers handoff without falsely recording a failed switch.

These are per-resource operations, not a transaction spanning service.sh all.
Status queries do not take mutating locks. Callers receiving 75 may retry on a
later watchdog pass; a CLI/UI caller must not interpret it as successful mutation.

## Bounded recovery

`src/service_guard/service_guard.c` runs a worker in a private process group.
It uses CLOCK_MONOTONIC, polls waitpid at 100 ms intervals, and after a deadline
or TERM/INT/HUP sends TERM then KILL one second later to the group. The child
remains unreaped during cleanup to prevent PID/group reuse. Normal child exit
status is preserved; deadlines return 124. This is an on-demand worker supervisor,
not another persistent camera daemon.

service.sh and motion_service.sh mutations have 20-second limits. Nested calls
get their own guard; contention fails immediately. Primary Wi-Fi reconnect runs
in an independent 35-second worker, leaving the main watchdog free to inspect
media and other services. Maintenance handoff/retry is bounded at 35 seconds.
Individual wpa_cli calls have two-second limits, targeting that command rather
than killall of every wpa_cli process. Neither Wi-Fi path cycles wlan0 down/up.

FTP uploads retain their 300-second limits, control connections 15 seconds,
and image capture/demux 30 seconds. FTP deadlines keep failed clips pending and
allow later files to proceed. There is no fixed deadline for the entire queue:
a large backlog doing useful work is allowed to drain.

## Validation and limits

Host tests cover concurrent acquisition, owner SIGKILL, normal exit/unlock,
background daemon inheritance, foreground pipeline survival, descriptor collisions,
last-command ownership, deadline cleanup, daemon startup races, repeated starts,
cooperative stop, and nonblocking/retryable Wi-Fi workers. Existing FTP receipts,
collector lifecycle, RTSP configuration, time configuration and nightvision tests
also pass. The CI workflow builds the real patched host ash before these tests.

Temporary native ARM tests on both physical cameras covered eight concurrent
contenders (one winner), SIGKILL reacquisition, timed group cleanup, descriptor
redirection and background release. Test files/binaries were removed. This did
not exercise live service restart or Wi-Fi disruption, and is not a full firmware
upgrade test. The host build was also exercised; ARM validation used a temporary
static test build rather than the production cross-toolchain payload.

Build host tests with:

```sh
bash scripts/build_test_busybox.sh /tmp/yi-host-busybox
export YI_TEST_BUSYBOX=/tmp/yi-host-busybox/busybox-1.36.1/busybox
python3 src/static/tests/test_service_serialization.py
python3 src/static/tests/test_service_control.py
python3 scripts/test_motion_history_service.py
```

Deploy scripts together with the rebuilt BusyBox ash and service_guard. An old
BusyBox does not provide this builtin; the source shim re-executes the packaged
shell rather than falling back to unsafe process counting. Existing stale mkdir
lock directories are ignored; they do not need removal to enable the new locks.

Residual limits: media progress telemetry/heartbeat-based hang detection is not
added here. A living but frozen encoder/server can still pass presence checks.
Process-group cleanup cannot kill a descendant that deliberately detaches into
a different session/group. Hard-killing the guard itself bypasses its cleanup;
remaining shell owners still exclude other callers while they run. Kernel
uninterruptible filesystem/device I/O cannot be recovered by a userspace signal
or deadline. No sustained RAM/CPU benchmark or production firmware package build
was performed in this change.
