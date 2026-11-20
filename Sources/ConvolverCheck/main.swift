import Accelerate
import AudioEngine
import Foundation

// Usage: ConvolverCheck <filter dir> [sampleRate]
//        ConvolverCheck --import <new filter dir> <impulse.wav>...
// Runs noise through ConvolutionEngine with random buffer sizes and compares it against
// direct convolution. Also measures real-time CPU load for the filter.
// With --import, builds a filter directory from WAV impulse responses (as the app's "Import filter…").

if CommandLine.arguments.dropFirst().first == "--import", CommandLine.arguments.count >= 4 {
    let args = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
    try FilterImport.importFilter(from: Array(args.dropFirst()), to: args[0])
    print("imported \(args.dropFirst().map(\.lastPathComponent)) → \(args[0].path)")
    exit(0)
}

guard let dirArg = CommandLine.arguments.dropFirst().first else {
    print("usage: ConvolverCheck <filter dir> [sampleRate] | --import <new filter dir> <impulse.wav>...")
    exit(1)
}
let dir = URL(fileURLWithPath: dirArg)
let rate = Double(CommandLine.arguments.dropFirst(2).first ?? "48000") ?? 48000
let firs = try FIRSet.load(directory: dir, sampleRate: rate)
let channels = firs.channels.count
let taps = firs.channels[0].count
print("filter \(dir.lastPathComponent) @ \(Int(rate)) Hz: \(channels) ch x \(taps) taps, gain \(firs.gainDB) dB")

var rng = SystemRandomNumberGenerator()
let frames = Int(rate) // 1 s of noise
let input = (0..<frames * channels).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
var output = [Float](repeating: 0, count: frames * channels)

let engine = ConvolutionEngine(firs: firs, channelCount: channels)
var offset = 0
input.withUnsafeBufferPointer { inp in
    output.withUnsafeMutableBufferPointer { out in
        while offset < frames {
            let n = min(frames - offset, Int.random(in: 1...1100, using: &rng))
            engine.process(inp.baseAddress! + offset * channels, out.baseAddress! + offset * channels, frames: n)
            offset += n
        }
    }
}

// Reference: y[n] = sum_k h[k] x[n-k], shifted by the engine latency.
var worst: Float = 0
var peak: Float = 0
let latency = engine.latencyFrames
for ch in 0..<channels {
    let x = stride(from: ch, to: input.count, by: channels).map { input[$0] }
    let h = firs.channels[ch]
    let padded = [Float](repeating: 0, count: h.count - 1) + x
    var reference = [Float](repeating: 0, count: frames)
    vDSP_conv(padded, 1, Array(h.reversed()), 1, &reference, 1, vDSP_Length(frames), vDSP_Length(h.count))
    for n in latency..<frames {
        let got = output[n * channels + ch]
        worst = max(worst, abs(got - reference[n - latency]))
        peak = max(peak, abs(reference[n - latency]))
    }
}
print(String(format: "max error %.2e (%.1f dB below signal peak %.3f), latency %d frames",
             worst, 20 * log10(worst / peak), peak, latency))

// Bypass must come out at the same time as the filter's own delay, scaled by the bypass gain.
let bypassEngine = ConvolutionEngine(firs: firs, channelCount: channels)
bypassEngine.bypass = true
let impulseLength = firs.latencyFrames + 4 * bypassEngine.blockSize
var impulse = [Float](repeating: 0, count: impulseLength * channels)
impulse[0] = 1
var bypassOut = [Float](repeating: 0, count: impulseLength * channels)
bypassEngine.process(impulse, &bypassOut, frames: impulseLength)
let expectedAt = (firs.latencyFrames + bypassEngine.latencyFrames) * channels
let expectedGain = powf(10, firs.bypassGainDB / 20)
let bypassOK = abs(bypassOut[expectedAt] - expectedGain) < 1e-6
    && bypassOut.enumerated().allSatisfy { $0.offset == expectedAt || $0.element == 0 }
print("bypass: delay \(firs.latencyFrames)+\(bypassEngine.latencyFrames) frames, gain \(firs.bypassGainDB) dB -> \(bypassOK ? "ok" : "WRONG")")

// Live analyzer: with noise going through, output over input must match the filter's response.
let probed = ConvolutionEngine(firs: firs, channelCount: channels)
probed.probe.isEnabled = true
let analyzer = SpectrumAnalyzer(sampleRate: rate)
let hop = Int(rate / 30)
var noise = [Float](repeating: 0, count: hop * channels)
var noiseOut = noise
for _ in 0..<(30 * 8 + firs.latencyFrames / hop) {  // ~8 s of display updates after the filter delay
    for i in noise.indices { noise[i] = Float.random(in: -0.5...0.5, using: &rng) }
    probed.process(noise, &noiseOut, frames: hop)
    analyzer.update(from: probed.probe)
}
let expected = (0..<min(2, channels)).map {
    SpectrumAnalyzer.magnitudeResponse(firs.channels[$0], sampleRate: rate, at: analyzer.frequencies)
}
// Below 150 Hz the 0.7 s analysis window can't fully resolve the narrow notches on room modes.
var analyzerWorst: Float = 0, analyzerWorstLow: Float = 0
for (i, f) in analyzer.frequencies.enumerated() where f >= 40 && f <= 16000 {
    // Noise power adds per channel, so compare with the mean power of the channel responses.
    let target = 10 * log10(expected.map { powf(10, $0[i] / 10) }.reduce(0, +) / Float(expected.count))
    guard let got = analyzer.correctionDB[i] else { analyzerWorst = .infinity; continue }
    if f < 150 {
        analyzerWorstLow = max(analyzerWorstLow, abs(got - target))
    } else {
        analyzerWorst = max(analyzerWorst, abs(got - target))
    }
}
let analyzerOK = analyzerWorst < 1 && analyzerWorstLow < 3
print(String(format: "analyzer: live correction within %.2f dB of the filter (150 Hz-16 kHz), %.2f dB below -> %@",
             analyzerWorst, analyzerWorstLow, analyzerOK ? "ok" : "WRONG"))

// CPU: process 10 s in 512-frame buffers and compare with wall-clock budget.
let buffer = [Float](repeating: 0.1, count: 512 * 4)
var sink = [Float](repeating: 0, count: 512 * 4)
let bench = ConvolutionEngine(firs: firs, channelCount: 4)
let blocks = Int(rate * 10) / 512
let start = DispatchTime.now()
for _ in 0..<blocks { bench.process(buffer, &sink, frames: 512) }
let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
print(String(format: "CPU: %.3f s for 10 s of 4-ch audio = %.2f%% of one core", elapsed, elapsed * 10))
exit(worst / peak < 1e-4 && bypassOK && analyzerOK ? 0 : 1)
