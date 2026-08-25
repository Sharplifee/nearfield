import Foundation
import CoreML

/// REPLACES THE LOOKUP TABLE AS THE MOAT.
///
/// The dissected target's advantage is a hand-maintained corpus of company IDs and model strings.
/// That corpus decays: it cannot classify a device whose manufacturer never registered, whose
/// company ID is spoofed, or whose model is newer than the last app update — which is why users
/// see walls of "Unknown" and "Ericsson Technology Licensing".
///
/// A classifier over the STRUCTURE of the advertisement does not decay the same way. Advertising
/// interval, payload length, service UUID composition, flags byte, TX power, name entropy and
/// address rotation behaviour together fingerprint a device CLASS (earbuds / fitness tracker /
/// tag / TV / medical / industrial sensor) even when every identifier is unknown or randomised.
///
/// Train offline on labelled captures; ship a small Core ML model. Falls back to the table.
struct AdvertisementFeatures: Sendable {
    var payloadLength: Double
    var serviceUUIDCount: Double
    var has16BitUUIDs: Double
    var has128BitUUIDs: Double
    var hasServiceData: Double
    var hasManufacturerData: Double
    var manufacturerDataLength: Double
    var hasLocalName: Double
    var localNameEntropy: Double        // randomised names score high
    var txPower: Double                 // -127 when absent
    var isConnectable: Double
    var advertisingIntervalMs: Double   // measured, not advertised — needs >= 3 packets
    var intervalJitter: Double          // stable interval implies a purpose-built beacon
    var addressRotates: Double          // resolvable private address behaviour
    var continuityTypeMask: Double      // bitmask of Apple 0x004C message types present

    var mlMultiArray: MLMultiArray? {
        let values: [Double] = [payloadLength, serviceUUIDCount, has16BitUUIDs, has128BitUUIDs,
                                hasServiceData, hasManufacturerData, manufacturerDataLength,
                                hasLocalName, localNameEntropy, txPower, isConnectable,
                                advertisingIntervalMs, intervalJitter, addressRotates,
                                continuityTypeMask]
        guard let array = try? MLMultiArray(shape: [NSNumber(value: values.count)], dataType: .double)
        else { return nil }
        for (i, v) in values.enumerated() { array[i] = NSNumber(value: v) }
        return array
    }
}

enum DeviceClass: String, CaseIterable, Sendable {
    case earbuds, headphones, watch, phone, tablet, computer, tv, speaker
    case fitnessTracker, medicalSensor, environmentSensor, tag, beacon
    case vehicle, pointOfSale, industrial, peripheralInput, unknown
}

final class DeviceFingerprinter: @unchecked Sendable {
    // MLModel is not Sendable but is immutable after load; isolation is by construction.
    static let shared = DeviceFingerprinter()
    private let model: MLModel?

    private init() {
        model = (try? MLModel(contentsOf: Bundle.main.url(forResource: "DeviceClassifier",
                                                          withExtension: "mlmodelc") ?? URL(fileURLWithPath: "/")))
    }

    /// Interval measurement is the single most discriminative feature and requires observing
    /// the same device over time — which is exactly what the ScanIngest coalescing table already
    /// accumulates. It is free data the target throws away.
    static func features(from decoded: DecodedAdvertisement,
                         packetTimestamps: [Date],
                         addressChanged: Bool) -> AdvertisementFeatures {
        let intervals = zip(packetTimestamps.dropFirst(), packetTimestamps)
            .map { $0.timeIntervalSince($1) * 1000 }
        let meanInterval = intervals.isEmpty ? 0 : intervals.reduce(0,+) / Double(intervals.count)
        let jitter = intervals.count < 2 ? 0 :
            (intervals.reduce(0) { $0 + pow($1 - meanInterval, 2) } / Double(intervals.count)).squareRoot()

        return AdvertisementFeatures(
            payloadLength: Double(decoded.manufacturerData?.count ?? 0),
            serviceUUIDCount: Double(decoded.serviceUUIDs.count),
            has16BitUUIDs: decoded.serviceUUIDs.contains { $0.count == 4 } ? 1 : 0,
            has128BitUUIDs: decoded.serviceUUIDs.contains { $0.count > 8 } ? 1 : 0,
            hasServiceData: decoded.serviceData.isEmpty ? 0 : 1,
            hasManufacturerData: decoded.manufacturerData == nil ? 0 : 1,
            manufacturerDataLength: Double(decoded.manufacturerData?.count ?? 0),
            hasLocalName: decoded.localName == nil ? 0 : 1,
            localNameEntropy: decoded.localName.map(shannonEntropy) ?? 0,
            txPower: Double(decoded.txPower ?? -127),
            isConnectable: decoded.isConnectable ? 1 : 0,
            advertisingIntervalMs: meanInterval,
            intervalJitter: jitter,
            addressRotates: addressChanged ? 1 : 0,
            continuityTypeMask: decoded.continuity.reduce(0) { $0 + pow(2, Double($1.type % 20)) }
        )
    }

    static func shannonEntropy(_ s: String) -> Double {
        let counts = s.reduce(into: [Character: Int]()) { $0[$1, default: 0] += 1 }
        let n = Double(s.count)
        return -counts.values.reduce(0.0) { acc, c in
            let p = Double(c) / n
            return acc + p * log2(p)
        }
    }

    func classify(_ features: AdvertisementFeatures) -> (DeviceClass, Double) {
        guard let model, let input = features.mlMultiArray,
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["features": input]),
              let out = try? model.prediction(from: provider),
              let label = out.featureValue(for: "classLabel")?.stringValue,
              let cls = DeviceClass(rawValue: label)
        else { return (.unknown, 0) }
        let confidence = out.featureValue(for: "classProbability")?
            .dictionaryValue[label as NSString]?.doubleValue ?? 0
        return (cls, confidence)
    }
}
