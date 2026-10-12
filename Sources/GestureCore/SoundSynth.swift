import Foundation

/// The feedback sounds, synthesized from a few sine partials and envelopes into 16-bit mono WAV
/// data. Generating them keeps binary assets out of the repository, and makes the sound design
/// a readable, tweakable recipe rather than an opaque file.
public enum SoundCue: String, CaseIterable {
    case engage, disengage, click, dragStart, drop, scrollFade

    /// A tone: frequency glides from `from` to `to` Hz.
    struct Partial {
        var from: Double
        var to: Double
        var gain: Double
        var start: Double = 0
    }

    struct Recipe {
        var duration: Double
        var partials: [Partial]
        var attack: Double
        var decay: Double          // exponential decay time constant (s)
        var noise: Double = 0      // gain of filtered noise (for the scroll whoosh)
        var volume: Double
    }

    var recipe: Recipe {
        switch self {
        case .engage:
            // Two soft rising notes, a fifth apart (A5 → E6): "on".
            return Recipe(duration: 0.32,
                          partials: [Partial(from: 880, to: 880, gain: 0.6),
                                     Partial(from: 1318.5, to: 1318.5, gain: 0.5, start: 0.09)],
                          attack: 0.006, decay: 0.11, volume: 0.22)
        case .disengage:
            // The same two notes, falling: "off".
            return Recipe(duration: 0.32,
                          partials: [Partial(from: 1318.5, to: 1318.5, gain: 0.5),
                                     Partial(from: 880, to: 880, gain: 0.6, start: 0.09)],
                          attack: 0.006, decay: 0.11, volume: 0.2)
        case .click:
            // A short, high, woody tick.
            return Recipe(duration: 0.04, partials: [Partial(from: 2600, to: 2200, gain: 1)],
                          attack: 0.001, decay: 0.008, volume: 0.16)
        case .dragStart:
            return Recipe(duration: 0.12, partials: [Partial(from: 520, to: 700, gain: 1)],
                          attack: 0.004, decay: 0.04, volume: 0.16)
        case .drop:
            return Recipe(duration: 0.12, partials: [Partial(from: 700, to: 480, gain: 1)],
                          attack: 0.004, decay: 0.04, volume: 0.16)
        case .scrollFade:
            return Recipe(duration: 0.3, partials: [], attack: 0.02, decay: 0.09, noise: 1, volume: 0.07)
        }
    }

    public static let sampleRate = 44_100

    /// Mono 16-bit PCM samples in -1...1 before quantization.
    public func samples() -> [Double] {
        let r = recipe
        let count = Int(r.duration * Double(Self.sampleRate))
        var out = [Double](repeating: 0, count: count)
        let dt = 1.0 / Double(Self.sampleRate)
        for partial in r.partials {
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) * dt - partial.start
                guard t >= 0 else { continue }
                let progress = min(t / max(r.duration - partial.start, 1e-6), 1)
                let freq = partial.from + (partial.to - partial.from) * progress
                phase += 2 * .pi * freq * dt
                out[i] += sin(phase) * partial.gain * Self.envelope(t, attack: r.attack, decay: r.decay)
            }
        }
        if r.noise > 0 {
            var rng = SeededRandom(seed: 11)
            var low = 0.0
            for i in 0..<count {
                let t = Double(i) * dt
                // One-pole low-pass on white noise: a soft "shh" rather than hiss.
                low += 0.08 * (rng.gaussian() - low)
                out[i] += low * r.noise * Self.envelope(t, attack: r.attack, decay: r.decay)
            }
        }
        // Normalize to the recipe volume, and fade the last 5 ms so nothing clicks at the end.
        let peak = out.map(abs).max() ?? 1
        let scale = peak > 0 ? r.volume / peak : 0
        let fade = Int(0.005 * Double(Self.sampleRate))
        for i in 0..<count {
            let tail = count - i
            let fadeGain = tail < fade ? Double(tail) / Double(fade) : 1
            out[i] *= scale * fadeGain
        }
        return out
    }

    static func envelope(_ t: Double, attack: Double, decay: Double) -> Double {
        if t < attack { return t / attack }
        return exp(-(t - attack) / decay)
    }

    /// A complete RIFF/WAVE file.
    public func wavData() -> Data {
        let pcm = samples().map { Int16(max(-1, min(1, $0)) * Double(Int16.max)) }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                     // PCM header size
        append(UInt16(1))                      // PCM
        append(UInt16(1))                      // mono
        append(UInt32(Self.sampleRate))
        append(UInt32(Self.sampleRate * 2))    // byte rate
        append(UInt16(2))                      // block align
        append(UInt16(16))                     // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        for sample in pcm { append(sample) }
        return data
    }
}
