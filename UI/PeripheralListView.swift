import SwiftUI
import SwiftData

struct PeripheralListView: View {
    @Environment(BluetoothCentral.self) private var central
    @Query(sort: \Peripheral.lastRSSI, order: .reverse) private var peripherals: [Peripheral]
    @State private var showOnlyVisible = true
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { p in
                    NavigationLink(value: p.identifier) { PeripheralRow(peripheral: p) }
                }
            }
            .searchable(text: $search, prompt: "Name, company, or UUID")
            .navigationTitle("Peripherals")
            .navigationDestination(for: UUID.self) { PeripheralDetailView(identifier: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Scan", selection: Binding(
                        get: { central.mode },
                        set: { central.start($0) })
                    ) {
                        Label("Scanning", systemImage: "dot.radiowaves.left.and.right")
                            .tag(BluetoothCentral.ScanMode.foregroundAll)
                        Label("Background", systemImage: "moon")
                            .tag(BluetoothCentral.ScanMode.background)
                        Label("Paused", systemImage: "pause")
                            .tag(BluetoothCentral.ScanMode.paused)
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .status) {
                    Text("\(filtered.count) devices").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filtered: [Peripheral] {
        peripherals.filter { p in
            let recent = !showOnlyVisible || Date.now.timeIntervalSince(p.lastSeen) < 30
            guard recent else { return false }
            guard !search.isEmpty else { return true }
            let hay = [p.name, p.companyName, p.marketingName, p.identifier.uuidString]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return hay.contains(search.lowercased())
        }
    }
}

struct PeripheralRow: View {
    let peripheral: Peripheral

    var body: some View {
        HStack(spacing: 12) {
            SignalBars(rssi: peripheral.lastRSSI)
            VStack(alignment: .leading, spacing: 2) {
                // Piers' request against the target: never render a wall of "Unknown".
                // Fall back to the trailing UUID segment so rows stay distinguishable.
                Text(peripheral.name ?? peripheral.marketingName ?? shortID)
                    .font(.body.weight(.medium))
                    .foregroundStyle(peripheral.name == nil ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let company = peripheral.companyName {
                        Text(company).font(.caption).foregroundStyle(.secondary)
                    }
                    if let battery = peripheral.batteryPercent {
                        Label("\(battery)%", systemImage: batterySymbol(battery))
                            .font(.caption).labelStyle(.titleAndIcon)
                    }
                }
            }
            Spacer()
            if let percent = SignalCalibration.percent(peripheral.lastRSSI) {
                Text("\(percent)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        // DEFECT AVOIDED — the target crashes on long-press of this row (open since Oct 2025).
        // Keep the context menu free of any lazily-resolved relationship.
        .contextMenu {
            Button("Copy Identifier") { Pasteboard.copy(peripheral.identifier.uuidString) }
            if let name = peripheral.name { Button("Copy Name") { Pasteboard.copy(name) } }
        }
    }

    private var shortID: String { String(peripheral.identifier.uuidString.suffix(8)) }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case 90...:  "battery.100"
        case 65..<90: "battery.75"
        case 40..<65: "battery.50"
        case 15..<40: "battery.25"
        default:      "battery.0"
        }
    }
}

struct SignalBars: View {
    let rssi: Int
    @State private var showRaw = false      // tap to toggle % <-> RSSI, per the target's 1.7.5
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "cellularbars")
                .foregroundStyle(SignalCalibration.isValid(rssi) ? .primary : .tertiary)
            if showRaw { Text("\(rssi)").font(.system(size: 9).monospacedDigit()) }
        }
        .onTapGesture { showRaw.toggle() }
        .accessibilityLabel(SignalCalibration.percent(rssi).map { "Signal \($0) percent" } ?? "Signal unavailable")
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = s
        #endif
    }
}
#if canImport(UIKit)
import UIKit
#endif
