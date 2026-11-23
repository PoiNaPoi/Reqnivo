import XCTest
@testable import Reqnivo

@MainActor
final class UpdatePolicyTests: XCTestCase {
    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reqnivo-update-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testBuildVersionComparisonHandlesMultiDigitBuildsNumerically() {
        XCTAssertEqual(UpdatePolicyEvaluator.compareBuildVersions("9", "10"), .orderedAscending)
        XCTAssertEqual(UpdatePolicyEvaluator.compareBuildVersions("10", "9"), .orderedDescending)
        XCTAssertEqual(UpdatePolicyEvaluator.compareBuildVersions("6", "6"), .orderedSame)
        XCTAssertEqual(UpdatePolicyEvaluator.compareBuildVersions("1.2", "1.10"), .orderedAscending)
    }

    func testLatestAndOlderFeedDoNotOfferUpdateOrDowngrade() {
        let sameBuild = UpdateFeedItemSnapshot(versionString: "6", displayVersionString: "0.0.6")
        let sameResult = UpdatePolicyEvaluator.evaluateFeed(currentBuild: "6", item: sameBuild, cached: nil)
        XCTAssertEqual(sameResult.availability, .upToDate)

        let olderBuild = UpdateFeedItemSnapshot(versionString: "5", displayVersionString: "0.0.5")
        let olderResult = UpdatePolicyEvaluator.evaluateFeed(currentBuild: "6", item: olderBuild, cached: nil)
        XCTAssertEqual(olderResult.availability, .upToDate)
    }

    func testOptionalUpdateOffersReleaseAndDoesNotBlock() {
        let item = UpdateFeedItemSnapshot(
            versionString: "7",
            displayVersionString: "0.0.7",
            releaseNotes: "Bug fixes",
            isCriticalUpdate: false
        )
        let result = UpdatePolicyEvaluator.evaluateFeed(currentBuild: "6", item: item, cached: nil)
        guard case .optional(let info) = result.availability else {
            return XCTFail("Expected optional update")
        }
        XCTAssertEqual(info.versionString, "7")
        XCTAssertEqual(info.displayVersionString, "0.0.7")
        XCTAssertEqual(info.releaseNotes, "Bug fixes")
        XCTAssertNil(result.policyToCache)
        XCTAssertFalse(result.availability.isRequired)
    }

    func testForceThresholdBlocksBelowThresholdAndAllowsAtThreshold() {
        let item = UpdateFeedItemSnapshot(
            versionString: "8",
            displayVersionString: "0.0.8",
            isCriticalUpdate: true,
            criticalThresholdBuild: "7"
        )

        let build6 = UpdatePolicyEvaluator.evaluateFeed(currentBuild: "6", item: item, cached: nil)
        XCTAssertTrue(build6.availability.isRequired)
        XCTAssertEqual(build6.policyToCache?.minimumSupportedBuild, "7")

        let build7 = UpdatePolicyEvaluator.evaluateFeed(currentBuild: "7", item: item, cached: nil)
        guard case .optional(let info7) = build7.availability else {
            return XCTFail("Expected build 7 to receive optional update to build 8")
        }
        XCTAssertEqual(info7.versionString, "8")
        XCTAssertFalse(build7.availability.isRequired)
    }

    func testUnsignedFeedIsRejectedAndDoesNotClearCachedForcePolicy() {
        let cached = CachedForcePolicy(
            minimumSupportedBuild: "7",
            targetVersionString: "7",
            targetDisplayVersionString: "0.0.7",
            releaseNotes: nil,
            recordedAt: Date()
        )
        let unsignedItem = UpdateFeedItemSnapshot(
            versionString: "8",
            displayVersionString: "0.0.8",
            isCriticalUpdate: true,
            criticalThresholdBuild: "8",
            signingValidationSucceeded: false
        )

        let withoutCache = UpdatePolicyEvaluator.evaluateFeed(
            currentBuild: "6",
            item: unsignedItem,
            cached: nil,
            errorMessage: "Signature invalid"
        )
        XCTAssertEqual(withoutCache.availability, .error("Signature invalid"))
        XCTAssertNil(withoutCache.policyToCache)

        let withCache = UpdatePolicyEvaluator.evaluateFeed(
            currentBuild: "6",
            item: unsignedItem,
            cached: cached,
            errorMessage: "Signature invalid"
        )
        XCTAssertTrue(withCache.availability.isRequired)
        XCTAssertEqual(withCache.availability.requiredRelease?.criticalThresholdBuild, "7")
        XCTAssertFalse(withCache.shouldClearCache)
    }

