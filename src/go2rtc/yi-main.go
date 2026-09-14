package main

import (
	"github.com/AlexxIT/go2rtc/internal/app"
	"github.com/AlexxIT/go2rtc/internal/exec"
	"github.com/AlexxIT/go2rtc/internal/rtsp"
	"github.com/AlexxIT/go2rtc/internal/streams"
	"github.com/AlexxIT/go2rtc/pkg/shell"
)

func main() {
	app.Version = "1.9.14"
	app.Init()
	streams.Init()
	rtsp.Init()
	exec.Init()
	shell.RunUntilSignal()
}
