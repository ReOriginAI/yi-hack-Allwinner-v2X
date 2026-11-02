# Firmware liveness review — 2026-11-02

Scope: source review of watchdog/service recovery, recording maintenance, MQTT,
streaming, audio, and selected CGI paths. Applies to shared y623/y28ga code,
with model/backend qualifications below. This is not a proof that every firmware
path makes progress. No firmware or persistent camera changes were deployed.

## Corrected during this review

- **Previous patch's flock regression:** a reversible lock probe on y28ga
  `192.168.1.199` returned `Function not implemented` (ENOSYS). Existing y623
  source also documents this kernel limitation. Removed the new flock guards;
  retained existing process-count guards and corrected matching for both ash
  and sh. Timelapse serialization remains unresolved. Availability of a BusyBox
  applet does not establish kernel support.
- **MQTT config parser:** `config_parse` used `while (!feof(fp))` and ignored
  failed reads. Persistent read errors set ferror without feof, allowing an
  infinite loop and callbacks using stale/uninitialized input. It now iterates
  on successful fgets. A host C regression reproduces a read error by reading
  a directory and checks a final config line is dispatched only once.
- **Recording cleanup:** deletion failure checks now also detect nonexistent
  selected paths and paths left behind after reported success. This prevents
  repeated no-progress deletion, including a filename truncated by the legacy
  whitespace-based listing parser. This does not fix that parser's filename
  handling or make filesystem I/O interruptible.

## Follow-up implementation

[SERVICE_SERIALIZATION.md](SERVICE_SERIALIZATION.md) records the subsequent
atomic-lock and bounded-recovery implementation and tests on both models.
The flock regression was replaced by a working ash socket builtin. Stale motion,
event, RTSP, watchdog and Wi-Fi mkdir ownership is no longer used. Wi-Fi helper
and lifecycle execution now have deadlines; primary Wi-Fi work runs outside the
watchdog loop. The findings below describe the original audit state; items 1
and 2 are addressed within the limits documented in that implementation report.
Media progress, MQTT callbacks, speaker ownership and CGI deadlines remain open.

## Audit findings, in recovery priority order

1. **Watchdog can block inside recovery work.** `wd.sh:soft_wifi_reconnect`
   calls vendor `wificonnect.sh` and `wifidhcp.sh` synchronously. Maintenance
   handoff also starts wpa_supplicant/DHCP synchronously. There is no enclosing
   deadline; a stuck vendor helper or DHCP hook prevents later watchdog passes
   (including media checks and reboot escalation). `udhcpc -b` backgrounds
   after initial acquisition fails; it is not a bound on arbitrary hook scripts.
   Recovery needs an independently supervised worker with descendant cleanup,
   rather than only putting a timeout around its parent shell.
2. **Persistent stale motion locks.** `motion_service.sh:ensure_ipc_events`
   and the y623 lifecycle guard use mkdir locks with EXIT cleanup but no owner
   recovery. SIGKILL/OOM during the protected operation can leave a directory
   that prevents subsequent operations until removed or rebooted. The y28ga
   shares the event lock; the lifecycle lock is y623-specific. A replacement
   must handle stale ownership, PID reuse and concurrent acquisition, without
   relying on flock.
3. **Presence does not establish media progress.** `wd.sh:check_rmm` accepts a
   living process; alternative RTSP checks process presence/listening; go2rtc
   intentionally permits idle producers. `h264grabber.c` can wait in FIFO open
   or write and can loop while the shared frame pointer stops advancing. A
   connected but frozen pipeline can pass those health checks. Use media
   progress telemetry with demand-aware thresholds before restarting; idle
   go2rtc and inactive recording must not trigger recovery. Semaphore helpers
   also exist, but USE_SEMAPHORE is disabled in the current grabber source and
   are not evidence of an active default-build semaphore deadlock.
4. **MQTT network loop waits for shell commands.** The default wolfMQTT backend
   calls system() directly in its message callback for config dumps and IPC
   commands. A hung command stops command processing while process-count health
   checks still pass. `conf2mqtt.sh` additionally generates a `sleep 60 | ...`
   wrapper for nonterminal callers: the shell waits for that pipeline even if
   publishing finishes early. Tracing the exported guard shows one re-entry,
   not infinite recursion. Commands need bounded execution and publishing
   should not occupy the broker loop. Reconnect loops also do not consult the
   main program's shutdown flag; shutdown during broker outage needs testing.
5. **Audio can retain shared ownership after a hard kill.** `speaker.c` stream
   mode takes a named semaphore before a blocking FIFO open and blocking I/O.
   Normal cleanup posts it; SIGKILL cannot. A killed owner can leave later
   playback reporting busy. Review all speaker users together before replacing
   the ownership primitive; streaming/backchannel sessions need demand-aware
   deadlines rather than a fixed maximum session duration.
6. **Unbounded proxy diagnostic request.** `www/httpd/cgi-bin/proxy.sh` invokes
   wget/proxychains without a request deadline or retry bound. A failed network
   path can retain a CGI child. This is request-local, rather than proof that
   the HTTP listener itself is stuck. Upload/body reads and other CGI I/O also
   warrant targeted slow-client tests.

## Residual limits and validation

Process-count guards are not atomic. A second simultaneous start can race;
matching corrections do not solve lifecycle serialization. Existing watchdog
PID locks also need PID-reuse and acquisition-race testing. Large FTP backlogs,
SD traversal/checksums/sync, and kernel uninterruptible I/O remain relevant.

Host validation: `test_config_read_error.py`, `test_operation_timeout.py`, and
`test_ftppush_queue.py` under `src/static/tests`; BusyBox ash syntax checks and
`git diff --check`. These cover parser read errors, timeout behavior, failed
cleanup, partial capture disposal, and FTP receipts. They do not constitute
hardware validation of the remaining findings. No native firmware rebuild was
performed.
