import Testing
@testable import GMGNRadio

@Test
func visualAudioInputPolicyKeepsMicrophoneCaptureOffByDefault() {
    #expect(!VisualAudioInputPolicy.usesMicrophone(environment: [:]))
    #expect(
        !VisualAudioInputPolicy.usesMicrophone(
            environment: ["GMGN_VISUAL_MIC_INPUT": "0"]
        )
    )
}

@Test
func visualAudioInputPolicyAllowsExplicitDevelopmentCapture() {
    #expect(
        VisualAudioInputPolicy.usesMicrophone(
            environment: ["GMGN_VISUAL_MIC_INPUT": "1"]
        )
    )
}
