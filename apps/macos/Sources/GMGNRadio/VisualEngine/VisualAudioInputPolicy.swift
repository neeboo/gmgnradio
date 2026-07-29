enum VisualAudioInputPolicy {
    static func usesMicrophone(environment: [String: String]) -> Bool {
        environment["GMGN_VISUAL_MIC_INPUT"] == "1"
    }
}
