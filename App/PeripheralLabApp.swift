import SwiftUI
import SwiftData

@main
struct NearfieldApp: App {
    @State private var entitlements = Entitlements()
    @State private var central: BluetoothCentral
    private let container: ModelContainer

    init() {
        let schema = Schema([Peripheral.self, Service.self, Characteristic.self,
                             ValueSample.self, WriteAttempt.self, Sighting.self])
        // Scan data is disposable telemetry, not user documents. Local only, no CloudKit.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        container = try! ModelContainer(for: schema, configurations: config)
        _central = State(initialValue: BluetoothCentral(container: container))
    }

    var body: some Scene {
        WindowGroup {
            PeripheralListView()
                .environment(entitlements)
                .environment(central)
                .task { await entitlements.bootstrap() }   // listener-then-sweep, see Entitlements
        }
        .modelContainer(container)
    }
}
