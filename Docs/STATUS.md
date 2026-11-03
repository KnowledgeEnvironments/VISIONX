# Project Status

Last updated: 2026-10-31

## 1.0 Source Snapshot

- Embedded X.Org 21.1.25 server on visionOS.
- TCP display `:0` with MIT-MAGIC-COOKIE-1 authorization by default.
- Explicit unauthenticated mode for isolated development testing.
- Rootless top-level window mapping to native visionOS scenes.
- Window map, unmap, configure, metadata, damage, focus, close, and destroy handling.
- Damage-driven BGRA-to-Metal presentation with full-surface recovery.
- Pointer, keyboard, hover, focus, and scroll translation.
- Bundled classic X11 bitmap fonts and importable font packs.
- Exact-pixel presentation and configurable CRT-inspired effects.
- Portable Swift unit coverage for core state, authorization, bridge behavior, fonts, input, and VisionGL.

## Experimental

- The App Store build includes the custom GLX provider, disabled by default. Users may enable **Experimental GLX** while the server is stopped; the provider is then advertised on the next server start.
- Indirect GLX discovery, contexts, drawables, command decoding, display lists, and swap coordination.
- OpenGL 1.1 fixed-function rendering through Metal for the implemented command subset.
- Immersive spatial-desktop routing and curved CRT presentation.

Experimental features may be incomplete, slower than intended, or incompatible with clients outside the current smoke suite.

## Not Supported

- DRI, DRI2, DRI3, or direct rendering.
- Mesa, glamor, or hardware-driver loading.
- Unix-domain display sockets in the production server.
- Modern shader-based OpenGL compatibility.
- Encrypted X11 transport or a built-in VPN/tunnel.
- A complete desktop environment or remote-desktop session.

## Snapshot Verification

The 1.0 source snapshot was checked as follows; this records past verification and is not a promise of continuing testing, maintenance, compatibility, or future releases:

- `swift test` passes.
- Shell and Python helpers pass syntax checks.
- An unsigned visionOS target compiles with the available SDK.
- Device-specific behavior is validated separately where hardware is available.
- The public tree contains no signing material, device identifiers, private paths, authorization tokens, or development-network details.
