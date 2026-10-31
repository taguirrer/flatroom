import Accelerate

/// Uniformly partitioned overlap-save convolution of one channel with a long FIR.
/// Processes exactly `blockSize` samples per call; latency is zero beyond the block itself.
/// All buffers are allocated up front so `process` is real-time safe.
final class PartitionedConvolver {
    let blockSize: Int
    private let fftSize: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let partitions: Int

    // Filter spectra and the frequency-domain delay line, both `partitions` x `half` (split complex).
    private let filterRe: UnsafeMutablePointer<Float>
    private let filterIm: UnsafeMutablePointer<Float>
    private let fdlRe: UnsafeMutablePointer<Float>
    private let fdlIm: UnsafeMutablePointer<Float>
    private var fdlHead = 0

    private let window: UnsafeMutablePointer<Float>  // [previous block | current block]
    private let accRe: UnsafeMutablePointer<Float>
    private let accIm: UnsafeMutablePointer<Float>
    private let time: UnsafeMutablePointer<Float>
    private let scale: Float

    init(impulseResponse ir: [Float], blockSize: Int) {
        precondition(blockSize > 0 && blockSize & (blockSize - 1) == 0, "blockSize must be a power of two")
        self.blockSize = blockSize
        fftSize = blockSize * 2
        half = blockSize
        log2n = vDSP_Length(fftSize.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        partitions = max(1, (ir.count + blockSize - 1) / blockSize)
        // zrip forward is 2x the DFT for each operand, the inverse adds a factor of fftSize.
        scale = 1 / Float(4 * fftSize)

        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        filterRe = alloc(partitions * half)
        filterIm = alloc(partitions * half)
        fdlRe = alloc(partitions * half)
        fdlIm = alloc(partitions * half)
        window = alloc(fftSize)
        accRe = alloc(half)
        accIm = alloc(half)
        time = alloc(fftSize)

        for k in 0..<partitions {
            let start = k * blockSize
            let count = min(blockSize, ir.count - start)
            vDSP_vclr(time, 1, vDSP_Length(fftSize))
            if count > 0 { ir.withUnsafeBufferPointer { time.update(from: $0.baseAddress! + start, count: count) } }
            forward(time, re: filterRe + k * half, im: filterIm + k * half)
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for p in [filterRe, filterIm, fdlRe, fdlIm, window, accRe, accIm, time] { p.deallocate() }
    }

    /// Clears the input history (e.g. after a stream restart) without touching the filter.
    func reset() {
        vDSP_vclr(fdlRe, 1, vDSP_Length(partitions * half))
        vDSP_vclr(fdlIm, 1, vDSP_Length(partitions * half))
        vDSP_vclr(window, 1, vDSP_Length(fftSize))
    }

    /// `input` and `output` hold `blockSize` contiguous samples; they may alias.
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) {
        // Slide the overlap-save window and transform it into the newest FDL slot.
        (window).update(from: window + blockSize, count: blockSize)
        (window + blockSize).update(from: input, count: blockSize)
        fdlHead = (fdlHead + partitions - 1) % partitions
        forward(window, re: fdlRe + fdlHead * half, im: fdlIm + fdlHead * half)

        // Y = sum_k X[n-k] * H[k]. Bin 0 packs DC (real) and Nyquist (imag) and is done by hand.
        vDSP_vclr(accRe, 1, vDSP_Length(half))
        vDSP_vclr(accIm, 1, vDSP_Length(half))
        var dc: Float = 0
        var nyquist: Float = 0
        for k in 0..<partitions {
            let slot = (fdlHead + k) % partitions
            let xRe = fdlRe + slot * half, xIm = fdlIm + slot * half
            let hRe = filterRe + k * half, hIm = filterIm + k * half
            dc += xRe[0] * hRe[0]
            nyquist += xIm[0] * hIm[0]
            var x = DSPSplitComplex(realp: xRe + 1, imagp: xIm + 1)
            var h = DSPSplitComplex(realp: hRe + 1, imagp: hIm + 1)
            var acc = DSPSplitComplex(realp: accRe + 1, imagp: accIm + 1)
            vDSP_zvma(&x, 1, &h, 1, &acc, 1, &acc, 1, vDSP_Length(half - 1))
        }
        accRe[0] = dc
        accIm[0] = nyquist

        var acc = DSPSplitComplex(realp: accRe, imagp: accIm)
        vDSP_fft_zrip(setup, &acc, 1, log2n, FFTDirection(FFT_INVERSE))
        time.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ztoc(&acc, 1, $0, 2, vDSP_Length(half))
        }
        // Overlap-save: only the second half is valid output.
        var s = scale
        vDSP_vsmul(time + blockSize, 1, &s, output, 1, vDSP_Length(blockSize))
    }

    private func forward(_ signal: UnsafeMutablePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        signal.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
    }
}
