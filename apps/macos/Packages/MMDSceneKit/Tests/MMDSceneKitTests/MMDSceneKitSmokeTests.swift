import Foundation
import SceneKit
import XCTest
@testable import MMDSceneKit

final class MMDSceneKitSmokeTests: XCTestCase {
    func testPhysicsBoneIndexTreatsPMXSentinelsAndOutOfRangeValuesAsUnbound() {
        XCTAssertNil(MMDPMXReader.physicsBoneIndex(rawValue: 0xFF, indexSize: 1, boneCount: 156))
        XCTAssertNil(MMDPMXReader.physicsBoneIndex(rawValue: 0xFFFF, indexSize: 2, boneCount: 156))
        XCTAssertNil(MMDPMXReader.physicsBoneIndex(rawValue: 0xFFFF_FFFF, indexSize: 4, boneCount: 156))
        XCTAssertNil(MMDPMXReader.physicsBoneIndex(rawValue: 156, indexSize: 2, boneCount: 156))
        XCTAssertNil(MMDPMXReader.physicsBoneIndex(rawValue: -1, indexSize: 4, boneCount: 156))
        XCTAssertEqual(MMDPMXReader.physicsBoneIndex(rawValue: 155, indexSize: 2, boneCount: 156), 155)
    }

    func testDetectsPMXData() {
        XCTAssertEqual(MMDFileType.detect(in: Data("PMX ".utf8)), .pmx)
    }

    func testDetectsVMDData() {
        XCTAssertEqual(
            MMDFileType.detect(in: Data("Vocaloid Motion Data 0002".utf8)),
            .vmd
        )
    }

    func testReaderDecodesLittleEndianScalarsWithoutEscapingPointers() {
        var bytes = Data([0x34, 0x12])
        bytes.append(contentsOf: [0x78, 0x56, 0x34, 0x12])
        bytes.append(contentsOf: [0xFE, 0xFF, 0xFF, 0xFF])
        bytes.append(contentsOf: [0x00, 0x00, 0x20, 0x40])

        let reader = MMDReader(data: bytes)

        XCTAssertEqual(MMDReader.toonTextures.count, 10)
        XCTAssertEqual(reader.getUnsignedShort(), 0x1234)
        XCTAssertEqual(reader.getUnsignedInt(), 0x1234_5678)
        XCTAssertEqual(reader.getInt(), -2)
        XCTAssertEqual(reader.getFloat(), 2.5)
        XCTAssertEqual(reader.getAvailableDataLength(), 0)
    }

    func testVMDTrackWithOnlyFrameZeroGetsFiniteTimeline() {
        let track = CAKeyframeAnimation(
            keyPath: "/左足.transform.quaternion"
        )
        track.values = [NSValue(scnVector4: SCNVector4(0, 0, 0, 1))]
        track.keyTimes = [0]

        MMDVMDReader.normalizeTimeline(track, fps: 30)

        XCTAssertEqual(track.keyTimes, [0])
        XCTAssertTrue(track.duration.isFinite)
        XCTAssertEqual(track.duration, 1.0 / 30.0, accuracy: 0.000_001)
    }

    func testVMDTrackWithMultipleFramesKeepsNormalizedTiming() {
        let track = CAKeyframeAnimation(
            keyPath: "/左膝.transform.quaternion"
        )
        track.values = [
            NSValue(scnVector4: SCNVector4(0, 0, 0, 1)),
            NSValue(scnVector4: SCNVector4(0, 0.2, 0, 0.98)),
            NSValue(scnVector4: SCNVector4(0, 0, 0, 1)),
        ]
        track.keyTimes = [0, 60, 120]

        MMDVMDReader.normalizeTimeline(track, fps: 30)

        XCTAssertEqual(track.keyTimes, [0, 0.5, 1])
        XCTAssertEqual(track.duration, 4, accuracy: 0.000_001)
        XCTAssertTrue(track.keyTimes?.allSatisfy(\.doubleValue.isFinite) == true)
    }

    func testRemovingPhysicsBehaviorFullyReturnsTheModelToAuthoredAnimation() {
        let scene = SCNScene()
        let model = MMDNode()
        let firstBone = SCNNode()
        let secondBone = SCNNode()
        firstBone.physicsBody = .dynamic()
        secondBone.physicsBody = .kinematic()
        model.addChildNode(firstBone)
        model.addChildNode(secondBone)

        let joint = SCNPhysicsBallSocketJoint(
            bodyA: firstBone.physicsBody!,
            anchorA: SCNVector3Zero,
            bodyB: secondBone.physicsBody!,
            anchorB: SCNVector3Zero
        )
        model.joints = [joint]
        scene.rootNode.addChildNode(model)
        model.addPhysicsBehavior(scene: scene)

        model.removePhysicsBehavior(scene: scene)

        XCTAssertTrue(scene.physicsWorld.allBehaviors.isEmpty)
        XCTAssertNil(firstBone.physicsBody)
        XCTAssertNil(secondBone.physicsBody)
        XCTAssertTrue(model.joints?.isEmpty == true)
    }
}
