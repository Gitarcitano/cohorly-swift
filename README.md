# CohorlySwift

<!-- cohorly-mirror-notice:start -->
> **This repository is a read-only mirror** of a private monorepo. Its
> contents are generated on every release, so changes made here would be
> overwritten.
>
> - Pull requests are not accepted for now.
> - Bugs and questions: open an issue in this repository.
> - Security vulnerabilities: follow [SECURITY.md](./SECURITY.md). Do not open
>   a public issue.
<!-- cohorly-mirror-notice:end -->


Standalone Swift Package for Cohorly (hosted, Mixpanel-style product analytics). Supports
iOS 15+ and macOS 12+ (macOS so `swift test` runs locally/in CI without a simulator).

**Documentation:** [iOS SDK reference](https://cohorly-docs.velloalabs.com/sdks/ios) · [Quickstart](https://cohorly-docs.velloalabs.com/quickstart) · [HTTP API](https://cohorly-docs.velloalabs.com/api/ingestion)

## Install

Add the Swift package from its standalone repo,
[Gitarcitano/cohorly-swift](https://github.com/Gitarcitano/cohorly-swift)
(Apache-2.0).

### Xcode

File > Add Package Dependencies..., enter
`https://github.com/Gitarcitano/cohorly-swift`, pick a version rule (e.g. "Up to
Next Major" from `0.1.0`), and add the **Cohorly** library product to your app
target.

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/Gitarcitano/cohorly-swift", from: "0.1.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "Cohorly", package: "cohorly-swift")]
    ),
]
```

Do not depend on the monorepo URL: its root `Package.swift` exists for local
development, and the monorepo root is proprietary while this SDK is Apache-2.0.

Local development within this monorepo can instead point directly at this subdirectory:
`.package(path: "sdks/ios")`, or in Xcode: File > Add Package Dependencies... and point it
at `sdks/ios`.

## Usage

```swift
import Cohorly

// Call once near app launch. `token` is your Cohorly project token - stamped on
// every tracked event's properties and included as a top-level `token` field on
// every /engage body, so the server can route data to the right project.
let cohorly = Cohorly.initialize(token: "YOUR_PROJECT_TOKEN")

cohorly.register(["app_version": "1.2.0"])
cohorly.track("Screen Viewed", properties: ["screen": "Home"])

cohorly.identify("user_123")
cohorly.people.set(["plan": "pro"])

