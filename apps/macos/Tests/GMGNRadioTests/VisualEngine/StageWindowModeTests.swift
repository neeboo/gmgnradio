import Testing
@testable import GMGNRadio

@Test
func stageWindowModeDescribesTheAvailableWindowAction() {
    #expect(StageWindowMode.windowed.buttonSymbolName == "arrow.up.left.and.arrow.down.right")
    #expect(StageWindowMode.windowed.accessibilityLabel == "进入全屏")
    #expect(StageWindowMode.fullScreen.buttonSymbolName == "arrow.down.right.and.arrow.up.left")
    #expect(StageWindowMode.fullScreen.accessibilityLabel == "退出全屏")
}
