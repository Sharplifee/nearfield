import Foundation

/// Public Bluetooth SIG assigned-numbers lookup.
/// Source: https://bitbucket.org/bluetooth-SIG/public/src/main/assigned_numbers/
/// Ship the YAML in Resources/, convert to JSON with Scripts/build-sig-catalog.swift.
///
/// DEFECT AVOIDED — the target renders company ID 0x0000 as "Ericsson Technology Licensing"
/// for any device with absent or zero manufacturer data. Most-reported inaccuracy against it.
struct SIGCatalog: Sendable {
    static let shared = SIGCatalog()

    private let companies: [UInt16: String]
    private let services: [String: String]
    private let characteristics: [String: CharacteristicEntry]

    struct CharacteristicEntry: Codable, Sendable { let name: String; let description: String? }

    private init() {
        let raw: [String: String] = Self.load("companies")
        companies = raw.reduce(into: [:]) { out, kv in
            if let id = UInt16(kv.key, radix: 16) { out[id] = kv.value }
        }
        services = Self.load("services")
        characteristics = Self.load("characteristics")
    }

    func company(_ id: UInt16?) -> String? {
        guard let id, id != 0x0000 else { return nil }   // <- the guard the target is missing
        return companies[id]
    }

    func serviceName(_ uuid: String) -> String? { services[normalise(uuid)] }
    func characteristic(_ uuid: String) -> CharacteristicEntry? { characteristics[normalise(uuid)] }

    /// 16-bit UUIDs arrive from CoreBluetooth as "180F", 128-bit in full form.
    /// Collapse the Bluetooth Base UUID so both hit the same table.
    private func normalise(_ uuid: String) -> String {
        let u = uuid.uppercased()
        if u.hasSuffix("-0000-1000-8000-00805F9B34FB"), u.hasPrefix("0000") {
            return String(u.dropFirst(4).prefix(4))
        }
        return u
    }

    private static func load<T: Decodable>(_ name: String) -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(T.self, from: data)
        else { fatalError("SIG catalog resource \(name).json missing — run Scripts/build-sig-catalog.swift") }
        return decoded
    }
}

enum KnownUUID {
    static let batteryService         = "180F"
    static let batteryLevel           = "2A19"
    static let deviceInformation      = "180A"
    static let firmwareRevision       = "2A26"
    static let softwareRevision       = "2A28"
    static let modelNumber            = "2A24"
    static let manufacturerName       = "2A29"
    static let appleCompanyID: UInt16 = 0x004C
}
