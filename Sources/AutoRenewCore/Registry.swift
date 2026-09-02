import Foundation

struct RegistryFile: Codable {
    var apps: [AppEntry]
    var settings: Settings
}

/// The app list and settings, backed by a single JSON file.
///
/// The menu-bar app and the `autorenew` CLI are separate processes reading the same file, and the
/// app stays running for weeks. Every read and every write therefore re-reads the file when it has
/// changed on disk — without that, the long-lived app would keep serving a stale copy and would
/// overwrite anything the CLI had added the next time it saved.
public final class Registry {
    private let lock = NSLock()
    public let fileURL: URL
    private var file: RegistryFile
    /// Modification date of the contents currently held in `file`; nil when the file is absent.
    private var loadedStamp: Date?

    public init(directory: URL? = nil) {
        let dir = directory ?? Registry.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("apps.json")
        file = RegistryFile(apps: [], settings: .default)
        lock.lock()
        load()
        lock.unlock()
    }

    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("AutoRenew", isDirectory: true)
    }

    public var apps: [AppEntry] {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChanged()
        return file.apps
    }

    public var settings: Settings {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChanged()
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

    /// Re-reads whatever another process wrote, applies `change` to that, and saves.
    ///
    /// The read-modify-write is serialized within this process by `lock`. Across processes the
    /// window between the reload and the write is sub-millisecond and both writers are user-driven,
    /// so a lost update would need two saves in the same instant; the reload is what makes the
    /// common case (CLI adds an app while the menu-bar app is running) safe.
    private func mutate(_ change: (inout RegistryFile) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChanged()
        change(&file)
        guard let data = try? Codec.encoder.encode(file) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            loadedStamp = modificationDate()
        } catch {
            Log.event("Registry write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Disk

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    /// Call with `lock` held.
    private func reloadIfChanged() {
        let stamp = modificationDate()
        guard stamp != loadedStamp else { return }
        load()
    }

    /// Call with `lock` held. Leaves the in-memory copy untouched if the file is missing or corrupt,
    /// so a half-written file can never silently empty the registry.
    private func load() {
        let stamp = modificationDate()
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Codec.decoder.decode(RegistryFile.self, from: data) else {
            if stamp == nil { loadedStamp = nil }
            return
        }
        file = decoded
        loadedStamp = stamp
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
