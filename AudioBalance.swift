import AudioToolbox
import CoreAudio
import Foundation

enum AudioBalanceError: LocalizedError {
    case invalidValue
    case noDefaultOutputDevice
    case propertyUnavailable
    case propertyNotSettable
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            return "Enter a number from 0 to 100."
        case .noDefaultOutputDevice:
            return "No default audio output device is available."
        case .propertyUnavailable:
            return "This output device does not support balance control."
        case .propertyNotSettable:
            return "This output device’s balance cannot be changed."
        case .coreAudio(let operation, let status):
            return "\(operation) failed (OSStatus \(status))."
        }
    }
}

enum AudioBalance {
    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioBalanceError.coreAudio(operation: operation, status: status)
        }
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        try check(status, operation: "Reading the default output device")

        guard deviceID != kAudioObjectUnknown else {
            throw AudioBalanceError.noDefaultOutputDevice
        }
        return deviceID
    }

    private static func virtualBalanceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func stereoPanAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStereoPan,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volumeAddress(channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
    }

    private static func stereoChannels(for deviceID: AudioDeviceID) throws -> (UInt32, UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            throw AudioBalanceError.propertyUnavailable
        }

        var channels: (UInt32, UInt32) = (0, 0)
        var dataSize = UInt32(MemoryLayout.size(ofValue: channels))
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &channels)
        try check(status, operation: "Reading stereo channels")
        return channels
    }

    private static func readVolume(channel: UInt32, deviceID: AudioDeviceID) throws -> Float32 {
        var address = volumeAddress(channel: channel)
        guard AudioObjectHasProperty(deviceID, &address) else {
            throw AudioBalanceError.propertyUnavailable
        }

        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &volume)
        try check(status, operation: "Reading channel volume")
        return volume
    }

    private static func writeVolume(_ volume: Float32, channel: UInt32, deviceID: AudioDeviceID) throws {
        var address = volumeAddress(channel: channel)
        guard AudioObjectHasProperty(deviceID, &address) else {
            throw AudioBalanceError.propertyUnavailable
        }

        var isSettable: DarwinBoolean = false
        try check(
            AudioObjectIsPropertySettable(deviceID, &address, &isSettable),
            operation: "Checking channel volume"
        )
        guard isSettable.boolValue else {
            throw AudioBalanceError.propertyNotSettable
        }

        var value = volume
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        )
        try check(status, operation: "Setting channel volume")
    }

    private static func readChannelBalance(deviceID: AudioDeviceID) throws -> Float32 {
        let channels = try stereoChannels(for: deviceID)
        let left = try readVolume(channel: channels.0, deviceID: deviceID)
        let right = try readVolume(channel: channels.1, deviceID: deviceID)

        if left == right {
            return 0.5
        }
        if left > right {
            return 0.5 * right / left
        }
        return 1 - (0.5 * left / right)
    }

    private static func writeChannelBalance(_ balance: Float32, deviceID: AudioDeviceID) throws {
        let channels = try stereoChannels(for: deviceID)
        let left = try readVolume(channel: channels.0, deviceID: deviceID)
        let right = try readVolume(channel: channels.1, deviceID: deviceID)
        let mainVolume = max(left, right)

        let leftVolume: Float32
        let rightVolume: Float32
        if balance <= 0.5 {
            leftVolume = mainVolume
            rightVolume = mainVolume * balance * 2
        } else {
            leftVolume = mainVolume * (1 - balance) * 2
            rightVolume = mainVolume
        }

        try writeVolume(leftVolume, channel: channels.0, deviceID: deviceID)
        try writeVolume(rightVolume, channel: channels.1, deviceID: deviceID)
    }

    static func readPercentage() throws -> Double {
        let deviceID = try defaultOutputDevice()
        var address = virtualBalanceAddress()
        if !AudioObjectHasProperty(deviceID, &address) {
            address = stereoPanAddress()
        }
        if !AudioObjectHasProperty(deviceID, &address) {
            return Double(try readChannelBalance(deviceID: deviceID)) * 100
        }

        var balance: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &balance)
        try check(status, operation: "Reading audio balance")
        return Double(balance) * 100
    }

    static func setPercentage(_ percentage: Double) throws {
        guard percentage.isFinite, (0 ... 100).contains(percentage) else {
            throw AudioBalanceError.invalidValue
        }

        let deviceID = try defaultOutputDevice()
        var address = virtualBalanceAddress()
        var balance = Float32(percentage / 100)
        if !AudioObjectHasProperty(deviceID, &address) {
            address = stereoPanAddress()
        }
        if !AudioObjectHasProperty(deviceID, &address) {
            try writeChannelBalance(balance, deviceID: deviceID)
            return
        }

        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        try check(settableStatus, operation: "Checking audio balance")
        guard isSettable.boolValue else {
            throw AudioBalanceError.propertyNotSettable
        }

        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &balance
        )
        try check(status, operation: "Setting audio balance")
    }
}

enum SystemVolume {
    /// Current output volume of the default device on a 0-100 scale, or nil
    /// when no volume source is available. Devices without a hardware volume
    /// scalar (the ones the volume keys still control) expose a virtual
    /// master volume instead, so several sources are tried in order.
    static func readPercentage() -> Int? {
        guard let deviceID = try? AudioBalance.defaultOutputDevice() else {
            return nil
        }
        if let main = readScalar(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) {
            return percentage(main)
        }
        if let virtual = readScalar(deviceID: deviceID, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain) {
            return percentage(virtual)
        }
        let channels = [
            readScalar(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar, element: 1),
            readScalar(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar, element: 2),
        ].compactMap { $0 }
        guard !channels.isEmpty else {
            return nil
        }
        return percentage(channels.reduce(0, +) / Float32(channels.count))
    }

    /// Set the default device's output volume (0-100) through CoreAudio.
    /// Returns false when neither the main volume scalar nor the virtual
    /// master volume is settable; per-channel writes are skipped because
    /// they would overwrite the balance.
    @discardableResult
    static func setPercentage(_ percentage: Int) -> Bool {
        guard let deviceID = try? AudioBalance.defaultOutputDevice() else {
            return false
        }
        let scalar = Float32(min(max(percentage, 0), 100)) / 100
        return writeScalar(scalar, deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar)
            || writeScalar(scalar, deviceID: deviceID, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    }

    private static func writeScalar(
        _ scalar: Float32,
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable: DarwinBoolean = false
        guard
            AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
            isSettable.boolValue
        else {
            return false
        }

        var value = scalar
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        )
        return status == noErr
    }

    private static func readScalar(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }
        return value
    }

    private static func percentage(_ scalar: Float32) -> Int {
        Int((Double(scalar) * 100).rounded())
    }
}
