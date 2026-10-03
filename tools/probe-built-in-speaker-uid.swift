import Foundation
import CoreAudio

// Read-only device metadata. No input capture, playback or default-route writes.
var list = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var bytes: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &list, 0, nil, &bytes) == noErr,
      bytes > 0 else { exit(1) }
var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
let status = devices.withUnsafeMutableBytes {
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &list, 0, nil, &bytes, $0.baseAddress!)
}
guard status == noErr else { exit(1) }
var candidates: [String] = []
for device in devices {
    var transport = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &transport, 0, nil, &size, &value) == noErr,
          value == kAudioDeviceTransportTypeBuiltIn else { continue }
    var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var streamSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr,
          streamSize > 0 else { continue }
    var uidProperty = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid: CFString?, uidSize = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(device, &uidProperty, 0, nil, &uidSize, &uid) == noErr,
          let uid else { continue }
    let identifier = uid as String
    if identifier.lowercased().contains("speaker") { candidates.append(identifier) }
}
guard candidates.count == 1 else { fputs("expected one built-in output device\n", stderr); exit(1) }
let result = try JSONSerialization.data(withJSONObject: ["builtInSpeakerUID": candidates[0]], options: [.sortedKeys])
print(String(decoding: result, as: UTF8.self))