// Manually flush (also happens automatically every 5s or every 20 events).
await cohorly.flush()
```

`token` is optional - omit it (or pass `nil`) if you don't use
per-project tokens.

You can also instantiate directly (e.g. for tests or multiple instances) instead of using
the shared singleton:

```swift
let client = Cohorly(
    apiHost: "https://cohorly-service.velloalabs.com",
    transport: MyMockTransport(),
    storage: InMemoryStorage(),
    flushInterval: 5,
    flushAt: 20
)
```

## API

- `Cohorly.initialize(apiHost:token:transport:storage:flushInterval:flushAt:) -> Cohorly` -
  configures and returns the shared instance (`Cohorly.shared`). `token` is optional.
- `track(_ event: String, properties: [String: Any]? = nil)`
- `identify(_ distinctId: String)`
- `reset()` - clears identity, super properties, and un-flushed events.
- `register(_ properties: [String: Any])` / `unregister(_ key: String)` - super properties
  merged into every event.
- `people.set(_:)` / `people.setOnce(_:)` / `people.increment(_:)` / `people.unset(_:)` /
  `people.deleteUser()`. Note: `unset`/`deleteUser` are destructive and refused by the
  server on the public project token alone (they need an org-owner or superadmin
  `Authorization` credential this SDK does not send) - server-side no-ops here; remove
  profile data from the dashboard or the admin privacy API instead.
- `flush() async` - manually flush; also resolves once any auto-triggered flush completes.
- `currentDistinctId: String`

### Feature flags

Flags are evaluated on `initialize` (opt out with `loadFeatureFlags: false`), on
`identify()` and on `reset()`, and cached in storage scoped by distinct id; reads
never hit the network.

How reads resolve against the persisted cache is controlled by
`flagPersistence` (default `.persistenceUntilNetworkSuccess`, the same three
modes the other Cohorly SDKs and Mixpanel's `variantLookupPolicy` offer):

- `.networkOnly` - never reads nor writes the cache on the serving path
  (identity changes still remove it - that is hygiene, not serving); flags
  come only from network responses this session, so a failed evaluation
  serves the fallback.
- `.networkFirst` - prefers the network, but because reads are synchronous a
  valid cache (inside the TTL) is served immediately like
  `.persistenceUntilNetworkSuccess`. Strict about freshness: a cache past
  the TTL is dropped, never served.
- `.persistenceUntilNetworkSuccess` - serves a valid cache immediately, so
  startup doesn't flicker; the first network success takes over and
  re-persists. A failed evaluation keeps the cached values serving. Trades
  freshness for offline availability: an expired cache still serves while
  inside `Cohorly.flagCacheMaxStale` (7 days).

The cache is written with a `stored_at` timestamp on every successful
evaluation and expires after `flagCacheTTL` (default 24h,
`Cohorly.defaultFlagCacheTTL` - the Mixpanel reference default, shared with
the sibling SDKs). A legacy cache with no `stored_at` cannot be dated, so
it is served indefinitely rather than expired - the graceful-upgrade path
preserving the pre-TTL behavior - until the next successful reload
rewrites it in the stamped format. `identify()` and `reset()` clear the
previous identity's flags (memory and disk) before fetching the new
identity's, so flag values never leak across users.

- `isFeatureEnabled(_ key: String, fallback: Bool = false) -> Bool`
- `getFeatureFlag(_ key: String, fallback: Bool)` /
  `getFeatureFlag(_ key: String, fallback: String)` -> `JSONValue` -
  `.string(variant)` when the flag serves a variant, else `.bool(enabled)`;
  `fallback` when the flag is unknown or unloaded (the two overloads mirror
  the shared contract's `boolean | string` fallback type). A read that
  resolves to `fallback` reports no exposure.
- `getFeatureFlagDetails(_ key: String, fallback: Bool = false)` /
  `getFeatureFlagDetails(_ key: String, fallback: String)` -> `FlagDetails` -
  the value plus `enabled`, `payload` and `source` (`.network` /
  `.persistence` / `.fallback`) and, for persistence-served values,
  `persistedAt` (epoch ms) and `ttlMs`. On a fallback result `enabled` is the
  fallback's truthiness and `payload` is `nil`.
- `getFeatureFlagPayload(_ key: String) -> JSONValue?`
- `currentFeatureFlags() -> [String: FlagResult]`
- `reloadFeatureFlags() async` - re-evaluate for the current distinct id.
- `onFeatureFlags(_ callback:) -> () -> Void` - fires after every successful
  reload, when `identify()`/`reset()` clear the served set (with an empty
  map), and immediately when flags are already loaded; returns unsubscribe.

Reads of known flags emit `$feature_flag_called` once per (key, value) per
identity, stamped with `$feature_flag_source` (`"network"` or `"persistence"`)
plus `$feature_flag_persisted_at` and `$feature_flag_ttl_ms` for persistence
reads; the same value served first from persistence and then from the network
is reported exactly once.

Auto-captured properties on every event: `$lib` ("ios"), `$os`, `$os_version`, `$model`,
`$screen_width` / `$screen_height` (the last three via `UIKit` where available, e.g. skipped
on macOS/watchOS).

Events and profile updates are queued in memory and persisted to `storage` (UserDefaults by
default) so nothing is lost across relaunch; the queue auto-flushes every 5 seconds or every
20 events (both configurable). All mutable state is confined to a private serial
`DispatchQueue`, so the client is safe to call from any thread.

## Native crashes

The optional `CohorlyCrash` product (same package, adds a dependency on
[KSCrash](https://github.com/kstenerud/KSCrash) `Recording`) records signals,
Mach exceptions, uncaught NSExceptions and C++ exceptions and sends each one on
the next launch as a `$exception` event (level `fatal`) through a background
`URLSession` upload, so a crash loop at startup still reports. MetricKit crash,
hang and CPU diagnostics are sent too, as `error` / `warning`. The `Cohorly`
product never links KSCrash.

```swift
import Cohorly
import CohorlyCrash

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let cohorly = Cohorly.initialize(token: "YOUR_PROJECT_TOKEN")
    CohorlyCrash.install(cohorly: cohorly)   // right after initialize
    return true
}

