import Foundation

struct RegistryFile: Codable {
    var apps: [AppEntry]
    var settings: Settings
}

public final class Registry {
    private let lock = NSLock()
    public let fileURL: URL
    private var file: RegistryFile

    public init(directory: URL? = nil) {
        let dir = directory ?? Registry.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("apps.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? Codec.decoder.decode(RegistryFile.self, from: data) {
            file = decoded
        } else {
            file = RegistryFile(apps: [], settings: .default)
        }
    }

    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("AutoRenew", isDirectory: true)
    }

    public var apps: [AppEntry] {
        lock.lock()
        defer { lock.unlock() }
        return file.apps
    }

    public var settings: Settings {
        lock.lock()
        defer { lock.unlock() }
        return file.settings
    }

    /// Adds an app, or updates the existing entry for the same project while preserving its history.
    public func add(_ entry: AppEntry) {
        mutate { f in
            if let index = f.apps.firstIndex(where: { $0.projectPath == entry.projectPath }) {
                var merged = f.apps[index]
                merged.name = entry.name
                merged.scheme = entry.scheme
                merged.bundleID = entry.bundleID
                merged.teamID = entry.teamID
                merged.configuration = entry.configuration
                f.apps[index] = merged
            } else {
                f.apps.append(entry)
            }
        }
    }

    public func remove(id: String) {
        mutate { f in
            f.apps.removeAll { $0.id == id }
        }
    }

    public func update(_ entry: AppEntry) {
        mutate { f in
            if let index = f.apps.firstIndex(where: { $0.id == entry.id }) {
                f.apps[index] = entry
            }
        }
    }

    public func updateSettings(_ change: (inout Settings) -> Void) {
        mutate { f in
            change(&f.settings)
        }
    }

    private func mutate(_ change: (inout RegistryFile) -> Void) {
        lock.lock()
        change(&file)
        let data = (try? Codec.encoder.encode(file)) ?? Data()
        lock.unlock()
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum Codec {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
