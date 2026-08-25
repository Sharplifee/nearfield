import Foundation
import Network
import NetworkExtension

/// Cross-layer identity binding. A device seen on BLE and simultaneously on Bonjour is the same
/// physical object — that link resolves "unknown peripheral" into "the HomePod in the kitchen"
/// far more reliably than any UUID lookup table.
///
/// Also provides the Wi-Fi BSSID location fingerprint. iOS gives NO Wi-Fi scan (NEHotspotHelper
/// needs an entitlement Apple effectively does not grant), but the CONNECTED BSSID is retrievable
/// and is a strong room/building-level anchor.
@Observable
@MainActor
final class NetworkPresence {

    struct Service: Identifiable, Hashable {
        var id: String { "\(name).\(type)" }
        var name: String
        var type: String
        var endpoint: String?
    }

    private(set) var services: [Service] = []
    private(set) var currentBSSID: String?
    private(set) var currentSSID: String?
    private var browsers: [NWBrowser] = []

    /// Types worth browsing for device identification. Extend freely.
    static let interestingTypes = [
        "_airplay._tcp", "_raop._tcp", "_homekit._tcp", "_hap._tcp",
        "_companion-link._tcp", "_sleep-proxy._udp", "_matter._tcp", "_matterc._udp",
        "_googlecast._tcp", "_spotify-connect._tcp", "_printer._tcp", "_ipp._tcp",
        "_ssh._tcp", "_smb._tcp", "_device-info._tcp"
    ]

    func startBrowsing() {
        stopBrowsing()
        for type in Self.interestingTypes {
            let params = NWParameters()
            params.includePeerToPeer = true      // picks up AWDL peers, not just infrastructure
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let found = results.compactMap { result -> Service? in
                        guard case let .service(name, t, _, _) = result.endpoint else { return nil }
                        return Service(name: name, type: t, endpoint: nil)
                    }
                    self.services.removeAll { $0.type == type }
                    self.services.append(contentsOf: found)
                }
            }
            browser.start(queue: .global(qos: .utility))
            browsers.append(browser)
        }
    }

    func stopBrowsing() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
    }

    /// Requires the Access WiFi Information capability AND location authorisation.
    /// Returns nil without both — check before promising the user a location fingerprint.
    func refreshWiFi() async {
        let network = await NEHotspotNetwork.fetchCurrent()
        currentSSID = network?.ssid
        currentBSSID = network?.bssid
    }

    /// Fuzzy bind: a Bonjour service whose name shares a token with the BLE local name is
    /// almost certainly the same device. Conservative on purpose — a false bind is worse than none.
    func candidateBinding(forBLEName name: String) -> Service? {
        let tokens = Set(name.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 })
        guard !tokens.isEmpty else { return nil }
        return services.first { svc in
            let svcTokens = Set(svc.name.lowercased().split(separator: " ").map(String.init))
            return !tokens.isDisjoint(with: svcTokens)
        }
    }
}
