import XCTest
@testable import EdgeAssistantCore

final class DeviceAndPipelineTests: XCTestCase {
    func testClassifyDeviceMatchesJSPrototype() throws {
        XCTAssertEqual(try DeviceProfile(ramGB: 12, hasNPU: true).tier, .flagship)
        XCTAssertEqual(try DeviceProfile(ramGB: 16, hasNPU: false).tier, .mainstream)
        XCTAssertEqual(try DeviceProfile(ramGB: 8, hasNPU: false).tier, .mainstream)
        XCTAssertEqual(try DeviceProfile(ramGB: 6, hasNPU: true).tier, .entry)
    }

    func testRejectsInvalidDeviceInput() {
        XCTAssertThrowsError(try DeviceProfile(ramGB: 0, hasNPU: true))
    }

    func testVoicePipelineMeetsTargetForAllTiers() {
        for tier in ModelTier.allCases {
            let plan = PipelinePlanner.plan(mode: .voice, tier: tier)
            XCTAssertTrue(plan.meetsTarget, "\(tier) should stay within 1200ms")
        }
    }

    func testVideoMayRequireDegradation() {
        XCTAssertTrue(PipelinePlanner.plan(mode: .video, tier: .flagship).meetsTarget)
        XCTAssertFalse(PipelinePlanner.plan(mode: .video, tier: .entry).meetsTarget)
    }

    func testStateMachineTransitionsMatchJSPrototype() {
        var sm = ConversationStateMachine()
        XCTAssertEqual(sm.send(.startCall), .listening)
        XCTAssertEqual(sm.send(.userStop), .thinking)
        XCTAssertEqual(sm.send(.firstToken), .speaking)
        XCTAssertEqual(sm.send(.ttsDone), .listening)
        XCTAssertEqual(sm.send(.stopCall), .idle)
        XCTAssertEqual(sm.send(.firstToken), nil) // idle 不接受 firstToken
        XCTAssertEqual(sm.state, .idle)
    }

    func testInterruptActionAlwaysCancelsInferenceWhenActive() {
        let speaking = Interrupt.action(for: .speaking)
        XCTAssertEqual(speaking, InterruptAction(stopTts: true, dropQueuedAudio: true, cancelInference: true, nextState: .listening))
        let thinking = Interrupt.action(for: .thinking)
        XCTAssertEqual(thinking, InterruptAction(stopTts: false, dropQueuedAudio: false, cancelInference: true, nextState: .listening))
        XCTAssertNil(Interrupt.action(for: .idle))
    }

    func testThermalMappingMatchesDesign() {
        XCTAssertEqual(ThermalMapper.level(for: .nominal), .normal)
        XCTAssertEqual(ThermalMapper.level(for: .fair), .warm)
        XCTAssertEqual(ThermalMapper.level(for: .serious), .hot)
        XCTAssertEqual(ThermalMapper.level(for: .critical), .critical)

        XCTAssertTrue(ThermalMapper.degradePlan(for: .critical).pauseInference)
        XCTAssertTrue(ThermalMapper.degradePlan(for: .hot).disableVisionPipeline)
        XCTAssertFalse(ThermalMapper.degradePlan(for: .warm).disableVisionPipeline)
        XCTAssertFalse(ThermalMapper.degradePlan(for: .normal).shortenReplyLimit)
    }
}
