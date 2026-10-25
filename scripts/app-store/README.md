# App Store media tooling

These scripts use native Debug simulator fixtures, CoreGraphics/CoreText, Python and Ruby standard libraries, and an optional local FFmpeg executable. They do not add app dependencies. Run from the repository root on macOS with Xcode, compatible iPhone/iPad Simulator runtimes, and resolved Swift packages.

## Capture and compose

```sh
mkdir -p output/app-store/2026-10
cp scripts/app-store/metadata.example.json output/app-store/2026-10/metadata.json
python3 scripts/app-store/capture.py --previews --ffmpeg /path/to/ffmpeg
swift scripts/app-store/render.swift
```

Capture creates and cleans up its own simulators. Use `--app /path/to/Debug.app` to reuse a build or omit `--previews` to capture screenshots only. Its fixtures use fictional hosts and output, bypass cloud/keychain/library access, and are excluded from Release builds. `scenes.json` is copied to the output folder on first capture. Edit the copy for alternate screenshot headlines.

`render.swift` expects optional creative image sources at `sources/header-generated.png` and `sources/search-generated.png` for separate header/search artwork. Supply artwork you have the right to publish. The screenshot content itself comes from real native captures. Preview export requires FFmpeg with H.264/AAC support; it is a local production tool, not an app dependency.

## Validate and upload

```sh
ruby scripts/app-store/upload.rb --validate
ruby scripts/app-store/test_upload.rb
```

Set `ASC_KEY_ID`, `ASC_ISSUER_ID`, and optionally `ASC_KEY_PATH` in your local environment. The default key path is `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8`. Never commit the private key, environment values, generated API records, or local signing material. The key needs App Store Connect permissions for the app and editable listing.

```sh
ruby scripts/app-store/upload.rb --inspect
ruby scripts/app-store/upload.rb --upload
# For copy/URL changes after media has been uploaded:
ruby scripts/app-store/upload.rb --metadata-only
```

The uploader resolves placement identifiers and limits from Apple’s reference catalog, validates dimensions and provenance, uploads images/videos, orders screenshots and previews separately, and reads back metadata and placement IDs. State files allow an interrupted run to resume without duplicating successful assets. It does not submit a review or release an app. Confirm the draft version in App Store Connect before running; update the example metadata and public URLs for your own fork.

Generated media, diagnostics, API responses, and receipts live under the ignored `output/` directory. The public README uses only selected screenshots copied into `docs/assets/`.
