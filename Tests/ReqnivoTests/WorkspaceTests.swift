import AppKit
import SwiftUI
import XCTest
@testable import Reqnivo

@MainActor
final class WorkspaceTests: XCTestCase {
    func testCaptureControlKeepsLayoutStableAcrossRunningAndBusyStates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CaptureModel(settingsStore: AppSettingsStore(root: root))
        for appearance in [NSAppearance.Name.aqua, .darkAqua,
                           .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            model.running = false
            model.busy = false
            let host = NSHostingView(rootView: HStack(spacing: 8) {
                CaptureControl(model: model)
                Text("Clear")
            })
            host.appearance = NSAppearance(named: appearance)
            let initialSize = host.fittingSize
            host.frame = NSRect(origin: .zero, size: initialSize)
            for (running, busy) in [(false, true), (true, false), (true, true), (false, false)] {
                model.running = running
                model.busy = busy
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, initialSize.width, accuracy: 1,
                               "Changing capture state must not move neighboring controls")
                XCTAssertEqual(host.fittingSize.height, initialSize.height, accuracy: 1,
                               "The progress indicator must not change the control height")
            }
        }
    }

    func testWorkspaceKeepsSearchAndInspectorInsideViewport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let flow = TrafficFlow(id: "viewport", method: "GET", url: "https://example.test/" + String(repeating: "path/", count: 50),
                               host: "example.test", status: 200, state: "complete",
                               started: 1, duration: 0.1, size: 2, error: nil)
        let message = FlowMessage(headers: [], body: "{}", truncated: false, streamed: false, httpVersion: "HTTP/2.0")
        let model = CaptureModel(detailLoader: { _ in
            FlowDetail(summary: flow, request: message, response: message)
        }, settingsStore: AppSettingsStore(root: root))
        model.applyTrafficEvents([FlowEvent(sequence: 1, flow: flow)])
        XCTAssertTrue(model.saveFilter(name: String(repeating: "Long saved filter ", count: 12)))
        let name = "Reqnivo.Tests.Workspace.\(UUID().uuidString)"
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(name) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let host = NSHostingController(rootView: VStack(spacing: 0) {
            CaptureWorkspace(model: model, autosavePrefix: name)
        }.frame(minWidth: 1050, minHeight: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        for (size, appearance) in [
            (NSSize(width: 1050, height: 700), NSAppearance.Name.aqua),
            (NSSize(width: 1050, height: 700), .darkAqua),
            (NSSize(width: 1380, height: 860), .aqua),
            (NSSize(width: 1380, height: 860), .darkAqua),
            (NSSize(width: 1800, height: 1000), .aqua),
            (NSSize(width: 1800, height: 1000), .darkAqua)
        ] {
            window.appearance = NSAppearance(named: appearance)
            model.recoveryNeeded = appearance == .darkAqua
            model.allowLAN = appearance == .darkAqua
            model.search = appearance == .aqua ? "" :
                (size.width == 1380 ? "method:GET" : "host:example.test method:GET -status:400-599")
            model.applySearch()
            if appearance == .darkAqua && size.width != 1380 {
                model.search = "status:999"
                model.applySearch()
                XCTAssertNotNil(model.queryError)
            }
            for vertical in [false, true] {
                model.inspectorOnRight = vertical
                for stacked in [false, true] {
                    model.messagesStacked = stacked
                    model.selectTraffic([flow.id], primary: flow.id)
                    window.setContentSize(size)
                    for _ in 0..<10 {
                        host.view.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let views = descendants(host.view)
                    let search = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.isEditable })
                    XCTAssertEqual(search.stringValue, model.search)
                    let pickers = views.compactMap { $0 as? NSSegmentedControl }
                    XCTAssertEqual(pickers.count, 2)
                    for control in [search as NSView] + pickers {
                        let bounds = control.convert(control.bounds, to: host.view)
                        XCTAssertGreaterThanOrEqual(bounds.minX, host.view.bounds.minX - 1)
                        XCTAssertGreaterThanOrEqual(bounds.minY, host.view.bounds.minY - 1)
                        XCTAssertLessThanOrEqual(bounds.maxX, host.view.bounds.maxX + 1)
                        XCTAssertLessThanOrEqual(bounds.maxY, host.view.bounds.maxY + 1)
                    }
                    XCTAssertFalse(model.running)
                    XCTAssertEqual(model.selectedID, flow.id)
                    if size.width == 1050 && appearance == .aqua && !vertical && !stacked {
                        let workspaceSplit = try XCTUnwrap(views.compactMap { $0 as? NSSplitView }
                            .first { $0.autosaveName == name + ".Workspace.horizontal" })
                        let controller = try XCTUnwrap(workspaceSplit.delegate as? NSSplitViewController)
                        let initialSearchBounds = search.convert(search.bounds, to: host.view)
                        for position in [CGFloat(180), workspaceSplit.bounds.height - 10, CGFloat(240)] {
                            workspaceSplit.setPosition(position, ofDividerAt: 0)
                            for _ in 0..<5 {
                                host.view.layoutSubtreeIfNeeded()
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            let bounds = search.convert(search.bounds, to: host.view)
                            XCTAssertEqual(bounds.minY, initialSearchBounds.minY, accuracy: 1,
                                           "Moving the native divider must not move the workspace search")
                        }
                        for collapsed in [true, false, true, false] {
                            controller.splitViewItems[1].isCollapsed = collapsed
                            for _ in 0..<5 {
                                host.view.layoutSubtreeIfNeeded()
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            let bounds = search.convert(search.bounds, to: host.view)
                            XCTAssertEqual(bounds.minY, initialSearchBounds.minY, accuracy: 1,
                                           "Native inspector collapse must not move the workspace search")
                            XCTAssertEqual(bounds.minX, initialSearchBounds.minX, accuracy: 1)
                            XCTAssertEqual(bounds.width, initialSearchBounds.width, accuracy: 1)
                        }
                    }
                    model.selectTraffic([], primary: nil)
                    for _ in 0..<5 {
                        host.view.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let collapsedBounds = search.convert(search.bounds, to: host.view)
                    XCTAssertGreaterThanOrEqual(collapsedBounds.minY, host.view.bounds.minY - 1)
                    XCTAssertLessThanOrEqual(collapsedBounds.maxY, host.view.bounds.maxY + 1)
                    XCTAssertFalse(descendants(host.view).contains { $0 is NSSegmentedControl && !$0.isHiddenOrHasHiddenAncestor })
                }
            }
        }
    }

    func testDividerRestoresWhenRecreatingTheWorkspace() {
        let name = "Reqnivo.Tests.\(UUID().uuidString)"
        let key = "NSSplitView Subview Frames " + name + ".horizontal"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        func makeWindow() -> (NSWindow, WorkspaceSplitController<Text, Text>) {
            let controller = WorkspaceSplitController(first: Text("Traffic"), second: Text("Inspector"))
            controller.configure(vertical: false, autosaveName: name, firstMinimum: 180, secondMinimum: 260)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 900, height: 640))
            controller.view.layoutSubtreeIfNeeded()
            return (window, controller)
        }
        let (firstWindow, first) = makeWindow()
        first.splitView.setPosition(230, ofDividerAt: 0)
        first.view.layoutSubtreeIfNeeded()
        let height = first.firstHost.view.frame.height
        firstWindow.contentViewController = nil
        let (secondWindow, second) = makeWindow()
        defer { secondWindow.contentViewController = nil }
        XCTAssertEqual(second.firstHost.view.frame.height, height, accuracy: 2)
    }

    func testSplitLayoutFitsInAWindowAndPreservesMinimums() {
        let name = "Reqnivo.Tests.\(UUID().uuidString)"
        defer {
            for axis in ["horizontal", "vertical"] {
                UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(name).\(axis)")
            }
        }
        let controller = WorkspaceSplitController(
            first: Text("Traffic").frame(maxWidth: .infinity, maxHeight: .infinity),
            second: Text("Inspector").frame(maxWidth: .infinity, maxHeight: .infinity))
        controller.configure(vertical: false, autosaveName: name,
                             firstMinimum: 180, secondMinimum: 260)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 640))
        defer { window.contentViewController = nil }
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.setPosition(240, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(controller.firstHost.view.frame.height, 180)
        XCTAssertGreaterThanOrEqual(controller.secondHost.view.frame.height, 260)
        controller.configure(vertical: true, autosaveName: name,
                             firstMinimum: 320, secondMinimum: 380)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(controller.firstHost.view.frame.width, 320)
        XCTAssertGreaterThanOrEqual(controller.secondHost.view.frame.width, 380)
    }

    func testLayoutChangesKeepTheSameHostedPanes() {
        let controller = WorkspaceSplitController(first: Text("Traffic"), second: Text("Inspector"))
        let first = controller.firstHost
        let second = controller.secondHost
        let name = "Reqnivo.Tests.\(UUID().uuidString)"
        controller.configure(vertical: false, autosaveName: name, firstMinimum: 180, secondMinimum: 260)
        XCTAssertFalse(controller.splitView.isVertical)
        XCTAssertEqual(controller.splitView.autosaveName, name + ".horizontal")
        controller.configure(vertical: true, autosaveName: name, firstMinimum: 320, secondMinimum: 380)
        XCTAssertTrue(controller.splitView.isVertical)
        XCTAssertTrue(controller.firstHost === first)
        XCTAssertTrue(controller.secondHost === second)
        XCTAssertEqual(controller.splitViewItems[0].minimumThickness, 320)
        XCTAssertEqual(controller.splitViewItems[1].minimumThickness, 380)
        XCTAssertEqual(controller.splitView.autosaveName, name + ".vertical")
    }

    func testSetupStatusesReflectActualFileAndEngineState() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CaptureModel(settingsStore: AppSettingsStore(root: root))
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.captureStatusText, "Listener stopped")
        XCTAssertFalse(model.allowLAN)
        XCTAssertEqual(model.lanStatusText, "Localhost only")
        model.allowLAN = true
        XCTAssertEqual(model.lanStatusText, "LAN access enabled")
        model.allowLAN = false
        XCTAssertEqual(model.lanStatusText, "Localhost only")
        XCTAssertFalse(model.setMacProxy)
        XCTAssertEqual(model.macProxyStatusText, "Mac proxy not managed")
        model.recoveryNeeded = true
        XCTAssertEqual(model.macProxyStatusText, "Mac proxy recovery required")
        await model.refreshCATrust()
        XCTAssertEqual(model.caTrustStatus, MacCATrust.check(model.engine.paths.certificate))
        XCTAssertEqual(model.caStatusText, model.caTrustStatus.text)
    }

    func testSidebarHierarchicalStatsAndPathBreakdown() {
        let testModel = CaptureModel()
        XCTAssertEqual(testModel.sidebarSelection, .all)
        testModel.sidebarSelection = .domain("api.test")
        XCTAssertEqual(testModel.selectedHost, "api.test")
        testModel.sidebarSelection = .client("127.0.0.1")
        XCTAssertNil(testModel.selectedHost)
        testModel.selectedHost = "other.test"
        XCTAssertEqual(testModel.sidebarSelection, .domain("other.test"))
    }

    func testAppearanceSwitchUpdatesGutterAndContainer() {
        let container = JSONPreviewContainer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            container.appearance = NSAppearance(named: appearance)
            container.viewDidChangeEffectiveAppearance()
            XCTAssertEqual(container.textView.backgroundColor, .textBackgroundColor)
        }
    }

    func testTrafficTableAccessibilityLabels() {
        let parent = TrafficTable(rows: [
            TrafficFlow(id: "f1", method: "POST", url: "https://api.test/checkout", host: "api.test",
                        status: 500, state: "error", started: 1, duration: 0.25, size: 50, error: "Gateway Timeout", number: 42, client: "127.0.0.1")
        ], selectedID: .constant("f1"))
        let coordinator = TrafficTable.Coordinator(parent: parent)
        coordinator.sourceRows = parent.rows
        let table = NSTableView()
        for id in ["id", "method", "status", "host", "path", "time", "size"] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            table.addTableColumn(col)
        }
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.sortAndReload(table)

        let statusCol = table.tableColumns.first(where: { $0.identifier.rawValue == "status" })
        let statusCell = coordinator.tableView(table, viewFor: statusCol, row: 0) as? NSTableCellView
        XCTAssertEqual(statusCell?.textField?.stringValue, "500")
        XCTAssertEqual(statusCell?.textField?.accessibilityLabel(), "Status 500")

        let idCol = table.tableColumns.first(where: { $0.identifier.rawValue == "id" })
        let idCell = coordinator.tableView(table, viewFor: idCol, row: 0) as? NSTableCellView
        XCTAssertEqual(idCell?.textField?.stringValue, "42")
        XCTAssertEqual(idCell?.textField?.accessibilityLabel(), "Request 42")
    }

    func testStatusTintDoesNotColorOtherCellsOrOverrideSelection() throws {
        let flow = TrafficFlow(id: "error", method: "POST", url: "https://api.test/items", host: "api.test",
                               status: 500, state: "error", started: 1, duration: 0.1, size: 20, error: "Failed")
        let coordinator = TrafficTable.Coordinator(parent: TrafficTable(rows: [flow], selectedID: .constant(nil)))
        coordinator.rows = [flow]
        let table = NSTableView()
        let status = try XCTUnwrap(coordinator.tableView(table, viewFor: NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("status")), row: 0) as? NSTableCellView)
        let method = try XCTUnwrap(coordinator.tableView(table, viewFor: NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("method")), row: 0) as? NSTableCellView)
        XCTAssertEqual(status.textField?.textColor, WorkspaceStyle.error)
        XCTAssertEqual(method.textField?.textColor, WorkspaceStyle.textPrimary)
        status.backgroundStyle = .emphasized
        XCTAssertEqual(status.textField?.textColor, .alternateSelectedControlTextColor)
        status.backgroundStyle = .normal
        status.appearance = NSAppearance(named: .darkAqua)
        status.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(status.textField?.textColor, WorkspaceStyle.error)
    }
}
