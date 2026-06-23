import Foundation

/// Small Codable persistence helper with atomic writes and pretty, stable JSON.
enum JSONStore {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        AppPaths.ensureDirectories()
        let data = try makeEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            Log.storage.error("Failed to decode \(url.lastPathComponent): \(error.localizedDescription)")
            // Preserve the unreadable file for diagnosis instead of silently overwriting it with
            // defaults on the next save. Keeps only the most recent corrupt copy.
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }
}
