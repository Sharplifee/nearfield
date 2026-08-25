import AppIntents
import Foundation

/// ARCHITECTURAL FIX vs THE TARGET.
/// Users report the target's "Interrogate" action returning "Operation took too long to respond."
/// That is not a bug — it is a synchronous BLE connect + full GATT walk inside an App Intent,
/// which has a hard execution budget. Correct shape: START and return a job handle immediately,
/// then poll or fetch the result with a second intent.

struct StartInterrogationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Interrogation"
    static let description = IntentDescription(
        "Begins connecting to a peripheral and walking its GATT tree. Returns a job ID immediately."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Peripheral") var peripheral: PeripheralEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try Gate.requirePro(.shortcuts)
        let job = await InterrogationJobs.shared.start(peripheral.id)
        return .result(value: job.uuidString)
    }
}

struct FetchInterrogationResultIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Interrogation Result"
    static let description = IntentDescription(
        "Returns the result of a started interrogation. Use Wait or Repeat if it is not ready yet."
    )

    @Parameter(title: "Job ID") var jobID: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ServiceEntity]> & ProvidesDialog {
        try Gate.requirePro(.shortcuts)
        guard let id = UUID(uuidString: jobID) else { throw IntentError.badJobID }
        switch await InterrogationJobs.shared.status(id) {
        case .running:
            return .result(value: [], dialog: "Still interrogating.")
        case .failed(let message):
            throw IntentError.failed(message)
        case .finished(let services):
            return .result(value: services, dialog: "Found \(services.count) services.")
        }
    }
}

struct ReadValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Value"
    @Parameter(title: "Peripheral") var peripheral: PeripheralEntity
    @Parameter(title: "Characteristic UUID") var characteristic: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Data> {
        try Gate.requirePro(.shortcuts)
        let value = try await InterrogationJobs.shared.readValue(peripheral.id, characteristic)
        return .result(value: value)
    }
}

struct WriteValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Write Value"

    enum Encoding: String, AppEnum {
        case text, number, hex
        static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Encoding")
        static let caseDisplayRepresentations: [Encoding: DisplayRepresentation] =
            [.text: "Text", .number: "Number", .hex: "Hex"]
    }

    @Parameter(title: "Peripheral") var peripheral: PeripheralEntity
    @Parameter(title: "Characteristic UUID") var characteristic: String
    @Parameter(title: "Value") var value: String
    @Parameter(title: "Encoding") var encoding: Encoding
    @Parameter(title: "Await Acknowledgement", default: true) var withResponse: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        try Gate.requirePro(.write)
        guard let data = ValueEncoder.encode(value, as: encoding) else { throw IntentError.badValue }
        try await InterrogationJobs.shared.write(data, to: characteristic,
                                                 on: peripheral.id, withResponse: withResponse)
        return .result()
    }
}

enum ValueEncoder {
    static func encode(_ string: String, as encoding: WriteValueIntent.Encoding) -> Data? {
        switch encoding {
        case .text:   string.data(using: .utf8)
        case .number: UInt64(string).map { withUnsafeBytes(of: $0.littleEndian) { Data($0) } }
        case .hex:    hex(string)
        }
    }
    static func hex(_ s: String) -> Data? {
        let cleaned = s.replacingOccurrences(of: " ", with: "")
                       .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard cleaned.count % 2 == 0 else { return nil }
        var out = Data(capacity: cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            out.append(byte); idx = next
        }
        return out
    }
}

/// Intents cannot be hidden from the Shortcuts gallery based on entitlement, so gate inside perform()
/// with an error Shortcuts renders usefully.
enum Gate {
    @MainActor static func requirePro(_ feature: ProFeature) throws {
        let isPro = UserDefaults(suiteName: "group.com.connor.nearfield")?.bool(forKey: "isPro") ?? false
        guard isPro else { throw IntentError.proRequired(feature.title) }
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case proRequired(String), badJobID, badValue, failed(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .proRequired(let f): "\(f) requires Nearfield Pro. Open the app to unlock."
        case .badJobID:           "That job ID is not valid."
        case .badValue:           "The value could not be encoded with the chosen encoding."
        case .failed(let m):      "Interrogation failed: \(m)"
        }
    }
}
