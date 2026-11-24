import AppKit
import SwiftUI
import XCTest
@testable import Reqnivo

@MainActor
final class InspectorLayoutTests: XCTestCase {
    func testPreviewStartsAtTopLeftAndResetsOnlyWhenContentChanges() async throws {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ]
        let headers = NSAttributedString(
            string: "HTTP/1.1\n" + (1...40).map {
                "X-Header-\($0): " + String(repeating: "value ", count: 80)
            }.joined(separator: "\n"), attributes: attributes)
        let host = NSHostingController(rootView: PreviewText(content: headers, scrollsHorizontally: true)
            .frame(width: 400, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        func layout() async throws {
            for _ in 0..<5 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await layout()
        let preview = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? JSONPreviewContainer }.first)
        let scroll = preview.scrollView
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        scroll.contentView.scroll(to: NSPoint(x: 200, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.rootView = PreviewText(content: headers, scrollsHorizontally: true)
            .frame(width: 400, height: 200)
        try await layout()
        XCTAssertEqual(scroll.contentView.bounds.minX, 200, accuracy: 1,
                       "An unchanged preview must preserve manual scrolling")
        XCTAssertEqual(scroll.contentView.bounds.minY, 100, accuracy: 1)
        host.rootView = PreviewText(
            content: NSAttributedString(string: "HTTP/2.0\n" + headers.string, attributes: attributes),
            scrollsHorizontally: true).frame(width: 400, height: 200)
        try await layout()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1,
                       "Replacement headers must reset horizontal scrolling")
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    }

    func testPreviewLineNumbersRedrawWhenScrollingWithoutChangingContent() async throws {
        let body = (1...100).map { "response line \($0)" }.joined(separator: "\n")
        let host = NSHostingController(rootView: PreviewText(
            content: NSAttributedString(string: body, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            ]), scrollsHorizontally: true, showsLineNumbers: true).frame(width: 400, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        host.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        for _ in 0..<5 {
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let preview = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? JSONPreviewContainer }.first)
        XCTAssertGreaterThan(preview.gutter.bounds.height, 100)
        XCTAssertEqual(preview.gutter.lineNumbers, Array(1...100))
        let layer = try XCTUnwrap(preview.gutter.layer)
        for offset: CGFloat in [150, 300, 0] {
            preview.gutter.display()
            layer.displayIfNeeded()
            XCTAssertFalse(layer.needsDisplay())
            preview.scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            preview.scrollView.reflectScrolledClipView(preview.scrollView.contentView)
            XCTAssertTrue(layer.needsDisplay(),
                          "Scroll notifications must invalidate the line-number backing layer")
            XCTAssertEqual(preview.scrollView.contentView.bounds.minY, offset, accuracy: 1)
        }
    }

    func testBalanceRequestEqualizesPanesWithoutReplacingHostsOrResettingLaterDrags() async throws {
        let controller = WorkspaceSplitController(first: Color.clear, second: Color.clear)
        let first = controller.firstHost
        let second = controller.secondHost
        let name = "Reqnivo.Tests.Balance.\(UUID().uuidString)"
        defer {
            for axis in ["horizontal", "vertical"] {
                UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(name).\(axis)")
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 360))
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 360)
        defer { window.contentViewController = nil }
        controller.configure(vertical: true, autosaveName: name, firstMinimum: 170, secondMinimum: 170,
                             balanceRevision: 3)
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.setPosition(170, ofDividerAt: 0)
        for _ in 0..<5 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(first.view.frame.width, 170, accuracy: 1,
                       "Initial configuration must not replay an old balance request")
        for revision in 4...6 {
            let vertical = revision != 5
            let width: CGFloat = revision == 6 ? 380 : 900
            window.setContentSize(NSSize(width: width, height: 360))
            controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 360)
            let minimum: CGFloat = vertical ? 170 : 100
            controller.configure(vertical: vertical, autosaveName: name, firstMinimum: minimum, secondMinimum: minimum,
                                 balanceRevision: revision - 1)
            controller.view.layoutSubtreeIfNeeded()
            controller.splitView.setPosition(minimum, ofDividerAt: 0)
            let unbalancedSize = vertical ? first.view.frame.width : first.view.frame.height
            controller.configure(vertical: vertical, autosaveName: name, firstMinimum: minimum, secondMinimum: minimum,
                                 balanceRevision: revision)
            for _ in 0..<5 {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            let firstSize = vertical ? first.view.frame.width : first.view.frame.height
            let secondSize = vertical ? second.view.frame.width : second.view.frame.height
            XCTAssertEqual(firstSize, secondSize, accuracy: 1)
            XCTAssertGreaterThan(firstSize, unbalancedSize + 10)
            XCTAssertTrue(controller.firstHost === first)
            XCTAssertTrue(controller.secondHost === second)
            controller.splitView.setPosition(minimum, ofDividerAt: 0)
            controller.configure(vertical: vertical, autosaveName: name, firstMinimum: minimum, secondMinimum: minimum,
                                 balanceRevision: revision)
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(vertical ? first.view.frame.width : first.view.frame.height, minimum, accuracy: 1)
        }
    }

