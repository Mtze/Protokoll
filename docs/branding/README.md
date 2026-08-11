# Branding assets

Source art for the Protokoll app icon. Reuse these for a product page or store
listing; do not edit the app icon PNGs in the asset catalog by hand.

- `Protokoll.svg` - vector master (scale to any size for web/print).
- `Protokoll-1024.png` - 1024x1024 raster master.
- `Protokoll.icns` - macOS icon bundle.

The shipping app icon lives in the shared asset catalog at
`Apps/Shared/Resources/Assets.xcassets/AppIcon.appiconset` and is wired into the
Mac, iOS, and watchOS targets via `ASSETCATALOG_COMPILER_APPICON_NAME` in
`project.yml`.
