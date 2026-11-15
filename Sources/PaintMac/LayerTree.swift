import AppKit

struct LayerTreeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension DocumentState {
    static let maximumGroupDepth = 8
    func children(of parent: UUID?) -> [PaintLayer] { layers.filter { $0.parentID == parent } }
    func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = [], current = layers.first { $0.id == id }?.parentID
        while let parent = current, result.count <= Self.maximumGroupDepth, !result.contains(parent) {
            result.append(parent); current = layers.first { $0.id == parent }?.parentID
        }
        return result
    }
    func subtreeIDs(_ id: UUID) -> Set<UUID> {
        Set(layers.filter { $0.id == id || ancestors(of: $0.id).contains(id) }.map(\.id))
    }
    var canPaintTarget: Bool { !isEffectivelyLocked(activeID) && (activeLayer.isPixelLayer || isEditingMask) }
    var activeEffectivelyVisible: Bool {
        activeLayer.visible && ancestors(of: activeID).allSatisfy { id in layers.first { $0.id == id }?.visible == true }
    }
    var visibleLayerIDs: [UUID] {
        func rows(_ parent: UUID?) -> [UUID] {
            children(of: parent).reversed().flatMap { node -> [UUID] in
                [node.id] + (node.isGroup && node.expanded ? rows(node.id) : [])
            }
        }
        return rows(nil)
    }
    func clippingUnits(parent: UUID?) -> [[UUID]] {
        var result: [[UUID]] = []
        for layer in children(of: parent) {
            if layer.isClipped, !result.isEmpty { result[result.count - 1].append(layer.id) }
            else { result.append([layer.id]) }
        }
        return result
    }
    var activeClippingUnit: [UUID] {
        clippingUnits(parent: activeLayer.parentID).first { $0.contains(activeID) } ?? [activeID]
    }
    var canClipActive: Bool {
        guard !isEffectivelyLocked(activeID) else { return false }
        if activeLayer.isClipped { return true }
        let units = clippingUnits(parent: activeLayer.parentID)
        guard let index = units.firstIndex(where: { $0.contains(activeID) }), index > 0 else { return false }
        return layers.first { $0.id == units[index - 1][0] }?.effect == nil
    }
    func canReorderActive(by offset: Int) -> Bool {
        guard !expandedMovingIDs([activeID]).contains(where: isEffectivelyLocked) else { return false }
        let units = clippingUnits(parent: activeLayer.parentID)
        guard let index = units.firstIndex(where: { $0.contains(activeID) }) else { return false }
        return units.indices.contains(index + offset)
    }
    var mergeDownRoots: [UUID] {
        let units = clippingUnits(parent: activeLayer.parentID)
        guard let index = units.firstIndex(where: { $0.contains(activeID) }), activeLayer.isClipped || index > 0 else { return [] }
        var chosen = activeLayer.isClipped ? [units[index]] : [units[index - 1], units[index]]
        if chosen.contains(where: { unit in layers.first(where: { $0.id == unit[0] })?.effect != nil }) { chosen = Array(units[0...index]) }
        return chosen.flatMap { $0 }
    }
    var canMergeDown: Bool { !mergeDownRoots.isEmpty && mergeDownRoots.allSatisfy { canModifySubtree($0) } }
    var canUngroupActive: Bool {
        canModifySubtree(activeID) && activeLayer.isGroup && activeLayer.opacity == 1 && activeLayer.mask == nil && !activeLayer.isClipped
            && activeClippingUnit.count == 1 && activeLayer.visible && !children(of: activeID).isEmpty
            && !children(of: activeID).contains { $0.effect != nil && !$0.isClipped }
    }
    /// Canonical storage is bottom-to-top postorder: a group's descendants
    /// precede its header. This keeps every subtree contiguous for history.
    mutating func canonicalizeLayers() {
        func ordered(_ parent: UUID?) -> [PaintLayer] {
            children(of: parent).flatMap { node in (node.isGroup ? ordered(node.id) : []) + [node] }
        }
        layers = ordered(nil)
    }
    func validateLayerTree() throws {
        func fail() throws { throw PaintError.invalidProject }
        let ids = Set(layers.map(\.id))
        guard ids.count == layers.count, ids.contains(activeID) else { try fail(); return }
        for layer in layers {
            guard (layer.isGroup ? 1 : 0) + (layer.text != nil ? 1 : 0) + (layer.effect != nil ? 1 : 0) <= 1,
                  layer.textClip == nil || layer.text != nil else { try fail(); return }
            try layer.text?.validate(); try layer.effect?.validate()
            if let parent = layer.parentID {
                guard parent != layer.id, let group = layers.first(where: { $0.id == parent }), group.isGroup else { try fail(); return }
            }
            let parents = ancestors(of: layer.id)
            guard parents.count + (layer.isGroup ? 1 : 0) <= Self.maximumGroupDepth, !parents.contains(layer.id), Set(parents).count == parents.count else { try fail(); return }
        }
        for parent in [nil] + layers.filter(\.isGroup).map({ Optional($0.id) }) {
            guard children(of: parent).first?.isClipped != true else { try fail(); return }
            for unit in clippingUnits(parent: parent) where unit.count > 1 {
                guard layers.first(where: { $0.id == unit[0] })?.effect == nil else { try fail(); return }
            }
        }
        var canonical = self; canonical.canonicalizeLayers()
        guard canonical.layers.map(\.id) == layers.map(\.id) else { try fail(); return }
    }
    /// Add a new pixel layer above the active sibling, or at the top of a group.
    mutating func insertLayer(_ value: PaintLayer) {
        var node = value
        if activeLayer.isGroup {
            node.parentID = activeID; layers[activeIndex].expanded = true
            layers.insert(node, at: activeIndex)
        } else {
            let siblings = children(of: activeLayer.parentID)
            let position = siblings.firstIndex { $0.id == activeID }!
            node.parentID = activeLayer.parentID
            node.isClipped = activeLayer.isClipped || (position + 1 < siblings.count && siblings[position + 1].isClipped)
            layers.insert(node, at: activeIndex + 1)
        }
        activeID = node.id
    }
    func isolatedLayers(roots: Set<UUID>) -> [PaintLayer] {
        let included = roots.reduce(into: Set<UUID>()) { $0.formUnion(subtreeIDs($1)) }
        return layers.filter { included.contains($0.id) }.map { value in
            var copy = value
            if roots.contains(copy.id) { copy.parentID = nil }
            return copy
        }
    }
    /// Move a group and all descendants together; masks follow image pixels.
    mutating func moveActive(from before: DocumentState, dx: Int, dy: Int, selection: SelectionMask?) {
        guard !before.isEffectivelyLocked(before.activeID), before.isEditingMask || before.canModifySubtree(before.activeID) else { return }
        if before.isEditingMask {
            editingRaster = before.editingRaster.moved(dx: dx, dy: dy, selection: selection)
            return
        }
        let ids = before.subtreeIDs(before.activeID)
        for index in layers.indices where ids.contains(layers[index].id) {
            let source = before.layers.first { $0.id == layers[index].id }!
            if var text = source.text {
                // Text moves as an editable object. Its creation clip and mask
                // remain linked; a selection does not fragment its source text.
                text.transform(dx: Double(dx), dy: Double(dy)); layers[index].text = text
                layers[index].textClip = source.textClip?.translated(dx: dx, dy: dy)
                layers[index].renderText()
            } else if source.isPixelLayer { layers[index].raster = source.raster.moved(dx: dx, dy: dy, selection: selection) }
            if let mask = source.mask {
                layers[index].mask = SelectionMask(editingRaster: mask.editingRaster.moved(dx: dx, dy: dy, selection: source.text != nil ? nil : selection))
            }
        }
    }
}

