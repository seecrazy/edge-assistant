import XCTest
@testable import EdgeAssistantCore

private final class FixedThermalClock: ThermalClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storage = thermalEpoch

    var instant: ContinuousClock.Instant {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func now() -> ContinuousClock.Instant {
        instant
    }
}

private let thermalEpoch = ContinuousClock.now

final class ThermalControllerTests: XCTestCase {
    private let hold = Duration.seconds(60)

    func testDegradePlanShortensChatReplyLimit() {
        XCTAssertNil(ThermalMapper.degradePlan(for: .normal).chatReplyCharLimit)
        XCTAssertEqual(ThermalMapper.degradePlan(for: .warm).chatReplyCharLimit, 120)
        XCTAssertEqual(ThermalMapper.degradePlan(for: .hot).chatReplyCharLimit, 90)
        XCTAssertTrue(ThermalMapper.degradePlan(for: .critical).pauseInference)
    }

    func testEscalationIsImmediateAndRecoveryWaitsForHold() {
        let clock = FixedThermalClock()
        var controller = ThermalHysteresisController(recoveryHold: hold, clock: clock)

        XCTAssertEqual(controller.update(.serious), .hot)
        XCTAssertTrue(controller.plan.disableVisionPipeline)

        clock.instant = thermalEpoch.advanced(by: .seconds(30))
        XCTAssertEqual(controller.update(.nominal), .hot)

        clock.instant = thermalEpoch.advanced(by: .seconds(60))
        XCTAssertEqual(controller.update(.nominal), .warm)

        XCTAssertEqual(controller.update(.serious), .hot)
    }

    func testCriticalRecoversOneLevelPerHoldInterval() {
        let clock = FixedThermalClock()
        var controller = ThermalHysteresisController(recoveryHold: hold, clock: clock)
        XCTAssertEqual(controller.update(.critical), .critical)

        clock.instant = thermalEpoch.advanced(by: .seconds(61))
        XCTAssertEqual(controller.update(.nominal), .hot)
        XCTAssertEqual(controller.update(.nominal), .hot)

        clock.instant = thermalEpoch.advanced(by: .seconds(122))
        XCTAssertEqual(controller.update(.nominal), .warm)

        clock.instant = thermalEpoch.advanced(by: .seconds(183))
        XCTAssertEqual(controller.update(.nominal), .normal)
        XCTAssertFalse(controller.plan.pauseInference)
    }

    func testEscalationDuringRecoveryResetsHoldTimer() {
        let clock = FixedThermalClock()
        var controller = ThermalHysteresisController(recoveryHold: hold, clock: clock)
        XCTAssertEqual(controller.update(.critical), .critical)

        clock.instant = thermalEpoch.advanced(by: .seconds(61))
        XCTAssertEqual(controller.update(.nominal), .hot)

        // 只等待 30s 后再次升级；升级重置计时，之后 30s 不能恢复。
        clock.instant = thermalEpoch.advanced(by: .seconds(91))
        XCTAssertEqual(controller.update(.critical), .critical)
        clock.instant = thermalEpoch.advanced(by: .seconds(121))
        XCTAssertEqual(controller.update(.nominal), .critical)
        clock.instant = thermalEpoch.advanced(by: .seconds(152))
        XCTAssertEqual(controller.update(.nominal), .hot)
    }
}
