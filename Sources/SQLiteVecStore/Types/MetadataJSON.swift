import Foundation

// Shared coders for the Codable metadata convenience APIs.
// sortedKeys keeps the JSON deterministic; compact output keeps it small.
enum MetadataJSON {
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<M: Decodable>(_ type: M.Type, from json: String) throws -> M {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
