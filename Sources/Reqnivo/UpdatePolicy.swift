import Foundation

enum UpdateNoUpdateReason: Equatable {
    case onLatestVersion
    case onNewerThanLatestVersion
    case systemIsTooOld
    case systemIsTooNew
    case hardwareDoesNotSupportARM64
    case unknown
}

struct UpdateReleaseInfo: Equatable {
    let versionString: String
    let displayVersionString: String
    let releaseNotes: String?
    let releaseNotesURL: URL?
    let criticalThresholdBuild: String?
    let isCompatible: Bool
    let compatibilityMessage: String?

    init(
        versionString: String,
        displayVersionString: String,
        releaseNotes: String? = nil,
        releaseNotesURL: URL? = nil,
        criticalThresholdBuild: String? = nil,
        isCompatible: Bool = true,
        compatibilityMessage: String? = nil
    ) {
        self.versionString = versionString
        self.displayVersionString = displayVersionString
        self.releaseNotes = releaseNotes
        self.releaseNotesURL = releaseNotesURL
        self.criticalThresholdBuild = criticalThresholdBuild
        self.isCompatible = isCompatible
        self.compatibilityMessage = compatibilityMessage
    }
}

enum UpdateAvailability: Equatable {
    case idle
    case checking
    case upToDate
    case optional(UpdateReleaseInfo)
    case required(UpdateReleaseInfo)
    case error(String)
    case unavailable(String)

    var isRequired: Bool {
        if case .required = self { return true }
        return false
    }

    var optionalRelease: UpdateReleaseInfo? {
        if case .optional(let info) = self { return info }
        return nil
    }

    var requiredRelease: UpdateReleaseInfo? {
        if case .required(let info) = self { return info }
        return nil
    }
}

struct UpdateFeedItemSnapshot: Equatable {
    let versionString: String
    let displayVersionString: String
    let releaseNotes: String?
    let releaseNotesURL: URL?
    let isCriticalUpdate: Bool
    let criticalThresholdBuild: String?
    let signingValidationSucceeded: Bool
    let isOSCompatible: Bool
    let isHardwareCompatible: Bool
    let compatibilityMessage: String?

    init(
        versionString: String,
        displayVersionString: String,
        releaseNotes: String? = nil,
        releaseNotesURL: URL? = nil,
        isCriticalUpdate: Bool = false,
        criticalThresholdBuild: String? = nil,
        signingValidationSucceeded: Bool = true,
        isOSCompatible: Bool = true,
        isHardwareCompatible: Bool = true,
        compatibilityMessage: String? = nil
    ) {
        self.versionString = versionString
        self.displayVersionString = displayVersionString
        self.releaseNotes = releaseNotes
        self.releaseNotesURL = releaseNotesURL
        self.isCriticalUpdate = isCriticalUpdate
        self.criticalThresholdBuild = criticalThresholdBuild
        self.signingValidationSucceeded = signingValidationSucceeded
        self.isOSCompatible = isOSCompatible
        self.isHardwareCompatible = isHardwareCompatible
        self.compatibilityMessage = compatibilityMessage
    }
}

struct CachedForcePolicy: Codable, Equatable {
    let minimumSupportedBuild: String
    let targetVersionString: String
    let targetDisplayVersionString: String
    let releaseNotes: String?
    let recordedAt: Date
}

struct UpdatePolicyStore {
    let root: URL
    var file: URL { root.appendingPathComponent("update-policy.json") }

    func load() throws -> CachedForcePolicy? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(CachedForcePolicy.self, from: Data(contentsOf: file))
    }

    func save(_ policy: CachedForcePolicy) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(policy)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }
}

struct UpdateEvaluationResult: Equatable {
    let availability: UpdateAvailability
    let policyToCache: CachedForcePolicy?
    let shouldClearCache: Bool
}

