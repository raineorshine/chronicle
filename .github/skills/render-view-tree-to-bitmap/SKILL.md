---
name: render-view-tree-to-bitmap
description: >-
  Capture what Chronicle actually renders by drawing its SwiftUI/AppKit view
  tree straight to a PNG from inside the process, with no screen-recording
  permission and no visible window. Use for debugging layout, margins,
  alignment, or "what does the real window look like" questions when
  `screencapture` is blocked or a headless agent has no display. Also covers
  driving the app to a specific state and measuring the resulting pixels.
---

# Render the app's view tree to a bitmap for debugging

`screencapture` needs display-recording permission and often fails in agent
/ CI / headless contexts ("could not create image from display"). You do not
need it. AppKit and SwiftUI can both rasterize a view tree to a bitmap
**in-process**, so you get exactly what the app draws without ever touching the
screen buffer.

This is the technique used to diagnose the "All Tasks header margin" bug: every
isolated render showed the header aligned, so the real window had to be
captured to find that overflowing content was being center-aligned.

## When to use this

- A layout / margin / alignment / spacing question where you need ground truth,
  not a guess.
- `screencapture` is unavailable or returns a permission error.
- You are a headless agent with no way to see the UI.
- You want to compare two app states pixel-for-pixel (e.g. `All Tasks` vs a
  selected task) and measure the difference numerically.

## Two ways to rasterize

### 1. Live window/view via `cacheDisplay` (most faithful to the running app)

Draws the actual on-screen layer tree of a live `NSView` into an
`NSBitmapImageRep`. This reflects real AppKit chrome (titlebar, toolbar,
NavigationSplitView insets) that offscreen renderers miss.

```swift
func capture(_ view: NSView, to path: String) {
    let bounds = view.bounds
    guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
    view.cacheDisplay(in: bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

// To include the titlebar + toolbar (the "Chronicle" title and its divider),
// capture the window frame view, not just the content view:
let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }!
let frameView = window.contentView?.superview ?? window.contentView!
capture(frameView, to: "/tmp/win.png")
```

Scale: on a 2x display the PNG comes out at 2x device pixels (e.g. a 900x600pt
window -> 1800x1200 px). Account for that when measuring.

### 2. Offscreen SwiftUI via `ImageRenderer` (faithful SwiftUI layout, real data)

Renders any `View` without a window. Best for isolating a subview's layout, and
it can use the real `@MainActor` store so the content is real, not mocked.

```swift
@MainActor
func renderDetail(_ store: DashboardStore, to path: String) {
    let v = DashboardDetail(store: store)
        .frame(width: 700, height: 1700, alignment: .topLeading) // see gotchas
        .background(Color.black)
        .environment(\.colorScheme, .dark)                        // see gotchas
    let r = ImageRenderer(content: v)
    r.scale = 2
    if let img = r.nsImage,
       let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
```

`DashboardDetail` and other views are `private` to `ContentView.swift`, so put
temporary debug code **in that same file** to reach them.

Use both methods and cross-check: `cacheDisplay` is authoritative for window
chrome but silently drops some layers; `ImageRenderer` is authoritative for
SwiftUI layout but omits window chrome. If they disagree, trust `cacheDisplay`
for "where is it in the window" and `ImageRenderer` for "how did the subview lay
itself out".

## Driving the app headlessly

An agent usually cannot click. Add a temporary DEBUG controller that a launch
reads, drives to the target state, captures, and quits.

- **Trigger via a control file, not env vars.** `launchctl setenv` + `open`
  does not propagate reliably. A file the app reads on launch does.
- **Launch with `open Chronicle.app`, not `./Chronicle`.** A direct binary
  launch never shows the window, so `onAppear` never fires. `open` shows it.
- **Drive state by calling the store directly** (`store.selectHome()`,
  `store.selectActivity(1)`), then wait for layout to settle before capturing.
- **Quit when done** with `NSApp.terminate(nil)` so the agent's `open`/`sleep`
  loop can move on.
- **Log to a file** (e.g. `/tmp/chronicle_dump.log`) so you can tell whether the
  hook fired, selected, and wrote each PNG.

Sketch (gate on `#if DEBUG`, wire from `ContentView.onAppear`):

