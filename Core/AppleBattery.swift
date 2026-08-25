import Foundation
import CoreBluetooth

/// Two-path battery resolution for Apple hardware.
///
/// PATH A — passive. AirPods and Beats broadcast battery nibbles in the clear inside
/// Apple's 0x004C Proximity Pairing message (type 0x07). No connection, no pairing.
/// Handled in AdvertisementDecoder.parseProximityPairingBattery.
///
/// PATH B — connected. iPhone/iPad/Mac/Watch expose the standard Battery Service (0x180F)
/// over GATT to ALREADY-TRUSTED peers. Trust comes from both devices being signed into the
/// same primary iCloud account, NOT from anything this app does. That is the whole insight
/// behind the target's "no need to install the app on all your devices" claim.
///
/// UNVERIFIED: whether 0x180F is readable on every current Apple platform version, or
/// whether some models require an active classic-Bluetooth pairing in addition to iCloud
/// trust. Must be measured on real hardware before this ships as a headline feature.
enum AppleBattery {

    // CBUUID is not Sendable — compute rather than store, so there is no shared mutable state.
    static var service: CBUUID { CBUUID(string: KnownUUID.batteryService) }
    static var level:   CBUUID { CBUUID(string: KnownUUID.batteryLevel) }

    /// Only attempt Path B on devices worth the connection cost.
    /// Connecting indiscriminately is what drains the user's battery and gets the app uninstalled.
    static func isLikelyOwnAppleDevice(_ adv: DecodedAdvertisement) -> Bool {
        guard adv.companyID == KnownUUID.appleCompanyID, adv.isConnectable else { return false }
        // Nearby Info (0x10) is present on Apple devices in normal operation.
        // Handoff (0x0C) and Magic Switch (0x0B) only appear between same-account devices.
        let types = Set(adv.continuity.map(\.type))
        return types.contains(0x0C) || types.contains(0x0B) || types.contains(0x10)
    }

    static func parseLevel(_ data: Data) -> Int? {
        guard let byte = data.first, byte <= 100 else { return nil }
        return Int(byte)
    }

    /// Apple model identifier -> marketing name. This table is the maintained corpus and is
    /// the single highest-maintenance asset in the product. Refresh every hardware cycle.
    /// Seed from the identifier strings devices publish in Device Information (0x180A / 0x2A24).
    static func marketingName(for identifier: String) -> String? { AppleModelCatalog.shared[identifier] }
}

struct AppleModelCatalog: Sendable {
    static let shared = AppleModelCatalog()
    private let map: [String: String]
    private init() {
        if let url = Bundle.main.url(forResource: "apple-models", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        } else { map = [:] }
    }
    subscript(_ id: String) -> String? { map[id] }
}
