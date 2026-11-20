# CohorlyCrash test fixtures

## `kscrash/`

KSCrash JSON reports, the converter's input. Derived from the example reports
shipped in the KSCrash repository at tag `2.6.1` (`Example-Reports/`, MIT
license, Copyright (c) 2012 Karl Stenerud):

| Fixture | Source | Changes |
| --- | --- | --- |
| `segv.json` | `BadPointer.json` | trimmed (see below) |
| `nsexception.json` | `NSException.json` | trimmed; `crash.last_exception_backtrace` added (KSCrash 2.x writes the exception's own call stack there), built from the crashed thread's frames below the abort path |
| `abort.json` | `Abort.json` | trimmed |
| `cpp.json` | `abort.json` | `crash.error` replaced by a `cpp_exception` error as KSCrash 2.6 records `std::runtime_error` |
| `fatal.json` | `segv.json` | `crash.error` replaced by `EXC_BREAKPOINT`/`SIGTRAP`; a `libswiftCore.dylib` image with the `crash_info_message` a Swift `fatalError` leaves |

Trimmed means: only `report`, `binary_images` (the images some frame
references), `system` (bundle keys, `machine`, `system_version`), `crash.error`,
`crash.threads` (index, crashed, name, dispatch queue, backtrace) and `user`;
registers, stack dumps, notable addresses and process state were dropped.
`report.timestamp` uses the 2.6 format (ISO 8601 with microseconds) and `user`
holds the keys `CrashUserInfo` writes. The reports are 32-bit (2011 device):
addresses are still formatted as 16 hex digits.

## `metrickit/`

`MXDiagnostic.jsonRepresentation()` dictionaries in the shape Apple documents
for `MXCrashDiagnostic`, `MXHangDiagnostic` and `MXCPUExceptionDiagnostic`
(`callStackTree` + `diagnosticMetaData`). Written by hand: the simulator does
not deliver MetricKit diagnostics. Addresses and UUIDs reuse the spike's
captures (`spikes/vel-1784-native-crash/fixtures/ios-*.json`).
