import SwiftUI
import SwiftData

struct PeripheralDetailView: View {
    let identifier: UUID
    @Environment(BluetoothCentral.self) private var central
    @Query private var matches: [Peripheral]

    init(identifier: UUID) {
        self.identifier = identifier
        _matches = Query(filter: #Predicate<Peripheral> { $0.identifier == identifier })
    }

    private var peripheral: Peripheral? { matches.first }

    var body: some View {
        List {
            if let p = peripheral {
                Section("Identity") {
                    LabeledContent("Name", value: p.name ?? "—")
                    LabeledContent("Company", value: p.companyName ?? "Unknown")
                    LabeledContent("Model", value: p.marketingName ?? p.modelIdentifier ?? "—")
                    LabeledContent("Firmware", value: p.firmwareVersion ?? "—")
                    LabeledContent("Signal", value: SignalCalibration.percent(p.lastRSSI).map { "\($0)% (\(p.lastRSSI) RSSI)" } ?? "—")
                    if let range = SignalCalibration.distanceRange(rssi: p.lastRSSI, txPower: nil) {
                        LabeledContent("Estimated range",
                                       value: String(format: "%.1f–%.1f m", range.lowerBound, range.upperBound))
                    }
                }

                if !p.continuityMessages.isEmpty {
                    Section("Apple Continuity") {
                        // DEFECT AVOIDED — the target crashes expanding these. Every field is a
                        // plain decoded value; nothing here re-parses on tap.
                        ForEach(p.continuityMessages, id: \.self) { message in
                            DisclosureGroup(message.label) {
                                LabeledContent("Type", value: String(format: "0x%02X", message.type))
                                LabeledContent("Length", value: "\(message.payload.count) bytes")
                                Text(message.payload.map { String(format: "%02X", $0) }.joined(separator: " "))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                // DEFECT AVOIDED — the target regressed in Apr 2026 to showing only the first
                // characteristic per service. Iterate the full array explicitly, never `.first`.
                ForEach(p.services) { service in
                    Section(service.resolvedName ?? service.uuidString) {
                        ForEach(service.characteristics) { ch in
                            NavigationLink { CharacteristicView(characteristic: ch) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ch.resolvedName ?? ch.uuidString)
                                    if let d = ch.specDescription {
                                        Text(d).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if service.characteristics.isEmpty {
                            Text("No characteristics discovered").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(peripheral?.name ?? "Peripheral")
        .task {
            if let p = peripheral { _ = try? await central.connect(p.identifier) }
        }
    }
}

struct CharacteristicView: View {
    let characteristic: Characteristic

    var body: some View {
        List {
            Section("Current value") {
                Text(characteristic.samples.last.map { $0.data.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "—")
                    .font(.body.monospaced()).textSelection(.enabled)
            }

            Section("History") {
                ForEach(characteristic.samples.reversed()) { sample in
                    LabeledContent(sample.at.formatted(date: .omitted, time: .standard),
                                   value: String(decoding: sample.data, as: UTF8.self))
                }
            }
            .proGated(.valueHistory)

            Section("Write") { WriteEditor(characteristic: characteristic) }
                .proGated(.write)
        }
        .navigationTitle(characteristic.resolvedName ?? "Characteristic")
    }
}

struct WriteEditor: View {
    let characteristic: Characteristic
    @State private var text = ""
    @State private var encoding: ValueEncoding = .text
    @State private var withResponse = true

    var body: some View {
        Picker("Encoding", selection: $encoding) {
            ForEach(ValueEncoding.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        TextField("Value", text: $text)
        Toggle("Await acknowledgement", isOn: $withResponse)
        Button("Send") { /* route through BluetoothCentral.write */ }
            .disabled(ValueEncoder.encode(text, as: encoding) == nil)
    }
}
