# Architecture

## Overview

UHF X11 runs an embedded X.Org server in the visionOS application process. X11 clients connect over TCP, X.Org owns protocol and resource semantics, and a custom `hw/visionx` device-dependent layer publishes top-level windows and pixel damage to Swift.

```text
X11 client
    │ TCP :0
    ▼
X.Org DIX / protocol core
    │
    ├── hw/visionx DDX ── CXOrgBridge ── VisionXCore
    │                                      │
    │                                      ├── rootless window lifecycle
    │                                      ├── input and focus
    │                                      └── authorization and fonts
    │
    └── experimental GLX provider ── VisionGL ── Metal
                                           │
                                           ▼
                               native visionOS window surfaces
```

## Modules

### VisionXCore

`VisionXCore` coordinates server lifecycle, MIT-MAGIC-COOKIE-1 setup authorization, network identity, font paths, top-level window state, input translation, runtime diagnostics, and the Swift side of the X.Org bridge.

`DirectTCPXTransport` is a diagnostic setup-authorization transport. The production X11 protocol engine is X.Org.

### CXOrgBridge and `hw/visionx`

`CXOrgBridge` defines the stable C boundary between Swift and the custom DDX. The DDX reports screen and window lifecycle events, metadata, damage, redirected framebuffer snapshots, and experimental GLX operations. Swift sends focus, close, activation, pointer, keyboard, and swap-completion events back to X.Org.

The embedded server uses `-displayfd` to avoid filesystem display locks and `-noreset` to keep the listener alive between client sessions. Shutdown is app-controlled and wakes the server poll loop without blocking the UI thread.

### Rootless Presentation

Mapped top-level X windows are tracked by `RootlessWindowManager`. Ordinary windows route to native visionOS windows; policy can route a surface to the immersive desktop instead. Override-redirect helpers are filtered so invisible toolkit probes do not become native scenes.

The DDX maintains per-window BGRA snapshots. Full copies establish or recover a surface; ordinary repaint uses X.Org Damage rectangles and Metal subregion uploads. SwiftUI carries control state while `MTKView` owns the high-rate pixel presentation path.

### Input

SwiftUI and UIKit event paths translate native coordinates and hardware-key events into X.Org pointer and keyboard events. Pointer coordinates are inverse-transformed when visual presentation effects alter the displayed surface. ICCCM close requests use `WM_DELETE_WINDOW` when supported and fall back to server-side destruction when necessary.

### Fonts

The app bundles indexed X.Org `misc`, `75dpi`, and `100dpi` bitmap fonts. User font packs live in Application Support outside the signed bundle. Only indexed bitmap-font directories are added to the X.Org font path.

### Experimental GLX

The custom provider reuses X.Org request dispatch where practical but avoids desktop GL, Mesa, DRI, glamor, and direct-rendering assumptions. `VisionGL` decodes the supported indirect command subset, tracks fixed-function OpenGL state and display lists, renders through Metal, and publishes completed frames through the same native window path.

The App Store build includes the custom provider, but the runtime default is off. When **Experimental GLX** is disabled, the provider does not register the `GLX` X11 extension. The setting can be changed only while the server is stopped and is applied the next time the server starts.

When enabled, the provider advertises GLX 1.3 with vendor string `UHF X11 VisionGL` and no GLX extension strings. Its renderer implements the documented indirect OpenGL 1.1 fixed-function subset; the advertised surface remains conservative while broader protocol coverage and device performance are established.

## Dependency Policy

X.Org components are pinned and either vendored or checksum-fetched. Cross builds use an isolated static prefix below `.build` so host libraries cannot leak into the visionOS binary. Upstream and bundled-font licenses remain attached to their respective components.
