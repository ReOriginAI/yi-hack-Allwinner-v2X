# NanoTTS for yi-hack

This module packages the user-supplied ARM-musl NanoTTS binary and Pico language data for offline text-to-speech on the camera.

Installed files:

- `/tmp/sd/yi-hack/bin/nanotts`
- `/tmp/sd/yi-hack/bin/tts` convenience wrapper
- `/tmp/sd/yi-hack/usr/share/pico/lang/*` voice data

The `tts` wrapper streams NanoTTS raw PCM16LE/16 kHz/mono output directly to the existing `speaker stream pcm` helper, so it does not require ffmpeg/sox or a temporary audio file. The wrapper serializes TTS requests, while the speaker helper's own semaphore prevents collision with a live two-way-audio/backchannel stream.

Example:

```sh
tts -v en-US --speed 0.9 "Motion detected at the front door"
```

Supported voices: `en-US`, `en-GB`, `de-DE`, `es-ES`, `fr-FR`, `it-IT`.
