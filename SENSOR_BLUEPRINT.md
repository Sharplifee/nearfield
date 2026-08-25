# Nearfield — full sensor-mesh blueprint

Expansion of the Bluetooth Inspector clone from a single-modality scanner into a
multi-modal localisation platform. Everything below is publicly documented Apple
framework surface. Nothing requires jailbreak, private API, or protocol defeat.

---

## 1. What is actually reachable — and what is not

Three widely-believed things are false. Design around them or lose months.

**UWB is not passive.** `NearbyInteraction` will not range an arbitrary BLE device.
Only two paths exist: a peer running your app that exchanges an `NIDiscoveryToken`,
or an accessory implementing Apple's UWB Accessory Protocol (DW3000 / SR150 class)
that hands you a configuration blob over its own GATT characteristic. There is no
sniffing mode. Plan for cooperating hardware or plan without UWB.

**iOS has no Wi-Fi scan.** `NEHotspotHelper` requires an entitlement Apple grants to
essentially nobody. `NEHotspotNetwork.fetchCurrent()` gives you the connected SSID and
BSSID with Access WiFi Information + location authorisation. That is a location
fingerprint, not a ranging source. Useful, but do not model it as one.

**SensorKit is research-gated.** Ambient light, device usage, and detailed pedometrics
need an approved Apple research application. Not shippable in a consumer app.

**Bluetooth address randomisation is permanent.** iOS hands you a rotating,
app-scoped `CBPeripheral.identifier`, never a MAC. Cross-session identity must be
inferred from advertisement structure — which is exactly what
`Intelligence/DeviceFingerprint.swift` is for.

---

## 2. Modality ladder — accuracy, cost, availability

| Modality | 1σ accuracy | Availability | Battery | Background |
|---|---|---|---|---|
| UWB distance | 0.10 m | Cooperating peer or accessory only | High | No |
| UWB direction | ~10° | iPhone 11+, camera assist improves | High | No |
| Acoustic ToF | 0.30 m | Own devices, LOS, < 10 m | Medium | **Yes** |
| iBeacon range | 1–3 m | Any 0x02 broadcaster. Free. | Low | Yes |
| Barometric floor | 1 m vertical | Any iPhone 6+ | Very low | Yes |
| BLE RSSI | 4–8 m | Always | Low | Yes, filtered |
| ARKit pose | 0.02 m (observer) | Foreground, camera | Very high | No |
| Dead reckoning | ~2% of distance | Always | Low | Yes |
| Wi-Fi BSSID | room-level | Connected network only | Nil | No |
| Bonjour presence | binary | Same subnet | Low | Limited |
| Magnetic anomaly | qualitative | Always | Very low | Yes |

**The unlock nobody uses: iBeacon ranging.** Any device broadcasting Apple continuity
type 0x02 can be handed straight to `CLLocationManager.startRangingBeacons` and Apple
returns a filtered metre estimate plus a proximity class. That is 1–3 m accuracy for
free, on hardware you do not control, with zero extra components. The dissected target
decodes 0x02 as a text label and stops there.

**The second unlock: the barometer.** ±1 m vertical means you can state which floor a
device is on. No amount of RSSI will ever tell you that. `CMAltimeter` is nearly free
in battery terms and runs in the background.

---

## 3. Fusion architecture

```
CoreBluetooth ─┐
NearbyInteraction ─┤
CoreLocation beacons ─┤
AVAudioEngine chirp ─┼──► RFObservation ──► ParticleFilter ──► PositionEstimate
CMAltimeter ─┤ (per target) (mean + covariance)
CMMagnetometer ─┤ │
NWBrowser / NEHotspot ─┘ ▼
▲ SensorMesh.guidance()
│ (bearing, distance, radius)
ARKit / CoreMotion ──── observerPosition
```

Every sensor reduces to one `RFObservation`. The estimator consumes only that type,
so modalities can be added, removed, or degraded without touching the filter.

**Why a particle filter and not a Kalman filter.** BLE RSSI likelihood is non-Gaussian
and multipath-skewed, and the problem is genuinely multi-modal: a device 5 m away
through a wall and 12 m away down a corridor produce identical RSSI. An EKF collapses
that into one confident wrong answer. Particles carry both hypotheses until a UWB
range, a floor change, or operator movement kills one. Low-variance systematic
resampling, 2000 particles, resample at ESS < N/2.

**Likelihood is evaluated in dB space, not metre space, for RSSI.** Inverting the path
loss model to metres before comparison inflates far-field error exponentially. This
single detail is why most RSSI trilateration falls apart past 8 m.

**Path loss exponent is estimated online**, not hardcoded. Once any metric-truth
modality has constrained the solution, regress RSSI against known distance to recover
n — which ranges from 1.6 in a corridor acting as a waveguide to 4.0 through walls.
The environment class comes out of the data.

---

## 4. Duty cycle — the real constraint

Running everything at once flattens an iPhone in ~90 minutes. `SensorMesh` runs a
four-tier ladder with auto-demotion:

