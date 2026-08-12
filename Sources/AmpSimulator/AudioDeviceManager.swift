import AudioToolbox
import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Hashable {
  let id: AudioDeviceID
  let uid: String
  let name: String
  let inputChannelCount: Int
  let outputChannelCount: Int
}

enum AudioDeviceError: Error, LocalizedError {
  case propertyReadFailed(OSStatus)
  case setDeviceFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .propertyReadFailed(let status):
      return "オーディオデバイス情報の取得に失敗しました (OSStatus \(status))"
    case .setDeviceFailed(let status):
      return "オーディオデバイスの設定に失敗しました (OSStatus \(status))"
    }
  }
}

/// Thin wrapper over the Core Audio HAL for listing audio interfaces and
/// pointing an AVAudioEngine IO node's underlying audio unit at one of them.
enum AudioDeviceManager {
  /// All devices exposing at least one input or output channel.
  static func listDevices() -> [AudioDeviceInfo] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)

    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
    guard status == noErr, dataSize > 0 else { return [] }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)
    guard status == noErr else { return [] }

    return deviceIDs.compactMap(deviceInfo(for:))
  }

  private static func deviceInfo(for id: AudioDeviceID) -> AudioDeviceInfo? {
    guard let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return nil }
    let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? ""
    let inputChannels = channelCount(id, scope: kAudioObjectPropertyScopeInput)
    let outputChannels = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
    guard inputChannels > 0 || outputChannels > 0 else { return nil }
    return AudioDeviceInfo(id: id, uid: uid, name: name, inputChannelCount: inputChannels, outputChannelCount: outputChannels)
  }

  private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
    }
    guard status == noErr, let unmanaged = value else { return nil }
    return unmanaged.takeRetainedValue() as String
  }

  private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain)

    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
    guard status == noErr, size > 0 else { return 0 }

    let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { rawPointer.deallocate() }

    status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, rawPointer)
    guard status == noErr else { return 0 }

    let bufferListPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
    let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  /// Points an IO node's underlying audio unit at the given hardware device.
  /// Must be called while the engine is stopped, before `engine.start()`.
  static func setDevice(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit) throws {
    var mutableID = deviceID
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &mutableID,
      UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else {
      throw AudioDeviceError.setDeviceFailed(status)
    }
  }
}
