import AppKit
import Compression
import CryptoKit
import Darwin

/// An exclusively locked session directory survives OS cache purges. Other
/// Paint.MAC processes may remove only abandoned, unlocked sessions.
final class HistorySession {
    let directory: URL
    private var descriptor: Int32 = -1
    private var removed = false
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Paint.MAC/UndoCache-v1", isDirectory: true)
    }
    static func cleanAbandoned(in root: URL) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix("session-") {
            let fd = Darwin.open(url.appendingPathComponent("owner.lock").path, O_RDWR)
            guard fd >= 0 else {
                // An interrupted mkdir/open sequence can leave no lock file.
                // A grace period protects another process still creating one.
                if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let date = values.contentModificationDate, date < Date(timeIntervalSinceNow: -3600) { try? fm.removeItem(at: url) }
                continue
            }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? fm.removeItem(at: url); flock(fd, LOCK_UN) }
            Darwin.close(fd)
        }
    }
    init(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Self.cleanAbandoned(in: root)
        directory = root.appendingPathComponent("session-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(directory.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
            try? fm.removeItem(at: directory); throw CocoaError(.fileWriteUnknown)
        }
    }
    func remove() {
        guard !removed else { return }; removed = true
        try? FileManager.default.removeItem(at: directory)
        if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { remove() }
}

/// RAM contains recent immutable tile bytes, never complete document snapshots.
/// Only verified, successfully persisted entries may be evicted from RAM.
final class HistoryTileCache {
    struct Statistics { let tiles: Int; let residentBytes: Int; let diskBytes: Int }
    private final class Entry {
        let id: UUID
        let channels: Int
        let byteCount: Int
        var resident: Data?
        weak var tile: PixelTile?
        var references = 0
        var diskBytes = 0
        var used: UInt64 = 0
        init(_ tile: PixelTile) { id = tile.id; channels = tile.channels; byteCount = tile.data.count; resident = tile.data; self.tile = tile }
    }
    let memoryBudget: Int
    let diskBudget: Int
    private let session: HistorySession?
    var directory: URL? { session?.directory }
    private let queue = DispatchQueue(label: "Paint.MAC undo tile cache", qos: .utility)
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var clock: UInt64 = 0
    private var closed = false
    private var notificationPending = false
    private var cacheError: Error?
    var lastError: Error? { lock.withLock { cacheError } }
    var onBudgetChange: (() -> Void)?

