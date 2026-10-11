import Foundation
import Network

struct CastDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let endpoint: NWEndpoint
}

extension CastDevice {
    init?(_ result: NWBrowser.Result) {
        guard case .service(let serviceName, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata { txt = record.dictionary }
        // "ca" is a capability bitmask and bit 0 means "has a screen". This skips speakers and speaker groups.
        if let capabilities = txt["ca"].flatMap(Int.init), capabilities & 1 == 0 { return nil }
        self.init(id: txt["id"] ?? serviceName,
                  name: txt["fn"] ?? serviceName,
                  model: txt["md"] ?? "Chromecast",
                  endpoint: result.endpoint)
    }
}

/// Finds Chromecasts on the local network over Bonjour (`_googlecast._tcp`).
final class DeviceBrowser {
    /// Called on the main queue with the current device list, sorted by name.
    var onChange: (([CastDevice]) -> Void)?

    private var browser: NWBrowser?

    func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            let devices = results
                .compactMap(CastDevice.init)
                .filter { seen.insert($0.id).inserted }  // the same TV can show up once per network interface
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self?.onChange?(devices)
        }
        browser.start(queue: .main)
        self.browser = browser
    }
}
