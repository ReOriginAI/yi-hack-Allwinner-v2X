# Motion tuning in the camera web UI

Open **Camera Settings → Local Motion Detection**. Settings apply when you click
**Save Configuration** and persist on the SD card across reboot.

On y623, **Use custom thresholds** replaces the 1–10 sensitivity preset with:

| Control | Range | Saved key |
| --- | --- | --- |
| Start threshold | 0.01–100%, steps of 0.01 | `MOTION_START_THRESHOLD` |
| Stop threshold | 0–99.99%, below start | `MOTION_STOP_THRESHOLD` |
| Start confirmation | 1–50 consecutive samples | `MOTION_START_SAMPLES` |
| Quiet time before stopping | 100–30,000 ms | `MOTION_STOP_DELAY` |
| Sample interval | 100–2,000 ms | `MOTION_POLL_INTERVAL` |
| Require motion level zero to stop | On/off | `MOTION_STOP_REQUIRE_ZERO` |

`MOTION_CUSTOM=yes` enables these settings. Disable it to return to the selected
`MOTION_SENSITIVITY` preset. Installing this feature preserves the selected preset
and adds inactive custom defaults of 3.00%, 0.30%, three start samples, 2,000 ms
quiet time, 100 ms sampling, and the level-zero requirement enabled.

Custom mode starts from the exact change threshold alone. Presets retain the
existing strong-motion hint, which can trigger at half the preset threshold when
the encoder reports motion level 2 or greater. **Copy selected sensitivity
preset** fills the custom fields with that preset's threshold and timing values;
the page explains the difference in start behavior.

The live readings show the main encoder's raw `Scene`, `Move`, `MovingLevel`,
`BinImgRatio`, and `MovingTh` values, current state, quiet countdown, sample age,
and settings actually used by the running
detector. The chart retains up to 60 samples in the browser, fetched every two
seconds while the page is visible. Unsaved edits do not change its active
threshold lines. If detection stops or samples become stale, the chart is hidden
and the page reports that readings are unavailable.
The ratio, vendor grades, and block threshold use separate chart scales.
The static metadata guide explains the compact raw format and extraction commands.

For a scene that stays near 1.7% change at motion level 1, the default sensitivity
5 can remain active after a trigger: its stop condition requires at most 0.30%
and level zero for two consecutive seconds. A custom stop threshold above that
background, below the start threshold, with the level-zero requirement disabled
can let the detector return to idle. Observe a quiet scene and real motion before
choosing values; those background measurements do not establish a universal
threshold. Longer sampling intervals reduce work but may miss brief motion.

The y28ga uses the firmware's generic IVA detector. Its UI exposes the actual
three firmware levels: low (stored value 2), medium (5), and high (9). Legacy
values 1–3 map to low, 4–7 to medium, and 8–10 to high. The firmware does not expose
the separate thresholds or timing controls implemented by y623's detector.
The page states that limitation and the API rejects custom mode on y28ga.

## Implementation and validation

`motion_settings.sh` supplies configuration defaults and validates complete merged
requests before `set_configs.sh` changes saved values. Invalid numeric ranges,
non-numeric values, and stop thresholds at or above start are rejected. Partial
requests use the existing settings for validation. A changed motion setting
restarts the motion service once; unchanged saves do not restart it. Apply errors
are reported separately from successful persistence.

The running `motiond` publishes its existing sample into `/tmp/motion.telemetry`
once a second using atomic rename. This small RAM snapshot adds no video buffer,
SD-card writes, or extra VE reads for the web page. `motion_status.sh` reads the
snapshot before obtaining uptime and rejects stale samples. Missing detector
samples reset confirmation and quiet timing without inventing START or STOP.
The recorder and FTP pipeline keep using the existing motion events. The .150
trial captures raw readings in [compact recording metadata](MOTION_METADATA.md)
using the existing detector measurements. RTSP and audio paths are unaffected.

