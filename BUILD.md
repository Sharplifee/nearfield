# Nearfield — clone build sheet

Clone of Bluetooth Inspector (id1509085044), rebuilt with the target's known defects
designed out and the monetization layer moved to step 3 instead of step 12.

## Xcode setup

1. New App project, SwiftUI, **Nearfield**, bundle `com.connor.nearfield`,
   deployment iOS 26 / macOS 26 / visionOS 26. Add a **Widget Extension** target for the
   Live Activity and an **App Clip** target later.
2. Drag the folders in as groups. Everything compiles as one module.
3. Signing & Capabilities on BOTH the app and widget targets:
   - App Groups: `group.com.connor.nearfield`  ← required, entitlement mirror lives here
   - Background Modes: **Uses Bluetooth LE accessories**, **Location updates**
4. Info.plist keys:
   - `NSBluetoothAlwaysUsageDescription`
   - `NSLocationWhenInUseUsageDescription`
   - `NSLocationAlwaysAndWhenInUseUsageDescription`
   - `NSSupportsLiveActivities` = YES
5. Build Settings → Swift Compiler → **Strict Concurrency Checking = Complete**, Swift 6 mode.
6. App Store Connect: one **non-consumable** IAP, product ID `com.connor.nearfield.pro`,
   Family Sharing ON. Add a local `.storekit` config file for simulator testing.

## Resources you must generate before first run

- `Resources/companies.json`, `services.json`, `characteristics.json`
  → `Scripts/build-sig-catalog.swift` against the SIG public repo. Public data. Free.
- `Resources/apple-models.json` — model identifier → marketing name.
  **This is the moat. Maintain it by hand, refresh every Apple hardware cycle.**

`SIGCatalog` intentionally `fatalError`s if these are missing so you cannot ship without them.

## Build order — do not reorder

1. `Core/BluetoothCentral.swift` — central + delegate bridge on a private queue.
2. `Data/Models.swift` + `Core/ScanIngest.swift` — coalescing actor. **Before any UI.**
   Test synthetically at 1000+ concurrent peripherals. The target rebuilt this twice
   because it shipped UI first.
3. `Store/Entitlements.swift` + `Store/ProGate.swift` — **before any gated feature exists.**
   Flip `isPro` by hand during development.
4. `Data/SIGCatalog.swift` + decoders.
5. `UI/PeripheralListView.swift`.
6. Interrogation path — `performInterrogation` in `BluetoothCentral.swift` is the one
   substantial stub left. Connect → discoverServices(nil) → discoverCharacteristics(nil,for:)
   → discoverDescriptors → readValue per `.read` → setNotifyValue per `.notify`/`.indicate`.
7. Write path (Pro).
8. `Core/AppleBattery.swift` — Path A ships free with the decoder; Path B needs hardware
   verification before you claim it in the listing.
9. Background scan + service filter suggestion.
10. Live Activity — `ScanActivityAttributes` carries pinned metrics, not just a count.
11. Core Location tagging + map. **Persist the zoom level** (target's users complain it resets).
12. App Intents — already written fire-and-return; do not make them synchronous.
13. `UI/PaywallView.swift` — replace `FeatureDemoView` with real looping demos.

## Defects designed out (all verified against the live target)

| Target defect | Where handled here |
|---|---|
| Company `0x0000` renders as "Ericsson Technology Licensing" | `SIGCatalog.company` returns nil for 0 |
| Crash on long-press of peripheral row | `PeripheralRow` context menu touches no lazy relationships |
| Crash expanding Apple Continuity → Number | `parseContinuity` is fully bounds-checked; detail view re-parses nothing |
| Only first characteristic per service (Apr 2026 regression) | `ForEach(service.characteristics)`, never `.first` |
| Shortcuts "Interrogate" times out | `StartInterrogationIntent` + `FetchInterrogationResultIntent` |
| Purchase restoration race | listener started before entitlement sweep in `bootstrap()` |
| Silent purchase failure | every catch sets `lastResult`; restore always shows progress + terminal state |
| Purchased but Pro won't unlock | `mirrorToAppGroup()` on every entitlement change |
| Map zoom resets | store `MapCameraPosition` in `@AppStorage` when you build step 11 |
| Wall of "Unknown" devices | row falls back to trailing 8 chars of the UUID |
| No distance readout | `SignalCalibration.distanceRange` returns a range, never a false point estimate |
| No user guide, 4.5 years | write it at v1.0, not v2 |

## Genuinely unverified — needs hardware

- Battery Path B (`0x180F` read on same-iCloud-account Apple devices). Untested.
  Do not put it in the App Store description until measured on real devices.
- `SignalCalibration.modelOffsets` are all zero placeholders. Measure with a fixed
  reference beacon before shipping the percentage as accurate.
- Apple Continuity TLV type labels are community-derived, not documented by Apple.

## Reuse into existing projects

- `ScanIngest` drops into **Home Monitoring System** as the BLE sensor-fusion ingest layer.
- `AppleBattery` Path B gives per-device battery telemetry across the MacBook / iPad /
  Apple TV mesh with no agent installed on any of them.
- `ScanActivityAttributes.pinned` is the **LiveActivityLab** Island-as-primary-surface
  mechanic applied to BLE characteristic values.
