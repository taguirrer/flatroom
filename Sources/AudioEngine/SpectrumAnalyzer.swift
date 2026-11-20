import Accelerate

/// Live 1/6-octave spectrum of what goes into the filter and what comes out of it, read from a
/// `SignalProbe`. Call `update` at display rate on one thread.
public final class SpectrumAnalyzer {
    /// Band centres, log-spaced from 20 Hz to 20 kHz (or just under Nyquist).
    public let frequencies: [Double]
    public let sampleRate: Double
    /// Band levels in dB (full-scale sine ≈ 0 dB), lightly smoothed over time like an RTA.
    public private(set) var inputDB: [Float]
    public private(set) var outputDB: [Float]
    /// Output over input averaged over several seconds of audio: the correction actually applied.
    /// Nil where the input had too little energy to tell. Holds its value through silence.
    public private(set) var correctionDB: [Float?]
    /// True while the latest block had audible input.
    public private(set) var hasSignal = false

    /// Short window for the spectrum (follows the music), long one for the correction (resolves
    /// the narrow notches a room filter puts on room modes).
    private let fast: BandFFT
    private let slow: BandFFT
    private var inFast, outFast, inSlow, outSlow: [Float]

    public init(sampleRate: Double, points: Int = 240) {
        self.sampleRate = sampleRate
        let top = min(20000, sampleRate * 0.49)
        frequencies = (0..<points).map { 20 * pow(top / 20, Double($0) / Double(points - 1)) }
        fast = BandFFT(size: max(4096, Int(sampleRate / 6).nextPowerOfTwo), sampleRate: sampleRate, frequencies: frequencies)
        slow = BandFFT(size: Int(sampleRate * 0.6).nextPowerOfTwo, sampleRate: sampleRate, frequencies: frequencies)
        inputDB = Array(repeating: -150, count: points)
        outputDB = inputDB
        correctionDB = Array(repeating: nil, count: points)
        inFast = Array(repeating: 0, count: points)
        outFast = inFast; inSlow = inFast; outSlow = inFast
    }

    /// Reads the newest audio from `probe` and updates the curves. Returns false if there wasn't
    /// enough audio yet (the curves are left as they were).
    @discardableResult
    public func update(from probe: SignalProbe) -> Bool {
        guard let (inNow, outNow) = fast.bandPowers(from: probe) else { return false }
        // RTA ballistics: ~0.1 s at 30 updates per second.
        for i in inNow.indices {
            inFast[i] += 0.3 * (inNow[i] - inFast[i])
            outFast[i] += 0.3 * (outNow[i] - outFast[i])
        }
        inputDB = inFast.map { 10 * log10(max($0, 1e-15)) }
        outputDB = outFast.map { 10 * log10(max($0, 1e-15)) }

        // The applied correction converges over a few seconds; silence doesn't pull it anywhere.
        hasSignal = (inNow.max() ?? 0) > 1e-10
        guard hasSignal, let (inLong, outLong) = slow.bandPowers(from: probe) else { return true }
        for i in inLong.indices {
            inSlow[i] += 0.03 * (inLong[i] - inSlow[i])
            outSlow[i] += 0.03 * (outLong[i] - outSlow[i])
        }
        // Bands far below the loudest one say more about noise than about the filter.
        let floor = (inSlow.max() ?? 0) * 1e-6
        correctionDB = inSlow.indices.map { i in
            inSlow[i] > floor && outSlow[i] > 0 ? 10 * log10(outSlow[i] / inSlow[i]) : nil
        }
        return true
    }

    /// Where each 1/6-octave band reads the spectrum: the bins inside it, or, for a band narrower
    /// than a bin, a point between the two nearest bins (so low bands don't step bin by bin).
    enum Band {
        case bins(ClosedRange<Int>)
        case between(Int, Float)  // lower bin and the weight of the one above it

        /// Mean power per bin over the band.
        func read(_ power: UnsafeBufferPointer<Float>) -> Float {
            switch self {
            case let .bins(range):
                var mean: Float = 0
                vDSP_meanv(power.baseAddress! + range.lowerBound, 1, &mean, vDSP_Length(range.count))
                return mean
            case let .between(bin, weight):
                return power[bin] * (1 - weight) + power[bin + 1] * weight
            }
        }
    }

