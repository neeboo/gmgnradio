import AVFoundation
import Foundation

@MainActor
final class AudioDeviceMonitor {
    private let notificationCenter: NotificationCenter
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(
        engine: AVAudioEngine,
        notificationCenter: NotificationCenter = .default,
        onConfigurationChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.notificationCenter = notificationCenter
        observer = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onConfigurationChange()
            }
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }
}
