import AppKit
import UniformTypeIdentifiers

@main
enum PaintMacApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSUserInterfaceValidations {
    var editor: EditorWindowController? {
        (NSApp.mainWindow?.windowController as? EditorWindowController)
            ?? (NSApp.keyWindow?.windowController as? EditorWindowController)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        if NSDocumentController.shared.documents.isEmpty { createDocument() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { createDocument() }; return true
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for file in filenames { open(URL(fileURLWithPath: file)) }
        sender.reply(toOpenOrPrint: .success)
    }

    @discardableResult
    func createDocument(state: DocumentState? = nil) -> PaintDocument {
        let document = PaintDocument()
        if let state { document.state = state }
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        return document
    }

    private func buildMenus() {
        let main = NSMenu()
        NSApp.mainMenu = main
        func menu(_ name: String) -> NSMenu {
            let item = NSMenuItem(); item.title = name
            let child = NSMenu(title: name); item.submenu = child; main.addItem(item)
            return child
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = target ?? self
            menu.addItem(item)
        }
        let app = menu("Paint.MAC")
        add(app, "About Paint.MAC", #selector(about)); app.addItem(.separator())
        add(app, "Hide Paint.MAC", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option], target: NSApp)
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator()); add(app, "Quit Paint.MAC", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = menu("File")
        add(file, "New Image", #selector(newImage), "n")
        add(file, "Open…", #selector(openImage), "o")
        add(file, "Import as Layer…", #selector(importImage), "o", modifiers: [.command, .shift])
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w", target: nil)
        file.items.last?.target = nil
        add(file, "Save Project…", #selector(saveProject), "s")
        add(file, "Save Project As…", #selector(saveProjectAs), "s", modifiers: [.command, .shift])
        add(file, "Export Image…", #selector(exportImage), "e", modifiers: [.command, .shift])

        let edit = menu("Edit")
        add(edit, "Undo", #selector(undoEdit), "z")
        add(edit, "Redo", #selector(redoEdit), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(cutPixels), "x")
        add(edit, "Copy", #selector(copyPixels), "c")
        add(edit, "Paste as Layer", #selector(pastePixels), "v")
        add(edit, "Delete Pixels", #selector(deletePixels))
        edit.addItem(.separator())
        add(edit, "Select All", #selector(selectAll), "a")
        add(edit, "Deselect", #selector(deselect), "d")

        let selection = menu("Selection")
        add(selection, "Rectangle Select", #selector(selectRectangle))
        add(selection, "Ellipse Select", #selector(selectEllipse))
        add(selection, "Lasso Select", #selector(selectLasso))
        selection.addItem(.separator())
        add(selection, "Select All", #selector(selectAll), "a")
        add(selection, "Deselect", #selector(deselect), "d")
        add(selection, "Invert Selection", #selector(invertSelection), "i", modifiers: [.command, .option])
        selection.addItem(.separator())
        add(selection, "Feather Selection…", #selector(featherSelection))

        let image = menu("Image")
        add(image, "Image & Canvas Size…", #selector(resizeImage), "r", modifiers: [.command, .option])
        add(image, "Resize Canvas…", #selector(resizeCanvas))
        add(image, "Crop to Selection", #selector(cropImage), "k", modifiers: [.command, .shift])
        image.addItem(.separator())
        add(image, "Invert Colors", #selector(invertImage), "i", modifiers: [.command, .shift])
        add(image, "Grayscale", #selector(grayscaleImage))

        let tools = menu("Tools")
        for tool in PaintTool.allCases {
            let item = NSMenuItem(title: "\(tool.title) (\(tool.key.uppercased()))", action: #selector(chooseTool(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = tool.rawValue
            tools.addItem(item)
        }

        let layer = menu("Layer")
        add(layer, "Add Layer", #selector(addLayer), "n", modifiers: [.command, .shift])
        add(layer, "Duplicate Layer", #selector(duplicateLayer), "d", modifiers: [.command, .shift])
        add(layer, "Edit Text / Effect…", #selector(editLayerContent))
        add(layer, "Rasterize Text Layer", #selector(rasterizeTextLayer))
        let effectItem = NSMenuItem(title: "New Effect Layer", action: nil, keyEquivalent: "")
        let effects = NSMenu(); effectItem.submenu = effects
        for kind in EffectKind.allCases {
            let item = NSMenuItem(title: kind.title + "…", action: #selector(addEffectLayer(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = kind.rawValue; effects.addItem(item)
        }
        layer.addItem(effectItem)
        add(layer, "Rename Layer…", #selector(renameLayer))
        add(layer, "Delete Layer", #selector(removeLayer))
        layer.addItem(.separator())
        add(layer, "Move Layer Up", #selector(layerUp))
        add(layer, "Move Layer Down", #selector(layerDown))
        add(layer, "Merge Down", #selector(mergeDown), "m", modifiers: [.command, .shift])
        layer.addItem(.separator())
        add(layer, "New Group", #selector(newGroup))
        add(layer, "Group Selected Layers", #selector(groupSelected), "g")
        add(layer, "Ungroup", #selector(ungroup), "g", modifiers: [.command, .shift])
        add(layer, "Merge Group", #selector(mergeGroup))
        add(layer, "Create Clipping Mask", #selector(toggleClipping), "g", modifiers: [.command, .option])
        layer.addItem(.separator())
        let maskItem = NSMenuItem(title: "Layer Mask", action: nil, keyEquivalent: "")
        maskItem.submenu = LayerMaskCommand.menu(target: self, action: #selector(layerMaskCommand(_:)))
        layer.addItem(maskItem)

        let view = menu("View")
        add(view, "Zoom In", #selector(zoomIn), "+")
        add(view, "Zoom Out", #selector(zoomOut), "-")
        add(view, "Actual Size", #selector(zoomActual), "1")
        add(view, "Fit to Window", #selector(zoomFit), "0")

        let window = menu("Window"); NSApp.windowsMenu = window
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"); window.items.last?.target = nil
        add(window, "Zoom", #selector(NSWindow.performZoom(_:))); window.items.last?.target = nil
        window.addItem(.separator())
        add(window, "Show Tab Bar", #selector(NSWindow.toggleTabBar(_:))); window.items.last?.target = nil
        add(window, "Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", modifiers: .control); window.items.last?.target = nil
        add(window, "Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", modifiers: [.control, .shift]); window.items.last?.target = nil
        add(window, "Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))); window.items.last?.target = nil
        add(window, "Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))); window.items.last?.target = nil
        let help = menu("Help"); NSApp.helpMenu = help
        add(help, "Tools & Shortcuts", #selector(showHelp))
    }

    @objc func newImage() { createDocument() }
    @objc func openImage() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.message = "Select one or more images or Paint.MAC projects. Each opens in its own tab."
        panel.allowedContentTypes = ImageFileIO.readableTypes + [UTType(exportedAs: PaintDocument.typeName, conformingTo: .package)]
        panel.begin { [weak self] result in
            if result == .OK { panel.urls.forEach { self?.open($0) } }
        }
    }
    private func open(_ url: URL) {
        if url.pathExtension.lowercased() == "paintmac" {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        } else {
            do {
                let imported = try ImageFileIO.read(Data(contentsOf: url), fileExtension: url.pathExtension)
                let raster: Raster
                var iconSource: IconSource?
                var icnsSource: ICNSSource?
                switch imported {
                case .image(let image): raster = image
                case .macIcon(let file):
                    let index: Int
                    if file.representations.count == 1 { index = 0 }
                    else {
                        guard let chosen = IconImportDialog(file: file, name: url.lastPathComponent).choose() else { return }
                        index = chosen
                    }
                    raster = try ICNSCodec.decode(file, index: index)
                    icnsSource = ICNSSource(file: file, index: index, name: url.deletingPathExtension().lastPathComponent)
                case .icon(let file):
                    let index: Int
                    if file.entries.count == 1 { index = 0 }
                    else {
                        guard let chosen = IconImportDialog(file: file, name: url.lastPathComponent).choose() else { return }
                        index = chosen
                    }
                    raster = try ICOCodec.decode(file, index: index)
                    iconSource = IconSource(file: file, index: index, name: url.deletingPathExtension().lastPathComponent)
                }
                let layer = PaintLayer(name: url.deletingPathExtension().lastPathComponent, raster: raster)
                var state = DocumentState(width: 1, height: 1)
                state.width = raster.width; state.height = raster.height
                state.layers = [layer]; state.activeID = layer.id
                let doc = createDocument(state: state)
                doc.iconSource = iconSource; doc.icnsSource = icnsSource
                doc.displayName = url.deletingPathExtension().lastPathComponent
                if let source = iconSource {
                    doc.windowControllers.first?.window?.subtitle = "ICO · \(raster.width) × \(raster.height) · image \(source.index + 1)/\(source.file.entries.count)"
                }
                if let source = icnsSource { doc.windowControllers.first?.window?.subtitle = "ICNS · " + source.file.representations[source.index].slot.title }
                doc.updateChangeCount(.changeDone)
            } catch { NSApp.presentError(error) }
        }
    }
    @objc func saveProject() { editor?.paintDocument.save(nil) }
    @objc func saveProjectAs() { editor?.paintDocument.saveAs(nil) }
    @objc func exportImage() {
        guard let editor else { return }
        editor.canvas.finishText()
        let document = editor.paintDocument
        let panel = NSSavePanel(); panel.title = "Export Image"
        panel.nameFieldStringValue = (document.icnsSource?.name ?? document.iconSource?.name ?? document.displayName) + ".png"
        panel.canSelectHiddenExtension = true; panel.isExtensionHidden = false
        let options = ImageExportOptions(width: document.state.width, height: document.state.height,
                                         source: document.iconSource, smooth: editor.canvas.smooth, icnsSource: document.icnsSource)
        options.attach(to: panel)
        panel.beginSheetModal(for: editor.window!) { result in
            guard result == .OK, let url = panel.url else { return }
            do { try document.export(to: url, settings: options.settings) }
            catch { editor.showError(error) }
        }
    }
    @objc func importImage() {
        guard let editor else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = ImageFileIO.readableTypes
        panel.beginSheetModal(for: editor.window!) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let raster: Raster
                switch try ImageFileIO.read(Data(contentsOf: url), fileExtension: url.pathExtension) {
                case .image(let image): raster = image
                case .macIcon(let file):
                    let index: Int
                    if file.representations.count == 1 { index = 0 }
                    else {
                        guard let chosen = IconImportDialog(file: file, name: url.lastPathComponent).choose() else { return }
                        index = chosen
                    }
                    raster = try ICNSCodec.decode(file, index: index)
                case .icon(let file):
                    let index: Int
                    if file.entries.count == 1 { index = 0 }
                    else {
                        guard let chosen = IconImportDialog(file: file, name: url.lastPathComponent).choose() else { return }
                        index = chosen
                    }
                    raster = try ICOCodec.decode(file, index: index)
                }
                try editor.importLayer(raster, name: url.deletingPathExtension().lastPathComponent)
            } catch { editor.showError(error) }
        }
    }
    @objc func undoEdit() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.undo() }
        else { editor?.paintDocument.undoManager?.undo() }
    }
    @objc func redoEdit() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.redo() }
        else { editor?.paintDocument.undoManager?.redo() }
    }
    @objc func addLayer() { editor?.addLayer() }
    @objc func duplicateLayer() { editor?.duplicateLayer() }
    @objc func removeLayer() { editor?.removeLayer() }
    @objc func editLayerContent() { editor?.editLayerContent() }
    @objc func rasterizeTextLayer() { editor?.rasterizeTextLayer() }
    @objc func addEffectLayer(_ sender: NSMenuItem) { editor?.addEffectLayer(sender) }
    @objc func renameLayer() { editor?.renameLayer() }
    @objc func layerUp() { editor?.layerUp() }
    @objc func layerDown() { editor?.layerDown() }
    @objc func mergeDown() { editor?.mergeDown() }
    @objc func newGroup() { editor?.newGroup() }
    @objc func groupSelected() { editor?.groupSelected() }
    @objc func ungroup() { editor?.ungroup() }
    @objc func mergeGroup() { editor?.mergeGroup() }
    @objc func toggleClipping() { editor?.toggleClipping() }
    @objc func layerMaskCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = LayerMaskCommand(rawValue: raw) else { return }
        editor?.performMaskCommand(command)
    }
    @objc func cropImage() { editor?.cropToSelection() }
    @objc func resizeImage() { editor?.resizeImage() }
    @objc func resizeCanvas() { editor?.resizeCanvas() }
    @objc func chooseTool(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let tool = PaintTool(rawValue: raw) { editor?.selectTool(tool) }
    }
    @objc func invertImage() { editor?.applyAdjustment("CIColorInvert", name: "Invert Colors") }
    @objc func grayscaleImage() { editor?.applyAdjustment("CIPhotoEffectMono", name: "Grayscale") }
    @objc func selectRectangle() { editor?.selectTool(.selection) }
    @objc func selectEllipse() { editor?.selectTool(.ellipseSelect) }
    @objc func selectLasso() { editor?.selectTool(.lasso) }
    @objc func invertSelection() { editor?.invertSelection() }
    @objc func featherSelection() { editor?.featherSelection() }
    @objc func selectAll() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.selectAll(nil) }
        else if let editor {
            let state = editor.paintDocument.state
            editor.canvas.changeSelection(.all(width: state.width, height: state.height), name: "Select All")
        }
    }
    @objc func deselect() { editor?.canvas.changeSelection(nil, name: "Deselect") }
    @objc func copyPixels() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.copy(nil) } else { editor?.copyPixels() }
    }
    @objc func cutPixels() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.cut(nil) } else { editor?.copyPixels(cut: true) }
    }
    @objc func pastePixels() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.paste(nil) } else { editor?.pastePixels() }
    }
    @objc func deletePixels() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.delete(nil) }
        else { editor?.canvas.deletePixels() }
    }
    @objc func zoomIn() { if let canvas = editor?.canvas { canvas.setZoom(canvas.zoom * 1.25) } }
    @objc func zoomOut() { if let canvas = editor?.canvas { canvas.setZoom(canvas.zoom / 1.25) } }
    @objc func zoomActual() { editor?.canvas.setZoom(1) }
    @objc func zoomFit() { editor?.canvas.zoomToFit() }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Paint.MAC", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.10.2",
            .credits: NSAttributedString(string: "A small, native home for your pixels.\nBuilt with Swift, AppKit, and Metal-backed Core Image.\nAn independent editor inspired by the Paint.NET workflow.")
        ])
    }
    @objc func showHelp() {
        let alert = NSAlert(); alert.messageText = "Make yourself at home."
        alert.informativeText = "B Brush · E Eraser · S Rectangle Select · V Move\nM Ellipse Select · Q Lasso Select\nF Fill · I Color Picker · L Line\nR Rectangle · O Ellipse · H Hand\nT Text · C Crop to Selection\nText: drag a box, type, move by its bar, resize by its corner.\n⌘Return finishes editing; Escape cancels.\n\nLeft mouse: main color. Right mouse: alternate color.\nPress the opposite mouse button to cancel a gesture.\nRelease both buttons before drawing again.\nX swaps colors. Right-click a palette swatch to set the alternate.\nSmooth/Sharp toggles edge antialiasing.\n\nMiddle mouse drag or Space + drag pans the canvas.\nMouse wheel or pinch zooms around the pointer.\n⌥ scroll pans; ⇧ scroll pans horizontally.\n[ and ] adjust brush size.\nSelection: ⇧ adds, ⌥ subtracts, ⇧⌥ intersects.\nControl constrains selections; Shift constrains drawn shapes.\nSelection → Feather Selection… softens the selection edge.\nOption-click samples the visible color.\nDelete clears pixels in the active layer.\n\n⌘O opens multiple files in tabs. Control-Tab switches tabs.\n⌥⌘R opens Image & Canvas Size.\n⌘S saves a layered .paintmac project.\n⇧⌘E exports PNG, JPEG, ICO, or ICNS.\nDouble-click text/effect layers to edit them; other layers to rename.\nLayer → New Effect Layer adds a live adjustment.\nLayer → Rasterize Text Layer enables pixel editing.\nMerge Down in the Layers panel (⇧⌘M) combines it with the layer below.\nLayers ▾ offers groups and clipping masks.\n⌘G groups selected layers; ⇧⌘G ungroups.\n⌥⌘G clips to the lower base layer.\nLayer Mask below it adds or manages a mask.\nClick a layer image or mask thumbnail to choose the editing target.\nOn masks: black hides, white reveals, gray is partial visibility.\nMask editing switches the palette to grayscale; X swaps black/white."
        alert.runModal()
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let action = item.action
        if action == #selector(newImage) || action == #selector(openImage) || action == #selector(about) || action == #selector(showHelp) { return true }
        guard let editor else { return false }
        let state = editor.paintDocument.state
        if action == #selector(layerMaskCommand(_:)), let item = item as? NSMenuItem,
           let raw = item.representedObject as? String, let command = LayerMaskCommand(rawValue: raw) {
            item.title = command.title(in: state)
            return command.isEnabled(in: state)
        }
        if action == #selector(chooseTool(_:)), let menu = item as? NSMenuItem,
           menu.representedObject as? String == PaintTool.crop.rawValue { return editor.canvas.selection?.isEmpty == false }
        if action == #selector(undoEdit) {
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
                (item as? NSMenuItem)?.title = "Undo"
                return text.undoManager?.canUndo == true
            }
            (item as? NSMenuItem)?.title = editor.paintDocument.undoManager?.undoMenuItemTitle ?? "Undo"
            return editor.paintDocument.undoManager?.canUndo == true
        }
        if action == #selector(redoEdit) {
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
                (item as? NSMenuItem)?.title = "Redo"
                return text.undoManager?.canRedo == true
            }
            (item as? NSMenuItem)?.title = editor.paintDocument.undoManager?.redoMenuItemTitle ?? "Redo"
            return editor.paintDocument.undoManager?.canRedo == true
        }
        if action == #selector(deselect) || action == #selector(invertSelection) { return editor.canvas.selection != nil }
        if action == #selector(cropImage) || action == #selector(featherSelection) { return editor.canvas.selection?.isEmpty == false }
        if action == #selector(editLayerContent) { return state.activeLayer.text != nil || state.activeLayer.effect != nil }
        if action == #selector(rasterizeTextLayer) { return state.activeLayer.text != nil }
        if action == #selector(addEffectLayer(_:)) { return state.layers.count < 32 }
        if action == #selector(removeLayer) { return state.subtreeIDs(state.activeID).count < state.layers.count }
        if action == #selector(mergeDown) { return state.canMergeDown }
        if action == #selector(layerDown) { return state.canReorderActive(by: -1) }
        if action == #selector(layerUp) { return state.canReorderActive(by: 1) }
        if action == #selector(ungroup) { return state.canUngroupActive }
        if action == #selector(mergeGroup) { return state.activeLayer.isGroup }
        if action == #selector(toggleClipping) {
            (item as? NSMenuItem)?.title = state.activeLayer.isClipped ? "Release Clipping Mask" : "Create Clipping Mask"
            return state.canClipActive
        }
        if action == #selector(duplicateLayer) { return state.layers.count + state.subtreeIDs(state.activeID).count <= 32 }
        if action == #selector(addLayer) || action == #selector(importImage) || action == #selector(newGroup) || action == #selector(groupSelected) { return state.layers.count < 32 }
        if action == #selector(copyPixels), state.activeLayer.effect != nil, !state.isEditingMask {
            return NSApp.keyWindow?.firstResponder is NSTextView
        }
        if action == #selector(deletePixels) || action == #selector(cutPixels) || action == #selector(invertImage) || action == #selector(grayscaleImage) {
            if (action == #selector(deletePixels) || action == #selector(cutPixels)), NSApp.keyWindow?.firstResponder is NSTextView { return true }
            return state.canPaintTarget && state.activeEffectivelyVisible
        }
        if action == #selector(pastePixels) {
            if NSApp.keyWindow?.firstResponder is NSTextView { return true }
            return NSPasteboard.general.availableType(from: [.png, .tiff]) != nil && state.layers.count < 32
        }
        return true
    }
}
