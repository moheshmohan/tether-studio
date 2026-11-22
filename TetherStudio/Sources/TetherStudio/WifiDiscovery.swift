import Foundation
import GPhotoC

/// A Sony camera that answered on the local network.
struct WifiCamera: Equatable {
    enum Service: Equatable {
        case pcRemote       // remote control: what this app connects to
        case smartphone     // Smartphone Connect is running instead of PC Remote
        case unknown
    }

    let host: String        // "192.168.1.69", or "host:port" when typed that way
    var model: String = ""
    var service: Service = .unknown
}

struct WifiSearchResult {
    var cameras: [WifiCamera] = []
    /// errno when the search could not be sent on any interface, else nil.
    var sendErrno: Int32?

    /// macOS answers "no route to host" for every local address when the app
    /// has been denied Local Network access.
    var looksBlocked: Bool { sendErrno == EHOSTUNREACH || sendErrno == EPERM }
}

/// Finds the camera on whatever network this Mac is on (SSDP, the way Sony's
/// own apps do) and reads which of its Wi-Fi services is running.
enum WifiDiscovery {
    static let descriptionPort = 64321
    static let controlPort = 15740

    // MARK: - pure parsing (unit-tested)

    /// `http://192.168.1.69:64321/dd.xml` → host, port, path.
    static func parseLocation(_ location: String) -> (host: String, port: Int, path: String)? {
        guard let url = URL(string: location.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "http", let host = url.host, !host.isEmpty else { return nil }
        return (host, url.port ?? 80, url.path.isEmpty ? "/" : url.path)
    }

    static func friendlyName(in xml: String) -> String {
        firstMatch(#"<friendlyName>\s*([^<]*?)\s*</friendlyName>"#, in: xml) ?? ""
    }

    /// Path of the capability document named by the device description.
    static func capabilityPath(in xml: String) -> String? {
        guard let raw = firstMatch(#"<SCPDURL>\s*([^<\s]+)\s*</SCPDURL>"#, in: xml) else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url.path }
        return raw.hasPrefix("/") ? raw : "/" + raw
    }

    /// The camera says `X_PTP_MediaServerSupport: Enable` only while
    /// Smartphone Connect is running; in PC Remote it says `Disable`.
    static func service(in xml: String) -> WifiCamera.Service {
        guard let value = firstMatch(#"<[^<>/]*MediaServer[^<>]*>\s*([\w.]+)\s*<"#, in: xml)
                ?? firstMatch(#"MediaServer\w*\s*=\s*"([^"]+)""#, in: xml) else { return .unknown }
        return ["ENABLE", "ENABLED", "TRUE", "1", "ON"].contains(value.uppercased()) ? .smartphone : .pcRemote
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - network (blocking; call off the main thread)

    static func search(waitMilliseconds: Int32 = 2500) -> WifiSearchResult {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = zv_ssdp_search(&buf, buf.count, waitMilliseconds)
        if n < 0 { return WifiSearchResult(cameras: [], sendErrno: -n) }

        var result = WifiSearchResult()
        for line in String(cString: buf).split(separator: "\n") {
            guard let loc = parseLocation(String(line)),
                  !result.cameras.contains(where: { $0.host == loc.host }) else { continue }
            result.cameras.append(describe(host: loc.host, port: loc.port, path: loc.path))
        }
        return result
    }

    /// The same question asked without needing any incoming packets: which
    /// addresses on this Mac's networks accept connections on the camera's
    /// control port, and which of those describe themselves as a Sony camera.
    /// Used when the search above hears nothing, which is what happens when
    /// the macOS firewall has not (yet) been told to allow this app.
    static func scan(timeoutMilliseconds: Int32 = 1500) -> [WifiCamera] {
        var buf = [CChar](repeating: 0, count: 8192)
        guard zv_scan_subnets(Int32(controlPort), timeoutMilliseconds, &buf, buf.count) > 0 else { return [] }
        return String(cString: buf).split(separator: "\n")
            .map { describe(host: String($0)) }
            .filter { !$0.model.isEmpty || $0.service != .unknown }
    }

    /// The address that worked last time first (one direct connection, well
    /// under a second when the camera is there), then the search, then (when
    /// allowed) the scan: the first that finds something.
    static func find(remembered: String?, allowScan: Bool) -> WifiSearchResult {
        var result = WifiSearchResult()
        if let remembered, let camera = probe(host: remembered).camera,
           !camera.model.isEmpty || camera.service != .unknown {
            result.cameras = [camera]
            return result
        }
        result = search()
        if result.cameras.isEmpty && allowScan { result.cameras = scan() }
        return result
    }

    /// Model and running service from the camera's description documents.
    static func describe(host: String, port: Int = descriptionPort, path: String = "/dd.xml") -> WifiCamera {
        var camera = WifiCamera(host: host)
        guard let dd = httpGet(host: host, port: port, path: path) else { return camera }
        camera.model = friendlyName(in: dd)
        var all = dd
        if let capPath = capabilityPath(in: dd), let did = httpGet(host: host, port: port, path: capPath) {
            all += "\n" + did
        }
        camera.service = service(in: all)
        return camera
    }

    /// For an address typed by hand or remembered from last time: nil when
    /// nothing listens on the camera's control port there.
    static func probe(host: String) -> (camera: WifiCamera?, sysErrno: Int32) {
        let r = zv_tcp_reachable(host, Int32(controlPort), 1500)    // a ":port" in host wins
        guard r == 0 else { return (nil, -r) }
        let bare = String(host.split(separator: ":").first ?? "")
        let described = describe(host: bare)
        return (WifiCamera(host: host, model: described.model, service: described.service), 0)
    }

    private static func httpGet(host: String, port: Int, path: String) -> String? {
        var buf = [CChar](repeating: 0, count: 200_000)
        let n = zv_http_get(host, Int32(port), path, &buf, buf.count, 3000)
        return n > 0 ? String(cString: buf) : nil
    }
}
