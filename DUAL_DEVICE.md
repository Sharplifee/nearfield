# Nearfield — iPhone 16 Pro + Apple Watch, collective operation

The Watch is not an accessory, a remote, or a mirror. It is a second radio at a
different point in space, running its own scan, with its own barometer and its own
inertial frame. That is what changes the mathematics.

---

## 1. Hardware surface — what each node actually brings

**iPhone 16 Pro**
- A18 Pro — runs the 2000-particle filter at 50 Hz without breaking a sweat
- Second-generation Ultra Wideband (U2) — longer range than U1, ~1.5x
- Thread radio — 802.15.4 mesh visibility
- LiDAR — ARKit scene reconstruction gives wall geometry as an occlusion prior
- Barometer, magnetometer, dual-frequency GNSS
- Camera Control button — one-press sweep trigger without unlocking
- Full background BLE with `CBCentralManagerOptionRestoreIdentifierKey`

**Apple Watch (Series 9 / 10 / Ultra 2 class)**
- U2 UWB
- BLE 5.3 central role
- Barometric altimeter (Series 6+)
- Full CMDeviceMotion — attitude, heading, gravity
- Haptic engine — the eyes-free output channel
- Double Tap (Series 9+) — trigger a sweep with the hand that isn't holding anything
- Digital Crown — scrub target list or threshold without looking

**Role split.** Watch senses and reports. Phone estimates and commands. No fusion
logic on watchOS — the link is intermittent and the Watch would produce a divergent
estimate the moment it drops.

---

## 2. The four things two nodes buy you

### 2.1 Decorrelated observations
A single walking operator produces highly correlated RSSI error: same body, same
orientation, same multipath geometry, sample after sample. Averaging correlated error
does not reduce it. Wrist and pocket sit 0.6–0.9 m apart with different body shadowing,
so their errors are largely independent — and independent errors are what actually make
a particle filter converge indoors.

The Watch's observer position is offset by the calibrated body baseline in the heading
direction before it enters the filter. Treating both nodes as co-located throws the
entire geometric advantage away.

### 2.2 Differential barometry
Two barometers on one body. Both drift identically with weather; the difference does not.
Subtracting cancels ambient pressure change entirely. Floor detection goes from "reliable
for twenty minutes" to "reliable all day", and any sustained change in the difference is
real vertical movement rather than a front moving through.

Median rather than mean over the recent window — raising your arm produces large transient
outliers that a mean absorbs and a median ignores.

### 2.3 The wrist sweep — a directional antenna made of a person
This is the technique worth the whole build. A BLE radio is omnidirectional. A human arm
and torso are not: body tissue attenuates 2.4 GHz by roughly 10–20 dB. Rotating the wrist
through a full circle modulates RSSI as a function of wrist heading, and the maximum points
at the transmitter.

Result: a coarse bearing (±30–40°) on **any** BLE device, with no UWB, no cooperating
hardware, no accessory. The operator's own body is the directional element.

Guardrails that make it honest rather than a random-number generator:
- Below ~6 dB dynamic range across the sweep, the shadow pattern never developed — discard.
- Circular concentration below 0.35 means the peak is not a peak — discard.
- Concentration maps directly to the angular sigma handed to the filter, so a weak sweep
  contributes a wide, weak constraint rather than a confident wrong arrow.

### 2.4 Instant lateral discrimination
When both nodes see the same advertisement, the sign of the bias-corrected RSSI difference
tells you which side of the body the target is on. Available every packet, zero user action.
The running mean difference across all targets is the antenna/body offset and is subtracted;
what remains is information. Below 3 dB it is noise and is suppressed.

---

## 3. Persistence on watchOS — different rules from iOS

There is no `bluetooth-central` background mode on watchOS. When the app leaves the
foreground, CoreBluetooth stops. Three options, in ascending order of runtime and of
how much justification they require:

| Mechanism | Runtime | Honest use |
|---|---|---|
| Foreground + always-on display | Indefinite, high drain | Active search |
| `WKExtendedRuntimeSession` | ~1 hour, ~2 min expiry warning | A bounded hunt |
| `HKWorkoutSession` | Indefinite while active | Walking a building — Survey Mode |

Default is the extended runtime session for hunts. The workout session is exposed
explicitly as "Survey Mode" and only when the user is genuinely walking a site, where a
walking workout is a truthful record of what they are doing. Do not fake a workout to
farm runtime — it is dishonest to the user and to HealthKit.

`extendedRuntimeSessionWillExpire` gives roughly two minutes. Flush the outbox and buzz
the wrist before the radio dies rather than going silent mid-hunt.

---

## 4. Transport — WatchConnectivity tier selection is not optional

| API | Semantics | Use for |
|---|---|---|
| `sendMessageData` | Immediate, both reachable, drops otherwise | Guidance, sweeps, clock |
| `transferUserInfo` | Queued, FIFO, guaranteed, survives termination | Observation batches |
| `updateApplicationContext` | Latest wins, overwrites | Node status only |
| `transferFile` | Bulk | Log export, sweep archives |

Observations are **batched at 25** before shipping. One message per BLE advertisement will
saturate the link within seconds — the Watch can see hundreds of packets per second in a
dense environment. Outbox is capped at 400 and drops oldest; a hundred queued
`transferUserInfo` calls will hit the system queue limit and start failing silently.

