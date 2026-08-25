import Foundation
import SwiftData

// Entity graph mirrors the dissected target: Peripheral -> Service -> Characteristic -> ValueSample.
// Built second, before any UI, because the target rebuilt this layer twice (CoreData 1.6, SwiftData 1.7.4).

@Model
final class Peripheral {
    #Index<Peripheral>([\.identifier], [\.lastSeen])
    @Attribute(.unique) var identifier: UUID

    var name: String?
    var nameHistory: [NameChange]
    var firstSeen: Date
    var lastSeen: Date

    var companyID: UInt16?          // SIG company identifier; nil when absent OR 0x0000
    var companyName: String?
    var modelIdentifier: String?    // e.g. iPhone15,3
    var marketingName: String?      // e.g. iPhone 14 Pro
    var firmwareVersion: String?
    var softwareVersion: String?

    var lastRSSI: Int
    var bestRSSI: Int
    var isConnectable: Bool
    var hasANCS: Bool
    var batteryPercent: Int?

    var rawAdvertisement: Data?
    var continuityMessages: [ContinuityMessage]

    @Relationship(deleteRule: .cascade, inverse: \Service.peripheral) var services: [Service]
    @Relationship(deleteRule: .cascade, inverse: \Sighting.peripheral) var sightings: [Sighting]

    init(identifier: UUID, rssi: Int, at date: Date = .now) {
        self.identifier = identifier
        self.nameHistory = []
        self.firstSeen = date
        self.lastSeen = date
        self.lastRSSI = rssi
        self.bestRSSI = rssi
        self.isConnectable = false
        self.hasANCS = false
        self.continuityMessages = []
        self.services = []
        self.sightings = []
    }
}

struct NameChange: Codable, Hashable { var name: String; var at: Date }
struct ContinuityMessage: Codable, Hashable { var type: UInt8; var label: String; var payload: Data }

@Model
final class Service {
    var uuidString: String
    var resolvedName: String?
    var isPrimary: Bool
    var peripheral: Peripheral?
    @Relationship(deleteRule: .cascade, inverse: \Characteristic.service) var characteristics: [Characteristic]

    init(uuidString: String, resolvedName: String?, isPrimary: Bool) {
        self.uuidString = uuidString; self.resolvedName = resolvedName
        self.isPrimary = isPrimary; self.characteristics = []
    }
}

@Model
final class Characteristic {
    var uuidString: String
    var resolvedName: String?
    var specDescription: String?
    var propertiesRaw: UInt              // CBCharacteristicProperties.rawValue
    var service: Service?
    @Relationship(deleteRule: .cascade, inverse: \ValueSample.characteristic) var samples: [ValueSample]
    @Relationship(deleteRule: .cascade, inverse: \WriteAttempt.characteristic) var writes: [WriteAttempt]

    init(uuidString: String, resolvedName: String?, specDescription: String?, propertiesRaw: UInt) {
        self.uuidString = uuidString; self.resolvedName = resolvedName
        self.specDescription = specDescription; self.propertiesRaw = propertiesRaw
        self.samples = []; self.writes = []
    }
}

@Model
final class ValueSample {
    var data: Data
    var at: Date
    var characteristic: Characteristic?
    init(data: Data, at: Date = .now) { self.data = data; self.at = at }
}

@Model
final class WriteAttempt {
    enum Status: Int, Codable { case queued, sent, acknowledged, failed }
    var data: Data
    var encoding: String        // "utf8" | "numeric" | "hex"
    var withResponse: Bool
    var statusRaw: Int
    var errorText: String?
    var at: Date
    var characteristic: Characteristic?

    init(data: Data, encoding: String, withResponse: Bool, at: Date = .now) {
        self.data = data; self.encoding = encoding; self.withResponse = withResponse
        self.statusRaw = Status.queued.rawValue; self.at = at
    }
    var status: Status { Status(rawValue: statusRaw) ?? .failed }
}

@Model
final class Sighting {
    var at: Date
    var latitude: Double?
    var longitude: Double?
    var rssi: Int
    var peripheral: Peripheral?
    init(at: Date, latitude: Double?, longitude: Double?, rssi: Int) {
        self.at = at; self.latitude = latitude; self.longitude = longitude; self.rssi = rssi
    }
}