| Tier | Active | Drain/hr |
|---|---|---|
| Idle | BLE service-filtered background | ~2% |
| Tracking | + iBeacon + motion + altimeter + Bonjour | ~7% |
| Hunting | + UWB + acoustic | ~16% |
| Precision | + ARKit world tracking, hard 10-min cap | ~34% |

Auto-demote out of Hunting once the 95% radius drops below 0.5 m — there is no reason
to burn radio once the ellipse has collapsed. Tear down higher tiers before building
lower ones: UWB and Wi-Fi share the front end on some SoCs and interleave badly.

---

## 5. Background persistence — three independent legs

The target has one leg (BLE state restoration) and it is fragile. Three legs, any one
of which can relaunch the process:

1. **`CBCentralManagerOptionRestoreIdentifierKey`** — relaunch on service-filtered
   BLE discovery. Requires explicit service UUIDs; wildcard is silently ignored.
2. **`CLMonitor` beacon conditions** (iOS 17+) — relaunch on a tracked beacon entering
   or leaving range. Survives termination.
3. **Continuous `AVAudioSession`** (`.playAndRecord`, `.mixWithOthers`, `.voiceChat`) —
   the strongest legal anchor on iOS, and it doubles as both the acoustic ranging
   transport and the Home Monitoring System intercom. One session, three jobs.

Plus `BGTaskScheduler` processing tasks for opportunistic catch-up. Each leg keeps the
others warm; losing one does not lose the session.

---

## 6. Identity — replacing the corpus with a classifier

The target's moat is a hand-maintained table of company IDs and Apple model strings.
It decays: unregistered manufacturers, spoofed company IDs, hardware newer than the
last app update. Hence the walls of "Unknown".

A classifier over advertisement *structure* does not decay the same way. Fifteen
features — payload length, service UUID composition, service data presence, TX power,
local-name Shannon entropy, measured advertising interval, interval jitter, address
rotation behaviour, Apple continuity type bitmask — fingerprint a device **class**
even when every identifier is unknown or randomised.

The measured advertising interval is the most discriminative single feature and is
free: `ScanIngest` already accumulates packet timestamps per device and currently
throws them away.

Keep the lookup table as the fast path. The classifier is the fallback that turns
"Unknown" into "probably a fitness tracker, 0.83".

---

## 7. Cross-layer identity binding

A device seen simultaneously on BLE and on Bonjour is one physical object. Browsing
`_airplay._tcp`, `_hap._tcp`, `_companion-link._tcp`, `_matter._tcp`,
`_sleep-proxy._udp` and friends with `includePeerToPeer = true` resolves anonymous
peripherals into named devices far more reliably than any UUID table. Bind
conservatively on shared name tokens — a false bind is worse than none.

---

## 8. Alerting — AlarmKit as the escalation ceiling

Five escalation levels: silent log, notification, time-sensitive, critical alert
(entitlement required), and **alarm** via AlarmKit (iOS 26).

AlarmKit exposes the privileged wake path reserved to Apple's Clock app for fifteen
years. An alarm breaks Focus, silent mode, and Do Not Disturb. A notification does not.
That is what converts a background BLE event from a badge you notice tomorrow into
"the house wakes you because the freezer sensor went silent at 3 a.m."

Request AlarmKit authorisation at rule-creation time, never at fire time. A denied
prompt at 3 a.m. is a failed alert.

Absence is not an event — poll for it. `evaluateAbsences` runs on the background timer.

---

## 9. Hardware extension — the cheap force multiplier

One UWB anchor per room collapses the whole localisation problem. A DW3000 or SR150
module implementing Apple's accessory protocol costs roughly $10–15 at hobby volume.
Three anchors give true trilateration at 10 cm and turn the particle filter from a
search aid into a positioning system.

For the Home Monitoring System this is the highest-leverage hardware purchase
available: three anchors per floor, powered from existing outlets, and every BLE
sensor in the house acquires a metric position.

---

## 10. What is genuinely unverified

- AlarmKit scheduling API surface — iOS 26, signatures must be checked against the
  shipping SDK. The file compiles the call site out behind `canImport`.
- Battery Path B (`0x180F` on same-iCloud-account Apple devices) — inferred from the
  target developer's own wording, never measured.
- Acoustic ToF in real rooms — 0.3 m is theoretical from cross-correlation resolution.
  Reverberation, speaker/mic frequency response above 18 kHz, and AGC behaviour will
  all degrade it. Measure before claiming.
- `SignalCalibration.modelOffsets` are zero placeholders.
- Apple continuity TLV type labels are community-derived, not documented.
- Duty-cycle drain figures are estimates for an iPhone 15 Pro class device.

## 11. Scope discipline

This is built for finding your own hardware and monitoring your own environment:
lost sensors, misplaced devices, home telemetry, RF diagnostics. Two things it should
never become, and which the architecture deliberately does not favour: covert tracking
of a person, and defeating another device's anti-stalking protections. Precise ranging
requires cooperating hardware precisely because Apple designed it that way — that
constraint is a feature, not an obstacle to route around.
