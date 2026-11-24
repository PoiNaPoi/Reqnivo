import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var updateController: UpdateController

    var body: some View {
        Group {
            if updateController.isBlocked {
                UpdateBlockingView(updateController: updateController, captureModel: model)
            } else {
                VStack(spacing: 0) {
                    UpdateNotificationBanner(updateController: updateController)
                    CaptureWorkspace(model: model)
                }
            }
        }
        .frame(minWidth: 1050, minHeight: 700)
        .task {
            await updateController.checkOnLaunch(captureModel: model)
        }
        .alert("Reqnivo", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct CaptureWorkspace: View {
    @ObservedObject var model: CaptureModel
    var autosavePrefix = "Reqnivo"
    @Environment(\.openWindow) private var openWindow
    @State private var inspectorVisible = true
    @State private var columnResetRevision = 0
    @State private var showLANDevices = false
    @State private var searchFocusRequest = 0

    private var orderedHosts: [String] {
        model.hosts.filter { model.pinnedHosts.contains($0) } + model.hosts.filter { !model.pinnedHosts.contains($0) }
    }

    @ViewBuilder private func domainPinMenu(_ host: String) -> some View {
        Button(model.isHTTPSDecryptionEnabled(host) ? "Disable HTTPS Decryption" : "Enable HTTPS Decryption") {
            Task { await model.setHTTPSDecryption(host, enabled: !model.isHTTPSDecryptionEnabled(host)) }
        }.disabled(model.busy)
        Button(model.pinnedHosts.contains(host) ? "Unpin" : "Pin",
               systemImage: model.pinnedHosts.contains(host) ? "pin.slash" : "pin") {
            if model.pinnedHosts.contains(host) { model.pinnedHosts.remove(host) }
            else { model.pinnedHosts.insert(host) }
        }
    }

    private var scopeTitle: (title: String, icon: String) {
        switch model.sidebarSelection {
        case .all:
            return ("All Traffic", "network")
        case .domain(let host):
            return (host, "globe")
        case .domainPath(let host, let pathPrefix):
            return ("\(host) › \(pathPrefix)", "arrow.triangle.branch")
        case .client(let client):
            return ("Client: \(client)", "desktopcomputer")
        }
    }

    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            CaptureToolbarButton(model: model)
                .keyboardShortcut("r", modifiers: [.command])
            StackedToolbarButton(title: "Clear", systemImage: "trash") { model.clearDisplay() }
                .help("Clear Display")
                .accessibilityLabel("Clear display")
            Divider().frame(height: 28)
            StackedToolbarButton(title: "Map Local", systemImage: "arrow.triangle.branch") { model.showMapLocalRules = true }
                .help("Manage Map Local rules")
                .accessibilityLabel("Map Local")
            StackedToolbarButton(title: model.paused.isEmpty ? "Breakpoints" : "Breakpoints (\(model.paused.count))",
                                 systemImage: "pause.circle") { model.showBreakpoints = true }
                .monospacedDigit()
                .help("Manage breakpoint rules")
                .accessibilityLabel(model.paused.isEmpty ? "Breakpoints" : "Breakpoints, \(model.paused.count) paused")
            StackedToolbarButton(title: "HTTPS", systemImage: "lock.open") { model.showHTTPSDecryption = true }
                .help("Choose domains to decrypt")
                .accessibilityLabel("HTTPS decryption")
            StackedToolbarButton(title: "Settings", systemImage: "slider.horizontal.3") { model.showSetup = true }
                .help("Capture settings")
                .accessibilityLabel("Capture settings")
            StackedToolbarButton(title: "Certificate", systemImage: "checkmark.seal") { openWindow(id: "install-certificate") }
                .help("Install certificate")
                .accessibilityLabel("Install certificate")
            Menu {
                Toggle("Inspector on Right", isOn: $model.inspectorOnRight)
                Toggle("Stack Request and Response", isOn: $model.messagesStacked)
                Button("Reset Traffic Columns") { columnResetRevision += 1 }
                Button("Focus Traffic Filter") { searchFocusRequest += 1 }.keyboardShortcut("f")
            } label: {
                Label("Layout", systemImage: "rectangle.split.2x2")
            }
            .menuStyle(.button)
            .buttonStyle(StackedToolbarButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Workspace Layout")
            .accessibilityLabel("Workspace layout")
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $model.sidebarSelection) {
                    Section("Capture") {
                        HStack {
                            Label("All Traffic", systemImage: "network")
                            Spacer()
                            Text(model.retainedCount.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(SidebarFilter.all)
                        .accessibilityLabel("All Traffic, \(model.retainedCount) requests")
                    }
                    if !model.hosts.isEmpty {
                        Section("Domains") {
                            ForEach(orderedHosts, id: \.self) { host in
                                let paths = model.hostPaths[host] ?? []
                                if paths.isEmpty {
                                    HStack {
                                        Label(host, systemImage: "globe").lineLimit(1)
                                        if model.pinnedHosts.contains(host) { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                                        Spacer()
                                        Text((model.hostCounts[host] ?? 0).formatted())
                                            .foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    .tag(SidebarFilter.domain(host))
                                    .help(host)
                                    .contextMenu { domainPinMenu(host) }
                                    .accessibilityLabel("Domain \(host), \(model.hostCounts[host] ?? 0) requests")
                                } else {
                                    DisclosureGroup {
                                        ForEach(paths) { item in
                                            HStack {
                                                Label(item.pathPrefix, systemImage: "arrow.turn.down.right").lineLimit(1)
                                                Spacer()
                                                Text(item.count.formatted())
                                                    .foregroundStyle(.secondary).monospacedDigit()
                                            }
                                            .tag(SidebarFilter.domainPath(host: host, pathPrefix: item.pathPrefix))
                                            .help("\(host)\(item.pathPrefix)")
                                            .accessibilityLabel("Path \(item.pathPrefix) on \(host), \(item.count) requests")
                                        }
                                    } label: {
                                        HStack {
                                            Label(host, systemImage: "globe").lineLimit(1)
                                            if model.pinnedHosts.contains(host) { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                                            Spacer()
                                            Text((model.hostCounts[host] ?? 0).formatted())
                                                .foregroundStyle(.secondary).monospacedDigit()
                                        }
                                        .tag(SidebarFilter.domain(host))
                                        .help(host)
                                        .contextMenu { domainPinMenu(host) }
                                        .accessibilityLabel("Domain \(host), \(model.hostCounts[host] ?? 0) requests")
                                    }
                                }
                            }
                        }
                    }
                    if !model.clients.isEmpty {
                        Section("Clients") {
                            ForEach(model.clients, id: \.self) { client in
                                HStack {
                                    Label(client, systemImage: client == "127.0.0.1" || client == "localhost" ? "desktopcomputer" : "laptopcomputer.and.ipad").lineLimit(1)
                                    Spacer()
                                    Text((model.clientCounts[client] ?? 0).formatted())
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                                .tag(SidebarFilter.client(client))
                                .help("Traffic from \(client)")
                                .accessibilityLabel("Client \(client), \(model.clientCounts[client] ?? 0) requests")
                            }
                        }
                    }
                }
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: WorkspaceStyle.sidebar))
                Divider()
                CaptureStatusView(model: model, onLANDevices: { showLANDevices = true },
                                  onCertificate: { openWindow(id: "install-certificate") })
            }
            .background(Color(nsColor: WorkspaceStyle.sidebar))
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Label(scopeTitle.title, systemImage: scopeTitle.icon)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        .help(scopeTitle.title)
                        .layoutPriority(-1)
                    Spacer()
                    Text("\(model.rows.count.formatted()) of \(model.retainedCount.formatted()) retained")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button { inspectorVisible.toggle() } label: {
                        Label(inspectorVisible && model.selectedID != nil ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.selectedID == nil)
                    .help(model.selectedID == nil ? "Select a request to inspect its details" :
                          (inspectorVisible ? "Hide Inspector" : "Show Inspector"))
                }.padding(.horizontal, 12).padding(.vertical, 8)
                TrafficFilterControls(model: model, focusRequest: searchFocusRequest)
                Divider()
                WorkspaceSplit(vertical: model.inspectorOnRight, autosaveName: autosavePrefix + ".Workspace",
                               firstMinimum: model.inspectorOnRight ? 320 : 180,
                               secondMinimum: model.inspectorOnRight ? 380 : 260,
                               secondCollapsed: model.selectedID == nil || !inspectorVisible) {
                    TrafficTable(rows: model.rows, selectedID: $model.selectedID,
                                 pinnedIDs: model.pinnedIDs,
                                 filterRevision: model.filterRevision, columnResetRevision: columnResetRevision,
                                 onSelection: model.selectTraffic, onSortChanged: model.updateTrafficSort,
                                 onPin: model.setPinned,
                                 onFilter: { _ = model.addFilter(field: $0, value: $1, excluded: $2) },
                                 canEditFilters: model.queryError == nil, onMapLocal: model.openMapLocal,
                                 onBreakpoint: model.openBreakpointRules,
                                 onReloaded: model.markTableReloaded, autosaveName: autosavePrefix + ".TrafficTable")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if model.rows.isEmpty {
                                ContentUnavailableView {
                                    Label(model.retainedCount > 0 ? "No matching traffic" : (model.running ? "Waiting for requests" : "Your traffic, in view"),
                                          systemImage: "network")
                                } description: {
                                    Text(model.retainedCount > 0 ? "Change the filter or select All Traffic." :
                                         (model.running ? "Route a browser or test device through port \(model.proxyPort)." :
                                          "Start capture, then enable Capture Mac Traffic or configure a client."))
                                } actions: {
                                    if model.retainedCount > 0 {
                                        if !model.search.isEmpty { Button("Clear Search") { model.search = "" } }
                                        if model.sidebarSelection != .all { Button("All Traffic") { model.sidebarSelection = .all } }
                                    } else if model.running {
                                        Button("Set Up Capture…") { model.showSetup = true }
                                    } else {
                                        CaptureControl(model: model)
                                    }
                                }
                            }
                        }
                } second: {
                    VStack(spacing: 0) {
                        if let flow = model.detail?.flow.summary, flow.tlsPassthrough == true {
                            EncryptedTrafficView(host: flow.host,
                                                 decryptionEnabled: model.isHTTPSDecryptionEnabled(flow.host),
                                                 busy: model.busy,
                                                 onEnable: { Task { await model.setHTTPSDecryption(flow.host, enabled: true) } },
                                                 onSettings: { model.showHTTPSDecryption = true })
                        } else {
                            InspectorView(detail: model.detail, loading: model.loadingDetail, messagesStacked: model.messagesStacked,
                                          onRendered: { model.markSelectionRendered(flowID: $0) },
                                          autosaveName: autosavePrefix + ".Messages",
                                          onSideBySide: { model.messagesStacked = false })
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 12) {
                    Circle().fill(Color(nsColor: model.running ? WorkspaceStyle.success : WorkspaceStyle.textSecondary))
                        .frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(model.status).lineLimit(1).help(model.status).layoutPriority(1)
                    Spacer()
                    Text("\(model.total.formatted()) captured")
                    Button { model.showMetrics = true } label: {
                        Text("RAM \(model.memory) · CPU \(model.cpu)").monospacedDigit()
                    }.buttonStyle(.plain).help("UI + engine process tree; CPU is a decaying average sampled by ps")
                    Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                         .map { "v\($0)" } ?? "Development build")
                }.font(.system(size: 11)).foregroundStyle(Color(nsColor: WorkspaceStyle.textSecondary))
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(Color(nsColor: WorkspaceStyle.workspace))
        }
        .navigationTitle("Reqnivo")
        .toolbar { workspaceToolbar }
        .sheet(isPresented: $model.showSetup) { SetupView(model: model) }
        .sheet(isPresented: $showLANDevices) { LANDevicesView(model: model) }
        .sheet(isPresented: $model.showHTTPSDecryption) { HTTPSDecryptionView(model: model) }
        .onChange(of: model.showCertificateInstaller) { _, show in
            if show { openWindow(id: "install-certificate"); model.showCertificateInstaller = false }
        }
        .onChange(of: model.showMapLocalRules) { _, show in
            if show { openWindow(id: "map-local"); model.showMapLocalRules = false }
        }
        .onChange(of: model.showBreakpoints) { _, show in
            if show { openWindow(id: "breakpoint-rules"); model.showBreakpoints = false }
        }
        .onChange(of: model.showPausedTraffic) { _, show in
            if show { openWindow(id: "paused-traffic"); model.showPausedTraffic = false }
        }
        .sheet(isPresented: $model.showMetrics) { MetricsView(model: model) }
    }
}

struct CaptureControl: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        Button(action: model.toggle) {
            HStack(spacing: 8) {
                ZStack {
                    if model.busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: model.running ? "stop.fill" : "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
                Text(model.busy ? "Please wait…" : (model.running ? "Stop" : "Start Capture"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(width: 148, height: 32)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(CaptureControlStyle(running: model.running))
        .disabled(model.busy)
        .help(model.busy ? "Please wait for the current operation to finish" :
              (model.running ? "Stop capture" : "Start capture"))
        .accessibilityLabel(model.running ? "Stop capture" : "Start capture")
        .accessibilityValue(model.busy ? "Please wait" : (model.running ? "Capturing" : "Stopped"))
    }
}

private struct CaptureControlStyle: ButtonStyle {
    let running: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let foreground = Color(nsColor: running ? WorkspaceStyle.error : WorkspaceStyle.onAccent)
        let boundary = Color(nsColor: running ? WorkspaceStyle.error : WorkspaceStyle.accent)
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .foregroundStyle(foreground)
            .background(Color(nsColor: running ? WorkspaceStyle.panel : WorkspaceStyle.accent), in: shape)
            .overlay {
                shape.fill(foreground.opacity(isEnabled ? (configuration.isPressed ? 0.14 : (hovering ? 0.08 : 0)) : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(boundary, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.55)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering && isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CaptureStatusView: View {
    @ObservedObject var model: CaptureModel
    let onLANDevices: () -> Void
    let onCertificate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.captureStatusText, systemImage: model.running ? "record.circle" : "stop.circle")
                .fontWeight(.medium)
                .foregroundStyle(Color(nsColor: WorkspaceStyle.textPrimary))
                .accessibilityLabel("Capture engine: \(model.captureStatusText)")
            MacCaptureToggle(model: model)
            Label(model.macProxyStatusText, systemImage: "desktopcomputer")
                .foregroundStyle(Color(nsColor: model.recoveryNeeded ? WorkspaceStyle.error : WorkspaceStyle.textSecondary))
                .accessibilityLabel("Mac system proxy: \(model.macProxyStatusText)")
            if model.recoveryNeeded {
                Button("Restore Mac Proxy", action: model.restoreProxy).disabled(model.busy)
            }
            Label(model.lanStatusText, systemImage: "wifi")
                .accessibilityLabel("Network access: \(model.lanStatusText)")
            if model.allowLAN {
                Button("LAN Devices (\(model.lanDevices.filter { !$0.approved }.count) waiting)", action: onLANDevices)
                    .accessibilityLabel("LAN Devices, \(model.lanDevices.filter { !$0.approved }.count) waiting for approval")
            }
            Divider()
            Label(model.caTrustStatus == .notGenerated && model.running ? "Waiting for capture CA" : model.caStatusText,
                  systemImage: model.caTrustStatus == .trusted ? "lock.shield" : "exclamationmark.shield")
                .accessibilityLabel("CA certificate: \(model.caStatusText)")
            if model.caTrustStatus == .notTrusted {
                Button("Install Certificate…", systemImage: "checkmark.seal", action: onCertificate)
                    .accessibilityLabel("Install certificate")
            } else if model.caTrustStatus == .notGenerated && !model.running {
                CaptureControl(model: model)
            }
            Button("Set Up Capture & HTTPS…") { model.showSetup = true }
                .buttonStyle(.link)
                .help("Trust is checked on this Mac only. Phones, emulators, and apps with their own trust stores require separate CA setup.")
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(nsColor: WorkspaceStyle.textSecondary))
        .fixedSize(horizontal: false, vertical: true)
        .tint(Color(nsColor: WorkspaceStyle.accent))
        .padding(12)
        // Minimum-size probes must not wrap status text at a near-zero width.
        .frame(minWidth: 200, alignment: .leading)
    }
}

struct InspectorView: View {
    let detail: InspectorDetail?
    let loading: Bool
    var messagesStacked = false
    var onRendered: (String) -> Void = { _ in }
    var autosaveName = "Reqnivo.Messages"
    var onSideBySide: () -> Void = {}
    @State private var balanceRevision = 0
    @State private var requestSection = 1
    @State private var responseSection = 1
    @State private var requestFoldedBody: String?
    @State private var requestCollapsed: Set<Int> = []
    @State private var responseFoldedBody: String?
    @State private var responseCollapsed: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let content = detail {
                let flowDetail = content.flow
                HStack {
                    if let number = flowDetail.summary.number {
                        Text("#\(number)").font(.caption.monospaced()).foregroundStyle(.secondary).help(flowDetail.summary.id)
                    }
                    Text(flowDetail.summary.method)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color(nsColor: WorkspaceStyle.workspace), in: RoundedRectangle(cornerRadius: 4))
                    Text(flowDetail.summary.url).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
                        .help(flowDetail.summary.url).layoutPriority(-1)
                    Spacer()
                    ZStack {
                        if loading { ProgressView().controlSize(.mini) }
                    }.frame(width: 12, height: 12).help("Loading selected request…")
                    if let status = flowDetail.summary.status {
                        Text(String(status)).font(.caption.bold().monospacedDigit())
                            .foregroundStyle(Color(nsColor: status >= 400 ? WorkspaceStyle.error : WorkspaceStyle.success))
                    }
                    Button("Split Evenly") {
                        onSideBySide()
                        balanceRevision += 1
                    }
                    .controlSize(.small)
                    .help("Arrange Request and Response side by side with equal widths")
                    .accessibilityLabel("Equal request and response widths")
                }.padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(Color(nsColor: WorkspaceStyle.textPrimary))
                    .background(Color(nsColor: WorkspaceStyle.panel))
                Divider()
                WorkspaceSplit(vertical: !messagesStacked, autosaveName: autosaveName,
                               firstMinimum: messagesStacked ? 100 : 170,
                               secondMinimum: messagesStacked ? 100 : 170,
                               balanceRevision: balanceRevision) {
                    MessagePane(title: "Request", message: flowDetail.request,
                                presentation: content.request, loading: loading, placeholder: "No request body",
                                onRendered: { onRendered(flowDetail.summary.id) },
                                section: $requestSection, foldedBody: $requestFoldedBody, collapsedRegions: $requestCollapsed)
                } second: {
                    MessagePane(title: "Response", message: flowDetail.response,
                                presentation: content.response, loading: loading,
                                placeholder: flowDetail.summary.error ?? "Waiting for response…",
                                onRendered: { onRendered(flowDetail.summary.id) },
                                section: $responseSection, foldedBody: $responseFoldedBody, collapsedRegions: $responseCollapsed)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Inspect a request", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Select a row to view request and response."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

private struct MessagePane: View {
    let title: String
    let message: FlowMessage?
    let presentation: MessagePresentation?
    let loading: Bool
    let placeholder: String
    var onRendered: () -> Void = {}
    @Binding var section: Int
    @State private var copied = false
    @Binding var foldedBody: String?
    @Binding var collapsedRegions: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    guard let presentation else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(presentation.copyText, forType: .string)
                    copied = true
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label(copied ? "Copied" : copyLabel, systemImage: copied ? "checkmark" : "doc.on.doc").fixedSize()
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                .controlSize(.small)
                .disabled(loading || presentation?.copyText.isEmpty != false || message?.streamed == true)
                .help(copied ? "Copied" : "\(copyLabel) as plain text")
                .accessibilityLabel("Copy \(title.lowercased()) body")
                .accessibilityValue(copied ? "Copied" : "")
            }.foregroundStyle(Color(nsColor: WorkspaceStyle.textPrimary))
                .padding(.horizontal, 12).padding(.vertical, 8)
            Picker("\(title) content", selection: $section) {
                Text("Headers").tag(0)
                Text(presentation?.isJSON == true ? "JSON" : "Body").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if let message, let presentation {
                if section == 1 && (message.truncated || message.streamed) {
                    Label(message.streamed ? "Streamed body · preview unavailable" : "Preview limited to 256 KiB · incomplete body",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
                if section == 1 && message.body.isEmpty && !message.streamed {
                    Text(title == "Request" ? "No request body" : "No response body")
                        .font(.callout).foregroundStyle(.secondary).padding(12)
                    Spacer()
                } else {
                    PreviewText(content: section == 0 ? presentation.headers : presentation.body,
                                scrollsHorizontally: true,
                                accessibilityLabel: "\(title) \(section == 0 ? "headers" : "body")",
                                folds: section == 1 ? presentation.folds : [],
                                showsLineNumbers: section == 1,
                                collapsed: Binding(
                                    get: { foldedBody == presentation.copyText ? collapsedRegions : [] },
                                    set: { foldedBody = presentation.copyText; collapsedRegions = $0 }
                                ),
                                onRendered: onRendered)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text(placeholder).font(.callout).foregroundStyle(.secondary).padding(12)
                Spacer()
            }
        }
        .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: WorkspaceStyle.panel))
        .onChange(of: message) { previous, next in
            copied = false
            if previous?.body != next?.body {
                foldedBody = nil
                collapsedRegions = []
            }
        }
        .onChange(of: section) { _, _ in copied = false }
    }

    private var copyLabel: String {
        if message?.truncated == true { return "Copy Preview" }
        return presentation?.isJSON == true ? "Copy JSON" : "Copy Body"
    }
}

struct PreviewText: NSViewRepresentable {
    let content: NSAttributedString
    var scrollsHorizontally = false
    var accessibilityLabel: String? = nil
    var folds: [JSONFoldRegion] = []
    var showsLineNumbers = false
    var collapsed: Binding<Set<Int>>? = nil
    var onRendered: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> JSONPreviewContainer {
        let container = JSONPreviewContainer(frame: .zero)
        let scroll = container.scrollView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        let view = container.textView
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.backgroundColor = .textBackgroundColor
        if let accessibilityLabel {
            view.setAccessibilityLabel(accessibilityLabel)
        }
        scroll.documentView = view
        let gutter = container.gutter
        gutter.onToggle = { [weak coordinator = context.coordinator] id in coordinator?.toggle(id) }
        context.coordinator.gutter = gutter
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak gutter] _ in
            gutter?.needsLayout = true
            gutter?.needsDisplay = true
        }
        return container
    }

    func updateNSView(_ view: JSONPreviewContainer, context: Context) {
        if let accessibilityLabel {
            view.textView.setAccessibilityLabel(accessibilityLabel)
        }
        context.coordinator.parent = self
        context.coordinator.update(view)
    }

    final class Coordinator {
        var parent: PreviewText
        weak var gutter: JSONFoldGutter?
        var observer: NSObjectProtocol?
        private var source: NSAttributedString?
        private var regions: [JSONFoldRegion] = []
        private var collapsed: Set<Int> = []

        init(parent: PreviewText) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func toggle(_ id: Int) {
            guard let binding = parent.collapsed else { return }
            var next = binding.wrappedValue
            if !next.insert(id).inserted { next.remove(id) }
            binding.wrappedValue = next
        }

        func update(_ container: JSONPreviewContainer) {
            let scroll = container.scrollView
            let textView = container.textView
            let horizontal = parent.scrollsHorizontally
            scroll.hasHorizontalScroller = horizontal
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = horizontal
            textView.autoresizingMask = horizontal ? [] : [.width]
            textView.textContainer?.widthTracksTextView = !horizontal
            textView.textContainer?.containerSize = NSSize(
                width: horizontal ? .greatestFiniteMagnitude : scroll.contentSize.width,
                height: .greatestFiniteMagnitude)
            let nextCollapsed = parent.collapsed?.wrappedValue ?? []
            let changedDocument = source?.isEqual(to: parent.content) != true
            guard changedDocument || regions != parent.folds || collapsed != nextCollapsed else {
                parent.onRendered?()
                return
            }
            source = parent.content
            regions = parent.folds
            collapsed = nextCollapsed
            let display = JSONFolding.display(parent.content, regions: regions, collapsed: collapsed)
            let position = scroll.contentView.bounds.origin
            textView.textStorage?.setAttributedString(display.content)
            textView.sizeToFit()
            if parent.showsLineNumbers {
                let starts = SyntaxTextEditor.lineStarts(in: display.content.string)
                var hidden = 0
                var next = 0
                let numbers = starts.enumerated().map { index, start in
                    while next < display.hiddenLines.count, display.hiddenLines[next].location < start {
                        hidden += display.hiddenLines[next].lines
                        next += 1
                    }
                    return index + hidden + 1
                }
                container.setFoldControls(display.controls, lineStarts: starts, lineNumbers: numbers)
            } else {
                container.setFoldControls(display.controls)
            }
            scroll.contentView.scroll(to: changedDocument ? .zero : position)
            scroll.reflectScrolledClipView(scroll.contentView)
            gutter?.needsLayout = true
            // Force glyph generation/layout so selection-to-render includes real text layout cost.
            if let manager = textView.layoutManager, let textContainer = textView.textContainer {
                manager.ensureLayout(for: textContainer)
            }
            parent.onRendered?()
        }
    }
}

struct MacCaptureToggle: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        Toggle("Capture Mac Traffic", isOn: Binding(
            get: { model.setMacProxy },
            set: { enabled in Task { await model.setMacCaptureEnabled(enabled) } }
        ))
        .toggleStyle(.checkbox)
        .disabled(model.busy || model.ruleOperation || model.recoveryNeeded)
        .help("Capture HTTP/HTTPS from apps using the selected Mac network service (\(model.service)). Changes require administrator approval. HTTPS requires trusting the Reqnivo CA. When stopped, applies on the next capture start.")
    }
}

struct SetupView: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var showHTTPSDecryption = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Capture Settings").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Get started") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("1. Connect your client").font(.headline)
                            Text("For this Mac, enable Capture Mac Traffic. For a phone or emulator, allow local network access below and configure its proxy to this Mac’s LAN IP and port \(model.proxyPort).")
                            Text("2. Install and trust the certificate").font(.headline)
                            Button("Install Certificate on Mac / Device…") { dismiss(); openWindow(id: "install-certificate") }
                            Text("3. Choose HTTPS domains").font(.headline)
                            Text("Only selected domains are decrypted. Other HTTPS connections remain encrypted.")
                            Button("Choose Domains…") { showHTTPSDecryption = true }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    Form {
                        TextField("Proxy port", value: $model.proxyPort, format: .number.grouping(.never))
                        TextField("Control port (localhost only)", value: $model.apiPort, format: .number.grouping(.never))
                        Toggle("Allow test devices on local network", isOn: $model.allowLAN)
                        Picker("Mac network service", selection: $model.service) {
                            ForEach(model.services, id: \.self) { Text($0).tag($0) }
                        }.disabled(!model.setMacProxy)
                    }.disabled(model.running || model.busy)
                    if model.allowLAN {
                        Text("Approve and manage devices using LAN Devices in the main window.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    MacCaptureToggle(model: model)
                    Group {
                        Text("Upstream HTTPS").font(.headline)
                        Toggle("Skip server certificate verification (debug only)", isOn: $model.skipUpstreamVerification)
                            .disabled(model.running || model.busy)
                        if model.skipUpstreamVerification {
                            Text("Server certificate and hostname checks will be skipped for all HTTPS hosts in this capture. A custom CA is not required. Enabled by default on each app launch. Changes apply on the next capture start.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text("Organization CA").font(.subheadline)
                        Text(model.hasUpstreamCA ? "Custom CA bundle installed" : "Using standard trusted CAs")
                            .font(.callout)
                        HStack {
                            Button(model.hasUpstreamCA ? "Replace CA File…" : "Choose CA File…", action: model.chooseUpstreamCA)
                            if model.hasUpstreamCA { Button("Remove Custom CA", action: model.removeUpstreamCA) }
                        }.disabled(model.running || model.busy || model.skipUpstreamVerification)
                        Text("Select a PEM CA bundle provided by your organization. It is added to the standard CAs for server verification. Certificate and hostname checks stay enabled when the skip option is off. Stop capture before changing it; changes apply on the next start.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Mac proxy changes require administrator approval. Stop restores the previous settings. A saved recovery record is checked on the next launch after an unexpected exit.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.recoveryNeeded {
                        Button("Restore Mac Proxy", action: model.restoreProxy).disabled(model.busy)
                    }
                    Divider()
                    Text("Device trust notes").font(.headline)
                    Text("Start capture once to create this Mac’s CA. On iOS, enable full trust in Certificate Trust Settings. Android/debug apps must trust the CA separately; disable pinning only in the debug build.")
                        .font(.callout).textSelection(.enabled)
                    HStack {
                        Button("Show Public CA Certificate", action: model.openCertificate)
                        Button("Open Setup Guide") {
                            if let url = URL(string: "https://docs.mitmproxy.org/stable/concepts/certificates/") { NSWorkspace.shared.open(url) }
                        }
                    }
                    Text("CA private keys stay on this Mac. Body previews are temporary (128 MiB disk budget), capped at 256 KiB; bodies over 1 MiB are streamed. Compressed/binary previews are omitted in this baseline.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 600, height: 650)
        .sheet(isPresented: $showHTTPSDecryption) { HTTPSDecryptionView(model: model) }
    }
}

struct MetricsView: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss

    private static func percentiles(_ samples: LatencySamples, target: Double) -> String {
        guard samples.count > 0 else { return "no samples yet" }
        return String(format: "%.1f / %.1f ms (n=%d, target p95 ≤ %.0f)", samples.percentile(0.5), samples.percentile(0.95),
                      samples.totalCount, target)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Performance Baseline").font(.title2.bold())
            Group {
                LabeledContent("UI RSS · CPU", value: String(format: "%.0f MB · %.1f%%", model.usage.uiMB, model.usage.uiCPU))
                LabeledContent("Engine RSS · CPU", value: String(format: "%.0f MB · %.1f%%", model.usage.engineMB, model.usage.engineCPU))
                LabeledContent("Preview storage", value: "\(ByteCountFormatter.string(fromByteCount: Int64(model.previewDiskBytes), countStyle: .binary)) · \(model.retainedPreviewFiles.formatted()) files")
                LabeledContent("UI + engine RSS (total)", value: model.memory)
                LabeledContent("Captured requests", value: model.total.formatted())
            }
            Divider()
            Group {
                LabeledContent("Last batch apply", value: String(format: "%.2f ms", model.lastBatchMilliseconds))
                LabeledContent("Filter, model only (last)", value: String(format: "%.2f ms", model.filterMilliseconds))
                LabeledContent("Filter end-to-end p50 / p95", value: Self.percentiles(model.filterEndToEndSamples, target: 100))
                LabeledContent("Detail fetch + prepare (last)", value: String(format: "%.2f ms", model.detailMilliseconds))
                LabeledContent("Selection-to-render p50 / p95", value: Self.percentiles(model.selectionRenderSamples, target: 250))
            }
            Text("RSS includes the UI and engine descendants and may double count shared pages. CPU comes from ps as a decaying average. Selection-to-render ends when text layout finishes in every visible inspector pane; filter end-to-end ends when the table finishes reloading. Neither measures scroll/frame hitches — use Instruments for those.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Initial targets (to be confirmed against the baseline): p95 filter ≤ 100 ms at 10,000 rows, p95 selection-to-render ≤ 250 ms for previews ≤ 256 KiB. Workload: 1–2 clients, 10 requests/second, 10,000 retained rows.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Export Snapshot…", action: model.exportMetrics)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
    }
}

struct LANDevicesView: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var addresses: [String] = []
    @State private var copiedAddress: String?

    private var pending: [LANDevice] { model.lanDevices.filter { !$0.approved } }
    private var approved: [LANDevice] { model.lanDevices.filter(\.approved) }
    private var listening: Bool { model.allowLAN && model.running }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 25)).foregroundStyle(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAN Devices").font(.title2.bold())
                    Text("Connect your phone. Approve it here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(listening ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(listening ? "Listening" : (model.allowLAN ? "Capture stopped" : "LAN disabled"))
                        .font(.caption.weight(.medium))
                }.padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.allowLAN {
                        proxySection
                        approvalSection
                        DisclosureGroup("How device approval works") {
                            Text("Access is based on IP, not a verified device identity. Use a trusted test network. Revoke disconnects active traffic. Approve again if the phone’s IP changes.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                        }.font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Enable “Allow test devices on local network” in Capture Settings to connect a device.", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Label("Access resets when capture stops", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 640, height: 660)
        .task {
            while !Task.isCancelled {
                addresses = DeviceCertificate.lanAddresses()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .task(id: copiedAddress) {
            guard copiedAddress != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            copiedAddress = nil
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeading("1", title: "Connect your phone")
            Text("Use the same Wi-Fi network. Set your phone’s proxy to one of these addresses.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(addresses, id: \.self) { address in
                let endpoint = "\(address):\(model.proxyPort)"
                HStack(spacing: 10) {
                    Image(systemName: "network").foregroundStyle(.secondary)
                    Text(endpoint).font(.system(.body, design: .monospaced).weight(.medium))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(endpoint, forType: .string)
                        copiedAddress = endpoint
                    } label: {
                        Label(copiedAddress == endpoint ? "Copied" : "Copy",
                              systemImage: copiedAddress == endpoint ? "checkmark" : "doc.on.doc")
                    }.buttonStyle(.borderless)
                        .accessibilityLabel("Copy proxy address \(endpoint)")
                }.padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if addresses.isEmpty {
                Label("No LAN address found. Check your Mac’s network connection.", systemImage: "wifi.exclamationmark")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Choose the address your phone can reach. No username or password is needed.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var approvalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeading("2", title: "Approve access")
            Text("Open http://mitm.it on your phone, then match its Wi-Fi IP below.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.running {
                Label("Start capture to receive device requests.", systemImage: "pause.circle")
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            } else if pending.isEmpty && approved.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 25))
                    Text("Waiting for your phone").font(.headline)
                    Text("Requests appear here when your phone uses the proxy.").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            if !pending.isEmpty {
                Text("NEEDS APPROVAL · \(pending.count)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                ForEach(pending) { deviceRow($0) }
            }
            if !approved.isEmpty {
                Text("APPROVED · \(approved.count)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(approved) { deviceRow($0) }
            }
            if !pending.isEmpty {
                Label("Only allow an IP that matches your device.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func stepHeading(_ number: String, title: String) -> some View {
        HStack(spacing: 9) {
            Text(number).font(.caption.bold()).foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text(title).font(.headline)
        }
    }

    private func deviceRow(_ device: LANDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.approved ? "checkmark.shield.fill" : "iphone")
                .font(.system(size: 20)).foregroundStyle(device.approved ? Color.green : Color.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.ip).font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text(device.approved ? "Allowed for this capture" : "Waiting for your approval")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if device.approved {
                Button("Revoke") { Task { await model.setLANDeviceApproval(device, approved: false) } }
                    .buttonStyle(.bordered)
            } else {
                Button("Allow") { Task { await model.setLANDeviceApproval(device, approved: true) } }
                    .buttonStyle(.borderedProminent).tint(Color.accentColor)
            }
        }.disabled(!model.running || model.busy || model.lanApprovalBusy)
            .padding(12)
            .background((device.approved ? Color.primary : Color.orange).opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
