# Third-Party Components

UHF X11 uses pinned X.Org components and bitmap fonts. These files retain their upstream copyright and license terms; the top-level MIT license applies only to project-owned work.

## Source Components

| Component | Version | Upstream |
| --- | ---: | --- |
| X.Org Server | 21.1.25 | [xorg-server-21.1.25.tar.xz](https://www.x.org/releases/individual/xserver/xorg-server-21.1.25.tar.xz) |
| xtrans | 1.6.0 | [xtrans-1.6.0.tar.xz](https://www.x.org/releases/individual/lib/xtrans-1.6.0.tar.xz) |
| pixman | 0.46.0 | [pixman-0.46.0.tar.xz](https://www.cairographics.org/releases/pixman-0.46.0.tar.xz) |
| libXau | 1.0.12 | [libXau-1.0.12.tar.xz](https://www.x.org/releases/individual/lib/libXau-1.0.12.tar.xz) |
| libfontenc | 1.1.8 | [libfontenc-1.1.8.tar.xz](https://www.x.org/releases/individual/lib/libfontenc-1.1.8.tar.xz) |
| libxkbfile | 1.1.3 | [libxkbfile-1.1.3.tar.xz](https://www.x.org/releases/individual/lib/libxkbfile-1.1.3.tar.xz) |
| libXfont2 | 2.0.9 | [libXfont2-2.0.9.tar.xz](https://www.x.org/releases/individual/lib/libXfont2-2.0.9.tar.xz) |

The support libraries are vendored for reproducible cross compilation. The upstream X.Org Server tree is excluded because of its size; `Scripts/fetch-xorg-server.sh` downloads the pinned archive, verifies its SHA-256 checksum, and fills in the upstream files without replacing the tracked `hw/visionx` integration.

Each vendored source directory contains its upstream license file. Copies needed in the app bundle are under `Apps/VisionX/Resources/ThirdPartyLicenses/Components`.

Vendored directories retain upstream build and test files so their source distributions remain recognizable. Those upstream tests are disabled in the visionOS cross build and were not part of the project's release gate unless specifically reported otherwise.

## Fonts

The app bundles X.Org-distributed bitmap fonts from the `misc`, `75dpi`, and `100dpi` families. Corresponding license texts are under `Apps/VisionX/Resources/ThirdPartyLicenses/Fonts`, and the assembled notice is `Apps/VisionX/Resources/ThirdPartyNotices.txt`.

## Updating

When changing a component version:

1. Update all version references in the fetch and build scripts.
2. Replace the pinned SHA-256 checksum with the digest of the official archive.
3. Rebase and review the `hw/visionx` integration against upstream changes.
4. Refresh bundled license texts and notices.
5. Run the Swift tests, cross build, unsigned app build, and relevant smoke tests.