    func testOfflineBehaviorKeepsKnownForceAndReportsErrorForUnknownPolicy() {
        let unknownOffline = UpdatePolicyEvaluator.evaluateFeed(
            currentBuild: "6",
            item: nil,
            cached: nil,
            errorMessage: "Network offline"
        )
        XCTAssertEqual(unknownOffline.availability, .error("Network offline"))

        let cached = CachedForcePolicy(
            minimumSupportedBuild: "7",
            targetVersionString: "7",
            targetDisplayVersionString: "0.0.7",
            releaseNotes: "Security fix",
            recordedAt: Date()
        )
        let knownForceOffline = UpdatePolicyEvaluator.evaluateFeed(
            currentBuild: "6",
            item: nil,
            cached: cached,
            errorMessage: "Network offline"
        )
        XCTAssertTrue(knownForceOffline.availability.isRequired)
        XCTAssertEqual(knownForceOffline.availability.requiredRelease?.displayVersionString, "0.0.7")
    }

    func testIncompatibleOSForceUpdateSurfacesCompatibilityError() {
        let item = UpdateFeedItemSnapshot(
            versionString: "9",
            displayVersionString: "0.0.9",
            isCriticalUpdate: true,
            criticalThresholdBuild: "9",
            signingValidationSucceeded: true,
            isOSCompatible: false
        )
        let result = UpdatePolicyEvaluator.evaluateFeed(
            currentBuild: "6",
            item: item,
            cached: nil,
            noUpdateReason: .systemIsTooOld
        )
        guard case .required(let info) = result.availability else {
            return XCTFail("Expected required update")
        }
        XCTAssertFalse(info.isCompatible)
        XCTAssertNotNil(info.compatibilityMessage)
    }

    func testUpdatePolicyStoreRoundTripAndAtomicPermissions() throws {
        let root = makeTempRoot()
        let store = UpdatePolicyStore(root: root)
        XCTAssertNil(try store.load())

        let policy = CachedForcePolicy(
            minimumSupportedBuild: "7",
            targetVersionString: "7",
            targetDisplayVersionString: "0.0.7",
            releaseNotes: "Critical fix",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.save(policy)
        XCTAssertEqual(try store.load(), policy)

        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testDevExecutableDoesNotConfigureUpdaterAndCaptureBlockStopsAndRecoversProxy() async {
        let root = makeTempRoot()
        let store = UpdatePolicyStore(root: root)
        let controller = UpdateController(
            policyStore: store,
            currentDisplayVersion: "0.0.6",
            currentBuildVersion: "6"
        )
        XCTAssertFalse(controller.isUpdaterConfigured)

        var proxyChanges: [Bool] = []
        let model = CaptureModel(
            macProxyChange: { proxyChanges.append($0) },
            settingsStore: AppSettingsStore(root: root)
        )
        controller.attach(captureModel: model)

        // Simulate running capture with Mac proxy active, then enforce block.
        model.recoveryNeeded = false
        model.service = "Wi-Fi"
        model.running = true
        await model.setMacCaptureEnabled(true)
        await model.enforceUpdateBlock()

        XCTAssertFalse(model.running)
        XCTAssertEqual(proxyChanges, [true, false])
        let ready = await model.prepareForRelaunch()
        XCTAssertTrue(ready)
    }

    func testCachedForcePolicyBlocksStartupWithoutStartingEngine() async throws {
        let root = makeTempRoot()
        let store = UpdatePolicyStore(root: root)
        try store.save(CachedForcePolicy(
            minimumSupportedBuild: "999",
            targetVersionString: "999",
            targetDisplayVersionString: "9.9.9",
            releaseNotes: "Required",
            recordedAt: Date()
        ))

        let controller = UpdateController(
            policyStore: store,
            currentDisplayVersion: "0.0.6",
            currentBuildVersion: "6"
        )
        XCTAssertTrue(controller.isBlocked)

        let model = CaptureModel(
            macProxyChange: { _ in },
            settingsStore: AppSettingsStore(root: root)
        )
        await controller.checkOnLaunch(captureModel: model)
        XCTAssertFalse(model.running)
        XCTAssertTrue(controller.isBlocked)

        await model.start()
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.error, "Update required before starting a new capture")
    }
}
