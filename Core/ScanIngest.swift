import Foundation
import SwiftData

/// Coalescing ingest actor. CoreBluetooth fires didDiscover per advertisement packet —
/// with allowDuplicates on, that is hundreds per second in a dense environment.
/// Nothing touches SwiftData per-packet. We fold into an in-memory table and flush on a tick.
actor ScanIngest {

    struct Pending {
        var identifier: UUID
        var lastRSSI: Int
        var bestRSSI: Int
        var name: String?
        var decoded: DecodedAdvertisement
        var seenAt: Date
        var packets: Int
    }

    private var pending: [UUID: Pending] = [:]
    private var flushTask: Task<Void, Never>?
    private let container: ModelContainer
    private let flushInterval: Duration

    /// Live snapshot for the UI — read cheaply, never blocks on the store.
    private(set) var visible: [UUID: Pending] = [:]

    init(container: ModelContainer, flushInterval: Duration = .seconds(2)) {
        self.container = container
        self.flushInterval = flushInterval
    }

    func ingest(identifier: UUID, rssi: Int, advertisement: [String: Any], at date: Date = .now) {
        let decoded = AdvertisementDecoder.decode(advertisement)
        if var existing = pending[identifier] {
            existing.lastRSSI = rssi
            existing.bestRSSI = max(existing.bestRSSI, rssi)
            existing.name = decoded.localName ?? existing.name
            existing.decoded = merge(existing.decoded, decoded)
            existing.seenAt = date
            existing.packets += 1
            pending[identifier] = existing
        } else {
            pending[identifier] = Pending(identifier: identifier, lastRSSI: rssi, bestRSSI: rssi,
                                          name: decoded.localName, decoded: decoded,
                                          seenAt: date, packets: 1)
        }
        visible[identifier] = pending[identifier]
        scheduleFlush()
    }

    /// Advertisements are partial — a device may send name in one packet and service UUIDs in the next.
    /// The target shipped a bug where advertisement data overwrote richer interrogation results (fixed 1.5.1).
    /// Merge additively; never let a sparse packet erase a fuller one.
    private func merge(_ old: DecodedAdvertisement, _ new: DecodedAdvertisement) -> DecodedAdvertisement {
        var m = old
        m.localName = new.localName ?? old.localName
        m.serviceUUIDs = Array(Set(old.serviceUUIDs).union(new.serviceUUIDs))
        m.serviceData.merge(new.serviceData) { _, incoming in incoming }
        m.manufacturerData = new.manufacturerData ?? old.manufacturerData
        m.companyID = new.companyID ?? old.companyID
        m.companyName = new.companyName ?? old.companyName
        m.txPower = new.txPower ?? old.txPower
        m.isConnectable = new.isConnectable || old.isConnectable
        if !new.continuity.isEmpty { m.continuity = new.continuity }
        m.airPodsBattery = new.airPodsBattery ?? old.airPodsBattery
        return m
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [flushInterval] in
            try? await Task.sleep(for: flushInterval)
            await self.flush()
        }
    }

    func flush() async {
        flushTask = nil
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }

        let context = ModelContext(container)
        context.autosaveEnabled = false

        for (id, p) in batch {
            let descriptor = FetchDescriptor<Peripheral>(predicate: #Predicate { $0.identifier == id })
            let model = (try? context.fetch(descriptor))?.first ?? {
                let new = Peripheral(identifier: id, rssi: p.lastRSSI, at: p.seenAt)
                context.insert(new)
                return new
            }()

            if let name = p.name, name != model.name {
                model.nameHistory.append(NameChange(name: name, at: p.seenAt))
                model.name = name
            }
            model.lastSeen = p.seenAt
            model.lastRSSI = p.lastRSSI
            model.bestRSSI = max(model.bestRSSI, p.bestRSSI)
            model.isConnectable = p.decoded.isConnectable
            model.companyID = p.decoded.companyID
            model.companyName = p.decoded.companyName
            model.rawAdvertisement = p.decoded.manufacturerData
            model.continuityMessages = p.decoded.continuity
            if let ap = p.decoded.airPodsBattery {
                model.batteryPercent = [ap.left, ap.right].compactMap { $0 }.min() ?? model.batteryPercent
            }
        }
        try? context.save()
    }

    /// Devices not seen within the window drop out of the "currently visible" count
    /// while remaining in the all-time store — the distinction the target added in 1.6.
    func prune(olderThan interval: TimeInterval = 30, now: Date = .now) {
        visible = visible.filter { now.timeIntervalSince($0.value.seenAt) < interval }
    }
}
