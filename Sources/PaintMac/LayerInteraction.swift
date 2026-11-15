import AppKit

extension DocumentState {
    func isEffectivelyLocked(_ id: UUID) -> Bool {
        ([id] + ancestors(of: id)).contains { value in layers.first { $0.id == value }?.isLocked == true }
    }
    func canModifySubtree(_ id: UUID) -> Bool { !subtreeIDs(id).contains(where: isEffectivelyLocked) }
    func expandedMovingIDs(_ ids: Set<UUID>) -> Set<UUID> {
        let roots = layers.filter { ids.contains($0.id) && !ancestors(of: $0.id).contains(where: ids.contains) }
        var moving = Set<UUID>()
        for root in roots {
            for id in clippingUnits(parent: root.parentID).first(where: { $0.contains(root.id) }) ?? [root.id] {
                moving.formUnion(subtreeIDs(id))
            }
        }
        return moving
    }
    func canRemoveLayers(_ ids: Set<UUID>) -> Bool {
        let removed = ids.reduce(into: Set<UUID>()) { $0.formUnion(subtreeIDs($1)) }
        guard !removed.isEmpty, removed.count < layers.count, !removed.contains(where: isEffectivelyLocked) else { return false }
        var candidate = self
        candidate.layers.removeAll { removed.contains($0.id) }
        // Deleting a clipping base also changes its surviving clipped layers.
        for parent in [nil] + layers.filter(\.isGroup).map({ Optional($0.id) }) {
            for unit in clippingUnits(parent: parent) where removed.contains(unit[0]) {
                if unit.dropFirst().contains(where: isEffectivelyLocked) { return false }
            }
        }
        return permitsLockedLayerChanges(to: candidate)
    }
    /// Visibility, names, and disclosure are UI/organizational controls that
    /// remain available while content is locked. Global image sizing is explicit.
    func permitsLockedLayerChanges(to next: DocumentState) -> Bool {
        for layer in layers where isEffectivelyLocked(layer.id) {
            guard var updated = next.layers.first(where: { $0.id == layer.id }) else { return false }
            updated.visible = layer.visible; updated.name = layer.name; updated.expanded = layer.expanded
            guard ancestors(of: layer.id) == next.ancestors(of: layer.id), updated == layer else { return false }
            if layer.isGroup {
                guard layers.filter({ ancestors(of: $0.id).contains(layer.id) }).map(\.id)
                        == next.layers.filter({ next.ancestors(of: $0.id).contains(layer.id) }).map(\.id) else { return false }
            }
        }
        return true
    }
    /// Insert before a bottom-to-top sibling, or at the top when nil. Moving
    /// clipping stacks and subtrees are indivisible; insertion cannot split one.
    func relocatingLayers(_ ids: Set<UUID>, into parent: UUID?, before sibling: UUID?) throws -> DocumentState {
        let movingIDs = expandedMovingIDs(ids)
        guard !movingIDs.isEmpty else { return self }
        guard !movingIDs.contains(where: isEffectivelyLocked), parent.map({ !isEffectivelyLocked($0) }) ?? true else {
            throw LayerTreeError(message: "Unlock the affected layers or group first.")
        }
        if let parent {
            guard !movingIDs.contains(parent), layers.contains(where: { $0.id == parent && $0.isGroup }) else {
                throw LayerTreeError(message: "A group cannot be moved inside itself or one of its children.")
            }
        }
        let siblings = children(of: parent)
        if let sibling, !siblings.contains(where: { $0.id == sibling }) { throw LayerTreeError(message: "Invalid layer destination.") }
        // If the boundary belongs to the moving set, use the next remaining
        // sibling at that boundary. This makes dropping in place a true no-op.
        let boundary = sibling.flatMap { id in siblings.firstIndex { $0.id == id } } ?? siblings.count
        var anchor = siblings.dropFirst(boundary).first { !movingIDs.contains($0.id) }?.id
        if let id = anchor, let unit = clippingUnits(parent: parent).first(where: { $0.contains(id) }) { anchor = unit[0] }
        var next = self
        var moved = layers.filter { movingIDs.contains($0.id) }
        let movingRoots = Set(moved.filter { $0.parentID.map({ !movingIDs.contains($0) }) ?? true }.map(\.id))
        for index in moved.indices where movingRoots.contains(moved[index].id) { moved[index].parentID = parent }
        next.layers.removeAll { movingIDs.contains($0.id) }
        let insertion = anchor.flatMap { id in next.layers.firstIndex { next.subtreeIDs(id).contains($0.id) } }
            ?? parent.flatMap { id in next.layers.firstIndex { $0.id == id } } ?? next.layers.count
        next.layers.insert(contentsOf: moved, at: insertion)
        next.canonicalizeLayers()
        guard permitsLockedLayerChanges(to: next) else { throw LayerTreeError(message: "Unlock the affected layers first.") }
        guard next.layers.allSatisfy({ next.ancestors(of: $0.id).count + ($0.isGroup ? 1 : 0) <= Self.maximumGroupDepth }) else { throw LayerTreeError(message: "Groups can be nested up to 8 levels.") }
        try next.validateLayerTree()
        if let parent, let index = next.layers.firstIndex(where: { $0.id == parent }) { next.layers[index].expanded = true }
        return next
    }
}

extension PaintDocument {
    func toggleLayerLock(_ id: UUID) {
        finishPendingEdits?()
        guard let index = state.layers.firstIndex(where: { $0.id == id }),
              !state.ancestors(of: id).contains(where: state.isEffectivelyLocked) else { return }
        edit(state.layers[index].isLocked ? "Unlock Layer" : "Lock Layer", protectLockedLayers: false) { $0.layers[index].isLocked.toggle() }
    }
}

final class LayerTableView: NSTableView {
    static let pasteboardType = NSPasteboard.PasteboardType("com.aesopov.paintmac.layer")
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onDelete?(); return
        }
        super.keyDown(with: event)
    }
    static func draggedIDs(_ pasteboard: NSPasteboard) -> Set<UUID> {
        Set((pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: pasteboardType).flatMap(UUID.init(uuidString:)) })
    }
}

final class LayerTrashButton: NSButton {
    weak var sourceTable: NSTableView?
    var canDelete: ((Set<UUID>) -> Bool)?
    var deleteLayers: ((Set<UUID>) -> Void)?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes([LayerTableView.pasteboardType]) }
    required init?(coder: NSCoder) { fatalError() }
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? NSTableView) === sourceTable && canDelete?(LayerTableView.draggedIDs(sender.draggingPasteboard)) == true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = accepts(sender); highlight(valid); return valid ? .move : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { highlight(false) }
        guard accepts(sender) else { return false }
        deleteLayers?(LayerTableView.draggedIDs(sender.draggingPasteboard)); return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { highlight(false) }
}
