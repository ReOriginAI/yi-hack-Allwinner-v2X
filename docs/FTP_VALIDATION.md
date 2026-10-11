# y623 FTP upload after motion metadata and local-time updates

Validated `192.168.1.150` on 2026-10-11 after the camera rebooted with the
night-vision, local-time and recorder-metadata updates. Its existing FTP server,
account, destination, directory-tree setting and upload cron were retained.

The configured pipeline uploads completed SD MP4s, then deletes the local
copy after a successful transfer. The native recorder first finalizes the clip;
the existing cron scans once per minute, at second 40. The Camera Settings
label **Service: started** means the detector is running; **state: motion**
indicates an active detection.

The camera's bounded native test event (`ipc_cmd -S 6`) exercised the same
generic START/STOP messages used by `motiond`. It produced:

| Check | Observed result |
| --- | --- |
| New SD path | `2026Y10M10D23H/W419M10S50.mp4` |
| MP4 UTC creation | `2026-10-11T03:19:08Z` |
| Recording duration | 50.086 seconds, including the firmware's recording tail |
| Scheduled upload log | `2026-10-10 23:20:48`, upload succeeded |
| FTP destination | `/FTPfiles/yicamFront/2026Y10M10D23H/W419M10S50.mp4` |
| Local deletion | Occurred after successful upload, as configured |

The file was independently downloaded from the FTP server and the user
confirmed its appearance. It retained the native 2304×1296 and 640×360 H.264
tracks, 16 kHz mono AAC and embedded `yi_motion` metadata. The START timestamp
was `1791688748539` ms with clip offset 539 ms; STOP was `1791688754551` ms with
offset 6,551 ms. The metadata remained complete after transfer.

All three tracks decoded successfully. The decode check used an explicit
millisecond output time base to avoid rounding native video timestamps to
FFmpeg's guessed output frame rate:

```sh
ffmpeg -v error -threads 1 -i recording.mp4 -map 0:v -map 0:a \
  -fps_mode:v passthrough -enc_time_base:v 1/1000 -f null -
```

An FTP failure was not reproduced during this check. The pre-reboot upload
log also contained successful uploads of the earlier metadata/time validation
clips. No FTP code or credential changes were needed. This check uses the
camera's test event; it does not establish the detector's sensitivity to a
particular real-world movement. The detector was reporting idle during the
upload investigation.

The later [preroll update](RECORDING_PREROLL.md) was also checked through FTP:
`2026Y10M11D00H/W415M41S19.mp4` uploaded successfully, retained both H.264 tracks
and AAC, and decoded without errors after download. Its first frame and UTC
creation time were `04:15:41Z`; embedded motion START was at +5,295 ms, showing
that buffered footage and aligned metadata survived the transfer.
