# Contributing

Thanks for helping. Bug reports, reports of devices that work (or don't), and pull requests are all welcome.

## Reporting a problem

[Open an issue](https://github.com/waqar3000/screen-cast-mac/issues/new/choose) using the bug report template. It's most useful with:

- your macOS version and Mac model (Apple Silicon or Intel)
- your Cast device (for example "Chromecast with Google TV" or a TV with Chromecast built in)
- what you expected and what happened
- the diagnostic log from right after the problem:

  ```bash
  log show --last 10m --predicate 'process == "ScreenCast" AND eventMessage BEGINSWITH "["' > screen-cast-log.txt
  ```

  The log includes your Cast device's name and its address on your local network. Remove anything you'd rather not share.

## Development setup

You need Xcode 15 or later.

```bash
git clone https://github.com/waqar3000/screen-cast-mac.git
cd screen-cast-mac
swift test          # unit tests
./build.sh --open   # build and launch the app
```

To edit in Xcode, open `Package.swift`. Run the app with `./build.sh --open` rather than from Xcode: it needs the app bundle's Info.plist for its permission prompts, and `build.sh` signs it so macOS remembers those permissions between builds. [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md) explains the architecture and the protocol.

## Testing changes

- **Unit tests:** `swift test` covers the protocol code (protobuf, encryption, RTP and RTCP). Please add tests when you change those parts.
- **On a real TV:** `open "build/Screen Cast.app" --args --test-cast 20` casts a test card for 20 seconds without needing Screen Recording permission. The log then shows the TV's own statistics every second: frames decoded and played, how late they were, resends, round trip and loss.
- **Latency:** if you change anything in the capture, encode or send path, compare the log's `Mac pipeline` and `TV … off target` numbers before and after.

## Pull requests

- Keep each pull request focused on one change, and describe what you tested and on which hardware.
- Match the style of the surrounding code: clear names, small focused types, and comments that explain *why* rather than *what*.
- Make sure `swift build` and `swift test` pass; GitHub Actions runs both on every pull request.
- By contributing, you agree that your contribution is licensed under the project's [MIT License](LICENSE).
