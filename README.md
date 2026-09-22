<h1 align="center">DuoFrameSimulator</h1>

<p align="center">
  Preview your app's layout at <b>iPhone Duo</b> display sizes, today, without waiting for the Xcode 27.1 Duo simulator.
</p>

<p align="center">
  <img alt="Platform iOS 17+" src="https://img.shields.io/badge/platform-iOS%2017%2B-blue">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-orange">
  <img alt="DEBUG-only" src="https://img.shields.io/badge/config-DEBUG--only-lightgrey">
</p>

<p align="center">
  <img width="760" alt="The simulator running an app in the Duo Inner Split View half pose, with the presets menu and Options submenu open over the framed window and its Split View companion pane." src="docs/preview.png">
</p>

A drop-in Swift package that reframes your running app to a chosen iPhone Duo footprint: the real size, safe
area, size classes and corner shape the fold would report. It hosts your actual root view controller, so what
you see is your app laying out under Duo geometry, not a mockup. One call, no app-specific code, and it
compiles to nothing in release builds.

## Highlights

- **The Duo display poses** plus a shelf of released iPhone form factors and a custom size.
- **Faithful geometry** where it counts: size, safe-area insets, size classes, and the real production resize
  path (frame changes fire the same trait and safe-area callbacks a live fold would).
- **Reframes the window, not the content**, so `.sheet`, `.fullScreenCover`, alerts and popovers land inside the
  footprint too.
- **Match physical size**, **Display Zoom** and **Override `UIScreen.bounds`** for the awkward edge cases.
- **Cosmetic vertical bars**: a Duo-style side strip with a fake Dynamic Island, live clock, status glyphs and
  your app's real nav and tab items, rehomed and still interactive.
- **Draggable menu button** that snaps to any edge, hidden behind a shake gesture, off by default in release.

## Requirements

| | |
|---|---|
| Platform | iOS 17+ |
| Configuration | DEBUG only (empty module otherwise) |
| Best on | iPad (iPad mini ideal); works on any device |

Runs anywhere. On iPhone the larger Duo frames scale down to fit the screen, so you still get the layout, just
not at physical size. For a true-to-size preview run on an iPad, where the frame renders at 1:1 or better. The
iPad mini is the sweet spot: its density error errs pessimistic, so a marginal control that passes there passes
on the Duo. Running on an iPad host needs an iPad-capable build (`TARGETED_DEVICE_FAMILY = 1,2`); for live
host-window resizing, switch the iPad to **Windowed Apps** in Settings → Multitasking & Gestures.

## Installation

Add the package in Xcode (**File → Add Package Dependencies…**) using the URL, and link the `DuoFrameSimulator`
product to your app target:

```
https://github.com/appoly/iPhoneDuoFrameSimulator
```

Or in a `Package.swift`:

```swift
.package(url: "https://github.com/appoly/iPhoneDuoFrameSimulator", from: "1.0.0")
```

Then call `install()` once before the first window appears, under `#if DEBUG`:

```swift
#if DEBUG
import DuoFrameSimulator
#endif

// SwiftUI App.init(), or application(_:didFinishLaunchingWithOptions:)
#if DEBUG
DuoFrameSimulator.install()
#endif
```

That's the whole integration. Every app window's root is re-parented under the simulator; UIKit's own windows
(keyboard, alerts) are left alone.

<details>
<summary><b>Optional: rebuild on screen-metric changes</b></summary>

If your app sizes anything from `UIScreen.main` inside SwiftUI bodies, add the rebuild modifier to your
`WindowGroup`'s root content. Display Zoom and the bounds override then take effect without a relaunch, by giving
the tree a new identity so every `body` re-runs (navigation and `@State` reset, exactly as a real relaunch would):

```swift
WindowGroup {
    RootView()
        #if DEBUG
        .duoFrameRebuildOnScreenMetricsChange()
        #endif
}
```
</details>

> [!NOTE]
> The whole package is wrapped in `#if DEBUG`, so it compiles to an empty module in release builds. Xcode only
> builds a package in Debug for configurations whose name contains "Debug", so a custom config like "Staging" gets
> the empty module and won't compile the call sites. Keep them under your own `#if DEBUG`.

## Using it

The menu lives on a **floating button** that mirrors the iPad window controls. Drag it anywhere; it snaps to the
nearest edge and remembers where you left it. It's **hidden by default** and toggled with a **shake gesture**
(Device → Shake in the Simulator). Pass `install(showsButton: true)` to start visible.

### Poses

| Preset | Size (pt) | Size classes |
|---|---|---|
| Duo Outer · Landscape | 678 × 466 | Compact × Compact |
| Duo Outer · Portrait | 466 × 678 | Compact × Regular |
| Duo Inner · Landscape | 951 × 669 | Regular × Regular |
| Duo Inner · Portrait | 669 × 951 | Regular × Regular |
| Duo Inner · Split View half | 475 × 669 | Compact × Regular |

