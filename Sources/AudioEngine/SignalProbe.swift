import Foundation

/// What goes into the filter and what comes out of it, kept for a live analyzer on another thread.
/// The audio thread writes whole blocks into one ring per channel and then advances the frame
/// count; readers copy the newest frames. Lock-free like the bypass flag: a reader racing the
/// writer can at worst get a few samples of the block being written, which is harmless for a display.
public final class SignalProbe {
    public static let capacity = 1 << 18  // 2x the longest analysis window (0.68 s at 192 kHz)
    public let channelCount: Int

    private let pre: UnsafeMutablePointer<Float>   // channelCount x capacity
    private let post: UnsafeMutablePointer<Float>  // channelCount x capacity
    private let written = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private let enabledFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    /// Off by default so the audio thread does no extra work unless someone is watching.
    public var isEnabled: Bool {
        get { enabledFlag.pointee }
        set { enabledFlag.pointee = newValue }
    }

    init(channelCount: Int) {
        self.channelCount = channelCount
        pre = .allocate(capacity: max(1, channelCount) * Self.capacity)
        post = .allocate(capacity: max(1, channelCount) * Self.capacity)
        pre.initialize(repeating: 0, count: max(1, channelCount) * Self.capacity)
        post.initialize(repeating: 0, count: max(1, channelCount) * Self.capacity)
        written.initialize(to: 0)
        enabledFlag.initialize(to: false)
    }

    deinit {
        pre.deallocate()
        post.deallocate()
        written.deallocate()
        enabledFlag.deallocate()
    }

    // MARK: Audio thread

    /// Stores one block of `channel` at the current position. `count` must divide `capacity`
    /// (any power-of-two block size does), so a block never wraps around the ring.
    func store(channel: Int, pre input: UnsafePointer<Float>, post output: UnsafePointer<Float>, count: Int) {
        let at = channel * Self.capacity + (written.pointee & (Self.capacity - 1))
        (pre + at).update(from: input, count: count)
        (post + at).update(from: output, count: count)
    }

    /// Publishes the block stored for every channel.
    func advance(_ count: Int) {
        written.pointee &+= count
    }

    // MARK: Readers

    /// Copies the newest `frames` of `channel` (filter input and output, time-aligned).
    /// Returns false until that much audio has gone through.
    public func copyLatest(channel: Int, frames: Int,
                           pre preOut: UnsafeMutablePointer<Float>, post postOut: UnsafeMutablePointer<Float>) -> Bool {
        let end = written.pointee
        guard channel < channelCount, frames <= Self.capacity / 2, end >= frames else { return false }
        let start = (end - frames) & (Self.capacity - 1)
        let first = min(frames, Self.capacity - start)
        let base = channel * Self.capacity
        preOut.update(from: pre + base + start, count: first)
        postOut.update(from: post + base + start, count: first)
        if first < frames {
            (preOut + first).update(from: pre + base, count: frames - first)
            (postOut + first).update(from: post + base, count: frames - first)
        }
        return true
    }
}
