// Превращение звуковой волны в лог-мел-спектрограмму — ровно то, что ждёт энкодер.
//
// Это самое хрупкое место всего распознавания: разойтись здесь с оригиналом
// значит получить на выходе не «чуть хуже», а бессмыслицу. Поэтому всё
// повторяет питоновский giga_core.py шаг в шаг, а сверка живёт в scripts/сверка.py.
//
// Преобразование Фурье считаем умножением на заранее посчитанную матрицу
// синусов и косинусов: длина окна 320 не степень двойки, готовые быстрые
// преобразования её не любят, а матрица честна, проста и на таких размерах
// достаточно быстра.

import Accelerate
import Foundation

struct FeatureConfig {
    var sampleRate = 16000
    var nMels = 64
    var nFFT = 320
    var winLength = 320
    var hopLength = 160
    var center = false
}

final class Features {
    let cfg: FeatureConfig
    private let nFreqs: Int
    private let window: [Float]
    private let cosT: [Float]      // [nFFT × nFreqs]
    private let sinT: [Float]      // [nFFT × nFreqs]
    private let fb: [Float]        // [nFreqs × nMels]

    init(_ cfg: FeatureConfig) {
        self.cfg = cfg
        nFreqs = cfg.nFFT / 2 + 1

        // Окно Ханна, периодическое — как torch.hann_window
        window = (0..<cfg.winLength).map {
            0.5 - 0.5 * cosf(2.0 * Float.pi * Float($0) / Float(cfg.winLength))
        }

        // Матрицы преобразования Фурье
        var c = [Float](repeating: 0, count: cfg.nFFT * nFreqs)
        var s = [Float](repeating: 0, count: cfg.nFFT * nFreqs)
        for n in 0..<cfg.nFFT {
            for k in 0..<nFreqs {
                let a = 2.0 * Double.pi * Double(k) * Double(n) / Double(cfg.nFFT)
                c[n * nFreqs + k] = Float(cos(a))
                s[n * nFreqs + k] = Float(-sin(a))
            }
        }
        cosT = c
        sinT = s

        fb = Features.melFilterbank(nFreqs: nFreqs, fMin: 0,
                                    fMax: Double(cfg.sampleRate) / 2,
                                    nMels: cfg.nMels, sampleRate: cfg.sampleRate)
    }

    /// Сколько кадров получится — та же формула, что в оригинале.
    func outLen(_ samples: Int) -> Int {
        cfg.center ? samples / cfg.hopLength + 1
                   : (samples - cfg.winLength) / cfg.hopLength + 1
    }

    /// Шкала мелов, вариант htk — по умолчанию именно он.
    private static func hzToMel(_ f: Double) -> Double { 2595.0 * log10(1.0 + f / 700.0) }
    private static func melToHz(_ m: Double) -> Double { 700.0 * (pow(10.0, m / 2595.0) - 1.0) }

    /// Треугольные фильтры, как в torchaudio.functional.melscale_fbanks (norm=None).
    private static func melFilterbank(nFreqs: Int, fMin: Double, fMax: Double,
                                      nMels: Int, sampleRate: Int) -> [Float] {
        let top = Double(sampleRate / 2)
        let allFreqs = (0..<nFreqs).map { top * Double($0) / Double(nFreqs - 1) }
        let mMin = hzToMel(fMin), mMax = hzToMel(fMax)
        let fPts = (0..<(nMels + 2)).map {
            melToHz(mMin + (mMax - mMin) * Double($0) / Double(nMels + 1))
        }
        var fDiff = [Double](repeating: 0, count: nMels + 1)
        for i in 0..<(nMels + 1) { fDiff[i] = fPts[i + 1] - fPts[i] }

        var out = [Float](repeating: 0, count: nFreqs * nMels)
        for i in 0..<nFreqs {
            for m in 0..<nMels {
                let down = -(fPts[m] - allFreqs[i]) / fDiff[m]
                let up = (fPts[m + 2] - allFreqs[i]) / fDiff[m + 1]
                out[i * nMels + m] = Float(max(0.0, min(down, up)))
            }
        }
        return out
    }

    /// Волна → признаки [nMels × кадры], разложенные подряд по строкам.
    func compute(_ wave: [Float]) -> (values: [Float], frames: Int) {
        var x = wave
        if cfg.center {
            let pad = cfg.nFFT / 2
            var padded = [Float](repeating: 0, count: x.count + 2 * pad)
            for i in 0..<pad { padded[i] = x[min(pad - i, x.count - 1)] }
            for i in 0..<x.count { padded[pad + i] = x[i] }
            for i in 0..<pad { padded[pad + x.count + i] = x[max(0, x.count - 2 - i)] }
            x = padded
        }

        let n = max(0, (x.count - cfg.nFFT) / cfg.hopLength + 1)
        if n == 0 { return ([], 0) }

        // кадры с наложенным окном: [n × nFFT]
        var frames = [Float](repeating: 0, count: n * cfg.nFFT)
        for f in 0..<n {
            let off = f * cfg.hopLength
            for j in 0..<cfg.nFFT { frames[f * cfg.nFFT + j] = x[off + j] * window[j] }
        }

        var re = [Float](repeating: 0, count: n * nFreqs)
        var im = [Float](repeating: 0, count: n * nFreqs)
        matmul(frames, cosT, &re, m: n, k: cfg.nFFT, nn: nFreqs)
        matmul(frames, sinT, &im, m: n, k: cfg.nFFT, nn: nFreqs)

        // мощность = re² + im²
        var power = [Float](repeating: 0, count: n * nFreqs)
        vDSP_vsq(re, 1, &power, 1, vDSP_Length(n * nFreqs))
        vDSP_vsq(im, 1, &im, 1, vDSP_Length(n * nFreqs))
        vDSP_vadd(power, 1, im, 1, &power, 1, vDSP_Length(n * nFreqs))

        // мел-полосы: [n × nMels]
        var mel = [Float](repeating: 0, count: n * cfg.nMels)
        matmul(power, fb, &mel, m: n, k: nFreqs, nn: cfg.nMels)

        // логарифм с обрезкой, как в оригинале
        for i in 0..<mel.count { mel[i] = logf(min(max(mel[i], 1e-9), 1e9)) }

        // энкодер ждёт [1, nMels, кадры] — переворачиваем
        var out = [Float](repeating: 0, count: cfg.nMels * n)
        for f in 0..<n {
            for m in 0..<cfg.nMels { out[m * n + f] = mel[f * cfg.nMels + m] }
        }
        return (out, n)
    }

    private func matmul(_ a: [Float], _ b: [Float], _ c: inout [Float],
                        m: Int, k: Int, nn: Int) {
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(m), Int32(nn), Int32(k),
                    1.0, a, Int32(k), b, Int32(nn), 0.0, &c, Int32(nn))
    }
}