An **Other sizes** submenu covers released iPhones (SE, mini, iPhone, XR, Plus, Pro, Pro Max) and a custom size,
as a general "other device" simulator. Those are plain phones: compact width, their own safe area, uniform
corners, no Duo side controls.

### Options

| Option | Default | What it does |
|---|---|---|
| Override size classes | On | Reports the pose's size classes to `NavigationSplitView`, adaptive presentations and `horizontalSizeClass` checks |
| Report phone idiom | Off | Forces `.phone` idiom (UIKit honours it inconsistently) |
| Match physical size | Off | Scales the frame so a point renders at the simulated device's real physical size |
| Display Zoom | Off | Lays out at the device's zoomed point size and swizzles `UIScreen.nativeScale` to match |
| Override `UIScreen.bounds` | Off | Reports the frame size from `UIScreen.bounds` (can misplace the keyboard and alerts) |
| Simulate vertical bars | On | Hides the system bars and draws the Duo side strip with the rehomed items |
| Adapt status glyph colours | Off | Samples the content under the clock and network glyphs to flip them black or white; re-renders the app content on each sample, so it carries a CPU cost |

### Fit

The frame fits to the whole scene: the physical screen on iPhone, the window on iPad (so it follows Split View,
Stage Manager and live resizes). A frame the size of the scene renders at 1:1; a smaller one renders at true
point size, centred with a border; only a larger one scales below 1. So on a 17 Pro, iPhone Pro fills the screen,
iPhone SE is a bordered 1:1, and iPhone Pro Max scales down to fit.

Settings persist in `UserDefaults`, so your last preset survives relaunches. They can also be forced at launch
with `-DuoFrameSimulator.settings <base64-json>` for scripted screenshots.

## How the framing works

<details>
<summary><b>Why the window, not the content</b></summary>

The obvious approach, transforming the app's view inside a full-screen container, works for the app itself but
not for `.sheet` / `.fullScreenCover` / alerts / popovers: UIKit presents those in a transition view attached to
the *window*, above the container, so they ignore the transform and fill the whole screen.

Framing the window instead puts every presentation inside the footprint. It does *not* change the window's scene, which
iOS exposes no API for (`GeometryPreferences.iOS` carries only orientation, `sizeRestrictions` only clamps a user
drag). Instead it sets the window's own `bounds`, `transform` and `center` within the scene.
</details>

<details>
<summary><b>Safe area</b></summary>

The framed window inherits little or none of the host's safe area (a sub-screen window usually reports zero), so
the hosted root is given `additionalSafeAreaInsets` equal to the faked Duo inset, clamped up to the host's real
overlap where the footprint still reaches a hardware region. There's no transform between the controller's view
and the window, so the child inherits the window's own insets normally.
</details>

<details>
<summary><b>Vertical bars, corners and the camera cutout</b></summary>

**Vertical bars.** With side controls on a pose, the strip draws a fake Dynamic Island, the clock and the
combined Wi-Fi/cellular glyph (metrics measured off Apple's HIG "Designing for iPhone Duo" screenshots), then the
nav bar's items, then the tab bar's items bottom-aligned. The buttons drive the real controllers, including
SwiftUI's native `TabView`, so tab switching genuinely selects. Every pose puts the controls on a side edge
except the inner display in portrait, the one HIG exception, which keeps horizontal bars.

**Split-view companion.** The inner Split View half draws the *other* app as a gradient placeholder pane on the
opposite side, with a gutter between them. Each app keeps its controls on its outer edge, and both flip when you
change the edge.

**Corners.** Per-corner rounding matches the fixed physical device corners: the device exterior, a pane's seam
against the divider, and the outer display's hinge. Inner rounds all four equally; a split pane rounds full on
its outer corners and at the seam radius against the divider; outer portrait rounds the camera edge more than the
hinge opposite it.

**Camera cutout.** Fixed to the hardware and rotating with the device: top of the strip in outer portrait, and
following the rotation in outer landscape. The inner display's camera is under-display, so there's no cutout.
</details>

## What it can and can't fake

**Faithful:** pose sizes, safe-area insets, size classes, and the production resize path (frame changes drive the
same `traitCollectionDidChange` and `viewSafeAreaInsetsDidChange` callbacks a real fold would). The point sizes,
side-controls and status-bar insets, and size classes are measured on the iPhone Duo simulator (Xcode 27.1).

**Still estimated:** the Display Zoom factors, the seam and hinge corner radii (only the exterior radius is
measured), and the side strip's internal glyph layout. These are cosmetic or secondary; refine them from the
simulator when needed.

**Out of reach until the 27.1 SDK:** real fold and hinge reserved regions, `ArrangementView`,
`UIHingeInteraction`, and genuine system vertical bars. The vertical-bars mode here is cosmetic; the tab
switching is real, but it isn't the system's layout. The system keyboard follows the framed window but its own
UI isn't adapted to the Duo.