Status goes by application context always. You only ever care about the current battery
level, never its history, and the overwrite semantics are exactly right for that.

---

## 5. Clock synchronisation — do not skip this

Every cross-device observation carries a timestamp, and the filter's predict step uses dt.
A 200 ms clock disagreement while the operator walks at 1.4 m/s attributes the Watch's
observations to positions 30 cm wrong — larger than the UWB error you were trying to exploit.

Cristian's algorithm over the link: ping/pong with monotonic `DispatchTime` on both ends,
offset from the **lowest-RTT** sample rather than the mean, because asymmetric delay is the
dominant error and the fastest round trip is the least contaminated. Uncertainty bound is
half the best RTT; expose it, and widen observation sigma when it grows.

---

## 6. Haptic guidance — the actual UX unlock

Phone in pocket, both hands free, steered by wrist taps. Two variables encoded on two
distinct dimensions:

- **Distance → pulse rate.** 2 Hz at 0.5 m down to 0.25 Hz at 20 m, logarithmic, so
  perceived progress feels linear while real distance halves. Humans read rate changes
  pre-attentively — no attention budget consumed.
- **Bearing → pulse type.** `.directionUp` when aligned, `.click` when off,
  `.failure` when behind.

Never encode both on rate. Two variables on one dimension is unreadable.

Alignment window is 35°, wider than instinct suggests, because wrist heading noise is
±10–15° and a tight window flickers maddeningly at the boundary.

Wrong floor overrides everything: three `.directionUp` / `.directionDown` pulses then
silence. There is no point steering someone horizontally toward a device one storey up.

---

## 7. The uncertainty ring is the interface

The Watch shows a circle whose diameter is the 95% horizontal radius, with the bearing
arrow inside it. As the filter converges the ring collapses toward the centre. An arrow
with no radius is a lie the moment the estimate is diffuse — which is most of the time
early in a hunt, and exactly when a user is most likely to trust it.

---

## 8. Duty cycle across two batteries

The Watch battery is the binding constraint, not the phone's. Roughly:

| Watch tier | Active | Drain/hr |
|---|---|---|
| Reporting | BLE scan, batched uplink | ~12% |
| Guided | + haptics at 1 Hz + motion | ~20% |
| Sweep | Burst only, 6 s | negligible |
| Survey (workout) | Continuous, all sensors | ~30% |

Guidance push is throttled to 1 Hz. Pushing on every filter iteration flattens a Watch
in about an hour and adds nothing — the estimate does not move meaningfully faster than
a person walks.

---

## 9. Build order

1. `Shared/DualDeviceProtocol.swift` — the wire types. Both targets link this.
2. `Shared/DeviceLink.swift` + `Shared/ClockSync.swift` — get the link solid and the clock
   measured before any sensor work. Everything downstream depends on trustworthy timestamps.
3. `Watch/WatchSensorNode.swift` — BLE scan + altimeter + uplink. Verify observations arrive
   and are correctly timestamped before adding anything else.
4. `Phone/DualNodeFusion.swift` — ingest, body-baseline offset, differential barometry.
5. `Watch/WatchHapticGuidance.swift` + guidance downlink. Test blindfolded; if you cannot
   find a device without looking at the wrist, the encoding is wrong.
6. Wrist sweep, both ends. Last, because it depends on motion, BLE, and link all being solid.

## 10. Xcode configuration

- Add a **watchOS App** target with a **Watch App for iOS App** relationship so the bundle
  IDs pair automatically.
- `Shared/` files: membership in BOTH targets.
- Watch target capabilities: HealthKit (for Survey Mode), Background Modes → Workout
  processing, Bluetooth (Watch does not need a background mode declaration, it needs a
  runtime session).
- `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription` on the Watch target.
- `NSMotionUsageDescription` on both.
- `WKBackgroundModes` array including `workout-processing` on the Watch.

---

## 11. Genuinely unverified — check before you commit

- **`NISession` on watchOS.** NearbyInteraction is available on watchOS, but direction
  measurement is generally NOT supported on Watch hardware — distance only. `UWBRanging`
  as written assumes iOS capabilities. Query `NISession.deviceCapabilities` on the Watch
  before promising direction and gate the UI on the answer.
- **Watch BLE scan rate under an extended runtime session.** Throttling behaviour is not
  documented. The wrist sweep needs at least ~4 samples/second to resolve a bearing in a
  6-second arc; if watchOS throttles below that, the sweep must lengthen or move to
  foreground-only.
- **`.handGestureShortcut(.primaryAction)`** for Double Tap — confirm the modifier against
  the watchOS SDK you are building with; the API moved during the watchOS 11 cycle.
- **Body baseline calibration swing constants** (`0.4 + swing * 0.04`) are placeholders.
  Measure across several people and both wrists.
- **Watch RSSI bias** — assumed to be a constant offset absorbed by `lateralBias`. It may be
  orientation-dependent rather than constant, in which case it needs to be a function of
  wrist attitude, not a scalar.
- **Drain figures** are estimates, not measurements.
- All of this is written but **never compiled** — no Swift toolchain was available.