    func testManagedInspectorOnlyCollapsesThroughItsVisibilityControl() async throws {
        let controller = WorkspaceSplitController(first: Color.clear, second: Color.clear)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700))
        defer { window.contentViewController = nil }
        let name = "Reqnivo.Tests.ManagedCollapse.\(UUID().uuidString)"
        defer {
            for axis in ["horizontal", "vertical"] {
                UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(name).\(axis)")
            }
        }
        for vertical in [false, true] {
            controller.configure(vertical: vertical, autosaveName: name,
                                 firstMinimum: 180, secondMinimum: 260, secondCollapsed: false)
            for _ in 0..<5 {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(controller.splitView.arrangedSubviews.count, 2)
            let inspector = try XCTUnwrap(controller.splitView.arrangedSubviews.dropFirst().first)
            XCTAssertFalse(controller.splitView(controller.splitView, canCollapseSubview: inspector),
                           "Dragging the divider must respect the inspector minimum rather than hide it")
            controller.configure(vertical: vertical, autosaveName: name,
                                 firstMinimum: 180, secondMinimum: 260, secondCollapsed: true)
            XCTAssertTrue(controller.splitViewItems[1].isCollapsed,
                          "The explicit visibility control must still be able to hide the inspector")
            controller.configure(vertical: vertical, autosaveName: name,
                                 firstMinimum: 180, secondMinimum: 260, secondCollapsed: false)
            XCTAssertFalse(controller.splitViewItems[1].isCollapsed)
        }
    }

    func testInspectorCollapseReturnsSpaceToTrafficAndCanReopenInBothOrientations() async {
        for vertical in [false, true] {
            let controller = WorkspaceSplitController(first: Color.clear, second: Color.clear)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 1000, height: 700))
            controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            let name = "Reqnivo.Tests.Collapse.\(UUID().uuidString)"
            controller.configure(vertical: vertical, autosaveName: name,
                                 firstMinimum: 180, secondMinimum: 260, secondCollapsed: true)
            for _ in 0..<5 {
                controller.view.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(controller.splitViewItems[1].isCollapsed)
            let collapsedTrafficSize = vertical ? controller.firstHost.view.frame.width : controller.firstHost.view.frame.height

            controller.configure(vertical: vertical, autosaveName: name,
                                 firstMinimum: 180, secondMinimum: 260, secondCollapsed: false)
            for _ in 0..<5 {
                controller.view.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(controller.splitViewItems[1].isCollapsed)
            let expandedTrafficSize = vertical ? controller.firstHost.view.frame.width : controller.firstHost.view.frame.height
            XCTAssertGreaterThan(collapsedTrafficSize, expandedTrafficSize)
            window.contentViewController = nil
        }
    }

    func testEmptyInspectorDoesNotShowMessagePanesBehindThePlaceholder() async {
        for stacked in [false, true] {
            for loading in [false, true] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let host = NSHostingController(rootView: InspectorView(
                        detail: nil, loading: loading, messagesStacked: stacked))
                    let window = makeWindow(host: host, appearance: appearance)
                    await layout(host)
                    XCTAssertFalse(descendants(of: host.view).contains { $0 is NSSplitView },
                                   "An unselected inspector must show only the empty state, not the message split")
                    XCTAssertFalse(descendants(of: host.view).contains { $0 is NSSegmentedControl },
                                   "Headers/Body controls must not show before selecting a request")
                    XCTAssertGreaterThanOrEqual(host.view.frame.height, 350)
                    window.contentViewController = nil
                }
            }
        }
    }

    func testSelectingAndClearingRequestShowsAndRemovesMessagePanes() async {
        let summary = TrafficFlow(id: "layout", method: "GET", url: "https://example.test/",
                                  host: "example.test", status: 200, state: "complete",
                                  started: 1, duration: 0.1, size: 2, error: nil)
        let message = FlowMessage(headers: [], body: "{}", truncated: false,
                                  streamed: false, httpVersion: "HTTP/2.0")
        let detail = InspectorDetail(flow: FlowDetail(summary: summary, request: message, response: message))
        let host = NSHostingController(rootView: InspectorView(detail: nil, loading: false))
        let window = makeWindow(host: host, appearance: .aqua)
        defer { window.contentViewController = nil }
        for stacked in [false, true] {
            host.rootView = InspectorView(detail: detail, loading: false, messagesStacked: stacked)
            await layout(host)
            let split = descendants(of: host.view).compactMap { $0 as? NSSplitView }.first
            XCTAssertNotNil(split)
            XCTAssertEqual(split?.isVertical, !stacked)
            XCTAssertEqual(descendants(of: host.view).filter { $0 is NSSegmentedControl }.count, 2)

            host.rootView = InspectorView(detail: nil, loading: false, messagesStacked: stacked)
            await layout(host)
            XCTAssertFalse(descendants(of: host.view).contains { $0 is NSSplitView })
            XCTAssertFalse(descendants(of: host.view).contains { $0 is NSSegmentedControl })
        }
    }

    func testLongRequestAndResponseLinesScrollHorizontallyWithoutWrapping() async throws {
        let summary = TrafficFlow(id: "long-response", method: "GET", url: "https://example.test/",
                                  host: "example.test", status: 200, state: "complete",
                                  started: 1, duration: 0.1, size: 2000, error: nil)
        let body = "{\"message\":\"" + String(repeating: "ข้อความยาว ", count: 80)
            + "\",\"url\":\"https://example.test/" + String(repeating: "path/", count: 80) + "\"}"
        let message = FlowMessage(headers: [["X-Long-Value", String(repeating: "header-value ", count: 80)]], body: body, truncated: false,
                                  streamed: false, httpVersion: "HTTP/2.0")
        let detail = InspectorDetail(flow: FlowDetail(summary: summary, request: message, response: message))
        let host = NSHostingController(rootView: InspectorView(detail: detail, loading: false))
        let window = makeWindow(host: host, appearance: .aqua)
        defer { window.contentViewController = nil }
        for stacked in [false, true] {
            host.rootView = InspectorView(detail: detail, loading: false, messagesStacked: stacked)
            await layout(host)
            for section in [1, 0] {
                for picker in descendants(of: host.view).compactMap({ $0 as? NSSegmentedControl }) {
                    picker.selectedSegment = section
                    picker.sendAction(picker.action, to: picker.target)
                }
                await layout(host)
                for title in ["Request", "Response"] {
                    let preview = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSTextView }
                        .first { $0.accessibilityLabel() == "\(title) \(section == 0 ? "headers" : "body")" })
                    let manager = try XCTUnwrap(preview.layoutManager)
                    let textContainer = try XCTUnwrap(preview.textContainer)
                    manager.ensureLayout(for: textContainer)
                    let text = preview.string as NSString
                    for token in section == 0 ? ["header-value"] : ["ข้อความยาว", "https://example.test/"] {
                        let line = text.lineRange(for: text.range(of: token))
                        let first = manager.glyphIndexForCharacter(at: line.location)
                        let last = manager.glyphIndexForCharacter(at: NSMaxRange(line) - 2)
                        XCTAssertEqual(manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY,
                                       manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).minY)
                    }
                    let scroll = try XCTUnwrap(preview.enclosingScrollView)
                    XCTAssertGreaterThan(preview.frame.width, scroll.contentSize.width)
                    XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1,
                                   "Opening headers or body must start at the left edge")
                    scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
                    XCTAssertEqual(preview.string, section == 0 ? detail.request.headers.string : detail.request.copyText)
                }
            }
        }
    }

    func testRequestHeadersStartAtLeftEdgeAfterReturningFromEmptyBody() async throws {
        let summary = TrafficFlow(id: "empty-body", method: "GET", url: "https://example.test/",
                                  host: "example.test", status: 200, state: "complete",
                                  started: 1, duration: 0.1, size: 0, error: nil)
        let message = FlowMessage(headers: [["X-Long-Value", String(repeating: "header-value ", count: 80)]],
                                  body: "", truncated: false, streamed: false, httpVersion: "HTTP/1.1")
        let detail = InspectorDetail(flow: FlowDetail(summary: summary, request: message, response: message))
        let host = NSHostingController(rootView: InspectorView(detail: detail, loading: false))
        let window = makeWindow(host: host, appearance: .aqua)
        defer { window.contentViewController = nil }
        for stacked in [false, true] {
            host.rootView = InspectorView(detail: detail, loading: false, messagesStacked: stacked)
            await layout(host)
            for _ in 0..<2 {
                for picker in descendants(of: host.view).compactMap({ $0 as? NSSegmentedControl }) {
                    picker.selectedSegment = 0
                    picker.sendAction(picker.action, to: picker.target)
                }
                await layout(host)
                let text = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSTextView }
                    .first { $0.accessibilityLabel() == "Request headers" })
                let scroll = try XCTUnwrap(text.enclosingScrollView)
                XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1)
                scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertEqual(scroll.contentView.bounds.minX, 200, accuracy: 1)
                for picker in descendants(of: host.view).compactMap({ $0 as? NSSegmentedControl }) {
                    picker.selectedSegment = 1
                    picker.sendAction(picker.action, to: picker.target)
                }
                await layout(host)
                XCTAssertFalse(descendants(of: host.view).compactMap { $0 as? NSTextView }
                    .contains { $0.accessibilityLabel() == "Request headers" })
            }
        }
    }

    func testCompactInspectorContainsBothContentPickers() async throws {
        let summary = TrafficFlow(id: "compact", method: "POST", url: "https://example.test/" + String(repeating: "path/", count: 50),
                                  host: "example.test", status: 500, state: "complete",
                                  started: 1, duration: 0.1, size: 2000, error: nil)
        let message = FlowMessage(headers: [["Content-Type", "application/json"]], body: "{\"ok\":false}",
                                  truncated: true, streamed: false, httpVersion: "HTTP/2.0")
        let detail = InspectorDetail(flow: FlowDetail(summary: summary, request: message, response: message))
        let prefix = "Reqnivo.Tests.Compact.\(UUID().uuidString)"
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(prefix) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let host = NSHostingController(rootView: InspectorView(detail: detail, loading: false, autosaveName: prefix)
            .frame(width: 380, height: 260).environment(\.colorScheme, .light))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for stacked in [false, true] {
                host.rootView = InspectorView(detail: detail, loading: false, messagesStacked: stacked, autosaveName: prefix)
                    .frame(width: 380, height: 260)
                    .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
                window.setContentSize(NSSize(width: 380, height: 260))
                for _ in 0..<5 {
                    host.view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                }
                let pickers = descendants(of: host.view).compactMap { $0 as? NSSegmentedControl }
                XCTAssertEqual(pickers.count, 2)
                for picker in pickers {
                    let bounds = picker.convert(picker.bounds, to: host.view)
                    XCTAssertGreaterThanOrEqual(bounds.minX, -1)
                    XCTAssertGreaterThanOrEqual(bounds.minY, -1)
                    XCTAssertLessThanOrEqual(bounds.maxX, 381)
                    XCTAssertLessThanOrEqual(bounds.maxY, 261)
                }
            }
        }
    }

    private func makeWindow(host: NSHostingController<InspectorView>, appearance: NSAppearance.Name) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = host
        window.setContentSize(NSSize(width: 900, height: 360))
        return window
    }

    private func layout(_ host: NSHostingController<InspectorView>) async {
        for _ in 0..<5 {
            host.view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
