import Foundation

/// Cristian's algorithm over WatchConnectivity.
///
/// Every cross-device observation carries a timestamp, and the particle filter's predict step
/// uses dt. If the two clocks disagree by even 200 ms while the operator is walking at 1.4 m/s,
/// the Watch's observations get attributed to positions 30 cm wrong — which is larger than the
/// UWB error you were trying to exploit.
///
/// `Date` on watchOS and iOS both track NTP and are usually within tens of milliseconds, but
/// "usually" is not a foundation. Measure it.
actor ClockSync {

    private(set) var offsetNanos: Int64 = 0        // add to remote timestamps to get local time
    private(set) var roundTripNanos: UInt64 = 0
    private(set) var sampleCount = 0
    private var samples: [(offset: Int64, rtt: UInt64)] = []

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Called on the initiator when the pong comes back.
    func record(sentAt t0: UInt64, remoteReceived t1: UInt64, remoteReplied t2: UInt64, receivedAt t3: UInt64) {
        let rtt = t3 &- t0 &- (t2 &- t1)
        // Offset = ((t1 - t0) + (t2 - t3)) / 2, in signed arithmetic.
        let offset = (Int64(bitPattern: t1 &- t0) + Int64(bitPattern: t2 &- t3)) / 2
        samples.append((offset, rtt))
        if samples.count > 32 { samples.removeFirst() }
        sampleCount += 1

        // Take the offset from the LOWEST-RTT sample, not the mean. Asymmetric delay is the
        // dominant error and the fastest round trip is the least contaminated by it.
        if let best = samples.min(by: { $0.rtt < $1.rtt }) {
            offsetNanos = best.offset
            roundTripNanos = best.rtt
        }
    }

    /// Confidence bound on the offset. Half the best RTT is the irreducible uncertainty.
    var uncertaintySeconds: Double { Double(roundTripNanos) / 2e9 }

    func correct(_ remote: Date) -> Date {
        remote.addingTimeInterval(Double(offsetNanos) / 1e9)
    }
}
