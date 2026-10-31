import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let what: String
    public let status: OSStatus

    public var description: String {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let fourCC = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
            ? " '\(String(decoding: bytes, as: UTF8.self))'" : ""
        return "\(what) failed: \(status)\(fourCC)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(what: what(), status: status) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
    var addr = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "get '\(selector)'")
    return value
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "get string '\(selector)'")
    return value?.takeRetainedValue() as String? ?? ""
}

func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 qualifier: [UInt8] = []) throws -> [T] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &addr, UInt32(qualifier.count), qualifier, &size), "size '\(selector)'")
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }
    return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
        try check(AudioObjectGetPropertyData(object, &addr, UInt32(qualifier.count), qualifier, &size, buffer.baseAddress!),
                  "get array '\(selector)'")
        initialized = Int(size) / MemoryLayout<T>.stride
    }
}

public struct AudioDevice: CustomStringConvertible {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let inputStreams: Int
    public let sampleRate: Double

    public var description: String {
        "[\(id)] \(name) uid=\(uid) in=\(inputChannels)ch/\(inputStreams)st out=\(outputChannels)ch sr=\(Int(sampleRate))"
    }

    init(id: AudioObjectID) throws {
        self.id = id
        uid = try getString(id, kAudioDevicePropertyDeviceUID)
        name = try getString(id, kAudioObjectPropertyName)
        inputChannels = try Self.channelCount(id, scope: kAudioObjectPropertyScopeInput)
        outputChannels = try Self.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        inputStreams = (try getArray(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) as [AudioObjectID]).count
        sampleRate = try getValue(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), "stream config size")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw), "stream config")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func all() throws -> [AudioDevice] {
        let ids: [AudioObjectID] = try getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return ids.compactMap { try? AudioDevice(id: $0) }
    }

    /// Sample rates the device can run at (each range's bounds; interfaces list discrete rates).
    public func availableSampleRates() -> [Double] {
        let ranges: [AudioValueRange] = (try? getArray(id, kAudioDevicePropertyAvailableNominalSampleRates)) ?? []
        return Array(Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] })).sorted()
    }

    public func setSampleRate(_ rate: Double) throws {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        try check(AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value),
                  "set sample rate \(rate)")
    }

    public static func defaultOutput() throws -> AudioDevice {
        try AudioDevice(id: getValue(AudioObjectID(kAudioObjectSystemObject),
                                     kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)))
    }
}

/// Keeps a Core Audio property listener alive; removes it when released.
public final class AudioPropertyObserver {
    private let object: AudioObjectID
    private var addr: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    public init(object: AudioObjectID, selector: AudioObjectPropertySelector,
                queue: DispatchQueue, handler: @escaping () -> Void) throws {
        self.object = object
        self.queue = queue
        addr = address(selector)
        block = { _, _ in handler() }
        try check(AudioObjectAddPropertyListenerBlock(object, &addr, queue, block), "add listener '\(selector)'")
    }

    public static func system(_ selector: AudioObjectPropertySelector, queue: DispatchQueue,
                              handler: @escaping () -> Void) throws -> AudioPropertyObserver {
        try AudioPropertyObserver(object: AudioObjectID(kAudioObjectSystemObject), selector: selector,
                                  queue: queue, handler: handler)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
    }
}

/// HAL process objects: every process that has opened audio.
public func audioProcessObjects() -> [AudioObjectID] {
    (try? getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)) ?? []
}

/// Bundle IDs of the processes the HAL knows about, each once. With `inCall`, only those
/// recording and playing at the same time (a voice or video call).
public func audioProcessBundleIDs(inCall: Bool = false) -> [String] {
    var seen = Set<String>()
    return audioProcessObjects()
        .filter { id in
            !inCall || [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput]
                .allSatisfy { (try? getValue(id, $0, initial: UInt32(0))) ?? 0 != 0 }
        }
        .compactMap { try? getString($0, kAudioProcessPropertyBundleID) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
}

/// The HAL process object for this process, used to exclude our own output from the tap.
public func currentProcessObject() throws -> AudioObjectID {
    var pid = getpid()
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
              "translate pid to process object")
    return object
}
