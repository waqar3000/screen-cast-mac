# Third-party notices

Screen Cast is MIT-licensed (see [LICENSE](LICENSE)). It includes, or was built with reference to, the following.

## Chromium: virtual display declarations

[`Sources/CGVirtualDisplay/include/CGVirtualDisplay.h`](Sources/CGVirtualDisplay/include/CGVirtualDisplay.h) declares macOS's private `CGVirtualDisplay` classes. The declarations are adapted from Chromium's [`ui/display/mac/test/virtual_display_util_mac.mm`](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/ui/display/mac/test/virtual_display_util_mac.mm), which is distributed under this license:

```
Copyright 2022 The Chromium Authors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google LLC nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Open Screen: Cast Streaming reference

The Cast Streaming code here is an independent Swift implementation, and no Open Screen code is included. The wire formats (RTP and RTCP layout, the OFFER/ANSWER messages, frame encryption) were worked out by reading Chromium's [Open Screen](https://chromium.googlesource.com/openscreen/) library, which is under the same BSD-style license as above (copyright The Chromium Authors).

## Test vectors

The AES-CTR test in `Tests/ScreenCastTests/FrameCryptoTests.swift` uses the published example from NIST Special Publication 800-38A, Appendix F.5.1.

## Trademarks

Google, Chromecast and Google Cast are trademarks of Google LLC. Apple, Mac and macOS are trademarks of Apple Inc. They're used here only to describe what the app works with. This project isn't affiliated with, sponsored by or endorsed by Google or Apple.