`scripts/test_motion_tuning.py` exercises background hysteresis, consecutive
confirmation, missing samples, custom versus preset hints, CLI/API rejection,
migration, exact service arguments, apply failures and stale status samples.
The existing VE pressure/parser, night-vision, time and RTSP configuration checks
also pass. On both live devices the controls were saved through the browser;
y623's effective settings matched the custom values and y28ga applied high and
medium firmware sensitivity. Deployment preserves the original files under
`/tmp/sd/yi-hack/.motion-ui-backup-20261011/` and updates the boot integrity
manifest alongside the installed files. Both cameras passed reboot validation;
y623's custom values survived reboot, its chart fitted a 390-pixel viewport, and
both Standard RTSP streams retained H.264 video and AAC audio. Test settings were
restored to the original sensitivity presets after validation.

## Detector recovery on .150

The 2026-10-14 `motiond` update makes recorder notifications nonblocking. A full
IPC queue previously blocked `mq_send`, stopping the entire detection loop.
The detector now keeps a bounded pending START and the latest state, attempts
at most two sends per poll, and continues sampling while the queue is full.
A short motion that ends during congestion still gets START followed by STOP
when delivery resumes. Several bursts during a prolonged outage may merge into
one notification interval, rather than accumulate an unbounded stale backlog;
the raw recording metadata retains the actual captured timestamps.

An unavailable broker is retried once per second. Queue identity is checked
once per second so an unlinked/recreated queue cannot silently retain messages
on an abandoned descriptor. Startup and reconnection send STOP to reset stale
recorder motion before sending a pending START. Shutdown retries for at most
500 ms; a broker that remains unavailable cannot receive the final STOP until a
subsequent startup/reconnection resets it.

The service's diagnostic pipe is nonblocking, and a closed pipe cannot terminate
the detector with SIGPIPE. Diagnostics may be dropped if the logger is stalled,
while detection and recorder notification retries continue. The two-byte motion
state file is published using atomic rename; failed publication is retried once
per second rather than waiting for the next transition. Telemetry includes
`ipc_pending`, `ipc_error`, and `state_pending`; the web UI reports pending
recorder notifications or status updates.

These changes address IPC and logging stalls in userspace. Reads inside the
vendor kernel driver remain synchronous. The existing allocator verification,
legacy memory-pressure guard, read-error backoff, invalid-sample rejection,
singleton service startup, and watchdog process recovery remain in place.

Run `python3 scripts/test_motion_robustness.py` for six tests covering full and
closed diagnostic pipes, an unavailable broker, atomic state updates, failed
state-publication recovery, and real private queues. The queue tests cover full
queues, short pending bursts, bounded merging, reconnect delay, queue replacement,
broken descriptors, and undersized queues. The same queue test passed as an ARM
binary on .150 using private queues; it never congested the real recorder queue.
Existing tuning, kernel/pressure, collector-lifecycle and metadata tests pass.

Fresh native `2026Y10M14D04H/W440M50S10.mp4` contains 13 compact raw rows over
10.059 s: the trigger burst is spaced 201–202 ms, then 1,005–1,016 ms. Both H.264
streams and AAC decode successfully, and its FTP copy matches the SD file byte
for byte. The control test used temporary runtime thresholds and restored the
saved 2.00% trigger, 1.60% release, two confirmations, 3,000 ms quiet delay,
100 ms polling, and disabled level-zero stop requirement. Camera/system files
were unchanged; all 41 boot-manifest entries passed. The live web chart, static
format guide, and pending-notification/status notices were checked. Standard
RTSP still returns H.264 and AAC. No recorder or event-consumer restart was
needed for this update.

The installed binary and web assets retain their predecessors and boot manifest
at `/tmp/sd/yi-hack/.motiond-robust-backup-20261014/`. Saved camera/system settings
are preserved. The .199 firmware IVA backend does not run `motiond` and was not
changed by this trial.
