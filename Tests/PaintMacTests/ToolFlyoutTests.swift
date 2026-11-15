import XCTest
import AppKit
@testable import PaintMac

/// XCTest's command-line host cannot acquire application activation reliably.
/// Supply the key-window precondition without changing desktop focus.
private final class HoverTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

final class ToolFlyoutTests: XCTestCase {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func editor() -> (PaintDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 320, height: 240); doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.window!.makeKeyAndOrderFront(nil); editor.window!.contentView!.layoutSubtreeIfNeeded()
        doc.undoManager!.groupsByEvent = false
        return (doc, editor)
    }
    private func button(_ group: ToolGroup, _ editor: EditorWindowController) throws -> ToolGroupButton {
        try XCTUnwrap(views(editor.window!.contentView!).compactMap { $0 as? ToolGroupButton }.first { $0.group == group })
    }
    private func key(_ value: String, code: UInt16, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code)!
    }
    func testRailHasTwoGroupsAndRemembersTypesAcrossPrimaryClicksAndShortcuts() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        let railButtons = views(editor.window!.contentView!).compactMap { $0 as? ToolButton }
        XCTAssertEqual(railButtons.count, 10); XCTAssertEqual(railButtons.filter { $0 is ToolGroupButton }.count, 2)
        let shapes = try button(.shapes, editor), selections = try button(.selections, editor)
        XCTAssertEqual(shapes.currentTool, .rectangle); XCTAssertEqual(selections.currentTool, .selection)
        for tool in [PaintTool.line, .ellipse, .rectangle, .lasso, .ellipseSelect, .selection] {
            editor.canvas.keyDown(with: key(tool.key, code: 0, window: editor.window!))
            let grouped = tool.isSelection ? selections : shapes
            XCTAssertEqual(editor.canvas.tool, tool); XCTAssertEqual(grouped.currentTool, tool); XCTAssertTrue(grouped.selected)
            XCTAssertTrue(grouped.accessibilityLabel()!.contains(tool.title))
            editor.selectTool(.brush); XCTAssertFalse(grouped.selected)
            grouped.performClick(nil); XCTAssertEqual(editor.canvas.tool, tool)
        }
        XCTAssertFalse(doc.undoManager!.canUndo)
    }
    func testFlyoutOpensRightChecksCurrentTypeAndChoosingVariantUpdatesButton() throws {
        let app = NSApplication.shared, old = app.appearance; defer { app.appearance = old }
        let (doc, editor) = editor(); defer { doc.close() }
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: theme)
            editor.window!.setContentSize(CGSize(width: 960, height: 640)); editor.window!.contentView!.layoutSubtreeIfNeeded()
            for group in ToolGroup.allCases {
                let button = try self.button(group, editor)
                editor.selectTool(group.tools[1]); editor.selectTool(.brush)
                let state = doc.state, focus = editor.window!.firstResponder
                button.showFlyout()
                let panel = try XCTUnwrap(button.flyout)
                let anchor = editor.window!.convertToScreen(button.convert(button.bounds, to: nil))
                XCTAssertGreaterThan(panel.frame.minX, anchor.maxX)
                XCTAssertTrue(panel.isVisible); XCTAssertFalse(panel.canBecomeKey); XCTAssertTrue(panel.parent === editor.window)
                XCTAssertTrue(editor.window!.firstResponder === focus); XCTAssertEqual(doc.state, state)
                let rows = views(panel.contentView!).compactMap { $0 as? NSButton }
                XCTAssertEqual(rows.count, 3)
                for tool in group.tools { XCTAssertTrue(rows.contains { $0.accessibilityLabel() == tool.title }) }
                XCTAssertEqual(rows.first { $0.accessibilityLabel() == group.tools[1].title }?.accessibilityValue() as? String, "Current type")
                let row = try XCTUnwrap(rows.first { $0.accessibilityLabel() == group.tools[2].title })
                row.performClick(nil)
                XCTAssertNil(button.flyout); XCTAssertEqual(editor.canvas.tool, group.tools[2]); XCTAssertEqual(button.currentTool, group.tools[2])
                XCTAssertTrue(button.selected); XCTAssertEqual(doc.state, state)
            }
        }
    }
    func testHoverDoesNotFinishTextButChoosingToolDoes() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        let canvas = editor.canvas
        canvas.beginText(in: CGRect(x: 10, y: 20, width: 240, height: 120), color: .black)
        let draft = try XCTUnwrap(canvas.textEditor)
        draft.textView.insertText("Preserve draft on hover", replacementRange: NSRange(location: NSNotFound, length: 0))
        let state = doc.state, focus = editor.window!.firstResponder
        let shapes = try button(.shapes, editor)
        shapes.showFlyout(); XCTAssertNotNil(shapes.flyout)
        XCTAssertTrue(canvas.textEditor === draft); XCTAssertTrue(editor.window!.firstResponder === focus)
        XCTAssertEqual(doc.state, state); XCTAssertFalse(doc.undoManager!.canUndo)
        shapes.dismissFlyout(); XCTAssertTrue(canvas.textEditor === draft); XCTAssertEqual(doc.state, state)
        shapes.showFlyout()
        let row = try XCTUnwrap(views(shapes.flyout!.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Ellipse" })
        doc.undoManager!.beginUndoGrouping(); row.performClick(nil); doc.undoManager!.endUndoGrouping()
        XCTAssertNil(canvas.textEditor); XCTAssertEqual(canvas.tool, .ellipse)
        XCTAssertEqual(doc.state.activeLayer.text?.string, "Preserve draft on hover")
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, state)
    }
    func testOnlyOneFlyoutAndWindowResizeAndCloseDismissIt() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        let shapes = try button(.shapes, editor), selections = try button(.selections, editor)
        shapes.showFlyout(); let previous = try XCTUnwrap(shapes.flyout)
        selections.showFlyout(); XCTAssertNil(shapes.flyout); XCTAssertFalse(previous.isVisible); XCTAssertNotNil(selections.flyout)
        editor.window!.setContentSize(CGSize(width: 1050, height: 700)); XCTAssertNil(selections.flyout)
        shapes.showFlyout(); editor.selectTool(.hand); XCTAssertNil(shapes.flyout)
        shapes.showFlyout(); editor.window!.close(); XCTAssertNil(shapes.flyout)
    }
    func testHoverDelayCancelsOnExitAndAccessibleShowMenuDoesNotSelectTool() throws {
        _ = NSApplication.shared
        let window = HoverTestWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 200),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let shapes = ToolGroupButton(group: .shapes)
        shapes.frame = CGRect(x: 10, y: 10, width: 38, height: 34); window.contentView!.addSubview(shapes)
        var choices: [PaintTool] = []; shapes.onChoose = { choices.append($0) }
        window.orderFront(nil)
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
        let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil)!
        shapes.mouseEntered(with: entered); shapes.mouseExited(with: exited)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3)); XCTAssertNil(shapes.flyout)
        shapes.mouseEntered(with: entered)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3)); XCTAssertNotNil(shapes.flyout)
        XCTAssertTrue(choices.isEmpty); shapes.dismissFlyout()
        XCTAssertTrue(shapes.accessibilityPerformShowMenu()); XCTAssertTrue(choices.isEmpty)
        shapes.dismissFlyout()
    }
}