```swift
#if DEBUG
@MainActor
final class DumpController {
    static let shared = DumpController()
    private let ctrl = "/tmp/chronicle_dump.txt"

    func begin(store: DashboardStore) {
        guard let mode = try? String(contentsOfFile: ctrl, encoding: .utf8) else { return }
        let wantTask = mode.contains("task")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            wantTask ? store.selectActivity(1) : store.selectHome()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.capture(to: wantTask ? "/tmp/win_task.png" : "/tmp/win_all.png")
                try? FileManager.default.removeItem(atPath: self.ctrl)
                NSApp.terminate(nil)
            }
        }
    }
    // capture(...) as above
}
#endif
```

Driver loop (note: `kill` here needs a literal numeric PID, not a variable):

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/Chronicle-*/Build/Products/Debug/Chronicle.app"
printf 'all\n'  > /tmp/chronicle_dump.txt; open $APP; sleep 7   # captures /tmp/win_all.png
printf 'task\n' > /tmp/chronicle_dump.txt; open $APP; sleep 7   # captures /tmp/win_task.png
rm -f /tmp/chronicle_dump.txt                                    # so normal launches are unaffected
```

## Measuring the result

Read pixels back with `NSBitmapImageRep.colorAt(x:y:)`. For this dark-themed
app, text is light on a dark background, so "a text row" is a row whose max
brightness in the content column crosses a threshold. Group bright rows into
bands to locate the heading / subtitle / date, then compare bands between two
captures.

```swift
func textBands(_ path: String, xLo: Int, xHi: Int) -> [(Int, Int)] {
    let img = NSImage(contentsOfFile: path)!
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    func rowMax(_ y: Int) -> Double {
        var m = 0.0
        for x in xLo..<min(xHi, rep.pixelsWide) {
            if let c = rep.colorAt(x: x, y: y) {
                m = max(m, (c.redComponent + c.greenComponent + c.blueComponent) / 3)
            }
        }
        return m
    }
    var bands: [(Int, Int)] = []; var start = -1
    for y in 0..<rep.pixelsHigh {
        if rowMax(y) > 0.5 { if start < 0 { start = y } }
        else if start >= 0 { if y - start >= 4 { bands.append((start, y)) }; start = -1 }
    }
    return bands
}
```

Normalize across captures taken at slightly different scroll/zoom by dividing
distances by a stable reference (e.g. the "Chronicle" title cap height). If that
reference is the same in both images, the captures are at the same scale and the
band positions are directly comparable.

## Gotchas (all hit while building this)

- **`cacheDisplay` drops some layers.** AppKit-backed `List` (the sidebar) and,
  when content overflows, sibling SwiftUI layers can render blank/missing. If a
  region looks empty, confirm with `ImageRenderer` before believing it.
- **`ImageRenderer` defaults to light mode.** Default text is black; on a black
  background it is invisible and you get empty bands. Set explicit colors or
  `.environment(\.colorScheme, .dark)`.
- **Fixed-height frames clip overflow.** If you wrap a tall view in a frame
  shorter than its content and it centers, the top clips off and you will think
  the header is "missing." Give the frame plenty of height (or `alignment:
  .topLeading`) when you want to see the top.
- **`ImageRenderer` is `@MainActor`.** In a standalone Swift script, wrap calls
  in `MainActor.assumeIsolated { ... }` or mark the function `@MainActor`.
- **`open` vs direct binary.** Only `open` shows the window and fires
  `onAppear`. A direct exec stays hidden.
- **`kill` in this agent needs a literal PID.** `pgrep`, then `kill <number>`;
  `kill "$var"` / loops over variables are rejected.
- **DerivedData path is not stable.** It changes across `xcodegen generate`
  runs; glob `Chronicle-*/Build/Products/Debug/Chronicle.app` instead of
  hardcoding the hash.

## Build & run recap

```bash
xcodegen generate                                                   # Chronicle.xcodeproj is gitignored
xcodebuild -project Chronicle.xcodeproj -scheme Chronicle \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

## Cleanup checklist (do this before shipping)

- [ ] Remove the `DumpController` and the `onAppear` debug hook (or keep them
      strictly under `#if DEBUG` if the project wants a permanent affordance).
- [ ] Delete `/tmp` PNGs, logs, harness scripts, and the control file.
- [ ] Delete the generated `Chronicle.xcodeproj` (gitignored).
- [ ] `git diff` and confirm only the intended change remains.
