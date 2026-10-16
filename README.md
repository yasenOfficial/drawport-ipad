# DrawPort (experimental iPadOS 18 port)

Based on the MIT-licensed [Draw reference app](https://github.com/DebelToni/Draw), upstream commit `34e4ed1`. Original copyright is retained in [LICENSE](LICENSE).

This is an **experimental** iPad UI port, not a production note-taking app. The upstream Xcode project targets iOS 26 and includes a private sync/AI stack that is **not** deployed here. This SwiftPM adaptation compiles with `xtool` for iPadOS 18.0+ but has not been validated for feature parity on all devices. `AIClient.swift` contains an intentionally invalid `.example.invalid` endpoint; sync and AI must be separately configured with a trusted backend. The restored AI button explains that it is unavailable when no service is configured; it does not send notes to the placeholder endpoint. Do not use it to store important notes without your own tested backup.

Current UI prototype: dark chrome with warm-white paper, configurable toolbar placement (default left) and hideable controls, notebook-only tabs and previous/next/new-page buttons in the top bar, a single overview button opening a right-side scrollable page overview with multi-select and confirmed deletion (no Deleted pages section), a confirmed Delete notebook action in the document menus, a 44-point top bar with a matching dark status-bar area and a continuous dark side-toolbar corner against the warm-paper bottom edge, a custom grid/wheel ink palette, reserved purple question/context ink, an eraser chooser, a squeeze-only curved custom Pencil palette without a persistent dock (core tools, colors and a configurable circled-plus menu), long-press stroke-width menus for pen/highlighter/Shapes, and both explicit Shape mode and a Pencil end-of-stroke hold-to-snap gesture. Tapping one stroke with Selection opens a contextual menu for copy-as-image, cut, duplicate, delete, resize, style and sharing an image. The custom palette is a visual prototype; actions, alignment and persistence still need individual iPad checks. The optional native-picker comparison mode is not the default. Multi-page deletion and layout also require on-device testing. Deletion removes page/notebook references after confirmation, without a recovery section; a blank page is created if all active pages are removed. Preexisting legacy deleted-page metadata is not purged by this UI change. Shape recognition and gesture interoperability remain experimental; they are not equivalent to Noteful’s multi-object lasso implementation. Ordinary pen strokes are only auto-snapped after a Pencil hold. Patterned-paper controls and pattern rendering are removed (including previews/exports); legacy metadata is kept for compatibility, and new pages are blank.

## Local study tools (experimental)

The notebook options menu offers offline interactive linear/quadratic/sine graphs with an editable parameter slider and values table. Graphs live in atomic, page-keyed sidecars under the app's local `InteractiveGraphs` directory; an individual graph exports as self-contained interactive HTML. These graph sidecars are **not yet included in DrawPort sync or notebook PDF exports**; back up the app container before relying on them. The PDF reference library imports source documents locally, supports text search and highlighted exact matches, and does not upload imports. Scanned-image PDF pages need OCR before text search can locate a quotation. These are local building blocks, **not AI-generated corrections, automatic citations or a deployed AI service**.

A user-provided opaque Sigma app icon is stored at `branding/AppIcon.png`. The current Linux `xtool` cannot compile an asset catalog; a local private signing stage can add `AppIcon.png` and corresponding Info.plist keys **before signing**. This repository does not contain the private signer, a signed IPA, or account information. The display name and bundle identifier remain DrawPort pending a naming decision.

## Build on Linux

Use Swift 6+ with an iPadOS SDK and [xtool](https://github.com/xtool-org/xtool):

```bash
xtool dev build --ipa
```

This produces an **unsigned** IPA. Update `xtool.yml` to your own stable bundle ID and sign it yourself before installing. Neither Apple credentials nor device pairing records belong in this repository. The iPadOS 18 fallback in `PortablePage.swift` rejects stroke thresholds that only iOS 26 can represent rather than silently changing geometry. There are no compiled or real-device regression tests for this fork yet.

## Limitations

No bundled server, sync account, Apple sign-in, signed IPA, provisioning profile, 2FA automation or refresh service. Installing an updated IPA without preserving and backing up the existing app container may lose notes; back up before testing updates.
