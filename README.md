# DuoFrameSimulator

A DEBUG-only tool for previewing an app's layout at **iPhone Duo** display sizes before the Xcode 27.1
Duo simulator ships. It hosts the app's real root view controller inside a container that pins it to a
chosen footprint, fakes that display's safe area, and overrides its size classes, all driven from a
floating menu in the top-right corner of the window.

It reframes the app by resizing its **window** to the chosen footprint (and scaling the window for Display Zoom),
so the OS still thinks it's on the host device, but the app — and everything UIKit hangs off the window, including
`.sheet`, `.fullScreenCover`, alerts and popovers — is handed the size, safe area and traits the Duo would report.
Debug chrome lives in a separate passthrough window above it.

## What it does

- **Presets menu** (top-right, mirroring the window controls Apple puts top-left): the Duo poses (outer/inner,
  landscape/portrait, an inner Split View half), plus an **Other sizes** submenu of released iPhone form
  factors (SE through Pro Max) and a custom size — a general "other device" simulator. Other-device frames are
  plain phones: compact-width, their own safe area and uniform corners, no Duo side controls, so the side-controls
  option simply doesn't apply to them (the same as the Off pose). Devices live in `DuoDevice`.
- **Faked safe area** for the side controls / Dynamic Island, on either the left or right edge.
- **Size-class override** so `NavigationSplitView`, adaptive presentations and any
  `horizontalSizeClass` checks see compact (outer) or regular (inner).
- **Physical-density mode** scales the frame so a point renders at the simulated device's real physical size:
  the host's points per inch over the device's (`DuoDevice.pointsPerInch`; 153 for the Duo and every 460-ppi 3x
  phone, 163 for the SE and XR, 159 for the mini). The Duo is ×1.07 on an iPad mini, the recommended host, and
  ×1 on a 3x iPhone; an SE on a 17 Pro shrinks to ×0.94. It never scales above the fit.
- **Display Zoom** (Options toggle) reproduces both halves of the iOS setting: the app lays out at the device's
  zoomed point size (e.g. 402×874 → 320×696 on the 6.3" Pro) while keeping the same footprint, so the content is
  magnified, *and* `UIScreen.nativeScale` is swizzled to report `scale / factor` (3.77 on that Pro), so code that
  detects zoom via `UIScreen.main.scale / nativeScale` sees the real 0.796 rather than 1. Per-device zoomed widths
  live in `DuoDevice`; only the 6.3" Pro is measured on-device, the Duo and custom sizes fall back to its factor.
  Toggling posts `DuoFrameSimulator.screenMetricsDidChange`; with the optional
  `duoFrameRebuildOnScreenMetricsChange()` modifier on the root content (see below) the whole SwiftUI tree is given a
  new identity, so every `body` re-runs with the new metrics. That is the in-app equivalent of the relaunch iOS does
  for a real Display Zoom change, and it costs the same: navigation and view state reset. Toggle with no sheet
  presented, since a torn-down presentation can leave app-side presenter state stranded. Anything the app computes
  once (`static let` sizes) still keeps its pre-toggle value until relaunch.
- **Override UIScreen.bounds** (Options toggle, off by default) swizzles `UIScreen.bounds` to the frame's layout
  size so `UIScreen.main.bounds`-based sizing follows the frame. UIKit sizes its own windows (keyboard, alerts) from
  the same getter, so expect those to misplace when the frame differs from the real screen; flip it off if so.
- **Vertical-bars mode** (stretch): hides the hosted system bars and draws a Duo-style side column in the
  strip — a fake Dynamic Island, the clock and the combined Wi-Fi/cellular status glyph at the top (metrics
  measured off Apple's HIG "Designing for iPhone Duo" screenshots), then the navigation bar's items, then
  the tab bar's items bottom-aligned, ordered per the HIG. The buttons drive the real controllers (nav/toolbar
  via target-action, tabs via the tab bar). The controls-edge safe-area inset equals the strip width, so app
  content that respects the safe area clears the strip.
- **Split-view companion** (inner Split View half): draws the *other* app as a gradient placeholder pane on
  the opposite side, with a gutter between the panes. The app sits on the same side as its side controls (each
  app keeps its controls on its outer edge), and both flip when you change the edge.
- **Per-corner rounding** matches the fixed physical device corners (not the control side). A corner blends the
  roundedness of the two edges meeting there — a free edge rounds full, the hinge edge reads squarer. Inner
  (either orientation, no split) rounds all four corners equally at the large radius; a split pane rounds hard
  on its outer corners and tight against the divider; outer portrait rounds the camera/control edge more than
  the hinge edge opposite it. Outer landscape is the portrait device rotated — controls-right is 90° clockwise
  (hinge, so the squarer corners, on top), controls-left is 90° anticlockwise (hinge on the bottom). Radii live
  in `DuoFrameCornerRadii`.
- **Camera cutout** is fixed to the hardware and rotates with the device: top of the strip in outer portrait;
  in outer landscape it follows the rotation — bottom of the strip with the controls on the right, top with
  them on the left. The inner display's camera is under-display, so there is no cutout. The strip's own items
  always read clock, network, nav bar, tab bar from the top; the camera is a separate cutout at its corner. Set
  via `DuoFrameVerticalBar.CameraPlacement`.

**Why the window, not the content.** An earlier version transformed the app's view inside a full-screen container.
That works for the app itself but not for `.sheet` / `.fullScreenCover` / alerts / popovers: UIKit presents those in
a transition view attached to the *window*, above the container, so they ignored the transform and filled the whole
screen. Framing the window instead puts every presentation inside the footprint. It does *not* change the window's
scene — iOS exposes no API for that (`GeometryPreferences.iOS` carries only orientation, `sizeRestrictions` only
clamps a user drag) — it sets the window's own `bounds`, `transform` and `center` within the scene.

**Safe area.** The framed window inherits little or none of the host's safe area (a sub-screen window usually reports
zero), so the hosted root is given `additionalSafeAreaInsets` = the faked Duo inset, clamped up to the host's real
overlap where the footprint still reaches a hardware region. There is no transform between the controller's view and
the window, so the child inherits the window's own insets normally.

