# Streaming lifecycle audit — 2026-09-14

Camera: 192.168.1.150, go2rtc PID 2134, rmm PID 1437.
Tests opened RTSP clients; no services were restarted or firmware deployed.

## Ordinary connection churn

60 alternating high/low DESCRIBE connections, closed after receiving SDP.
Eight additional alternating video PLAY connections received RTP then closed
without TEARDOWN. PLAY testing overlapped the DESCRIBE batches.

| Sample | RSS KiB | FDs | Threads | Grabbers |
| --- | ---: | ---: | ---: | ---: |
| Initial (producers already active) | 11036 | 11 | 11 | 2 |
| After 20 DESCRIBEs | 10588 | 12 | 11 | 2 |
| After 40 | 11088 | 9 | 11 | 1 |
| After 60 | 11180 | 9 | 11 | 1 |
| After 15-second settling period | 11180 | 6 | 11 | 0 |

Swap remained zero. One system zombie appeared in each snapshot, not an
increasing grabber zombie count. These short tests do not establish long-term
leak freedom; initial and final producer workloads differ. Final FDs were
stdin/stdout/stderr, the listener, epoll, and eventfd. Ordinary client closure
therefore released producer processes and connection descriptors in this run.

## Repeated DESCRIBE on one connection: reproduced defect

Three sequential DESCRIBE requests for
`rtsp://192.168.1.150/ch0_0.h264?video` on one TCP socket returned SDP containing
**1, 2, then 3 video media entries**, respectively.

Source path:

- pkg/rtsp/server.go Accept fires MethodDescribe for every request.
- internal/rtsp/rtsp.go registers the same connection with AddConsumer each time.
- internal/streams/add_consumer.go adds tracks and appends the consumer again.
- internal/streams/stream.go RemoveConsumer removes only the first matching
  entry. The connection cleanup callback runs once on disconnect.

This establishes duplicate live track registration and a source-level stale
consumer retention path. Unlike normal churn, repeated requests on a single
connection can leave references in the stream's consumer list after disconnect.
RSS per leaked connection was not quantified. Only three requests were used
for the live reproduction to keep its impact bounded.

Fix direction: make repeated DESCRIBE idempotent, with a regression test checking
stable SDP track count and zero retained registrations after disconnect. Define
behavior for changed URLs/media queries explicitly. Preserve the fix as a patch
applied by init.go2rtc; editing only the extracted source does not survive rebuild.

## Additional source findings

1. service.sh calls start_rtsp unconditionally on `rtsp start`. go2rtc's RTSP
   initialization logs and returns on listen failure; the application still waits
   for a signal. Repeated starts can therefore leave redundant daemons after a
   port collision. This was not deliberately triggered on the camera. A start
   guard must also serialize concurrent starts.
2. h264grabber stdout allocation and setvbuf both use sizeof(pointer), yielding
   four bytes on ARM32. This is an unintended buffering/CPU issue, not a proven
   leak. A larger buffer requires explicit frame flushing to preserve latency.
3. h264grabber's inconsistent-header continue path skips sem_write_unlock.
   USE_SEMAPHORE is commented out and the Makefile does not define it, so the
   imbalance is dormant in the current build.

Not covered: long-duration soak, stalled readers, intentional producer death,
TEARDOWN-specific behavior, backchannel churn, and microphone/AAC lifecycle.
