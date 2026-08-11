# Branding assets

Source art for the Protokoll app icon. Reuse these for a product page or store
listing; do not edit the app icon PNGs in the asset catalog by hand.

- `Protokoll.svg` - macOS vector master: a padded squircle with a drop shadow on
  a transparent canvas (the Mac Dock shape). Scale to any size for web/print.
- `Protokoll-1024.png` - 1024x1024 raster master of the macOS squircle.
- `Protokoll.icns` - macOS icon bundle.
- `Protokoll-iOS.svg` / `Protokoll-iOS-1024.png` - iOS/watchOS variant: the same
  art rendered **full-bleed and fully opaque** (no rounded corners, no alpha),
  because iOS and watchOS apply their own corner/circle mask and reject icons
  with an alpha channel.

## Why two shapes

macOS Dock icons are padded squircles with their own shadow, so the Mac idiom
uses the squircle art (`mac_*.png`). iOS and watchOS want a full-bleed square
with no transparency; supplying the squircle there would show a shrunken icon
with black corners. The catalog therefore ships the squircle for the `mac`
idiom and the full-bleed opaque `icon_1024.png` for the `ios`/`watchos` idioms.

To regenerate the iOS/watchOS art after editing `Protokoll.svg`, re-run the same
transform (full-bleed background + scaled content) into `Protokoll-iOS.svg`,
then `rsvg-convert` + `magick ... -alpha remove -alpha off` to a 1024 PNG and
copy it over `AppIcon.appiconset/icon_1024.png`.

The shipping app icon lives in the shared asset catalog at
`Apps/Shared/Resources/Assets.xcassets/AppIcon.appiconset` and is wired into the
Mac, iOS, and watchOS targets via `ASSETCATALOG_COMPILER_APPICON_NAME` in
`project.yml`.