**Caveats to verify on device (this path is new and untested):**
- **The system may fight a custom window frame.** SwiftUI's `WindowGroup` and scene changes can reset `window.frame`;
  the tool re-applies it on every layout pass, but if the OS overrides it you'll see it snap back. This is the main
  risk of the window approach.
- **Sheet sizing.** A `.pageSheet` sizes itself to the (now small) window, which is the point, but detents and the
  card's own insets are the system's to place; check they land sensibly, especially under Display Zoom.
- **Safe area under Display Zoom at full screen.** When the footprint fills the screen and the window reports real
  insets, those are in the window's zoomed point space; the clamp handles the common cases but the notch overlap
  edge case wants a real-device check.
- **The keyboard** follows the window, so it should now sit inside the frame; confirm it isn't clipped by the corner
  mask.

**Fit is to the whole physical screen**, not the host's safe area. A frame the same size as the real screen
renders full-screen at 1:1; a smaller frame renders at true point size, centred with a border; only a frame
larger than the screen scales below 1 (letterboxing just for an aspect-ratio mismatch). So on an iPhone 17 Pro,
picking iPhone Pro fills the screen, iPhone SE is a bordered 1:1, and iPhone Pro Max scales down to fit.

Settings persist in `UserDefaults`, so the last preset survives relaunches. Presets can also be forced at
launch with `-DuoFrameSimulator.settings <base64-json>` (used for scripted screenshots).

### The vertical-bar poses

Every pose puts the controls on the side **except the inner display in portrait**, which keeps horizontal
bars — the one HIG exception. So with vertical bars on: outer portrait/landscape, inner landscape and the
inner Split View half draw the side strip; inner portrait leaves the real horizontal bars alone.

### Driving the tabs

Tapping a re-homed tab drives the real selection, including through SwiftUI's native `TabView` — `selectTab`
sets `selectedTab`/`selectedIndex` and calls the tab bar delegate, and SwiftUI follows. Note this couldn't be
verified by the automated tapper: `axe`/simctl synthetic taps don't land on scaled/transformed content, so tab
interactivity has to be confirmed with a real click in Device Hub or the Simulator (it works).

## Adding it to a project

1. Add the package as a dependency (a local path while it has no remote, e.g. **File → Add Package
   Dependencies… → Add Local…**, or `XCLocalSwiftPackageReference` in the pbxproj) and link the
   `DuoFrameSimulator` product to the app target.
2. Import it and call `DuoFrameSimulator.install()` once before the first window appears, under `#if DEBUG`:

   ```swift
   #if DEBUG
   import DuoFrameSimulator
   #endif

   // SwiftUI App.init(), or application(_:didFinishLaunchingWithOptions:)
   #if DEBUG
   DuoFrameSimulator.install()
   #endif
   ```

3. Optionally, if the app sizes anything from `UIScreen.main` inside SwiftUI bodies, add the rebuild modifier to the
   `WindowGroup`'s root content so Display Zoom and the bounds override take effect without a relaunch:

   ```swift
   WindowGroup {
       RootView()
           #if DEBUG
           .duoFrameRebuildOnScreenMetricsChange()
           #endif
   }
   ```

Nothing here references app-specific types. The whole package is wrapped in `#if DEBUG`, so it compiles to an
empty module in release builds; the app's own `#if DEBUG` guards keep the call sites out too. Xcode builds a
package in Debug only for app configurations it recognises as debug (the name contains "Debug"), so a custom
configuration such as "Staging" would get an empty module and fail to compile the call sites.

Numbers to confirm on the real 27.1 simulator: the Duo point sizes, the side-controls and Dynamic Island insets,
the inner-display downsample scheme and the Split View half size classes. Update `DuoFrameInsets` and
`DuoFramePreset.size(custom:)` once they're known.

The menu button is **hidden by default** and toggled with a **shake gesture** (Device → Shake in the
Simulator). Pass `DuoFrameSimulator.install(showsButton: true)` to start with it visible.

To exercise the presets on an iPad host you need an **iPad build** (`TARGETED_DEVICE_FAMILY = 1,2`),
which enables resizable windows. No iPhone is 669 pt tall, so neither Duo frame fits a phone host. Use
the **iPad mini** — its 6% density error errs pessimistic, so a marginal control that passes there
passes on the Duo. For window-resize mode, switch the iPad to **Windowed Apps** in
Settings → Multitasking & Gestures.

## What it can and can't fake

Faithful: size, safe-area insets, size classes, and the production resize path (frame changes drive the
same `traitCollectionDidChange` / `viewSafeAreaInsetsDidChange` callbacks a real fold would).

Guesses, flagged until Apple publishes them: the exact Duo point sizes and Dynamic Island insets are
placeholders (iPhone 17 Pro values). The inner-display sizes assume the Plus-model downsample scheme.
Split View halves' size classes are unpublished.

Can't fake anything gated behind the 27.1 SDK: real fold/hinge reserved regions, `ArrangementView`,
`UIHingeInteraction`, or genuine system vertical bars. The vertical-bars mode here is cosmetic — the tab
switching is real, but it isn't the system's layout.

