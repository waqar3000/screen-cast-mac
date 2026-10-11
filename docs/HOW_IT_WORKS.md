# How Screen Cast works

This document explains Screen Cast's architecture and the parts of the Cast protocols it implements. Google doesn't publish a specification for Cast Streaming, so everything here comes from reading Chromium's open-source [Open Screen](https://chromium.googlesource.com/openscreen/) library and testing against real devices. It should be useful to anyone building a Cast Streaming sender.

## Overview

```
 ┌────────────────────────── Mac ───────────────────────────┐            ┌──── Chromecast ────┐
 │                                                           │            │                    │
 │  ScreenCaptureKit ──► VideoEncoder (H.264) ─┐             │  UDP: RTP  │  "Chrome Mirroring"│
 │   (+ VirtualDisplay)                        ├► RtpSender ─┼───────────►│   receiver app     │
 │  System audio ─────► AudioEncoder (Opus) ───┘     ▲       │  RTCP ◄────┤   (0F5096E8)       │
 │                                                   │       │            │                    │
 │                          CastStreamingSession ────┘       │            │                    │
 │                                   ▲                       │  TLS: JSON │                    │
 │  DeviceBrowser (Bonjour) ──► CastClient ──────────────────┼───────────►│  receiver-0        │
 └───────────────────────────────────────────────────────────┘            └────────────────────┘
```

There are two channels to the TV:

1. **The control channel** (`CastClient`): a TLS connection to port 8009 using the Cast V2 protocol. It launches the mirroring receiver and negotiates the streams.
2. **The media channel** (`CastStreamingSession`): RTP packets carrying encrypted video and audio over UDP, with RTCP feedback coming back on the same socket.

## Source map

| File | Role |
|---|---|
| `Cast/DeviceBrowser.swift` | Finds Chromecasts with Bonjour (`_googlecast._tcp`). Devices without a screen (speakers, speaker groups) are skipped using the `ca` capability bits. |
| `Cast/CastMessage.swift` | Encodes and decodes the Cast V2 `CastMessage` protobuf by hand. |
| `Cast/CastClient.swift` | The TLS control channel: connect, heartbeat, launch an app, OFFER/ANSWER, stop. |
| `Streaming/CastStreamingSession.swift` | Builds the OFFER, applies the ANSWER, paces packets out over UDP, handles RTCP, sends sender reports, and computes statistics. |
| `Streaming/RtpSender.swift` | Encrypts and packetizes one stream's frames, keeps them for retransmission, and applies receiver feedback. |
| `Streaming/ReceiverFeedback.swift` | Parses the receiver's compound RTCP packets. |
| `Streaming/VideoEncoder.swift` | Hardware H.264 via VideoToolbox, producing Annex B output. |
| `Streaming/AudioEncoder.swift` | 10 ms Opus packets via AVAudioConverter. |
| `Streaming/ScreenStreamer.swift` | ScreenCaptureKit capture of a display and system audio. |
| `Streaming/VirtualDisplay.swift` | Creates the second display with the private `CGVirtualDisplay` API. |
| `Streaming/TestPattern.swift` | A synthetic test card (clock and beeps) for testing without screen capture. |
| `AppModel.swift`, `ContentView.swift` | The SwiftUI app. |

## 1. Finding and controlling the TV (Cast V2)

Chromecasts advertise `_googlecast._tcp` over Bonjour. The TXT record carries the friendly name (`fn`), model (`md`), and a capability bitmask (`ca`, where bit 0 means the device has video output).

The control channel is TLS on port 8009. The Chromecast's TLS certificate is self-signed, so the app accepts it without verification. (Chrome also runs Cast device authentication, a challenge signed with a Google-issued device certificate. This app doesn't, so it trusts any device on the local network that answers as a Chromecast.) Each message is a 4-byte big-endian length followed by a `CastMessage` protobuf:

| Field | Type | Value |
|---|---|---|
| 1 `protocol_version` | varint | 0 |
| 2 `source_id` | string | `sender-0` |
| 3 `destination_id` | string | `receiver-0`, or an app's transport ID |
| 4 `namespace` | string | e.g. `urn:x-cast:com.google.cast.receiver` |
| 5 `payload_type` | varint | 0 (string) |
| 6 `payload_utf8` | string | JSON |

The session goes like this:

