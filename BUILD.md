# Building Spectra

## Prerequisites

- macOS 15 or later on Apple Silicon.
- Xcode 16 or later. This project was built against Xcode 26 and the macOS 26 SDK.
- The Metal Toolchain component. Xcode 26 ships the Metal compiler as a separate download. If a build fails with `cannot execute tool 'metal' due to missing Metal Toolchain`, run:

  ```sh
  xcodebuild -downloadComponent MetalToolchain
  ```

- [XcodeGen](https://github.com/yonyz/XcodeGen) to generate the project from `project.yml`:

  ```sh
  brew install xcodegen
  ```

## Generate the project

The `.xcodeproj` is generated from `project.yml`, so it is not committed. Generate it after cloning and any time you add or move source files:

```sh
xcodegen generate
```

## Build from the command line

```sh
xcodebuild -project Spectra.xcodeproj -scheme Spectra -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

`Scripts/build.sh` wraps the regenerate-and-build loop and filters output down to diagnostics:

```sh
./Scripts/build.sh
```

## Build and run in Xcode

```sh
xcodegen generate
open Spectra.xcodeproj
```

Select the Spectra scheme and run. For a distributable build, set a signing team in the project settings; the command-line build above disables signing for local development.

## First run

1. Spectra launches with a menu bar item and the Studio window.
2. The Effects workspace shows a Screen Recording prompt. Click "Grant Access," approve in System Settings, and Spectra appears in the Screen Recording list.
3. Back in Spectra, click "Spectra is On" in the sidebar to start rendering across the desktop.

Spectra excludes its own windows from capture, so the Studio window and overlay never feed back into themselves.

## Layout

```
project.yml              XcodeGen project definition
Info.plist               Bundle metadata, Screen Recording usage string, .spectra UTI
Spectra.entitlements     Non-sandboxed, hardened runtime
Sources/                 All Swift and Metal source, organized by module
Resources/               Asset catalog (app icon, accent color)
Scripts/build.sh         Regenerate + build + filter diagnostics
```

## Verifying shaders in isolation

Any single Metal file can be compiled on its own against the shared header:

```sh
xcrun metal -c Sources/Shaders/Color.metal -I Sources/Shaders -o /tmp/color.air
```
