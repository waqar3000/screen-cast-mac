# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue. Use GitHub's [private vulnerability reporting](https://github.com/waqar3000/screen-cast-mac/security/advisories/new) for this repository. You should hear back within a week.

## What's in scope

Screen Cast captures your screen and sound and sends them over your local network, so these are the areas that matter most:

- how the app handles messages and packets from devices on the network
- the encryption of the media stream
- anything that could expose screen contents to a device other than the one you picked

## Known limitations

These are documented design limits rather than vulnerabilities:

- **No Cast device authentication.** The app accepts the Chromecast's self-signed TLS certificate and doesn't run Cast device authentication. Another device on your local network that pretends to be a Chromecast could receive the stream if you pick it.
- **Ad hoc signing with a bundle-ID requirement.** Builds without an Apple Development certificate use a designated requirement that checks only the bundle ID, so macOS keeps permissions across rebuilds. macOS would also trust another ad hoc app claiming the same bundle ID. See [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md#7-permissions-and-signing).
