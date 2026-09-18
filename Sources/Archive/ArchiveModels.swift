import Foundation

// The shapes the Eileen Darby Images REST API (v1) actually returns, decoded
// with `.convertFromSnakeCase`. Only the fields the app reads are declared;
// anything else in a response is ignored, so a server that adds fields keeps
// working. Fields the API documents as "absent is null, never omitted" are
// optionals here for the same reason in reverse: a null must never be a
// decoding failure.

// MARK: - Authentication

public struct CodeResponse: Codable, Equatable, Sendable {
    public var sent: Bool
    public var expiresIn: Int
}

public struct LoginResponse: Codable, Equatable, Sendable {
    public var accessToken: String
    public var expiresIn: Int
    public var refreshToken: String
    public var session: Int
    public var device: String?
}

public struct RefreshResponse: Codable, Equatable, Sendable {
    public var accessToken: String
    public var expiresIn: Int
    public var session: Int?
}

public struct ArchiveSession: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var device: String?
    public var created: Int?
    public var lastUsed: Int?
    public var expires: Int?
    public var revoked: Int?
    public var current: Bool?
    public var active: Bool?
}

struct SessionsResponse: Codable {
    var sessions: [ArchiveSession]
}

// MARK: - Scanners

/// A scanning machine the archive knows. Every transfer names one; the row
/// flagged `unknown` is the placeholder for "nobody wrote it down", which the
/// API refuses exactly as it refuses none at all, so it is never offered.
public struct ArchiveScanner: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var unknown: Bool?

    public init(id: Int, name: String, unknown: Bool? = nil) {
        self.id = id
        self.name = name
        self.unknown = unknown
    }

    public var isEligible: Bool { unknown != true }
}

/// `{ "scanners": [ … ] }` as the other lists are shaped, or a bare array.
struct ScannersResponse: Decodable {
    var scanners: [ArchiveScanner]

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let list = try? keyed.decode([ArchiveScanner].self, forKey: .scanners) {
            scanners = list
        } else {
            scanners = try decoder.singleValueContainer().decode([ArchiveScanner].self)
        }
    }

    enum CodingKeys: String, CodingKey { case scanners }
}

// MARK: - Shows

public struct ArchiveShow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var category: String?
    public var number: String?
    public var name: String?
    public var date: ShowDate?
    public var notes: ShowNotes?

    public struct ShowDate: Codable, Equatable, Sendable {
        public var year: Int?
        public var month: Int?
        public var day: Int?
    }

    public struct ShowNotes: Codable, Equatable, Sendable {
        public var `public`: String?
        public var `private`: String?
        public var qc: String?
    }

    public init(id: String, category: String? = nil, number: String? = nil, name: String? = nil,
                date: ShowDate? = nil, notes: ShowNotes? = nil) {
        self.id = id
        self.category = category
        self.number = number
        self.name = name
        self.date = date
        self.notes = notes
    }

    /// "The Iceman Cometh (1946)" — the name with the year when there is one,
    /// or the id alone for a show that has no name yet.
    public var displayName: String {
        let base = (name?.isEmpty == false) ? name! : id
        if let y = date?.year { return "\(base) (\(y))" }
        return base
    }
}

public struct ShowPage: Codable, Equatable, Sendable {
    public var total: Int?
    public var page: Int?
    public var perpage: Int?
    public var shows: [ArchiveShow]
}

// MARK: - Inventory

public struct ArchiveInventory: Codable, Equatable, Sendable {
    public var show: String
    public var total: Int?
    public var types: [InventoryType]
}

public struct InventoryType: Codable, Equatable, Identifiable, Sendable {
    public var type: String
    public var name: String?
    public var total: Int?
    public var ranges: [InventoryRange]

    public init(type: String, name: String? = nil, total: Int? = nil, ranges: [InventoryRange] = []) {
        self.type = type
        self.name = name
        self.total = total
        self.ranges = ranges
    }

    public var id: String { type }
    public var displayName: String { name ?? type }
}

public struct InventoryRange: Codable, Hashable, Sendable {
    /// The format's *name* ("120mm Rollei"); the id comes from the assets.
    public var format: String?
    public var roll: String?
    public var range: String

    public init(format: String? = nil, roll: String? = nil, range: String) {
        self.format = format
        self.roll = roll
        self.range = range
    }
}

// MARK: - Assets

