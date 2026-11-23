import AppKit
import SwiftUI

struct UpdateBlockingView: View {
    @ObservedObject var updateController: UpdateController
    @ObservedObject var captureModel: CaptureModel

    private var releaseInfo: UpdateReleaseInfo? {
        updateController.availability.requiredRelease
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            Image(systemName: releaseInfo?.isCompatible == false ? "exclamationmark.triangle.fill" : "arrow.down.app.fill")
                .font(.system(size: 48))
                .foregroundStyle(releaseInfo?.isCompatible == false ? Color.orange : Color.accentColor)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Update Required")
                    .font(.title.bold())
                Text("This version of Reqnivo is below the minimum supported build and must be updated before continuing.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            if let info = releaseInfo {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Current Version:")
                                .foregroundStyle(.secondary)
                            Text("\(updateController.currentDisplayVersion) (Build \(updateController.currentBuildVersion))")
                                .monospacedDigit()
                            Spacer()
                        }
                        HStack {
                            Text("Required Version:")
                                .foregroundStyle(.secondary)
                            Text("\(info.displayVersionString) (Build \(info.versionString))")
                                .bold()
                                .monospacedDigit()
                            Spacer()
                        }
                        if let notes = info.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                            Divider()
                            Text("Release Notes")
                                .font(.headline)
                            ScrollView {
                                Text(notes)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 150)
                        } else if let notesURL = info.releaseNotesURL {
                            Link("View Release Notes", destination: notesURL)
                                .font(.callout)
                        }
                    }
                    .padding(6)
                }
                .frame(maxWidth: 540)

                if !info.isCompatible, let message = info.compatibilityMessage {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 520, alignment: .leading)
                        .padding(10)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if let error = updateController.lastActionError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(10)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if let warning = updateController.cacheWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
            }

            Text("Installing the update will restart Reqnivo. Your settings, rules, certificates, and proxy recovery records will be preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button("Quit Reqnivo", role: .destructive) {
                    updateController.quitApplication()
                }
                .accessibilityLabel("Quit Reqnivo")

                if captureModel.recoveryNeeded {
                    Button(updateController.proxyRecoveryFailed ? "Retry Proxy Recovery" : "Restore Mac Proxy") {
                        Task {
                            if updateController.proxyRecoveryFailed {
                                await updateController.retryProxyRecoveryForInstall()
                            } else {
                                captureModel.restoreProxy()
                            }
                        }
                    }
                    .disabled(captureModel.busy)
                }

                if releaseInfo?.isCompatible != false {
                    Button("Retry") {
                        updateController.retryCheck()
                    }
                    .disabled(updateController.isChecking)

                    Button("Update Now") {
                        updateController.installAvailableUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!updateController.isUpdaterConfigured)
                }
            }

            Spacer(minLength: 12)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct UpdateBlockedSecondaryView: View {
    @ObservedObject var updateController: UpdateController

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Update Required")
                .font(.title3.bold())
            Text("This window is locked until Reqnivo is updated to the required version.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Quit Reqnivo") {
                    updateController.quitApplication()
                }
                if updateController.availability.requiredRelease?.isCompatible != false && updateController.isUpdaterConfigured {
                    Button("Update Now") {
                        updateController.installAvailableUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 360, minHeight: 220)
    }
}

struct UpdateNotificationBanner: View {
    @ObservedObject var updateController: UpdateController
    @State private var showReleaseNotes = false
    @State private var dismissedError = false

    var body: some View {
        if updateController.shouldShowOptionalBanner, let info = updateController.availability.optionalRelease {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reqnivo \(info.displayVersionString) (Build \(info.versionString)) is available")
                        .font(.callout.weight(.semibold))
                    Text("You are currently on \(updateController.currentDisplayVersion) (Build \(updateController.currentBuildVersion)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let notes = info.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Button("Release Notes") {
                        showReleaseNotes = true
                    }
                    .popover(isPresented: $showReleaseNotes) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Reqnivo \(info.displayVersionString)")
                                .font(.headline)
                            ScrollView {
                                Text(notes)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(16)
                        .frame(width: 380, height: 240)
                    }
                }
                Button("Later") {
                    updateController.deferOptionalUpdate()
                }
                Button("Update") {
                    updateController.installAvailableUpdate()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        } else if !dismissedError, case .error(let message) = updateController.availability {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Could not check for updates: \(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Retry") {
                    updateController.retryCheck()
                }
                .controlSize(.small)
                Button {
                    dismissedError = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss update check error")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
