#if os(iOS) && (DEBUG || STUDIO_DEVICE_CAPTURE)
import Foundation
import StudioDeviceWire

/// Takes on disk, waiting to be collected.
///
/// They live in Caches rather than Documents: a take is a transfer buffer, not
/// user data, and if the system reclaims one before Studio pulls it that is the
/// right outcome — it must never be the reason a developer's app gets evicted.
/// A take is only deleted once Studio confirms it has both halves, so a Studio
/// that crashed mid-pull can come back for it (`hello` lists what's pending).
struct TakeStore: Sendable {
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudioDeviceKit/Takes", isDirectory: true)
    }

    func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func videoURL(for id: String) -> URL {
        directory(for: id).appendingPathComponent("video.mov")
    }

    func touchesURL(for id: String) -> URL {
        directory(for: id).appendingPathComponent("touches.json")
    }

    /// Make room for a new take and return its identifier.
    func createTake() throws -> String {
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: directory(for: id),
                                                withIntermediateDirectories: true)
        return id
    }

    func write(_ take: TouchTake, for id: String) throws {
        let encoder = JSONEncoder()
        try encoder.encode(take).write(to: touchesURL(for: id), options: .atomic)
    }

    func loadTake(_ id: String) throws -> TouchTake {
        try JSONDecoder().decode(TouchTake.self,
                                 from: Data(contentsOf: touchesURL(for: id)))
    }

    func videoBytes(for id: String) -> Int {
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: videoURL(for: id).path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: touchesURL(for: id).path)
    }

    var pendingIDs: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { exists($0) }
            .sorted() ?? []
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// Drop everything — used when a take fails to assemble, and offered to the
    /// developer through `StudioDevice.clearTakes()`.
    func deleteAll() {
        for id in pendingIDs { delete(id) }
    }
}
#endif
