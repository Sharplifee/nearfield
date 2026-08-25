import Foundation
import CoreBluetooth

/// Pure, Sendable decode of a CoreBluetooth advertisement dictionary.
/// No I/O, no persistence — safe to call from the ingest actor.
struct DecodedAdvertisement: Sendable, Hashable {
    var localName: String?
    var serviceUUIDs: [String] = []
    var overflowServiceUUIDs: [String] = []
    var solicitedServiceUUIDs: [String] = []
    var serviceData: [String: Data] = [:]
    var manufacturerData: Data?
    var companyID: UInt16?
    var companyName: String?
    var txPower: Int?
    var isConnectable: Bool = false
    var continuity: [ContinuityMessage] = []
    var airPodsBattery: AirPodsBattery?
}

struct AirPodsBattery: Sendable, Hashable {
    var left: Int?; var right: Int?; var caseLevel: Int?
    var leftCharging: Bool; var rightCharging: Bool; var caseCharging: Bool
}

enum AdvertisementDecoder {

    static func decode(_ adv: [String: Any]) -> DecodedAdvertisement {
        var out = DecodedAdvertisement()
        out.localName = adv[CBAdvertisementDataLocalNameKey] as? String
        out.txPower = (adv[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        out.isConnectable = (adv[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false

        out.serviceUUIDs = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        out.overflowServiceUUIDs = (adv[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        out.solicitedServiceUUIDs = (adv[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []

        if let sd = adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            out.serviceData = Dictionary(uniqueKeysWithValues: sd.map { ($0.key.uuidString, $0.value) })
        }

        if let mfg = adv[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 2 {
            out.manufacturerData = mfg
            let id = UInt16(mfg[mfg.startIndex]) | (UInt16(mfg[mfg.startIndex + 1]) << 8)  // little-endian
            // Company 0x0000 is a real SIG entry but is overwhelmingly a padding/absent artefact.
            out.companyID = id == 0 ? nil : id
            out.companyName = SIGCatalog.shared.company(out.companyID)

            if id == KnownUUID.appleCompanyID {
                let payload = mfg.dropFirst(2)
                out.continuity = parseContinuity(Data(payload))
                out.airPodsBattery = out.continuity
                    .first { $0.type == 0x07 }
                    .flatMap { parseProximityPairingBattery($0.payload) }
            }
        }
        return out
    }

    /// Apple's 0x004C payload is a sequence of TLV messages: [type][length][value...].
    /// Types are undocumented; labels below are community-derived and treated as best-effort.
    /// DEFECT AVOIDED — the target crashes when expanding a continuity field; every read here is bounds-checked.
    static func parseContinuity(_ data: Data) -> [ContinuityMessage] {
        var messages: [ContinuityMessage] = []
        var i = data.startIndex
        while i + 1 < data.endIndex {
            let type = data[i]
            let length = Int(data[i + 1])
            let valueStart = i + 2
            let valueEnd = valueStart + length
            guard length > 0, valueEnd <= data.endIndex else { break }   // bail, never trap
            messages.append(ContinuityMessage(type: type,
                                              label: continuityLabel(type),
                                              payload: Data(data[valueStart..<valueEnd])))
            i = valueEnd
        }
        return messages
    }

    static func continuityLabel(_ type: UInt8) -> String {
        switch type {
        case 0x02: "iBeacon"
        case 0x05: "AirDrop"
        case 0x06: "Home Kit"
        case 0x07: "Proximity Pairing"
        case 0x08: "Hey Siri"
        case 0x09: "AirPlay Target"
        case 0x0A: "AirPlay Source"
        case 0x0B: "Magic Switch"
        case 0x0C: "Handoff"
        case 0x0D: "Tethering Target"
        case 0x0E: "Tethering Source"
        case 0x0F: "Nearby Action"
        case 0x10: "Nearby Info"
        case 0x12: "Find My"
        default:   String(format: "Unknown (0x%02X)", type)
        }
    }

    /// Proximity Pairing (0x07) carries AirPods battery nibbles in the clear.
    /// Layout is undocumented and version-dependent — treat a short payload as no data, never as zero.
    static func parseProximityPairingBattery(_ p: Data) -> AirPodsBattery? {
        guard p.count >= 11 else { return nil }
        let b = [UInt8](p)
        func level(_ nibble: UInt8) -> Int? { nibble == 0x0F ? nil : Int(nibble) * 10 }
        let podsByte = b[6], caseByte = b[7], chargeByte = b[8]
        return AirPodsBattery(
            left: level(podsByte >> 4),
            right: level(podsByte & 0x0F),
            caseLevel: level(caseByte & 0x0F),
            leftCharging:  chargeByte & 0b0000_0001 != 0,
            rightCharging: chargeByte & 0b0000_0010 != 0,
            caseCharging:  chargeByte & 0b0000_0100 != 0
        )
    }
}
