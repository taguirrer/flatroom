import Accelerate
import AVFoundation

/// One FIR per channel for a given sample rate, as written by filter-design/design_fir.py.
public struct FIRSet {
    public let sampleRate: Double
    public let channels: [[Float]]
    /// Gain baked into the filter (negative headroom).
    public let gainDB: Float
    /// Gain applied in bypass so A/B is loudness-matched (falls back to `gainDB`).
    public let bypassGainDB: Float
    /// Delay of the filter itself (half its length for linear phase); bypass is delayed to match.
    public let latencyFrames: Int

    /// Loads `fir_<rate>.wav` (+ `meta.json` for the gains) from a filter directory.
    public static func load(directory: URL, sampleRate: Double) throws -> FIRSet {
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("fir_\(Int(sampleRate)).wav"),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.fileFormat.sampleRate == sampleRate else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "sample rate mismatch"])
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: frames))
        }
        var meta: [String: Any] = [:]
        if let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            meta = json
        }
        let gain = Float(meta["gain_db"] as? Double ?? 0)
        let bypass = (meta["bypass_gain_db"] as? Double).map(Float.init) ?? gain
        let files = meta["files"] as? [String: [String: Any]]
        let latency = files?[String(Int(sampleRate))]?["latency_samples"] as? Int ?? 0
        return FIRSet(sampleRate: sampleRate, channels: channels, gainDB: gain, bypassGainDB: bypass,
                      latencyFrames: latency)
    }
}

/// Filters the first `firs.channels.count` channels of an interleaved stream of any buffer size;
/// remaining channels pass through. Adds `blockSize` frames of latency to every channel.
public final class ConvolutionEngine {
    public let blockSize: Int
    public var latencyFrames: Int { blockSize }
    /// Block latency plus the filter's own delay (what the listener actually hears).
    public var totalLatencyFrames: Int { blockSize + delayLength }

    private let convolvers: [PartitionedConvolver]
    private let bypassGain: Float
    public let channelCount: Int
    private let inFifo: UnsafeMutablePointer<Float>   // channelCount x blockSize, planar
    private let outFifo: UnsafeMutablePointer<Float>  // channelCount x blockSize, planar
    private var position = 0
    // Bypass delay line (one ring per filtered channel) so switching A/B doesn't jump in time.
    private let delay: UnsafeMutablePointer<Float>
    private let delayLength: Int
    private var delayPosition = 0
    /// Read on the audio thread; written from anywhere. A torn read just flips one block early or late.
    private let bypassFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    public var bypass: Bool {
        get { bypassFlag.pointee }
        set { bypassFlag.pointee = newValue }
    }

    public init(firs: FIRSet, channelCount: Int, blockSize: Int = 512) {
        self.blockSize = blockSize
        self.channelCount = channelCount
        convolvers = firs.channels.prefix(channelCount).map { PartitionedConvolver(impulseResponse: $0, blockSize: blockSize) }
        bypassGain = powf(10, firs.bypassGainDB / 20)
        inFifo = .allocate(capacity: channelCount * blockSize)
        outFifo = .allocate(capacity: channelCount * blockSize)
        inFifo.initialize(repeating: 0, count: channelCount * blockSize)
        outFifo.initialize(repeating: 0, count: channelCount * blockSize)
        bypassFlag.initialize(to: false)
        delayLength = firs.latencyFrames
        delay = .allocate(capacity: max(1, convolvers.count * delayLength))
        delay.initialize(repeating: 0, count: max(1, convolvers.count * delayLength))
    }

    deinit {
        inFifo.deallocate()
        outFifo.deallocate()
        bypassFlag.deallocate()
        delay.deallocate()
    }

    /// Interleaved in/out with `channelCount` channels; `input` and `output` may alias.
    public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let chunk = min(frames - done, blockSize - position)
            for ch in 0..<channelCount {
                let fifoIn = inFifo + ch * blockSize + position
                let fifoOut = outFifo + ch * blockSize + position
                var one: Float = 1
                // Read this chunk's input before overwriting the same samples with delayed output.
                vDSP_vsmul(input + done * channelCount + ch, channelCount, &one, fifoIn, 1, vDSP_Length(chunk))
                vDSP_vsmul(fifoOut, 1, &one, output + done * channelCount + ch, channelCount, vDSP_Length(chunk))
            }
            position += chunk
            done += chunk
            if position == blockSize {
                runBlock()
                position = 0
            }
        }
    }

    private func runBlock() {
        let bypassed = bypassFlag.pointee
        var gain = bypassGain
        for ch in 0..<channelCount {
            let src = inFifo + ch * blockSize
            let dst = outFifo + ch * blockSize
            if ch < convolvers.count {
                // Keep the convolver and the delay line fed while bypassed so switching is seamless.
                convolvers[ch].process(src, dst)
                if delayLength > 0 {
                    exchangeWithDelay(channel: ch, src: src)  // src now holds the delayed input
                }
                if bypassed { vDSP_vsmul(src, 1, &gain, dst, 1, vDSP_Length(blockSize)) }
            } else {
                dst.update(from: src, count: blockSize)
            }
        }
        if delayLength > 0 { delayPosition = (delayPosition + blockSize) % delayLength }
    }

    /// Swaps `blockSize` samples between `src` and the channel's ring at `delayPosition`:
    /// the ring keeps the new input, `src` receives the input from `delayLength` frames ago.
    private func exchangeWithDelay(channel: Int, src: UnsafeMutablePointer<Float>) {
        let ring = delay + channel * delayLength
        var done = 0
        var pos = delayPosition
        while done < blockSize {
            let n = min(blockSize - done, delayLength - pos)
            vDSP_vswap(src + done, 1, ring + pos, 1, vDSP_Length(n))
            done += n
            pos = (pos + n) % delayLength
        }
    }
}
