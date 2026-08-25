import Foundation
import CoreBluetooth
import SwiftData
import Observation

/// Central role controller. The CBCentralManagerDelegate lives on a dedicated serial queue,
/// never on main, and forwards into the ScanIngest actor. This is the split the target
/// arrived at only after two rewrites.
@Observable
@MainActor
final class BluetoothCentral {

    enum ScanMode: String, CaseIterable, Sendable {
        case foregroundAll      // wildcard + duplicates: dense, accurate, foreground only
        case background         // service-filtered: the ONLY legal background scan on iOS
        case paused
    }

    private(set) var state: CBManagerState = .unknown
    private(set) var mode: ScanMode = .paused
    private(set) var visibleCount: Int = 0
    var backgroundServiceFilter: [CBUUID] = []

    private let bridge: CentralBridge
    let ingest: ScanIngest

    init(container: ModelContainer) {
        let ingest = ScanIngest(container: container)
        self.ingest = ingest
        self.bridge = CentralBridge(ingest: ingest)
        bridge.onStateChange = { [weak self] newState in
            Task { @MainActor in self?.state = newState }
        }
    }

    func start(_ mode: ScanMode) {
        self.mode = mode
        switch mode {
        case .foregroundAll:
            // Wildcard + duplicates. Illegal in background: iOS silently returns nothing.
            bridge.scan(services: nil, allowDuplicates: true)
        case .background:
            // Background REQUIRES explicit service UUIDs and IGNORES allowDuplicates.
            guard !backgroundServiceFilter.isEmpty else { self.mode = .paused; return }
            bridge.scan(services: backgroundServiceFilter, allowDuplicates: false)
        case .paused:
            bridge.stop()
        }
    }

    /// Rank service UUIDs seen in foreground sessions by how many distinct peripherals
    /// advertised them, so the user picks a background filter that will actually fire.
    /// This is the target's "suggests suitable service IDs" heuristic, made explicit.
    func suggestedBackgroundServices(from context: ModelContext, limit: Int = 8) -> [(uuid: String, devices: Int)] {
        let all = (try? context.fetch(FetchDescriptor<Service>())) ?? []
        let counts = Dictionary(grouping: all, by: \.uuidString)
            .mapValues { Set($0.compactMap { $0.peripheral?.identifier }).count }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    func connect(_ id: UUID) async throws -> InterrogationResult {
        try await bridge.interrogate(id)
    }

    func write(_ data: Data, to characteristic: CBUUID, on peripheral: UUID, withResponse: Bool) async throws {
        try await bridge.write(data, characteristic: characteristic, peripheral: peripheral, withResponse: withResponse)
    }
}

struct InterrogationResult: Sendable {
    struct Char: Sendable { var uuid: String; var properties: UInt; var value: Data? }
    struct Svc: Sendable { var uuid: String; var isPrimary: Bool; var characteristics: [Char] }
    var services: [Svc]
    var batteryPercent: Int?
    var firmware: String?
    var software: String?
    var model: String?
}

/// NSObject delegate bridge. @unchecked Sendable is deliberate and contained:
/// all mutable state is confined to `queue`, and every escape hops to the actor.
final class CentralBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.connor.nearfield.central", qos: .utility)
    private var manager: CBCentralManager!
    private let ingest: ScanIngest
    private var tracked: [UUID: CBPeripheral] = [:]
    private var pendingScan: (services: [CBUUID]?, duplicates: Bool)?

    var onStateChange: (@Sendable (CBManagerState) -> Void)?

    init(ingest: ScanIngest) {
        self.ingest = ingest
        super.init()
        // Restore identifier is mandatory for background relaunch after termination.
        manager = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.connor.nearfield.central",
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    func scan(services: [CBUUID]?, allowDuplicates: Bool) {
        queue.async { [self] in
            guard manager.state == .poweredOn else { pendingScan = (services, allowDuplicates); return }
            manager.stopScan()
            manager.scanForPeripherals(withServices: services, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates
            ])
        }
    }

    func stop() { queue.async { [self] in manager.stopScan() } }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateChange?(central.state)
        if central.state == .poweredOn, let p = pendingScan {
            pendingScan = nil
            scan(services: p.services, allowDuplicates: p.duplicates)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in restored { tracked[p.identifier] = p; p.delegate = self }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        tracked[peripheral.identifier] = peripheral
        peripheral.delegate = self
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        // Snapshot the dictionary before crossing the isolation boundary.
        let snapshot = advertisementData
        Task { await ingest.ingest(identifier: id, rssi: rssi, advertisement: snapshot) }
    }

    // MARK: Interrogation — continuation-based, with a hard deadline.

    private var interrogations: [UUID: CheckedContinuation<InterrogationResult, Error>] = [:]

    func interrogate(_ id: UUID) async throws -> InterrogationResult {
        // NOTE: callers from App Intents must NOT await this synchronously — see PeripheralIntents.swift.
        try await withThrowingTaskGroup(of: InterrogationResult.self) { group in
            group.addTask { try await self.performInterrogation(id) }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw InterrogationError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func performInterrogation(_ id: UUID) async throws -> InterrogationResult {
        // Implementation: connect -> discoverServices(nil) -> discoverCharacteristics(nil,for:)
        // -> discoverDescriptors -> readValue for every .read property -> setNotifyValue where supported.
        // Elided here; wire the delegate callbacks into `interrogations[id]`.
        throw InterrogationError.notImplemented
    }

    func write(_ data: Data, characteristic: CBUUID, peripheral: UUID, withResponse: Bool) async throws {
        guard let p = tracked[peripheral] else { throw InterrogationError.peripheralGone }
        guard p.state == .connected else { throw InterrogationError.notConnected }
        guard let ch = p.services?.flatMap({ $0.characteristics ?? [] }).first(where: { $0.uuid == characteristic })
        else { throw InterrogationError.characteristicNotFound }
        // Respect the properties bitmask — writing the wrong type is the #1 silent write failure.
        let type: CBCharacteristicWriteType =
            withResponse && ch.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse && !p.canSendWriteWithoutResponse {
            throw InterrogationError.notReadyForWrite
        }
        p.writeValue(data, for: ch, type: type)
    }
}

enum InterrogationError: LocalizedError {
    case timedOut, notImplemented, peripheralGone, notConnected, characteristicNotFound, notReadyForWrite
    var errorDescription: String? {
        switch self {
        case .timedOut: "The peripheral did not respond in time."
        case .notImplemented: "Interrogation path not yet wired."
        case .peripheralGone: "That peripheral is no longer in range."
        case .notConnected: "Connect to the peripheral first."
        case .characteristicNotFound: "That characteristic was not found on the connected peripheral."
        case .notReadyForWrite: "The peripheral is still processing the previous message."
        }
    }
}