public struct ArchiveAsset: Codable, Equatable, Identifiable, Sendable {
    public var assetid: String
    public var show: String?
    public var type: String?
    public var roll: String?
    /// Zero padded, e.g. "0012" — the API keeps it as text because that form
    /// is the identifier.
    public var number: String
    public var version: String?
    public var canonical: Bool?
    public var format: Int?
    /// Filled in when a scan arrives, not when the asset is registered.
    public var image: AssetImage?

    public var id: String { assetid }

    /// A scan has been filed for this asset.
    public var hasScan: Bool {
        (image?.filesize ?? 0) > 0 || image?.extension != nil
    }

    /// The middle part of an assetid, which is how a path names an asset:
    /// `T00316_NA0012_00` → `NA0012`. Nil for anything not of that shape.
    public static func pathName(ofAssetID id: String) -> String? {
        let parts = id.split(separator: "_")
        return parts.count == 3 ? String(parts[1]) : nil
    }

    /// The numeric part of `number`, ignoring a suffix letter: "0012A" → 12.
    public var numberValue: Int? {
        let digits = number.prefix { $0.isNumber }
        return Int(digits)
    }
}

public struct AssetImage: Codable, Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    public var bitdepth: Int?
    public var colordepth: Int?
    public var filesize: Int?
    public var `extension`: String?
}

public struct AssetPage: Codable, Equatable, Sendable {
    public var total: Int?
    public var page: Int?
    public var perpage: Int?
    public var assets: [ArchiveAsset]
}

public struct AssetBatch: Codable, Equatable, Sendable {
    public var show: String?
    public var count: Int?
    public var assets: [ArchiveAsset]
}

// MARK: - Uploads

public struct ArchiveUpload: Codable, Equatable, Sendable {
    public var id: Int
    public var assetid: String?
    public var filename: String?
    public var state: String
    public var bytes: Int?
    public var chunkSize: Int?
    public var chunks: Int?
    public var received: Int?
    public var percent: Double?
    public var outstanding: [Int]
    public var outstandingTotal: Int?
    public var completed: Int?
    public var error: String?
    public var rendered: Flexible?
    public var renderError: String?

    public var isComplete: Bool { state == "complete" }
    public var isAbandoned: Bool { state == "abandoned" }
    /// Derivatives exist. `rendered` is null until they do, then a value the
    /// contract doesn't pin down — a timestamp today — so only its presence
    /// is read.
    public var isRendered: Bool { rendered?.raw != nil }
    /// The true count of blocks still to send; `outstanding` itself is capped
    /// at 50 entries.
    public var remaining: Int { outstandingTotal ?? outstanding.count }
}

/// A JSON scalar of unknown type, kept as text. Decodes a number, string or
/// bool; a null decodes to `raw == nil`. For fields whose presence matters
/// more than their type.
public struct Flexible: Codable, Equatable, Sendable {
    public var raw: String?

    public init(raw: String?) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { raw = nil }
        else if let i = try? c.decode(Int.self) { raw = String(i) }
        else if let d = try? c.decode(Double.self) { raw = String(d) }
        else if let b = try? c.decode(Bool.self) { raw = String(b) }
        else if let s = try? c.decode(String.self) { raw = s }
        else { raw = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let raw { try c.encode(raw) } else { try c.encodeNil() }
    }
}

// MARK: - Errors

struct ErrorBody: Codable {
    var error: String
}

public enum ArchiveError: Error, LocalizedError, Equatable {
    /// The server answered with an error status and, usually, a message.
    case http(status: Int, message: String)
    /// No usable token: never signed in, or the refresh was refused (which is
    /// also what a revoked device sees). The client stops rather than loops.
    case unauthenticated
    case invalidBaseURL(String)
    case network(String)
    case decoding(String)
    case badResponse
    /// Trouble on this machine — an unreadable file. Not worth a retry.
    case file(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): return "\(message) (HTTP \(status))"
        case .unauthenticated: return "Not signed in"
        case .invalidBaseURL(let s): return "Not a usable API address: \(s)"
        case .network(let s): return s
        case .decoding(let s): return "Unexpected reply from the server: \(s)"
        case .badResponse: return "Unexpected reply from the server"
        case .file(let s): return s
        }
    }

    public var httpStatus: Int? {
        if case .http(let status, _) = self { return status }
        return nil
    }

    /// The message for a 409 that lists which assets already exist:
    /// "Already registered: T00316_NA0002_00, T00316_NA0003_00".
    public var alreadyRegisteredAssetIDs: [String]? {
        guard case .http(409, let message) = self,
              let range = message.range(of: "Already registered:") else { return nil }
        return message[range.upperBound...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
