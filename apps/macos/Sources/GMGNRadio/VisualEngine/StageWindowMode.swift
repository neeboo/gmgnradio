enum StageWindowMode: Equatable, Sendable {
    case windowed
    case fullScreen

    var buttonSymbolName: String {
        switch self {
        case .windowed:
            "arrow.up.left.and.arrow.down.right"
        case .fullScreen:
            "arrow.down.right.and.arrow.up.left"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .windowed:
            "进入全屏"
        case .fullScreen:
            "退出全屏"
        }
    }
}