    init(memoryBudget: Int = 128 * 1024 * 1024, diskBudget: Int = 2 * 1024 * 1024 * 1024, root: URL = HistorySession.defaultRoot) {
        self.memoryBudget = max(0, memoryBudget); self.diskBudget = max(0, diskBudget)
        do { session = try HistorySession(root: root) }
        catch { session = nil; cacheError = error }
    }
    var statistics: Statistics { lock.withLock {
        Statistics(tiles: entries.count, residentBytes: entries.values.reduce(0) { $0 + ($1.resident?.count ?? 0) },
                   diskBytes: entries.values.reduce(0) { $0 + $1.diskBytes })
    } }
    private func notify() {
        let schedule = lock.withLock { () -> Bool in
            if notificationPending || closed { return false }; notificationPending = true; return true
        }
        if schedule { DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.lock.withLock { self.notificationPending = false }; self.onBudgetChange?()
        } }
    }
    func retain(_ tile: PixelTile) {
        let fresh: Entry? = lock.withLock {
            clock &+= 1
            if let entry = entries[tile.id] { entry.references += 1; entry.used = clock; entry.tile = tile; return nil }
            let entry = Entry(tile); entry.references = 1; entry.used = clock; entries[tile.id] = entry; return entry
        }
        guard let fresh else { return }
        guard let directory else { notify(); return }
        queue.async { [weak self, fresh] in
            guard let self else { return }
            guard let data = self.lock.withLock({ self.closed || self.entries[fresh.id] !== fresh ? nil : fresh.resident }) else { return }
            do {
                let encoded = Self.encode(data)
                let url = directory.appendingPathComponent(fresh.id.uuidString)
                try encoded.write(to: url, options: .atomic)
                // Verify before permitting eviction, including filesystem writes.
                guard try Self.decode(Data(contentsOf: url), expected: data.count) == data else { throw CocoaError(.fileReadCorruptFile) }
                let allocated = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                self.lock.withLock {
                    if self.entries[fresh.id] === fresh { fresh.diskBytes = max(encoded.count, allocated.totalFileAllocatedSize ?? allocated.fileAllocatedSize ?? encoded.count) }
                }
                self.evict(); self.notify()
            } catch {
                self.lock.withLock { self.cacheError = error }; self.notify()
            }
        }
    }
    func release(_ ids: Set<UUID>) {
        let urls: [URL] = lock.withLock {
            var result: [URL] = []
            for id in ids {
                guard let entry = entries[id] else { continue }; entry.references -= 1
                if entry.references == 0 {
                    entries.removeValue(forKey: id)
                    if let directory { result.append(directory.appendingPathComponent(id.uuidString)) }
                }
            }; return result
        }
        if !urls.isEmpty { queue.async { for url in urls { try? FileManager.default.removeItem(at: url) } } }
    }
    func tile(_ id: UUID, channels: Int) throws -> PixelTile {
        let entry = try lock.withLock { () throws -> Entry in
            guard let e = entries[id], !closed, e.channels == channels else { throw CocoaError(.fileReadCorruptFile) }
            clock &+= 1; e.used = clock; return e
        }
        if let live = lock.withLock({ entry.tile }) { return live }
        let data: Data
        if let resident = lock.withLock({ entry.resident }) { data = resident }
        else {
            guard let directory else { throw CocoaError(.fileReadNoSuchFile) }
            data = try Self.decode(Data(contentsOf: directory.appendingPathComponent(id.uuidString)), expected: entry.byteCount)
        }
        let tile = PixelTile(data, channels: channels, id: id)
        lock.withLock { entry.tile = tile; entry.resident = data }
        evict(); return tile
    }
    private func evict() { lock.withLock {
        var count = entries.values.reduce(0) { $0 + ($1.resident?.count ?? 0) }
        for e in entries.values.sorted(by: { $0.used < $1.used }) where count > memoryBudget && e.diskBytes > 0 {
            count -= e.resident?.count ?? 0; e.resident = nil
        }
    } }
    /// Tests and orderly shutdown use a barrier; normal painting never waits.
    func flush() { queue.sync {}; evict() }
    func shutdown() {
        lock.withLock { closed = true; entries.removeAll() }
        queue.sync {}; session?.remove()
    }
    private static func encode(_ data: Data) -> Data {
        var compressed = Data(count: data.count + 1024)
        let count = compressed.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                      src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_LZFSE)
        } }
        let useCompression = count > 0 && count < data.count
        var result = Data([0x50, 0x4d, 0x54, 0x31])
        var size = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(useCompression ? 1 : 0); result.append(contentsOf: SHA256.hash(data: data))
        result.append(useCompression ? compressed.prefix(count) : data); return result
    }
    private static func decode(_ encoded: Data, expected: Int) throws -> Data {
        guard encoded.count >= 41, Array(encoded.prefix(4)) == [0x50, 0x4d, 0x54, 0x31],
              encoded[8] <= 1 else { throw CocoaError(.fileReadCorruptFile) }
        let size = encoded[4..<8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        guard size == expected else { throw CocoaError(.fileReadCorruptFile) }
        let payload = Data(encoded.dropFirst(41)), result: Data
        if encoded[8] == 0 { result = payload }
        else {
            var decoded = Data(count: expected)
            let count = decoded.withUnsafeMutableBytes { dst in payload.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_LZFSE)
            } }
            guard count == expected else { throw CocoaError(.fileReadCorruptFile) }; result = decoded
        }
        guard result.count == expected, Data(SHA256.hash(data: result)) == encoded.subdata(in: 9..<41) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}

