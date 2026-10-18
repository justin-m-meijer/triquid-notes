# Triquid Notes

A native client for self-hosted [Trilium](https://github.com/TriliumNext/Trilium) notes, for iPhone,
iPad and Mac (as the iPad app on Apple silicon). Made by [Justin Meijer](https://www.justinmeijer.nl)
as a hobby project.

- App Store: https://apps.apple.com/app/id6816314389
- Website: https://www.justinmeijer.nl/apps/triquid-notes/
- Questions, ideas or bugs: info@justinmeijer.nl, or open an issue here.

Triquid Notes is a fork of [Trinote](https://github.com/StephenArg/Trinote) by StephenArg. That is why
the code and the Xcode targets are still called `Trinote`.

## Features

- Signs in like the Trilium web app (password, optional TOTP, or SSO), not through ETAPI
- Browse the full note tree, including cloned notes that appear in more than one place
- Read and edit text, code, image and file notes; create and delete notes
- Full-text search through your server
- Attachments: upload from Photos or Files, download, share
- In-app previews of Office documents, ODF, RTF and EPUB (Trilium 0.105+, Quick Look on older servers)
- Share extension: send web pages, text, images and files from other apps into Trilium
- Offline cache of the tree and recently opened notes
- Several servers, with switching between them

## Building it yourself

You need:

- A Mac with **Xcode 26** or later (the app targets iOS 26 and uses Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), which generates the Xcode project from `project.yml`

```bash
brew install xcodegen
git clone https://github.com/justin-m-meijer/triquid-notes.git
cd triquid-notes
xcodegen generate
open Trinote.xcodeproj
```

Then:

1. Select the **Trinote** scheme and an iOS 26 simulator, and press **⌘R**. The simulator needs no signing.
2. To run on your own device, open **Signing & Capabilities** for both the **Trinote** and
   **TrinoteShare** targets, choose your own team, and change the bundle identifiers
   (`com.justinmeijer.nl.liquid-notes` and `…liquid-notes.fileshare`) to ones of your own.

Do not edit the generated `Trinote.xcodeproj` by hand: change `project.yml` and run `xcodegen generate`
again. Swift Package Manager fetches the one dependency, Highlightr, on the first build.

## Connecting to your server

You need a self-hosted Trilium server, version 0.95 to 0.106.

- **Password:** enter the server address you use in the browser and your Trilium password. TOTP works.
- **SSO (OpenID / OAuth)**, e.g. Authelia, Authentik, Keycloak or PocketID: this needs a small one-time
  addition on your server. See [docs/sso-setup.md](docs/sso-setup.md).
- **Self-signed certificate:** install and trust your CA on the device first
  (Settings → General → VPN & Device Management).

Protected notes still need your Trilium protected-notes password after you sign in. They can be read
but not created in the app.

## Where things are

```
Trinote/App/          app entry point and navigation
Trinote/Core/         API client, sync, cache, models and other shared logic
Trinote/Features/     the screens: tree, note view and editor, search, settings, …
Trinote/Resources/    Info.plist, assets, translations and the bundled web editors
TrinoteShare/         the share extension
TrinoteShared/        code used by both the app and the share extension
project.yml           XcodeGen project definition
```

## License

Licensing is mixed. Files that come from Trinote stay under the Mozilla Public License 2.0, and the
files written for Triquid Notes are under the PolyForm Noncommercial License 1.0.0. See
[LICENSE.md](LICENSE.md) for which is which, and
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the bundled libraries.

Triquid Notes is not affiliated with or endorsed by the Trilium project.
