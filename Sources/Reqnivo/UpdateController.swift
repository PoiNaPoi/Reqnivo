import AppKit
import Foundation
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var availability: UpdateAvailability = .idle
    @Published private(set) var isChecking = false
    @Published private(set) var optionalDismissed = false
    @Published private(set) var lastActionError: String?
    @Published private(set) var cacheWarning: String?
    @Published private(set) var proxyRecoveryFailed = false
    @Published private(set) var canCheckForUpdates = false

    let currentDisplayVersion: String
    let currentBuildVersion: String
    let isUpdaterConfigured: Bool

    private let policyStore: UpdatePolicyStore
    private let startupTimeout: Duration
    private weak var captureModel: CaptureModel?
    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?
    private var startupContinuation: CheckedContinuation<Void, Never>?
    private var didStartOnLaunch = false
    private var pendingInstallHandler: (() -> Void)?

    var isBlocked: Bool {
        availability.isRequired
    }

    var shouldShowOptionalBanner: Bool {
        !isBlocked && !optionalDismissed && availability.optionalRelease != nil
    }

    var shouldShowErrorBanner: Bool {
        if case .error = availability, !isBlocked { return true }
        return false
    }

    init(
        policyStore: UpdatePolicyStore? = nil,
        bundle: Bundle = .main,
        currentDisplayVersion: String? = nil,
        currentBuildVersion: String? = nil,
        startupTimeout: Duration = .seconds(10)
    ) {
        self.policyStore = policyStore ?? UpdatePolicyStore(root: RuntimePaths().root)
        self.startupTimeout = startupTimeout

        let info = bundle.infoDictionary ?? [:]
        self.currentDisplayVersion = currentDisplayVersion ?? (info["CFBundleShortVersionString"] as? String) ?? "dev"
        self.currentBuildVersion = currentBuildVersion ?? (info["CFBundleVersion"] as? String) ?? "0"

        let isAppBundle = bundle.bundleURL.pathExtension == "app"
        let feedURL = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.isUpdaterConfigured = isAppBundle && !feedURL.isEmpty && !publicKey.isEmpty

        super.init()
        loadCachedForcePolicy()
    }

    func attach(captureModel: CaptureModel) {
        self.captureModel = captureModel
        captureModel.isUpdateBlocked = { [weak self] in
            self?.isBlocked ?? false
        }
    }

    func checkOnLaunch(captureModel: CaptureModel) async {
        attach(captureModel: captureModel)
        guard !didStartOnLaunch else { return }
        didStartOnLaunch = true

        loadCachedForcePolicy()
        if isBlocked {
            await captureModel.enforceUpdateBlock()
            return
        }

        guard isUpdaterConfigured else {
            availability = .unavailable("Automatic updates are unavailable in development builds.")
            await captureModel.startOnLaunch()
            return
        }

        ensureUpdaterStarted()
        await performStartupProbe()

        if isBlocked {
            await captureModel.enforceUpdateBlock()
        } else {
            await captureModel.startOnLaunch()
        }
    }

    func checkForUpdatesManually() {
        lastActionError = nil
        proxyRecoveryFailed = false
        guard isUpdaterConfigured else {
            availability = .unavailable("Updates are unavailable in development builds.")
            lastActionError = "Updates are unavailable in development builds."
            return
        }
        ensureUpdaterStarted()
        optionalDismissed = false
        isChecking = true
        updaterController?.checkForUpdates(nil)
    }

    func retryCheck() {
        lastActionError = nil
        proxyRecoveryFailed = false
        guard isUpdaterConfigured else {
            availability = .unavailable("Updates are unavailable in development builds.")
            return
        }
        ensureUpdaterStarted()
        if isBlocked {
            updaterController?.checkForUpdates(nil)
        } else {
            Task {
                await performStartupProbe()
            }
        }
    }

    func installAvailableUpdate() {
        lastActionError = nil
        proxyRecoveryFailed = false
        guard isUpdaterConfigured else { return }
        ensureUpdaterStarted()
        updaterController?.checkForUpdates(nil)
    }

    func deferOptionalUpdate() {
        optionalDismissed = true
    }

    func retryProxyRecoveryForInstall() async {
        guard let captureModel else { return }
        lastActionError = nil
        let recovered = await captureModel.prepareForRelaunch()
        proxyRecoveryFailed = !recovered
        if recovered, let handler = pendingInstallHandler {
            pendingInstallHandler = nil
            handler()
        } else if !recovered {
            lastActionError = captureModel.error ?? "Mac proxy recovery failed. Review System Settings → Network → Proxies and retry."
        }
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    // MARK: - Private

    private func loadCachedForcePolicy() {
        do {
            let cached = try policyStore.load()
            if let blocked = UpdatePolicyEvaluator.evaluateCached(currentBuild: currentBuildVersion, cached: cached) {
                availability = blocked
            }
        } catch {
            cacheWarning = "Could not read cached update policy: \(error.localizedDescription)"
        }
    }

    private func ensureUpdaterStarted() {
        guard updaterController == nil, isUpdaterConfigured else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false

        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        updaterController = controller
    }

    private func performStartupProbe() async {
        guard let updater = updaterController?.updater else { return }
        if !isBlocked {
            availability = .checking
        }
        isChecking = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startupContinuation = continuation
            updater.checkForUpdateInformation()

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.startupTimeout ?? .seconds(10))
                guard let self, let pending = self.startupContinuation else { return }
                self.startupContinuation = nil
                self.isChecking = false
                if !self.isBlocked {
                    self.availability = .error("Update check timed out. You can continue working and retry later.")
                }
                pending.resume()
            }
        }
    }

    private func resumeStartupProbeIfWaiting() {
        guard let pending = startupContinuation else { return }
        startupContinuation = nil
        pending.resume()
    }

    private func snapshot(from item: SUAppcastItem, noUpdateReason: UpdateNoUpdateReason? = nil) -> UpdateFeedItemSnapshot {
        var threshold: String?
        if let criticalDict = item.propertiesDictionary["sparkle:criticalUpdate"] as? [String: Any],
           let version = criticalDict["sparkle:version"] as? String,
           !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            threshold = version
        }
        let signingValid = item.signingValidationStatus == .succeeded
        return UpdateFeedItemSnapshot(
            versionString: item.versionString,
            displayVersionString: item.displayVersionString,
            releaseNotes: item.itemDescription,
            releaseNotesURL: item.releaseNotesURL,
            isCriticalUpdate: item.isCriticalUpdate,
            criticalThresholdBuild: threshold,
            signingValidationSucceeded: signingValid,
            isOSCompatible: item.minimumOperatingSystemVersionIsOK && item.maximumOperatingSystemVersionIsOK,
            isHardwareCompatible: item.arm64HardwareRequirementIsOK
        )
    }

    private func applyEvaluation(item: UpdateFeedItemSnapshot?, noUpdateReason: UpdateNoUpdateReason? = nil, errorMessage: String? = nil) {
        let cached = try? policyStore.load()
        let result = UpdatePolicyEvaluator.evaluateFeed(
            currentBuild: currentBuildVersion,
            item: item,
            cached: cached,
            noUpdateReason: noUpdateReason,
            errorMessage: errorMessage
        )

        if let policy = result.policyToCache {
            do {
                try policyStore.save(policy)
                cacheWarning = nil
            } catch {
                cacheWarning = "Could not save update policy cache: \(error.localizedDescription)"
            }
        } else if result.shouldClearCache {
            try? policyStore.clear()
        }

        availability = result.availability
        if result.availability.isRequired {
            optionalDismissed = false
            Task { [weak self] in
                await self?.captureModel?.enforceUpdateBlock()
            }
        }
    }

    private func prepareForInstallAndRelaunch() async {
        guard let captureModel else {
            let handler = pendingInstallHandler
            pendingInstallHandler = nil
            handler?()
            return
        }
        let ready = await captureModel.prepareForRelaunch()
        if ready {
            proxyRecoveryFailed = false
            let handler = pendingInstallHandler
            pendingInstallHandler = nil
            handler?()
        } else {
            proxyRecoveryFailed = true
            lastActionError = captureModel.error ?? "Mac proxy recovery failed. Retry recovery before installing the update."
        }
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        isChecking = false
        lastActionError = nil
        let snap = snapshot(from: item)
        applyEvaluation(item: snap)
        resumeStartupProbeIfWaiting()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        isChecking = false
        let nsError = error as NSError
        let reasonRaw = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        let reason: UpdateNoUpdateReason = {
            switch reasonRaw {
            case Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue): return .onLatestVersion
            case Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue): return .onNewerThanLatestVersion
            case Int(SPUNoUpdateFoundReason.systemIsTooOld.rawValue): return .systemIsTooOld
            case Int(SPUNoUpdateFoundReason.systemIsTooNew.rawValue): return .systemIsTooNew
            case Int(SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue): return .hardwareDoesNotSupportARM64
            default: return .unknown
            }
        }()
        let latestItem = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let snap = latestItem.map { snapshot(from: $0, noUpdateReason: reason) }
        applyEvaluation(item: snap, noUpdateReason: reason)
        resumeStartupProbeIfWaiting()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        isChecking = false
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.noUpdateError.rawValue) {
            resumeStartupProbeIfWaiting()
            return
        }
        if nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.installationCanceledError.rawValue) {
            lastActionError = "Update installation was cancelled."
            resumeStartupProbeIfWaiting()
            return
        }
        lastActionError = error.localizedDescription
        applyEvaluation(item: nil, errorMessage: error.localizedDescription)
        resumeStartupProbeIfWaiting()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        isChecking = false
        resumeStartupProbeIfWaiting()
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        isChecking = false
        lastActionError = "Update download was cancelled."
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingInstallHandler = installHandler
        Task { @MainActor [weak self] in
            await self?.prepareForInstallAndRelaunch()
        }
        return true
    }
}