1. `CONNECT` to `receiver-0` (namespace `…tp.connection`), then a `PING` every 5 seconds on `…tp.heartbeat`.
2. `LAUNCH` the mirroring receiver, app ID **`0F5096E8`** ("Chrome Mirroring"). The reply is a `RECEIVER_STATUS` containing the app's `transportId` and `sessionId`.
3. `CONNECT` to the transport ID.
4. Send an `OFFER` on `urn:x-cast:com.google.cast.webrtc` and wait for the `ANSWER`. Replies on this namespace match on `seqNum`, not `requestId`.
5. To finish, send `STOP` with the session ID to `receiver-0`.

An unprompted `RECEIVER_STATUS` that no longer lists our session means someone stopped the cast from the TV or another device.

## 2. Negotiating streams (OFFER/ANSWER)

The OFFER describes each stream the sender can send:

```json
{
  "type": "OFFER", "seqNum": 2,
  "offer": {
    "castMode": "mirroring",
    "receiverGetStatus": true,
    "supportedStreams": [
      { "index": 0, "type": "audio_source", "codecName": "opus", "rtpProfile": "cast",
        "rtpPayloadType": 127, "ssrc": 12345, "targetDelay": 100,
        "aesKey": "<32 hex>", "aesIvMask": "<32 hex>", "receiverRtcpEventLog": true,
        "rtpExtensions": ["adaptive_playout_delay"], "timeBase": "1/48000",
        "channels": 2, "bitRate": 128000 },
      { "index": 1, "type": "video_source", "codecName": "h264", "rtpProfile": "cast",
        "rtpPayloadType": 96, "ssrc": 67890, "targetDelay": 100,
        "aesKey": "<32 hex>", "aesIvMask": "<32 hex>", "receiverRtcpEventLog": true,
        "rtpExtensions": ["adaptive_playout_delay"], "timeBase": "1/90000",
        "maxFrameRate": "60", "maxBitRate": 15000000,
        "resolutions": [{ "width": 1920, "height": 1080 }] }
    ]
  }
}
```

The receiver answers with the UDP port, the streams it accepted (`sendIndexes`), and the SSRC it will use for each accepted stream's feedback:

```json
{ "type": "ANSWER", "seqNum": 2, "result": "ok",
  "answer": { "castMode": "mirroring", "udpPort": 10008, "sendIndexes": [0, 1],
              "ssrcs": [12346, 67891], "receiverRtcpEventLog": [0, 1],
              "rtpExtensions": [["adaptive_playout_delay"], ["adaptive_playout_delay"]] } }
```

Things that matter in practice:

- **Keep SSRCs below 2³¹.** A Chromecast silently dropped any stream whose SSRC was 2³¹ or higher. If all of them were, it answered `"Invalid or missing codec on first OFFER"`. Chrome uses 1–50000 for audio and 50001–100000 for video, and so does this app.
- **Payload types 127 (audio) and 96 (video).** Chrome sends these whatever the codec, because some receivers require them.
- **Every stream must be encrypted:** `aesKey` and `aesIvMask` are mandatory.
- **`targetDelay`** is the playout delay in milliseconds: how long after capture the receiver shows a frame.

## 3. RTP packets

Each encoded frame is encrypted, then split across RTP packets of at most 1400 bytes. Every packet starts with a standard 12-byte RTP header, followed by a Cast header:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|V=2|P|X| CC=0  |M|     PT      |        sequence number        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         RTP timestamp                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                             SSRC                              |
+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
|K|R| ext count |   frame ID    |           packet ID           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         max packet ID         | ref frame ID  | extensions... |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- **M** (marker) is set on the frame's last packet.
- **K** marks a key frame. **R** means a reference frame ID follows. A key frame references itself; with H.264 and no B-frames, every other frame references the frame before it. Audio frames are all key frames.
- **Frame ID** travels as its low 8 bits. Both sides expand it relative to IDs they've already seen.
- **Extensions:** the *adaptive playout delay* extension (type 1, 2 bytes: the new delay in ms) changes the receiver's delay mid-stream. It goes in a frame's first packet and is repeated until the receiver's feedback reports the new delay.

The video payload is H.264 in Annex B format (start codes), with SPS and PPS in front of every key frame. Audio is one Opus packet per frame, each covering 10 ms.

### Encryption

Each frame is encrypted on its own with AES-128 in counter mode. The initial counter is the stream's `aesIvMask` with the 32-bit frame ID XOR'd into bytes 8–11 (big-endian). `FrameCryptoTests` checks this against the NIST AES-CTR test vectors.

