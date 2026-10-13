# Changelog

## 1.0.1

- Fixed frames sometimes reaching the video encoder out of order, or two at a time. This could happen when the screen changed only now and then, as a second display often does while you work on the main screen. It may be the cause of a crash reported on an M1 Max ([#1](https://github.com/waqar3000/screen-cast-mac/issues/1)).
- On macOS 15, the app now appears in **Screen & System Audio Recording** settings the first time it asks. If it doesn't, the message explains how to add it with **+**.

## 1.0.0

First public release.

- Cast your Mac's screen and sound to a Chromecast using Cast Streaming, the protocol Chrome uses for screen mirroring.
- **Mirror** a screen, or use the TV as a **second display** at 1280×720, 1600×900 or 1920×1080 (HiDPI). You can switch while casting.
- **Delay** settings of 0.05, 0.1 and 0.25 s, adjustable while casting.
- Video at up to 1920×1080 and 60 fps (hardware H.264), with Opus audio.
- Lost packets are resent, and a sharp key frame is sent when the screen settles.
- Live connection panel: quality rating, delay, frame rate, bitrate, Mac processing time, round trip, packet loss, late frames and Wi-Fi.
- `--test-cast` diagnostic mode, and diagnostic logs that include the TV's playback statistics.
- Universal app for Apple Silicon and Intel Macs, on macOS 13 or later.
