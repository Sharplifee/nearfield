import SwiftUI
import SwiftData

@main
struct NearfieldApp: App {
    @State private var entitlements = Entitlements()
    @State private var central: BluetoothCentral
    private let container: ModelContainer

    init() {
        EventLog.configure(url: "https://lbvaosyfikkpvcwksiph.supabase.co", apiKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxidmFvc3lmaWtrcHZjd2tzaXBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUwMDg0MDksImV4cCI6MjA5MDU4NDQwOX0.Gh9whjmUPz4rdKYr5yo8ZHS0nSNpkQUOwdIladX6mG4", project: "nearfield")   // append-only event log (public.event_log)
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