## 4. Feedback and retransmission (RTCP)

The receiver sends compound RTCP packets back to the sender's UDP port. Each starts with the receiver's SSRC for that stream, which tells the sender which stream the feedback is about. Screen Cast reads:

| Packet | Contents | What the sender does |
|---|---|---|
| Receiver Report (PT 201) | Fraction lost, plus the last sender report's time and how long the receiver held it | Packet loss and round-trip statistics |
| Cast Feedback (PT 206, FMT 15, `CAST`) | **Checkpoint** (every frame up to here received), current playout delay, and NACKs (frame, packet, bitmask of the next 8 packets; packet `0xFFFF` means the whole frame) | Frees stored frames, resends missing packets (at most once per 10 ms each) |
| Picture Loss (PT 206, FMT 1) | The receiver can't decode | Encodes a key frame (at most every 200 ms) |
| Receiver log (PT 204, subtype 2, `CAST`) | Per-frame events: decoded, played out (with how late), packet received | Statistics: frames decoded and played, late frames |

The sender sends an RTCP **Sender Report** (PT 200) for each stream every 500 ms. It ties an RTP timestamp to an NTP wall-clock time, which is how the receiver works out when to play each frame. Both streams use the same origin for their RTP clocks, so audio and video stay in sync.

If the newest frame isn't acknowledged within 100 ms, its last packet is sent again (a "kick-start"). Otherwise, if the whole frame was lost, the receiver wouldn't know to ask for it. If more than 60 video frames go unacknowledged, the sender stops sending until the next key frame.

## 5. Keeping latency low

A frame reaches the TV about 25–35 ms after capture. The rest of the delay is the playout delay the user picks. Getting there needed a few non-obvious steps:

- **The hardware encoder holds each frame until the next one arrives.** On a still screen that can be seconds. If no new frame comes within 25 ms, `VideoEncoder` submits a copy of the last frame, which pushes the real one out. The copy encodes to a few dozen bytes and is sent normally, timestamped just before the frame that eventually pushes it out, so the TV never shows it late. VideoToolbox's low-latency mode avoids the hold but smeared fast-moving text badly.
- **A sharp frame when the screen settles.** While things move, the encoder spends few bits per frame, and once the screen stops it has nothing new to improve. Half a second after the screen goes still, the app sends a key frame of the still image.
- **60 fps capture,** so a frame waits less to be captured and the encoder's hold is shorter.
- **Packet pacing:** video packets go out at most 16 every 2 ms, so a large key frame doesn't overflow the receiver's buffers. Audio and resent packets go first.

## 6. The second display

`VirtualDisplay` uses CoreGraphics' private `CGVirtualDisplay` classes (declared in `Sources/CGVirtualDisplay`) to add a display that macOS treats as a real monitor. It offers 1280×720, 1600×900 and 1920×1080 as HiDPI modes. macOS draws each at twice the resolution and the capture scales it down to 1920×1080, which keeps text sharp. The app waits until the new display reports the chosen size before capturing it. Capturing too early picks up a stale size, and the picture ends up small in the middle of the TV.

## 7. Permissions and signing

Local Network privacy (macOS 15) tracks an app by its executable's Mach-O UUID, which changes with every build. Screen Recording permission tracks the code signature. So that rebuilt apps keep their permissions, `build.sh`:

- pins each architecture's `LC_UUID` to a value derived from the bundle ID, and
- signs ad hoc (unless an Apple Development certificate is available) with a designated requirement that checks only the bundle ID.

The trade-off is that macOS would also trust another ad hoc app claiming the same bundle ID. Builds signed with a Developer ID don't need the second step.

Because the executable's UUID is fixed, os.Logger messages from different builds can't be decoded by the system log (it looks up format strings by UUID). So the app logs with `NSLog`.

## 8. Testing

- `swift test` runs unit tests for the protobuf encoding, the encryption (NIST vectors), the RTP packet layout, and RTCP parsing and retransmission.
- `--test-cast <seconds>` casts a test card (a running clock, plus a beep at the top of each second) to the first TV found, then quits. It needs no Screen Recording permission. It's useful for checking a device, and for measuring delay and lip sync by filming the TV next to a clock.
- The log shows the TV's own statistics every second (see the README's troubleshooting section).