    static func bands(for frequencies: [Double], binHz: Double, bins: Int) -> [Band] {
        frequencies.map { f in
            let lo = max(1, Int((f * pow(2, -1.0 / 12) / binHz).rounded(.up)))
            let hi = min(bins - 1, Int((f * pow(2, 1.0 / 12) / binHz).rounded(.down)))
            if lo <= hi { return .bins(lo...hi) }
            let position = min(Double(bins - 2), max(1, f / binHz))
            return .between(Int(position), Float(position - position.rounded(.down)))
        }
    }

    /// Magnitude response of an FIR in dB, averaged over the same 1/6-octave bands.
    public static func magnitudeResponse(_ ir: [Float], sampleRate: Double, at frequencies: [Double]) -> [Float] {
        // At least ~1 Hz per bin so the lowest bands have a few bins each.
        let n = max(ir.count, Int(sampleRate)).nextPowerOfTwo
        let half = n / 2
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var signal = [Float](repeating: 0, count: n)
        signal.replaceSubrange(0..<ir.count, with: ir)
        var re = [Float](repeating: 0, count: half), im = re, power = re
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                signal.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        let bands = bands(for: frequencies, binHz: sampleRate / Double(n), bins: half)
        return power.withUnsafeBufferPointer { power in
            bands.map { 10 * log10(max($0.read(power) / 4, 1e-15)) }  // zrip is 2x the DFT
        }
    }
}

/// One FFT size with its window and band layout, turning probe audio into 1/6-octave band powers.
private final class BandFFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private let bands: [SpectrumAnalyzer.Band]
    private let bandWidths: [Float]  // band width in bins: turns mean power per bin into band power
    private var pre, post, windowed, re, im, power: [Float]

    init(size: Int, sampleRate: Double, frequencies: [Double]) {
        self.size = size
        log2n = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))  // plain 0.5 - 0.5 cos
        let binHz = sampleRate / Double(size)
        bands = SpectrumAnalyzer.bands(for: frequencies, binHz: binHz, bins: size / 2)
        bandWidths = frequencies.map { Float($0 * (pow(2, 1.0 / 12) - pow(2, -1.0 / 12)) / binHz) }
        pre = [Float](repeating: 0, count: size)
        post = pre; windowed = pre
        re = [Float](repeating: 0, count: size / 2)
        im = re; power = re
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Band powers of the filter's input and output, averaged over the probed channels.
    func bandPowers(from probe: SignalProbe) -> (input: [Float], output: [Float])? {
        var input = [Float](repeating: 0, count: bands.count)
        var output = input
        guard probe.channelCount > 0 else { return nil }
        for ch in 0..<probe.channelCount {
            let ok = pre.withUnsafeMutableBufferPointer { p in
                post.withUnsafeMutableBufferPointer { q in
                    probe.copyLatest(channel: ch, frames: size, pre: p.baseAddress!, post: q.baseAddress!)
                }
            }
            guard ok else { return nil }
            accumulate(pre, into: &input)
            accumulate(post, into: &output)
        }
        var scale = 1 / Float(probe.channelCount)
        vDSP_vsmul(input, 1, &scale, &input, 1, vDSP_Length(input.count))
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(output.count))
        return (input, output)
    }

    private func accumulate(_ signal: [Float], into bandsOut: inout [Float]) {
        let half = size / 2
        vDSP_vmul(signal, 1, window, 1, &windowed, 1, vDSP_Length(size))
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        // zrip gives 2x the DFT and the Hann window halves a sine: a full-scale sine peaks at (N/2)^2.
        var norm = 1 / Float(half * half)
        vDSP_vsmul(power, 1, &norm, &power, 1, vDSP_Length(half))
        power.withUnsafeBufferPointer { power in
            for (b, band) in bands.enumerated() { bandsOut[b] += band.read(power) * bandWidths[b] }
        }
    }
}

private extension Int {
    var nextPowerOfTwo: Int { self <= 1 ? 1 : 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount) }
}