extension PaintDocument {
    func createGroup(wrapping ids: Set<UUID> = []) throws {
        finishPendingEdits?()
        guard state.layers.count < 32 else { throw PaintError.tooManyLayers }
        var next = state
        let selected = ids.isEmpty ? [] : next.layers.filter { ids.contains($0.id) && !next.ancestors(of: $0.id).contains(where: ids.contains) }
        var roots: [UUID] = [], parent = next.activeLayer.isGroup ? next.activeID : next.activeLayer.parentID
        if !selected.isEmpty {
            parent = selected[0].parentID
            guard selected.allSatisfy({ $0.parentID == parent }) else { throw LayerTreeError(message: "Select layers from the same group to group them together.") }
            let units = next.clippingUnits(parent: parent)
            let chosen = units.enumerated().filter { _, unit in unit.contains(where: ids.contains) }
            let positions = chosen.map(\.offset)
            guard positions.last! - positions.first! + 1 == positions.count else { throw LayerTreeError(message: "Select adjacent layers to group them together.") }
            roots = chosen.flatMap(\.element)
        }
        var group = PaintLayer(name: "Group", raster: Raster(width: state.width, height: state.height))
        group.isGroup = true; group.parentID = parent
        let insertion: Int
        if let last = roots.last { insertion = next.layers.firstIndex { $0.id == last }! + 1 }
        else { insertion = next.activeLayer.isGroup ? next.activeIndex : next.layers.firstIndex { $0.id == next.activeClippingUnit.last! }! + 1 }
        next.layers.insert(group, at: insertion)
        for index in next.layers.indices where roots.contains(next.layers[index].id) { next.layers[index].parentID = group.id }
        next.activeID = group.id; next.canonicalizeLayers()
        guard next.layers.allSatisfy({ next.ancestors(of: $0.id).count + ($0.isGroup ? 1 : 0) <= DocumentState.maximumGroupDepth }) else { throw LayerTreeError(message: "Groups can be nested up to 8 levels.") }
        try next.validateLayerTree()
        guard state.permitsLockedLayerChanges(to: next) else { throw LayerTreeError(message: "Unlock the affected layers first.") }
        let previous = state; state = next; commit(previous, name: roots.isEmpty ? "New Group" : "Group Layers")
    }
    func ungroupActive() {
        finishPendingEdits?()
        guard state.canUngroupActive else { return }
        edit("Ungroup Layers") { state in
            let group = state.activeLayer, children = state.children(of: group.id)
            for index in state.layers.indices where state.layers[index].parentID == group.id { state.layers[index].parentID = group.parentID }
            state.layers.removeAll { $0.id == group.id }; state.activeID = children.last!.id
            state.canonicalizeLayers()
        }
    }
    func moveLayers(_ ids: Set<UUID>, into parent: UUID?, before sibling: UUID? = nil) throws {
        finishPendingEdits?()
        let next = try state.relocatingLayers(ids, into: parent, before: sibling)
        let previous = state; state = next; commit(previous, name: "Move Layers")
    }
    func duplicateActiveNode() throws {
        finishPendingEdits?()
        let ids = state.subtreeIDs(state.activeID)
        guard state.layers.count + ids.count <= 32 else { throw PaintError.tooManyLayers }
        edit("Duplicate Layer") { state in
            let original = state.activeLayer
            let nodes = state.layers.filter { ids.contains($0.id) }
            let mapping = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, UUID()) })
            let copies = nodes.map { source -> PaintLayer in
                var copy = PaintLayer(id: mapping[source.id]!, name: source.id == original.id ? source.name + " copy" : source.name,
                                      raster: source.raster, visible: source.visible, opacity: source.opacity)
                copy.isLocked = source.isLocked
                copy.text = source.text; copy.textClip = source.textClip; copy.effect = source.effect
                copy.mask = source.mask; copy.maskEnabled = source.maskEnabled; copy.isGroup = source.isGroup
                copy.parentID = source.parentID.map { mapping[$0] ?? $0 }; copy.isClipped = source.isClipped; copy.expanded = source.expanded
                return copy
            }
            let insertion = original.isClipped ? state.activeIndex + 1 : state.layers.firstIndex { $0.id == state.activeClippingUnit.last! }! + 1
            state.layers.insert(contentsOf: copies, at: insertion)
            state.activeID = mapping[original.id]!
        }
    }
    func removeActiveNode() { removeLayers([state.activeID]) }
    func removeLayers(_ ids: Set<UUID>) {
        finishPendingEdits?()
        guard state.canRemoveLayers(ids) else { return }
        edit("Delete Layers") { state in
            let removed = ids.reduce(into: Set<UUID>()) { $0.formUnion(state.subtreeIDs($1)) }
            let originalIndex = state.activeIndex
            for parent in [nil] + state.layers.filter(\.isGroup).map({ Optional($0.id) }) {
                for unit in state.clippingUnits(parent: parent) where removed.contains(unit[0]) {
                    for index in state.layers.indices where unit.dropFirst().contains(state.layers[index].id) {
                        state.layers[index].isClipped = false
                    }
                }
            }
            state.layers.removeAll { removed.contains($0.id) }
            if removed.contains(state.activeID) { state.activeID = state.layers[min(originalIndex, state.layers.count - 1)].id }
        }
    }
    func reorderActiveNode(by offset: Int) {
        finishPendingEdits?()
        guard state.canReorderActive(by: offset) else { return }
        edit("Reorder Layer") { state in
            var units = state.clippingUnits(parent: state.activeLayer.parentID)
            let index = units.firstIndex { $0.contains(state.activeID) }!
            units.swapAt(index, index + offset)
            let ordered = units.flatMap { $0 }.flatMap { id in state.layers.filter { state.subtreeIDs(id).contains($0.id) } }
            let allIDs = Set(ordered.map(\.id)), insertion = state.layers.firstIndex { allIDs.contains($0.id) }!
            state.layers.removeAll { allIDs.contains($0.id) }; state.layers.insert(contentsOf: ordered, at: insertion)
            state.canonicalizeLayers()
        }
    }
    func toggleClippingMask() {
        finishPendingEdits?()
        guard state.canClipActive else { return }
        edit(state.activeLayer.isClipped ? "Release Clipping Mask" : "Create Clipping Mask") { state in
            if state.activeLayer.isClipped && state.activeLayer.effect != nil {
                let unit = state.activeClippingUnit
                let position = unit.firstIndex(of: state.activeID)!
                let released = Set(unit[position...])
                for index in state.layers.indices where released.contains(state.layers[index].id) { state.layers[index].isClipped = false }
            } else { state.layers[state.activeIndex].isClipped.toggle() }
        }
    }
    func mergeActiveGroup(forceMask: Bool = false) {
        finishPendingEdits?()
        guard state.canModifySubtree(state.activeID), state.activeLayer.isGroup else { return }
        var nodes = state.layers
        if forceMask { nodes[state.activeIndex].maskEnabled = true }
        guard let raster = try? Raster(image: renderer.contentImage(of: state.activeID, layers: nodes, width: state.width, height: state.height)) else { return }
        edit(forceMask ? "Apply Group Mask" : "Merge Group") { state in
            let root = state.activeLayer, descendants = state.subtreeIDs(root.id).subtracting([root.id])
            state.layers.removeAll { descendants.contains($0.id) }
            let index = state.activeIndex
            state.layers[index].raster = raster; state.layers[index].isGroup = false; state.layers[index].expanded = true
            state.layers[index].mask = nil; state.layers[index].maskEnabled = true; state.editingMask = false
        }
    }
    func mergeActiveDown(forceMask: Bool = false) {
        finishPendingEdits?()
        guard state.canMergeDown else { return }
        let roots = state.mergeDownRoots
        var isolated = state.isolatedLayers(roots: Set(roots))
        if forceMask, let index = isolated.firstIndex(where: { $0.id == state.activeID }) { isolated[index].maskEnabled = true }
        guard let raster = try? Raster(image: renderer.composite(isolated, width: state.width, height: state.height)) else { return }
        edit("Merge Layer Down") { state in
            let keptID = roots[0], removed = Set(isolated.map(\.id)).subtracting([keptID])
            state.layers.removeAll { removed.contains($0.id) }
            let index = state.layers.firstIndex { $0.id == keptID }!
            state.layers[index].raster = raster; state.layers[index].rasterizeText(); state.layers[index].effect = nil
            state.layers[index].opacity = 1; state.layers[index].visible = true
            state.layers[index].isGroup = false; state.layers[index].isClipped = false; state.layers[index].expanded = true
            state.layers[index].mask = nil; state.layers[index].maskEnabled = true
            state.activeID = keptID; state.editingMask = false
        }
    }
}