enum UpdatePolicyEvaluator {
    static func compareBuildVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftParts = lhs.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        let rightParts = rhs.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        let maxCount = max(leftParts.count, rightParts.count)
        for index in 0..<maxCount {
            let left = index < leftParts.count ? String(leftParts[index]) : "0"
            let right = index < rightParts.count ? String(rightParts[index]) : "0"
            if let lNum = Int(left), let rNum = Int(right) {
                if lNum < rNum { return .orderedAscending }
                if lNum > rNum { return .orderedDescending }
            } else {
                let result = left.compare(right, options: [.numeric])
                if result != .orderedSame { return result }
            }
        }
        return .orderedSame
    }

    static func evaluateCached(currentBuild: String, cached: CachedForcePolicy?) -> UpdateAvailability? {
        guard let cached else { return nil }
        guard compareBuildVersions(currentBuild, cached.minimumSupportedBuild) == .orderedAscending else {
            return nil
        }
        return .required(UpdateReleaseInfo(
            versionString: cached.targetVersionString,
            displayVersionString: cached.targetDisplayVersionString,
            releaseNotes: cached.releaseNotes,
            criticalThresholdBuild: cached.minimumSupportedBuild
        ))
    }

    static func evaluateFeed(
        currentBuild: String,
        item: UpdateFeedItemSnapshot?,
        cached: CachedForcePolicy?,
        noUpdateReason: UpdateNoUpdateReason? = nil,
        errorMessage: String? = nil
    ) -> UpdateEvaluationResult {
        let cacheSatisfied = cached.map { compareBuildVersions(currentBuild, $0.minimumSupportedBuild) != .orderedAscending } ?? false

        if let item, item.signingValidationSucceeded {
            let rawThreshold: String? = {
                if let explicit = item.criticalThresholdBuild?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
                    return explicit
                }
                return item.isCriticalUpdate ? item.versionString : nil
            }()

            if let rawThreshold, compareBuildVersions(currentBuild, rawThreshold) == .orderedAscending {
                let effectiveThreshold: String
                if let cached, compareBuildVersions(cached.minimumSupportedBuild, rawThreshold) == .orderedDescending {
                    effectiveThreshold = cached.minimumSupportedBuild
                } else {
                    effectiveThreshold = rawThreshold
                }

                let compatible = item.isOSCompatible && item.isHardwareCompatible &&
                    noUpdateReason != .systemIsTooOld &&
                    noUpdateReason != .systemIsTooNew &&
                    noUpdateReason != .hardwareDoesNotSupportARM64

                let compatMessage = item.compatibilityMessage ?? defaultCompatibilityMessage(for: noUpdateReason, item: item)

                let info = UpdateReleaseInfo(
                    versionString: item.versionString,
                    displayVersionString: item.displayVersionString,
                    releaseNotes: item.releaseNotes,
                    releaseNotesURL: item.releaseNotesURL,
                    criticalThresholdBuild: effectiveThreshold,
                    isCompatible: compatible,
                    compatibilityMessage: compatible ? nil : compatMessage
                )
                let policy = CachedForcePolicy(
                    minimumSupportedBuild: effectiveThreshold,
                    targetVersionString: item.versionString,
                    targetDisplayVersionString: item.displayVersionString,
                    releaseNotes: item.releaseNotes,
                    recordedAt: Date()
                )
                return UpdateEvaluationResult(availability: .required(info), policyToCache: policy, shouldClearCache: false)
            }
        }

        if let cached, !cacheSatisfied {
            let info = UpdateReleaseInfo(
                versionString: cached.targetVersionString,
                displayVersionString: cached.targetDisplayVersionString,
                releaseNotes: cached.releaseNotes,
                criticalThresholdBuild: cached.minimumSupportedBuild
            )
            return UpdateEvaluationResult(availability: .required(info), policyToCache: nil, shouldClearCache: false)
        }

        if let item, item.signingValidationSucceeded,
           item.isOSCompatible, item.isHardwareCompatible,
           compareBuildVersions(currentBuild, item.versionString) == .orderedAscending {
            let info = UpdateReleaseInfo(
                versionString: item.versionString,
                displayVersionString: item.displayVersionString,
                releaseNotes: item.releaseNotes,
                releaseNotesURL: item.releaseNotesURL,
                criticalThresholdBuild: item.criticalThresholdBuild
            )
            return UpdateEvaluationResult(availability: .optional(info), policyToCache: nil, shouldClearCache: cacheSatisfied)
        }

        if let errorMessage {
            return UpdateEvaluationResult(availability: .error(errorMessage), policyToCache: nil, shouldClearCache: cacheSatisfied)
        }

        return UpdateEvaluationResult(availability: .upToDate, policyToCache: nil, shouldClearCache: cacheSatisfied)
    }

    private static func defaultCompatibilityMessage(for reason: UpdateNoUpdateReason?, item: UpdateFeedItemSnapshot) -> String? {
        switch reason {
        case .systemIsTooOld:
            return "Reqnivo \(item.displayVersionString) is required, but this Mac's macOS version is too old for the available package. Upgrade macOS or contact your administrator."
        case .systemIsTooNew:
            return "Reqnivo \(item.displayVersionString) is required, but the available package does not support this macOS version. Contact your administrator."
        case .hardwareDoesNotSupportARM64:
            return "Reqnivo \(item.displayVersionString) is required, but this Mac's hardware architecture is not supported by the available package."
        default:
            if !item.isOSCompatible {
                return "Reqnivo \(item.displayVersionString) is required, but this Mac's macOS version is not supported by the available package. Upgrade macOS or contact your administrator."
            }
            if !item.isHardwareCompatible {
                return "Reqnivo \(item.displayVersionString) is required, but this Mac's hardware architecture is not supported by the available package."
            }
            return nil
        }
    }
}
