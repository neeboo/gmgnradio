import Testing
@testable import GMGNRadio

@Test
func vmdHumanoidMapRecognizesCommonJapaneseBoneAliases() {
    #expect(VMDHumanoidMap.bones(named: "センター").map(\.rawValue) == ["hips"])
    #expect(VMDHumanoidMap.bones(named: "上半身2").map(\.rawValue) == ["chest"])
    #expect(VMDHumanoidMap.bones(named: "左ひじ").map(\.rawValue) == ["leftLowerArm"])
    #expect(VMDHumanoidMap.bones(named: "右足首").map(\.rawValue) == ["rightFoot"])
    #expect(VMDHumanoidMap.bones(named: "両目").map(\.rawValue) == ["leftEye", "rightEye"])
    #expect(VMDHumanoidMap.bones(named: "左人指２").map(\.rawValue) == ["leftIndexIntermediate"])
}

@Test
func vmdHumanoidMapRecognizesCommonMorphAliases() {
    #expect(VMDHumanoidMap.expressionName(for: "あ") == "aa")
    #expect(VMDHumanoidMap.expressionName(for: "まばたき") == "blink")
    #expect(VMDHumanoidMap.expressionName(for: "ウィンク右") == "blinkRight")
    #expect(VMDHumanoidMap.expressionName(for: "笑い") == "happy")
    #expect(VMDHumanoidMap.expressionName(for: "独自表情") == "独自表情")
}
