# Building and Testing

## Requirements

- macOS with Xcode, a visionOS SDK, and Xcode's Metal Toolchain component.
- Swift 6.
- Meson, Ninja, `pkg-config`, and `make` for the embedded X.Org build.
- An Apple Vision Pro or visionOS simulator for application testing.

Homebrew and MacPorts both provide the non-Apple build tools. No signing certificate, provisioning profile, team identifier, or device identifier is stored in this repository.

If Xcode reports that `metal` is unavailable, install the Metal Toolchain from Xcode's Components settings before building the app target.

## Clean Checkout

The supporting X.Org libraries are vendored. The much larger upstream X.Org Server tree is reconstructed around the tracked VisionX integration files by:

```sh
Scripts/fetch-xorg-server.sh
```

Downloads are pinned by version and SHA-256 checksum. Existing tracked integration files are not overwritten.

## Swift Packages

Run all portable unit tests:

```sh
swift test
```

The package exposes three libraries:

- `VisionXCore` — server lifecycle, authorization, window routing, input, fonts, and bridges.
- `VisionGL` — indirect GLX/OpenGL compatibility state and Metal rendering.
- `CXOrgBridge` — the C ABI between X.Org and Swift.

## Embedded X.Org

Build the static dependencies and VisionX X.Org backend for a device:

```sh
Scripts/build-xorg-visionos.sh
```

The output is written below `.build/`. To run the phases separately:

```sh
Scripts/build-xorg-deps-visionos.sh
Scripts/configure-xorg-visionos.sh
meson compile -C .build/xorg-server-xros Xvisionx visionx_xorg_backend
```

Normal builds disable stock X.Org GLX and include the custom VisionX provider instead. The custom provider is runtime-gated and disabled by default because desktop GL, DRI, and Mesa assumptions do not apply to visionOS.

## Unsigned App

An unsigned compile is useful for checking the Xcode target without local signing state:

```sh
xcodebuild build \
  -project VisionX.xcodeproj \
  -target VisionX \
  -configuration Debug \
  -sdk xros \
  CODE_SIGNING_ALLOWED=NO
```

## Device Build

Find your values locally, then pass them through the environment:

```sh
xcrun devicectl list devices

export VISIONX_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export VISIONX_DEVICE_ID="YOUR_DEVICE_ID"
Scripts/build-device.sh
```

`VISIONX_BUNDLE_ID`, `VISIONX_CONFIGURATION`, and related build variables may also be overridden. The script builds the embedded backend, asks Xcode to sign with your local Apple Development identity, and installs the app on the selected device.

Create an App Store archive with:

```sh
export VISIONX_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
Scripts/archive-app-store.sh
```

Archives and signing products remain ignored local artifacts.

## Simulator

Build, install, and launch on the most recently listed Apple Vision Pro simulator:

```sh
Scripts/build-simulator.sh
```

Set `VISIONX_SIMULATOR_ID` to choose a particular simulator. The helper launches a development configuration bound to loopback with unsafe authentication and experimental GLX enabled, so it is not representative of the normal app defaults.

Run the automated simulator smoke harness with:

```sh
Scripts/smoke-simulator-clients.sh
```

Artifacts are written below `.tmp/client-smoke/` and are intentionally ignored.

## Runtime Diagnostics

To copy the app's runtime log from a device:

```sh
export VISIONX_DEVICE_ID="YOUR_DEVICE_ID"
Scripts/pull-runtime-log.sh
```

Review logs and screenshots for network addresses, authorization cookies, local paths, and device identifiers before sharing them publicly.
