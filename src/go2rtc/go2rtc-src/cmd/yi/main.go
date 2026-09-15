package main

import (
	"runtime/debug"

	"github.com/AlexxIT/go2rtc/internal/app"
	"github.com/AlexxIT/go2rtc/internal/exec"
	"github.com/AlexxIT/go2rtc/internal/rtsp"
	"github.com/AlexxIT/go2rtc/internal/streams"
	"github.com/AlexxIT/go2rtc/pkg/shell"
)

const yiMemoryLimit = 12 << 20 // 12 MiB of Go runtime-managed memory

func main() {
	// Yi cameras have only about 60 MiB available to Linux. Keep go2rtc below
	// the memory range that caused system-wide OOM pressure while leaving the
	// normal GOGC=100 policy intact. SetMemoryLimit is a soft runtime limit, so
	// short-lived non-Go mappings can still make RSS slightly exceed this value.
	debug.SetMemoryLimit(yiMemoryLimit)

	app.Version = "1.9.14"
	app.Init()
	streams.Init()
	rtsp.Init()
	exec.Init()
	shell.RunUntilSignal()
}
