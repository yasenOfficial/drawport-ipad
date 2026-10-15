# DrawPort (experimental iPadOS 18 port)

Based on the MIT-licensed [Draw reference app](https://github.com/DebelToni/Draw), upstream commit `34e4ed1`. Original copyright is retained in [LICENSE](LICENSE).

This is an **experimental** iPad UI port, not a production note-taking app. The upstream Xcode project targets iOS 26 and includes a private sync/AI stack that is **not** deployed here. This SwiftPM adaptation compiles with `xtool` for iPadOS 18.0+ but has not been validated for feature parity on all devices. `AIClient.swift` contains an intentionally invalid `.example.invalid` endpoint; sync and AI must be separately configured with a trusted backend. Do not use it to store important notes without your own tested backup.

Current UI prototype: configurable toolbar placement (default left), top notebook and numbered-page tabs, compact ink colors with long-press color picker, eraser mode chooser, page overview with numbers, optional Pencil squeeze palette, and a separate opt-in shape mode. Shape recognition is experimental; it does not modify ordinary pen strokes. Existing paper patterns remain in saved documents, but the pattern toggle is hidden and new pages default to blank.

## Build on Linux

Use Swift 6+ with an iPadOS SDK and [xtool](https://github.com/xtool-org/xtool):

```bash
xtool dev build --ipa
```

This produces an **unsigned** IPA. Update `xtool.yml` to your own stable bundle ID and sign it yourself before installing. Neither Apple credentials nor device pairing records belong in this repository. The iPadOS 18 fallback in `PortablePage.swift` rejects stroke thresholds that only iOS 26 can represent rather than silently changing geometry. There are no compiled or real-device regression tests for this fork yet.

## Limitations

No bundled server, sync account, Apple sign-in, signed IPA, provisioning profile, 2FA automation or refresh service. Installing an updated IPA without preserving and backing up the existing app container may lose notes; back up before testing updates.
