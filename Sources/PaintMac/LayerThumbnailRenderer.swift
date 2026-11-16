import AppKit
import CoreImage

/// Per-editor previews contain only small output images and tile-version IDs.
/// A single background job and one latest request per target bound work/memory
/// even when hundreds of mouse events arrive before a thumbnail finishes.
final class LayerThumbnailRenderer {
    struct Key: Hashable { let layer: UUID; let mask: Bool }
    private struct Version: Equatable {
        let width: Int, height: Int, channels: Int
        let profile: RGBProfile
        let base: [UInt8]
        let keys: [Int]
        let tiles: [UUID]
        init(_ grid: TileGrid) {
            width = grid.width; height = grid.height; channels = grid.channels
            profile = grid.profile; base = grid.base
            keys = grid.tiles.keys.sorted(); tiles = keys.map { grid.tiles[$0]!.id }
        }
    }
    private struct Request {
        let grid: TileGrid
        let version: Version
        let completion: (CGImage) -> Void
    }
    private let queue = DispatchQueue(label: "Paint.MAC thumbnails", qos: .utility)
    private lazy var context = CIContext(options: [.cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!, .workingFormat: CIFormat.RGBAf])
    private var cached: [Key: (Version, CGImage)] = [:]
    private var pending: [Key: Request] = [:]
    private var timer: Timer?
    private var busy = false
    private(set) var renderedCount = 0

    deinit { timer?.invalidate() }

    func retainLayers(_ ids: Set<UUID>) {
        cached = cached.filter { ids.contains($0.key.layer) }
        pending = pending.filter { ids.contains($0.key.layer) }
    }

    /// Main-thread API. Return the previous image immediately; never wait for CI.
    @discardableResult
    func request(_ grid: TileGrid, key: Key, completion: @escaping (CGImage) -> Void) -> CGImage? {
        let version = Version(grid)
        if let old = cached[key], old.0 == version {
            pending.removeValue(forKey: key)
            completion(old.1); return old.1
        }
        pending[key] = Request(grid: grid, version: version, completion: completion)
        schedule()
        return cached[key]?.1
    }

    private func schedule() {
        guard !busy, timer == nil, !pending.isEmpty else { return }
        // Common modes keep the final update running during mouse tracking.
        let timer = Timer(timeInterval: 1.0 / 15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil; self.renderNext()
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func renderNext() {
        guard let key = pending.keys.first, let request = pending[key] else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let image = autoreleasepool {
                let context = self.context
                let grid = request.grid
                let scale = min(1, min(80 / CGFloat(grid.width), 64 / CGFloat(grid.height)))
                let size = CGSize(width: max(1, ceil(CGFloat(grid.width) * scale)), height: max(1, ceil(CGFloat(grid.height) * scale)))
                return context.createCGImage(grid.ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
                    from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: RGBProfile.displayP3.space)
            }
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                guard let self else { return }
                self.busy = false; self.renderedCount += 1
                // Publish only if this is still the requested pixel version.
                if let latest = self.pending[key], latest.version == request.version {
                    self.pending.removeValue(forKey: key)
                    if let image {
                        self.cached[key] = (request.version, image)
                        latest.completion(image)
                    }
                }
                self.schedule()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}
