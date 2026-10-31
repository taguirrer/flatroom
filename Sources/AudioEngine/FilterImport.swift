import Accelerate
import AVFoundation

/// Turns impulse responses exported as WAV (REW's "Export filter impulse response", rePhase, DRC…)
/// into a filter directory: `fir_<rate>.wav` for every rate an interface may run at, plus `meta.json`.
public enum FilterImport {
    public static let sampleRates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]

    public struct ImportError: LocalizedError {
        public let errorDescription: String?
    }

    /// One file per rate is ideal. A missing rate is resampled from the highest-rate file: going down
    /// is exact up to the new Nyquist frequency; going up leaves no correction (and no signal) above
    /// the source's Nyquist frequency, so export at 192 kHz when you can.
    public static func importFilter(from files: [URL], to directory: URL) throws {
        let sources = try files.map(read)
        guard let best = sources.max(by: { $0.rate < $1.rate }) else {
            throw ImportError(errorDescription: "No impulse response files")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var filesMeta: [String: Any] = [:]
        for rate in sampleRates {
            var channels = try sources.first { $0.rate == rate }?.channels
                ?? best.channels.map { try resample($0, from: best.rate, to: rate) }
            if channels.count == 1 { channels.append(channels[0]) }  // mono filter: same for L and R
            let name = "fir_\(Int(rate)).wav"
            try write(channels, rate: rate, to: directory.appendingPathComponent(name))
            filesMeta[String(Int(rate))] = ["file": name, "taps": channels[0].count,
                                            "latency_samples": peakIndex(channels[0])]
        }

        let meta: [String: Any] = [
            "type": "imported",
            "source": files.map(\.lastPathComponent).joined(separator: ", "),
            "gain_db": 0,
            "bypass_gain_db": (bypassGainDB(best.channels, rate: best.rate) * 100).rounded() / 100,
            "files": filesMeta,
        ]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("meta.json"))
    }

    private static func read(_ url: URL) throws -> (rate: Double, channels: [[Float]]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.length < 1 << 22,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw ImportError(errorDescription: "\(url.lastPathComponent): not an impulse response") }
        try file.read(into: buffer)
        let count = Int(buffer.format.channelCount)
        guard count == 1 || count == 2 else {
            throw ImportError(errorDescription: "\(url.lastPathComponent): \(count) channels (expected 1 or 2)")
        }
        let channels = (0..<count).map {
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
        }
        return (file.fileFormat.sampleRate, channels)
    }

    private static func write(_ channels: [[Float]], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: AVAudioChannelCount(channels.count), interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for (ch, samples) in channels.enumerated() {
            buffer.floatChannelData![ch].update(from: samples, count: samples.count)
        }
        try? FileManager.default.removeItem(at: url)
        // WAV files are interleaved on disk; the buffer we hand over stays planar.
        let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                       channels: AVAudioChannelCount(channels.count), interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: fileFormat.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// Resamples an impulse response so it has the same frequency response at the new rate.
    static func resample(_ ir: [Float], from source: Double, to target: Double) throws -> [Float] {
        if source == target { return ir }
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false)!
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw ImportError(errorDescription: "Cannot resample \(Int(source)) → \(Int(target)) Hz")
        }
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.primeMethod = .none  // output starts at the first input sample; we trim the filter delay below

        // Pad with silence so the converter's own delay doesn't cut the tail.
        let pad = Int(source / 10)
        let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(ir.count + pad))!
        input.frameLength = input.frameCapacity
        input.floatChannelData![0].initialize(repeating: 0, count: ir.count + pad)
        input.floatChannelData![0].update(from: ir, count: ir.count)

        let ratio = target / source
        let outCapacity = AVAudioFrameCount(Double(ir.count + pad) * ratio) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity)!
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? ImportError(errorDescription: "Resampling failed") }

        let out = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        // The converter delays its output; align it with a delta resampled the same way.
        let shift = try converterDelay(from: source, to: target)
        let length = Int((Double(ir.count) * ratio).rounded())
        let scale = Float(source / target)  // more taps per second: each one carries less of the gain
        return (0..<length).map { $0 + shift < out.count ? out[$0 + shift] * scale : 0 }
    }

    nonisolated(unsafe) private static var delays: [String: Int] = [:]  // only used while importing, one at a time

    /// Frames the converter adds before the signal (measured once per rate pair with a delta).
    private static func converterDelay(from source: Double, to target: Double) throws -> Int {
        let key = "\(source)>\(target)"
        if let known = delays[key] { return known }
        let at = Int(source / 100)
        var delta = [Float](repeating: 0, count: Int(source / 20))
        delta[at] = 1
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false)!
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inFormat, to: outFormat)!
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.primeMethod = .none
        let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(delta.count))!
        input.frameLength = input.frameCapacity
        input.floatChannelData![0].update(from: delta, count: delta.count)
        let output = AVAudioPCMBuffer(pcmFormat: outFormat,
                                      frameCapacity: AVAudioFrameCount(Double(delta.count) * target / source) + 1024)!
        var fed = false
        _ = converter.convert(to: output, error: nil) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        let out = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        let shift = peakIndex(out) - Int((Double(at) * target / source).rounded())
        delays[key] = shift
        return shift
    }

    private static func peakIndex(_ samples: [Float]) -> Int {
        var value: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxmgvi(samples, 1, &value, &index, vDSP_Length(samples.count))
        return Int(index)
    }

    /// Gain for loudness-matched bypass: the filter's mean power on pink noise (equal energy per
    /// octave) between 40 Hz and 16 kHz, averaged over the channels.
    private static func bypassGainDB(_ channels: [[Float]], rate: Double) -> Double {
        let freqs = (0..<200).map { 40 * pow(16000.0 / 40, Double($0) / 199) }
        var power = 0.0
        for ir in channels {
            for f in freqs {
                let w = -2 * Double.pi * f / rate
                var re = 0.0, im = 0.0
                for (n, h) in ir.enumerated() where h != 0 {
                    re += Double(h) * cos(w * Double(n))
                    im += Double(h) * sin(w * Double(n))
                }
                power += re * re + im * im
            }
        }
        return 10 * log10(power / Double(channels.count * freqs.count))
    }
}
