import Foundation

/// 產生提示音的 WAV 資料（16-bit PCM 單聲道），不必在專案裡放二進位音檔。
public enum ToneGenerator {

    /// 產生一段正弦波嗶聲，前後各加淡入淡出避免爆音。
    public static func wavData(frequency: Double = 1_200, duration: Double = 0.15,
                               volume: Double = 0.8, sampleRate: Int = 44_100) -> Data {
        let sampleCount = max(1, Int(Double(sampleRate) * duration))
        let fade = max(1, min(sampleCount / 4, Int(Double(sampleRate) * 0.01)))
        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            var env = 1.0
            if i < fade { env = Double(i) / Double(fade) }
            if i > sampleCount - fade { env = Double(sampleCount - i) / Double(fade) }
            let v = sin(2 * .pi * frequency * Double(i) / Double(sampleRate)) * volume * env
            samples[i] = Int16(max(-1, min(1, v)) * Double(Int16.max))
        }
        return wav(samples: samples, sampleRate: sampleRate)
    }

    /// 兩聲短嗶（通過照相點時使用）。
    public static func doubleBeep(frequency: Double = 900, sampleRate: Int = 44_100) -> Data {
        let one = pcmSamples(frequency: frequency, duration: 0.09, sampleRate: sampleRate)
        let gap = [Int16](repeating: 0, count: Int(Double(sampleRate) * 0.07))
        return wav(samples: one + gap + one, sampleRate: sampleRate)
    }

    static func pcmSamples(frequency: Double, duration: Double, sampleRate: Int) -> [Int16] {
        let data = wavData(frequency: frequency, duration: duration, sampleRate: sampleRate)
        let body = data.subdata(in: 44..<data.count)
        var out = [Int16](repeating: 0, count: body.count / 2)
        for i in 0..<out.count {
            let lo = UInt16(body[body.startIndex + i * 2])
            let hi = UInt16(body[body.startIndex + i * 2 + 1])
            out[i] = Int16(bitPattern: lo | (hi << 8))
        }
        return out
    }

    static func wav(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2
        func append32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)            // fmt chunk size
        append16(1)             // PCM
        append16(1)             // mono
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(2)             // block align
        append16(16)            // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        for s in samples { append16(UInt16(bitPattern: s)) }
        return data
    }
}