// Optional, lets iOS wake the app when a crash upload finishes:
func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    if !CohorlyCrash.handleEventsForBackgroundURLSession(identifier, completionHandler: completionHandler) {
        completionHandler()
    }
}
```

- Crashes carry the release, identity and device of the launch that crashed,
  never those of the launch that sends them. `install` follows `identify()` and
  `reset()` on its own.
- The release defaults to `<CFBundleIdentifier>@<CFBundleShortVersionString>+<CFBundleVersion>`
  (`install(cohorly:release:dist:)` overrides it). Upload each build's dSYMs with
  that release so frames are symbolicated:
  `cohorly debug-files upload --release com.example.shop@1.4.0+27 path/to/Shop.app.dSYM`
  (`@cohorly/cli`, macOS).
- Never install a second crash reporter in the same process (e.g. turn off
  Sentry's `enableNativeCrashHandling`).
- Under the Xcode debugger KSCrash's Mach handler is off; crashes arrive through
  the signal path.

`Examples/CrashDemo` is a sample app that crashes on demand and measures the
launch-time cost.

## Session replay

The optional `CohorlyReplay` product (same package, no extra dependency) owns
the replay session: it stamps `$session_id` on events, draws each session's
sampling decision and sends recorded chunks to `POST /replay`. An app that does
not add it carries no replay code, and its events have no `$session_id`.

On iOS it also records the screen of sessions sampled for it, as wireframes
(a description of each view: position, size, colors, text, kind) or, with
`mode: .screenshot`, as masked images of the window, plus touches. A session
drawn for error mode (`onErrorSampleRate`) keeps the last 30 to 60 seconds in
memory and sends them only when an error happens. On macOS the product
builds (for `swift test`) but records nothing.

Add the product to your target: in Xcode, pick `CohorlyReplay` next to
`Cohorly` when adding the package; in `Package.swift`,
`.product(name: "CohorlyReplay", package: "cohorly-swift")`. Besides UIKit it
imports only SwiftUI (a system framework, for the `.cohorlyNoCapture()`
modifier); it never imports MapKit, WebKit, MetalKit, SceneKit or SpriteKit
(their views are recognized by class name).

```swift
import Cohorly
import CohorlyReplay

