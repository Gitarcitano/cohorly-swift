# CohorlySwift

Standalone Swift Package for Cohorly (hosted, Mixpanel-style product analytics). Supports
iOS 15+ and macOS 12+ (macOS so `swift test` runs locally/in CI without a simulator).

**Documentation:** [iOS SDK reference](https://cohorly-docs.velloalabs.com/sdks/ios) · [Quickstart](https://cohorly-docs.velloalabs.com/quickstart) · [HTTP API](https://cohorly-docs.velloalabs.com/api/ingestion)

## Install

The whole cohorly monorepo is directly addable as a Swift Package - a root-level
`Package.swift` points at these sources, so no separate repo is needed.

### Xcode

File > Add Package Dependencies..., enter the repo URL
(`https://github.com/giovannetarcitano/cohorly`), pick a version rule (e.g. "Up to Next
Major" from `0.1.0`, matching the release tags below), and add the **Cohorly** library
product to your app target.

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/giovannetarcitano/cohorly", from: "0.1.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "Cohorly", package: "cohorly")]
    ),
]
```

Version rules track git tags on the monorepo (e.g. `0.1.0`, `0.2.0`); any tag also
updates the npm SDKs in `packages/*`, but this package only pulls in `sdks/ios/Sources`.

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
never hit the network. A failed evaluation keeps the previous cache.

- `isFeatureEnabled(_ key: String) -> Bool` - false for unknown/unloaded flags.
- `getFeatureFlag(_ key: String) -> JSONValue` - `.string(variant)` when the flag
  serves a variant, else `.bool(enabled)`.
- `getFeatureFlagPayload(_ key: String) -> JSONValue?`
- `currentFeatureFlags() -> [String: FlagResult]`
- `reloadFeatureFlags() async` - re-evaluate for the current distinct id.
- `onFeatureFlags(_ callback:) -> () -> Void` - fires after every successful
  reload (and immediately when flags are already loaded); returns unsubscribe.

Auto-captured properties on every event: `$lib` ("ios"), `$os`, `$os_version`, `$model`,
`$screen_width` / `$screen_height` (the last three via `UIKit` where available, e.g. skipped
on macOS/watchOS).

Events and profile updates are queued in memory and persisted to `storage` (UserDefaults by
default) so nothing is lost across relaunch; the queue auto-flushes every 5 seconds or every
20 events (both configurable). All mutable state is confined to a private serial
`DispatchQueue`, so the client is safe to call from any thread.

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