/// Lightweight metadata + IDs, deliberately retaining no image/mask buffers.
final class HistorySnapshot {
    struct Grid {
        let width: Int, height: Int, channels: Int
        let base: [UInt8]
        let profile: RGBProfile
        let tiles: [Int: UUID]
        init(_ grid: TileGrid) { width = grid.width; height = grid.height; channels = grid.channels; profile = grid.profile; base = grid.base; tiles = grid.tiles.mapValues(\.id) }
        func restored(_ cache: HistoryTileCache) throws -> TileGrid {
            var grid = TileGrid(width: width, height: height, channels: channels, base: base)
            grid.profile = profile
            grid.tiles = try tiles.mapValues { try cache.tile($0, channels: channels) }; return grid
        }
    }
    private var metadata: DocumentState
    private let rasters: [Grid]
    private let masks: [Grid?]
    private let maskBounds: [CGRect?]
    private let clips: [Grid?]
    private let clipBounds: [CGRect?]
    private let selection: Grid?
    private let selectionBounds: CGRect?
    private let cache: HistoryTileCache
    private let ids: Set<UUID>
    let metadataBytes: Int
    init(_ state: DocumentState, cache: HistoryTileCache) {
        self.cache = cache; metadata = state
        rasters = state.layers.map { Grid($0.raster.storage) }
        masks = state.layers.map { $0.mask.map { Grid($0.storage) } }; maskBounds = state.layers.map { $0.mask?.bounds }
        clips = state.layers.map { $0.textClip.map { Grid($0.storage) } }; clipBounds = state.layers.map { $0.textClip?.bounds }
        selection = state.selection.map { Grid($0.storage) }; selectionBounds = state.selection?.bounds
        var tiles: [UUID: PixelTile] = [:]
        func collect(_ grid: TileGrid) { for tile in grid.tiles.values { tiles[tile.id] = tile } }
        for i in state.layers.indices {
            let layer = state.layers[i]
            collect(layer.raster.storage)
            if let mask = layer.mask { collect(mask.storage) }; if let clip = layer.textClip { collect(clip.storage) }
            metadata.layers[i].raster = Raster(width: state.width, height: state.height, format: layer.raster.format)
            metadata.layers[i].raster.resolution = layer.raster.resolution
            metadata.layers[i].mask = nil; metadata.layers[i].textClip = nil
        }
        if let mask = state.selection { collect(mask.storage) }; metadata.selection = nil
        ids = Set(tiles.keys); tiles.values.forEach(cache.retain)
        metadataBytes = state.format.profile.icc.count + tiles.count * 48 + state.layers.reduce(256) { $0 + 256 + $1.name.utf8.count + ($1.text?.string.utf8.count ?? 0) }
    }
    func restored() throws -> DocumentState {
        var state = metadata
        for i in state.layers.indices {
            state.layers[i].raster.storage = try rasters[i].restored(cache)
            if let mask = masks[i] { state.layers[i].mask = SelectionMask(storage: try mask.restored(cache), bounds: maskBounds[i]!) }
            if let clip = clips[i] { state.layers[i].textClip = SelectionMask(storage: try clip.restored(cache), bounds: clipBounds[i]!) }
        }
        if let selection { state.selection = SelectionMask(storage: try selection.restored(cache), bounds: selectionBounds!) }
        return state
    }
    deinit { cache.release(ids) }
}

final class TileHistoryAction: NSObject {
    weak var document: PaintDocument?
    var snapshot: HistorySnapshot?
    let name: String
    let group: UInt64
    init(document: PaintDocument, snapshot: HistorySnapshot, name: String, group: UInt64) {
        self.document = document; self.snapshot = snapshot; self.name = name; self.group = group
    }
    func perform() { if let snapshot { document?.restoreHistory(snapshot, name: name) } }
}
final class WeakHistoryAction {
    weak var action: TileHistoryAction?
    init(_ action: TileHistoryAction) { self.action = action }
}