let cohorly = Cohorly.initialize(token: "YOUR_PROJECT_TOKEN")
CohorlyReplay.install(                       // right after initialize
    cohorly: cohorly,
    config: CohorlyReplayConfig(sampleRate: 0.1, onErrorSampleRate: 1)
)
```

- `sampleRate`: share of sessions recorded whole, 0 to 1 (default 0).
  `onErrorSampleRate`: share of the other sessions that keep a short buffer
  sent when an error happens, 0 to 1 (default 0). Values outside 0 to 1 are
  clamped. The draw happens once per session and is kept with it, so a
  relaunch inside the same session never draws again. `maskAllImages`
  (default `true`): images are drawn as grey boxes; `false` sends them as
  small JPEGs (see Masking).
- `mode` (default `.wireframe`): `.screenshot` records each capture as one
  JPEG of the key window instead (see Screenshot mode).
- `remoteConfig` (default `false`): read the rates and the minimum duration
  saved in Settings > Session replay, without a new release. Each field the
  project saved wins over your code's value; a field it never saved keeps
  yours, and with no network and no cached copy your values apply. The SDK
  keeps the settings for 1 hour per project. A change applies to new sessions
  only: a session in progress keeps its decision. A new session gets its
  `$session_id` at once and waits at most 3 seconds for the settings before
  it is sampled (`install` and `track()` never wait). With a minimum
  duration, a recorded session sends nothing until it is that long, and a
  shorter one is never sent (sessions recorded on error are always sent).
  Triggers, masking and `mode` always come from your code. Without it, the
  SDK never asks the server.
- `$session_id` (1 to 64 characters of `[A-Za-z0-9_-]`) goes on every
  `track()` once `install` ran, rates of 0 included, `$exception` events too; a
  `$session_id` you pass in the properties wins (the event still counts as
  session activity). With `CohorlyCrash` installed
  as well, a crash sent on the next launch carries the `$session_id` of the
  session it happened in.
- A session rotates when the app comes back to the foreground after 30 minutes
  or more in the background, or once it is 24 hours old (on return to the
  foreground, or on the next `track()` while in the foreground). It never
  rotates in the background. `reset()` starts a new one at once. The session
  is stored in the SDK storage, so a relaunch continues it unless it expired.
- Chunks wait in their own queue on disk (`Library/Caches/cohorly/replay`,
  one directory per project, 20 MB at most, oldest dropped first), apart from
  the event queue, gzipped, and are retried with the same backoff rules as
  events but their own counter: a replay 429 never delays `/track`. A 404
  stops replay until the next launch; a `replay quota exceeded` refusal
  pauses whole-session recording until its `Retry-After` (one hour without
  it), across relaunches.

### What is recorded

- The key window's `UIView` tree, at most once per second while something
  changes and less and less often (down to every 8 s) while the screen stays
  still; a capture that changed nothing sends nothing. Captures follow the main
  run loop: no timer, no display link. Never in the background.
- A full snapshot at the start of each session, after the app comes back to
  the foreground, when the key window or the screen (the class name of the
  view controller on top, sent as the screen name) changes; small changes in
  between.
- Touch starts and ends, with their position.
- Chunks of at most 10 seconds, written to disk at once when the app goes to
  the background (under a background task) or the session changes.

`optOutTracking()` stops the recorder and drops what it holds in memory;
`optInTracking()` starts a new session from a full snapshot.

### Screenshot mode

```swift
CohorlyReplay.install(
    cohorly: cohorly,
    config: CohorlyReplayConfig(sampleRate: 0.1, mode: .screenshot)
)
```

Each capture is the key window drawn with `drawHierarchy` at one pixel per
point and sent as a JPEG (quality 0.3), with the same timing, chunks and
touches as wireframes. Everything on screen appears: SwiftUI `Text`, shapes,
maps, Metal. Before the image is encoded, the masked areas are painted
black in the same bitmap, so an unmasked pixel never leaves the device or
reaches disk: text fields, secure fields and editable text views, images
(while `maskAllImages`), marked views and their subtrees, web views and the
SwiftUI `.cohorlyNoCapture()` areas. An identical image sends nothing.
Recordings are larger and captures cost more main-thread time than
wireframes: measure on your heaviest screen first.

### Errors

A session drawn for error mode records into memory: at most the last 60
seconds (5 MB), from a full snapshot. Nothing is sent until an error:

- `cohorly.track("$exception", properties: [...])` sends the buffer by itself.
- For errors reported another way, call `CohorlyReplay.notifyError()` (any
  thread; nothing happens when replay is not installed or the session is not
  in error mode).

The recording is sent with `mode: "error"` under the session's
`$session_id`, so it opens from the error issue at the moment of the error.
Two sends are at least 5 seconds apart; an error inside that gap goes with
the next one. In session mode an error sends nothing extra.

A native crash caught by `CohorlyCrash` goes **without** the error buffer.
The crash handler may only run async-signal-safe code, and writing the
buffer (Swift objects, JSON, gzip) allocates and takes locks: doing it there
could hang the handler and lose the crash report itself. In session mode the
crash still carries `$session_id` and opens the recording sent until then.

### Screen views

Pass `trackScreenViews: true` to track `$screen` automatically (off by
default; replay never turns it on, and with it off the player's timeline lists
no screens). The player lists each one on the timeline:

```swift
let cohorly = Cohorly.initialize(token: "YOUR_PROJECT_TOKEN", trackScreenViews: true)
```

- Each `UIViewController` that becomes its window's visible screen (root, then
  presented, a navigation stack's visible one, a tab bar's selected one) sends
  one `$screen` with one property, `$screen_name`: the class name without
  module. Default properties, super properties and `$session_id` ride along
  like on any `track`.
- Ignored: keyboard windows and controllers whose class name starts with `UI`
  or `_` (containers, `UIAlertController`, `UIHostingController`, other system
  ones). The same instance sends once; going back to a previous controller, or
  a new instance of the same class, sends again; returning from the background
  sends nothing.
- SwiftUI screens are not tracked automatically (they are
  `UIHostingController`s): call
  `cohorly.track("$screen", properties: ["$screen_name": "Settings"])`.
- Known limitation: dismissing a `pageSheet` or `formSheet` sheet does not call
  `viewDidAppear` on the controller below, so returning to it is not tracked.
- Not walked into: `UISplitViewController`, `UIPageViewController` and custom
  containers. A visible `UISplitViewController`/`UIPageViewController` sends
  nothing; a custom container sends its own name once. Track those by hand.
- A controller whose `viewDidAppear` does not call `super` is not tracked.
- Initialize before the first screen appears: the screen already showing when
  the SDK starts is not sent until the next screen change.
- Each `$screen` counts against the monthly event quota.
- It swizzles `UIViewController.viewDidAppear(_:)` once, only when on, calling
  the previous implementation first.

### Masking

- Every `UITextField`, editable `UITextView` and `UISearchBar` shows its text
  as asterisks of the same length. Always: no option turns this off.
- Secure fields (`isSecureTextEntry`, or a password, new password, one-time
  code or credit card `textContentType`) are masked and marked as passwords;
  nothing unmasks them.
- `UILabel`, `UIButton` titles and non-editable `UITextView` show their text.
  A `UITextView` that was editable at any point stays masked after it turns
  read-only.
- Images are grey boxes while `maskAllImages` is `true` (the default). With
  `false` they are sent as low-quality JPEGs at the size of their view, except
  inside a marked view.

### Hiding a view

A marked view and its whole subtree become one grey placeholder, with no text,
image or child:

```swift
cardView.cohorlyNoCapture = true                        // UIKit (also in Interface Builder)
balanceView.accessibilityIdentifier = "cohorly-no-capture" // the token anywhere in the identifier
```

SwiftUI:

```swift
Text(account.iban).cohorlyNoCapture()
Text(account.note).cohorlyNoCapture(isPrivate) // false records it as usual
```

The modifier lays a transparent marker view over the content, read at
capture time. In screenshot mode its area is painted over; in wireframe mode
the recorder draws the marker's area as an opaque placeholder above
everything else in the window, drops whatever lies entirely inside it and
empties whatever only overlaps it
(no text, pixels or typed value, just the box).

### Limitations

- SwiftUI, wireframe mode: screens are recorded through the UIKit views
  SwiftUI uses underneath. Text fields, lists and images appear (and are
  masked); `Text`, shapes and anything drawn in layers do not. Screenshot
  mode records them.
- Wireframe mode: map (`MKMapView`), web (`WKWebView`), Metal (`MTKView`),
  SceneKit and SpriteKit views are one labelled placeholder ("Map", "Web",
  "Metal", "SceneKit", "SpriteKit"): their content is not views. In
  screenshot mode they appear, except web views, which are painted over.
- Screenshot mode: masks follow the views' frames at the moment of the
  capture. During an animation in flight a mask may sit a few points off the
  content it covers until the animation ends.
- Touches carry no target view (`id` 0, or the screenshot's in screenshot
  mode): the player shows where the finger was, not what it hit.
- Native crashes are sent without the error buffer (see Errors).
- Only the key window is recorded (in an app without scenes, the
  application's key window): alerts and other windows above it are not, nor
  their touches.
- More than 2000 views on one screen: the rest is not recorded (logged once).

## Opting out

```swift
cohorly.optOutTracking()      // persisted: survives a relaunch
cohorly.hasOptedOutTracking() // true
cohorly.optInTracking()       // collect again; what was dropped stays dropped
```

`optOutTracking()` drops every queued event and profile update. Until
`optInTracking()`, `track()`, `people`, the `/alias` call of `identify()` and
flag requests do nothing (identity still changes locally). With
`CohorlyReplay` installed, replay stops and its queued chunks are deleted;
opting back in starts a new replay session.

## Delivery and retries

Queued events survive relaunch and are never dropped on a transient failure.
`CohorlyTransportError.httpError(status:retryAfter:)` carries the HTTP status and
the parsed `Retry-After`, driving a Mixpanel-style retry contract:

- **429** keeps the queue and backs off, honoring the server's `Retry-After`.
- **5xx / network** keeps the queue with exponential backoff (base 2s, doubling
  per consecutive failure, capped at `maxRetryDelay`, default 600s, +/-20% jitter).
- **413** halves the effective batch size and retries smaller (no data loss).
- **400** drops the offending batch permanently.
- **401** keeps the queue and backs off at the max delay.

A success resets the failure counter and clears backoff. While backing off, the
interval timer and size-triggered flushes are skipped; a manual `await flush()`
always forces an attempt. The persisted queue is capped at `maxQueueSize`
(default 1000), dropping the oldest events on overflow. Both `maxQueueSize` and
`maxRetryDelay` are parameters on `initialize(...)` / `init(...)`.

## Testing

```bash
cd sdks/ios
swift build
swift test
```

Or from the repo root, using the top-level `Package.swift` that points at these same
sources (this is what SPM consumers resolve against when adding the monorepo as a
dependency):

```bash
swift build
swift test
```

Unit tests use an in-memory storage implementation and a mock `CohorlyTransport` to cover
payload shape (`distinct_id`/`time`/`$insert_id`/`$lib`/`token`), batching (size and
interval triggered), retry-on-failure, identify/reset, and queue persistence across
instances.

## Publishing

Distribution is **SPM only**, via the public
[Gitarcitano/cohorly-swift](https://github.com/Gitarcitano/cohorly-swift)
mirror - already live. Per [docs/RELEASING.md](../../docs/RELEASING.md#sdk-releases):
push an `ios-vX.Y.Z` tag on the monorepo, `sync-sdks.yml` mirrors `Sources/`,
`Tests/`, `Package.swift` to that repo and tags it there with the bare version
(e.g. `0.2.0`, no `ios-v` prefix).

Deliberately not on CocoaPods: trunk stops accepting new podspecs
2026-12-02 (permanent read-only), not worth publishing into 5 months before
lock. `packages/sdk-react-native`'s native module vendors (copies) the small
device-info subset it needs instead of depending on this package - see that
package's README.
