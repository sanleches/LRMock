# RawLight

A local-first, non-destructive RAW photo library and editor for **iPad** and **Mac**, built with SwiftUI, SwiftData, and Core Image.

RawLight combines fast folder-based organization with a professional, GPU-accelerated develop pipeline — managed like a Lightroom catalog, with every edit stored as a portable, non-destructive recipe. It is native-first: decoding and rendering go through Apple's own imaging stack, so there is no desktop engine to port and no cloud account to create.


## Highlights

- **Managed library (catalog folder).** Originals are copied into a generation-based library (`Originals/`, `Recipes/`, `Catalog/`, `Trash/`) with a complete SHA-256 content digest. Referenced (in-place) folders are also supported.
- **Non-destructive by design.** The original file is never modified. Every edit lives in a versioned `.rawlight` recipe (JSON) saved next to the catalog, plus a fast SwiftData index.
- **RAW-native development.** RAW files are developed through Apple's `CIRAWFilter` (true Kelvin white balance, EV exposure, native noise reduction/sharpening); JPEG/HEIC/TIFF/PNG are handled directly.

## Develop tools

- **Light** — exposure, contrast, highlights, shadows, whites, blacks
- **Color** — white balance (temp/tint), vibrance, saturation, black & white with channel mix
- **Tone curves** — master (luminance) + per-channel R/G/B, smooth monotone-cubic interpolation
- **Color mixer (HSL)** — 8 hue bands × hue/saturation/luminance, applied via a GPU color-cube LUT
- **Color grading** — 3-way shadows/midtones/highlights split toning
- **Effects** — texture, clarity, dehaze, vignette, grain
- **Detail** — sharpening (amount/radius), luminance + color noise reduction
- **Geometry** — crop, aspect presets, straighten, rotate, flip
- **Local / selective adjustments**, undo/redo history, and copy/paste of develop settings between photos

## Editor experience

- Live histogram, dense tabbed inspector with compact sliders (tap a value to type it, double-tap to reset)
- Before/After toggle and press-and-hold to peek the original
- Pinch/trackpad zoom + pan, double-tap to toggle 1x/2x
- Progressive rendering (fast interactive pass while dragging, full-quality when you pause)

## Export

JPEG / HEIC / TIFF / PNG, with color space (sRGB / Display P3 / Adobe RGB), resize, and quality. Save to a folder (native Save panel on macOS, document exporter on iPadOS) or Share. Export always re-renders from the original + recipe and never touches the source.

## Architecture

```
LRMock/
  App/            Composition root, shared services
  Core/
    Models/       SwiftData catalog models + value types (DevelopSettings, ...)
    Catalog/      SwiftData schema, versioned migrations, library mutations
    Storage/      Managed library layout, import, bookmarks, recipes, trash, digests
    Imaging/      Core Image pipeline, tone-curve LUT, color-cube engine, RAW decode
    Metadata/     EXIF extraction
  Features/
    Library/      Sidebar, grid, loupe, inspector, crop, export
    Shared/       Theme, async thumbnails, develop preview, histogram, sliders
```

- **UI never touches Core Image or the filesystem directly** — it renders through a `RawPipeline` protocol and goes through storage services, so the imaging backend can evolve independently.
- The catalog lives *inside* the library generation, so the whole library (originals + recipes + index) is one relocatable unit.
- `DevelopSettings` uses a lenient decoder, so adding fields never breaks existing recipes.

## Requirements

- Xcode with the iOS/macOS SDKs for the deployment target in the project (currently iPadOS/macOS 26.4)
- Device families: iPad, Mac (Designed for iPad / native), Apple Vision Pro

## Build & run

Open `LRMock.xcodeproj` in Xcode, choose an **iPad simulator** or **My Mac**, and Run.

From the command line, the project supports multiple platforms, so restrict the SDK to avoid cross-platform destination resolution:

```bash
# iPad simulator
xcodebuild -project LRMock.xcodeproj -target LRMock \
  -sdk iphonesimulator -configuration Debug \
  SUPPORTED_PLATFORMS=iphonesimulator build

# macOS
xcodebuild -project LRMock.xcodeproj -target LRMock \
  -sdk macosx -configuration Debug SUPPORTED_PLATFORMS=macosx build
```

For smooth, real-time editing, run a **Release** build on a real device — Debug + Simulator numbers are not representative.

## Tests

Unit, integration, and performance tests live in `LRMockTests` (Swift Testing + XCTest):

```bash
xcodebuild test -project LRMock.xcodeproj -scheme LRMock \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:LRMockTests SUPPORTED_PLATFORMS=iphonesimulator
```

Coverage includes develop-settings round-trips and lenient decoding, tone-curve monotonicity, the color-cube engine, content digests/fingerprints, catalog schema migrations, the imaging pipeline (exposure, B&W, export), and render/algorithm benchmarks.

## License

Released under the [MIT License](LICENSE).
