import AppKit
import SwiftUI

/// Icon-over-title label used by every main toolbar action.
struct StackedToolbarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon
                .font(.system(size: 16, weight: .regular))
                .frame(width: 20, height: 20)
            configuration.title
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: 52, minHeight: 38)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct StackedToolbarButtonStyle: ButtonStyle {
    var tint: NSColor = WorkspaceStyle.textPrimary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let foreground = Color(nsColor: tint)
        configuration.label
            .labelStyle(StackedToolbarLabelStyle())
            .foregroundStyle(foreground)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(foreground.opacity(isEnabled ? (configuration.isPressed ? 0.18 : (hovering ? 0.10 : 0)) : 0))
            )
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering && isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StackedToolbarButton: View {
    let title: String
    let systemImage: String
    var tint: NSColor = WorkspaceStyle.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: systemImage) }
            .buttonStyle(StackedToolbarButtonStyle(tint: tint))
    }
}

struct CaptureToolbarButton: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        Button(action: model.toggle) {
            Label {
                Text(model.busy ? "Wait" : (model.running ? "Stop" : "Start"))
            } icon: {
                if model.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.running ? "stop.fill" : "play.fill")
                }
            }
        }
        .buttonStyle(StackedToolbarButtonStyle(tint: model.running ? WorkspaceStyle.error : WorkspaceStyle.accent))
        .disabled(model.busy)
        .help(model.busy ? "Please wait for the current operation to finish" :
              (model.running ? "Stop capture" : "Start capture"))
        .accessibilityLabel(model.running ? "Stop capture" : "Start capture")
        .accessibilityValue(model.busy ? "Please wait" : (model.running ? "Capturing" : "Stopped"))
    }
}
