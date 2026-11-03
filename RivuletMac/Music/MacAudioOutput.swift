// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CoreAudio
import Foundation
import OSLog

/// What the Sample Rate setting asks of the sound output.
nonisolated enum MusicOutputRate {
    static let key = "musicOutputSampleRate"
    static let dontChange = 0
    static let matchTrack = 1
    static let fixedChoices = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    /// The stored choice, or Don't Change when it is not one of the choices.
    static var setting: Int {
        let stored = UserDefaults.standard.object(forKey: key) as? Int ?? dontChange
        return stored == dontChange || stored == matchTrack || fixedChoices.contains(stored) ? stored : dontChange
    }

    static func label(_ hz: Int) -> String {
        String(format: "%g kHz", Double(hz) / 1000)
    }

    /// The rate to set, or nil to leave the output alone.
    static func target(setting: Int, trackRate: Int?, isTranscode: Bool, available: [AudioValueRange]) -> Int? {
        guard setting != dontChange, !isTranscode else { return nil }
        let rates = Set(available.flatMap { range -> [Int] in
            // A range with equal ends is one rate; a wider one offers any rate between.
            if range.mMinimum == range.mMaximum { return [Int(range.mMinimum.rounded())] }
            return (fixedChoices + [Int(range.mMinimum.rounded()), Int(range.mMaximum.rounded())])
                .filter { Double($0) >= range.mMinimum && Double($0) <= range.mMaximum }
        })
        if setting != matchTrack { return rates.contains(setting) ? setting : nil }
        guard let trackRate, trackRate > 0 else { return nil }
        if rates.contains(trackRate) { return trackRate }
        for base in [44_100, 48_000] where trackRate % base == 0 {
            return rates.filter { $0 % base == 0 && $0 <= trackRate }.max()
        }
        return nil
    }
}

/// Sets the default sound output's rate to suit the music, and puts it back.
@MainActor
final class MacAudioOutput {
    private static let log = Logger(subsystem: "com.rivulet.app", category: "Music")

    /// Device UID to the rate it had before the first change.
    private var original: [String: Double] = [:]
    private var unsettable = Set<String>()
    private var lastRequest: MacMusicSource?

    init() {
        Self.listen { [weak self] in self?.defaultOutputChanged() }
    }

    func apply(for source: MacMusicSource) async {
        lastRequest = source
        let trackRate = source.track.audioStream?.samplingRate
        guard let device = CoreAudioDevice.defaultOutput(), CoreAudioDevice.isSwitchable(device),
              let uid = CoreAudioDevice.uid(device),
              let target = MusicOutputRate.target(
                setting: MusicOutputRate.setting, trackRate: trackRate, isTranscode: source.isTranscode,
                available: CoreAudioDevice.availableRates(device)),
              !unsettable.contains(uid), CoreAudioDevice.isRateSettable(device) else {
            restore()
            return
        }
        let goal = Double(target)
        guard CoreAudioDevice.nominalRate(device) != goal else { return }
        if original[uid] == nil, let rate = CoreAudioDevice.nominalRate(device) { original[uid] = rate }
        let status = CoreAudioDevice.setNominalRate(device, goal)
        guard status == 0 else {
            Self.log.error("Sample rate change failed, status \(status)")
            unsettable.insert(uid)
            return
        }
        for _ in 0..<25 {
            if CoreAudioDevice.nominalRate(device) == goal { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Puts back every rate this changed.
    func restore() {
        for (uid, rate) in original {
            if let device = CoreAudioDevice.device(uid: uid) { _ = CoreAudioDevice.setNominalRate(device, rate) }
        }
        original = [:]
        lastRequest = nil
    }

    /// The fixed rates the current output offers; none when it cannot be switched.
    static func supportedRates() -> [Int] {
        guard let device = CoreAudioDevice.defaultOutput(), CoreAudioDevice.isSwitchable(device),
              CoreAudioDevice.isRateSettable(device) else { return [] }
        return MusicOutputRate.fixedChoices.filter {
            MusicOutputRate.target(setting: $0, trackRate: nil, isTranscode: false,
                                   available: CoreAudioDevice.availableRates(device)) != nil
        }
    }

    private func defaultOutputChanged() {
        let kept = lastRequest
        restore()
        if let kept { Task { await apply(for: kept) } }
    }

    // Nonisolated on purpose: Core Audio calls the block on the queue given, and a
    // closure built in a main-actor method would trap on that isolation check.
    private nonisolated static func listen(_ handler: @escaping @MainActor @Sendable () -> Void) {
        var address = CoreAudioDevice.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}

private nonisolated enum CoreAudioDevice {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutput() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == 0 && device != kAudioObjectUnknown ? device : nil
    }

    static func uid(_ device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == 0 ? value?.takeRetainedValue() as String? : nil
    }

    static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == 0 && device != kAudioObjectUnknown ? device : nil
    }

    static func transportType(_ device: AudioObjectID) -> UInt32? {
        var address = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == 0 ? value : nil
    }

    static func nominalRate(_ device: AudioObjectID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == 0 ? value : nil
    }

    static func availableRates(_ device: AudioObjectID) -> [AudioValueRange] {
        var address = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == 0 else { return [] }
        return ranges
    }

    static func isRateSettable(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == 0 && settable.boolValue
    }

    static func setNominalRate(_ device: AudioObjectID, _ rate: Double) -> OSStatus {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }

    /// Wired outputs only; Bluetooth, AirPlay, aggregate and virtual devices keep their own rate.
    static func isSwitchable(_ device: AudioObjectID) -> Bool {
        guard let type = transportType(device) else { return false }
        let wired = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
                     kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
                     kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort]
        return wired.contains(type) && availableRates(device).count > 0
    }
}
