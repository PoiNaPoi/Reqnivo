import AppKit
import SwiftUI

struct TrafficFilterControls: View {
    @ObservedObject var model: CaptureModel
    var focusRequest = 0
    @State private var adding = false
    @State private var field: TrafficQuery.Field = .host
    @State private var value = ""
    @State private var excluded = false
    @State private var naming = false
    @State private var filterName = ""
    @State private var renaming: SavedTrafficFilter?
    @State private var showSearchHelp = false
    @FocusState private var focus: Focus?
    @FocusState private var valueFocused: Bool

    private enum Focus: Hashable { case search, addFilter, help }

    private var active: SavedTrafficFilter? {
        model.savedFilters.first { $0.id == model.activeSavedFilterID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField("Search traffic…", text: $model.search)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .search)
                        .accessibilityLabel("Filter traffic")
                        .help("AND filters: host, path, method, status, type, state. Prefix - to exclude. Quote values containing spaces.")
                        .onSubmit { model.applySearch() }
                        .onExitCommand {
                            if !model.search.isEmpty { model.search = "" }
                            else { focus = nil }
                        }
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear traffic filter")
                    }
                }
                .font(.system(size: 13))
                .padding(8)
                .background(Color(nsColor: WorkspaceStyle.panel), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: WorkspaceStyle.controlBoundary)))
                .frame(minWidth: 180)
                Button("Add Filter", systemImage: "line.3.horizontal.decrease.circle") { adding = true }
                    .fixedSize()
                    .focused($focus, equals: .addFilter)
                    .disabled(model.queryError != nil)
                    .popover(isPresented: $adding) { builder }
                Menu {
                    Button("Save Current Filter…") {
                        renaming = nil
                        filterName = ""
                        naming = true
                    }.disabled(model.queryError != nil)
                    if let active {
                        Button("Update \(active.name)") { model.saveFilter(name: active.name, replacingID: active.id) }
                            .disabled(model.queryError != nil || !model.savedFilterModified)
                    }
                    Divider()
                    if model.savedFilters.isEmpty {
                        Text("No saved filters")
                    }
                    ForEach(model.savedFilters) { entry in
                        Menu(entry.name) {
                            Button("Apply") { model.applySavedFilter(entry) }
                            Text("Scope: \(scopeName(entry.scope))")
                            Text(entry.query.isEmpty ? "All text" : entry.query)
                            Button("Rename…") {
                                renaming = entry
                                filterName = entry.name
                                naming = true
                            }
                            Button("Delete", role: .destructive) { model.deleteFilter(entry) }
                        }
                    }
                } label: {
                    Label("Saved Filters", systemImage: "line.3.horizontal.decrease")
                }
                .fixedSize()
                .help("Save, apply or manage filters")
                Button { showSearchHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain)
                    .focused($focus, equals: .help)
                    .accessibilityLabel("Traffic search help")
                    .popover(isPresented: $showSearchHelp) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Search traffic").font(.headline)
                            Text("Combine text with filters, for example:")
                            Text("host:api.test method:GET status:400-499").monospaced()
                            Text("Use host, path, method, status, type or state. Filters use AND. Prefix - to exclude; quote values containing spaces.")
                        }.padding().frame(width: 360)
                    }
            }
            .font(.system(size: 12))
            if let active {
                HStack(spacing: 6) {
                    Text(active.name).lineLimit(1).help(active.name)
                    if model.savedFilterModified {
                        Text("Modified").foregroundStyle(Color(nsColor: WorkspaceStyle.warning))
                    }
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
            if let selectedID = model.selectedID, !model.rows.contains(where: { $0.id == selectedID }) {
                Text("Inspecting a request hidden by filters")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.queryError {
                Label("\(error). Showing the last valid query.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Color(nsColor: WorkspaceStyle.error))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Invalid traffic query. \(error). Showing the last valid query.")
            }
            if !model.effectiveQuery.terms.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.effectiveQuery.terms.enumerated()), id: \.offset) { index, term in
                            HStack(spacing: 4) {
                                Button {
                                    model.editQuery {
                                        guard $0.terms.indices.contains(index), $0.terms[index] == term else { return }
                                        $0.terms[index].excluded.toggle()
                                    }
                                } label: {
                                    Text("\(term.excluded ? "−" : "+") \(term.field.rawValue): \(term.value)")
                                }
                                .help("Toggle include/exclude")
                                .accessibilityLabel("\(term.excluded ? "Exclude" : "Include") \(term.field.rawValue) \(term.value). Toggle.")
                                .accessibilityValue(term.excluded ? "Excluded" : "Included")
                                Button {
                                    model.editQuery {
                                        guard $0.terms.indices.contains(index), $0.terms[index] == term else { return }
                                        $0.terms.remove(at: index)
                                    }
                                } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("Remove \(term.field.rawValue) filter")
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(nsColor: WorkspaceStyle.panel), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color(nsColor: WorkspaceStyle.divider)))
                            .help("\(term.excluded ? "Exclude" : "Include") \(term.field.rawValue): \(term.value)")
                        }
                    }.font(.caption)
                }
                .scrollIndicators(.hidden)
                .disabled(model.queryError != nil)
            }
        }
        .foregroundStyle(Color(nsColor: WorkspaceStyle.textSecondary))
        .tint(Color(nsColor: WorkspaceStyle.accent))
        .padding(.horizontal, 12).padding(.vertical, 8)
        // Match the traffic pane's width floor when measuring multiline diagnostics.
        .frame(minWidth: 320, alignment: .leading)
        .onChange(of: focusRequest) { _, _ in
            adding = false
            showSearchHelp = false
            focus = .search
        }
        .onChange(of: adding) { wasAdding, isAdding in
            if wasAdding && !isAdding && focus != .search { focus = .addFilter }
        }
        .onChange(of: showSearchHelp) { wasShowing, isShowing in
            if wasShowing && !isShowing && focus != .search { focus = .help }
        }
        .alert(renaming == nil ? "Save Filter" : "Rename Filter", isPresented: $naming) {
            TextField("Filter name", text: $filterName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let entry = renaming { model.renameFilter(entry, name: filterName) }
                else { model.saveFilter(name: filterName) }
            }.disabled(filterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(renaming == nil ? "Saves the query and current sidebar scope, not traffic or pins." : "Enter a new name.")
        }
    }

    private var builder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display Filter · AND").font(.headline)
            Picker("Field", selection: $field) {
                ForEach(TrafficQuery.Field.allCases) { Text($0.rawValue).tag($0) }
            }
            if field == .state {
                Picker("State", selection: $value) {
                    Text("Choose…").tag("")
                    ForEach(["pending", "complete", "error", "paused-request", "paused-response", "tls-passthrough"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
            } else {
                TextField(field == .status ? "100–599 or 400-499" : "Value", text: $value)
                    .focused($valueFocused)
                    .onSubmit { add() }
            }
            Toggle("Exclude matching traffic (display only)", isOn: $excluded)
            HStack {
                Spacer()
                Button("Add") { add() }.disabled(value.isEmpty)
            }
        }
        .padding().frame(width: 350)
        .onAppear { valueFocused = true }
        .onChange(of: field) { _, _ in value = "" }
    }

    private func add() {
        if model.addFilter(field: field, value: value, excluded: excluded) {
            adding = false
            value = ""
        }
    }

    private func scopeName(_ scope: SidebarFilter) -> String {
        switch scope {
        case .all: return "All Traffic"
        case .domain(let host): return host
        case .domainPath(let host, let path): return host + path
        case .client(let client): return "Client: " + client
        }
    }
}
