// Чтение записей и нарезка длинных на куски по паузам.

import Foundation

enum Audio {
    /// Читает 16-битный моно wav. Ничего лишнего: именно такой пишет само приложение.
    static func readWav(_ path: String) throws -> (samples: [Float], rate: Int) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count > 44 else { throw OrtError.failed("слишком короткий wav: \(path)") }

        func u32(_ o: Int) -> UInt32 {
            UInt32(data[o]) | UInt32(data[o+1]) << 8 | UInt32(data[o+2]) << 16 | UInt32(data[o+3]) << 24
        }
        func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | UInt16(data[o+1]) << 8 }

        guard u32(0) == 0x4646_4952 else { throw OrtError.failed("это не wav: \(path)") }

        var rate = 16000, channels = 1, bits = 16
        var i = 12
        while i + 8 <= data.count {
            let id = u32(i), size = Int(u32(i + 4))
            let body = i + 8
            if id == 0x2074_6D66 {                    // "fmt "
                channels = Int(u16(body + 2))
                rate = Int(u32(body + 4))
                bits = Int(u16(body + 14))
            } else if id == 0x6174_6164 {             // "data"
                guard bits == 16 else { throw OrtError.failed("нужен 16-битный wav, а тут \(bits)") }
                let end = min(body + size, data.count)
                var out = [Float]()
                out.reserveCapacity((end - body) / 2 / max(1, channels))
                var p = body
                while p + 2 * channels <= end {
                    let v = Int16(bitPattern: UInt16(data[p]) | UInt16(data[p+1]) << 8)
                    out.append(Float(v) / 32768.0)    // берём первый канал
                    p += 2 * channels
                }
                return (out, rate)
            }
            i = body + size + (size % 2)
        }
        throw OrtError.failed("в wav нет данных: \(path)")
    }

    /// Середины пауз — кандидаты в точки разреза.
    /// Повторяет ffmpeg silencedetect: тише порога дольше заданного времени.
    static func silences(_ x: [Float], rate: Int,
                         noiseDb: Float = -35, minSeconds: Double = 0.3) -> [Double] {
        let порог = powf(10.0, noiseDb / 20.0)
        let минимум = Int(minSeconds * Double(rate))
        var точки: [Double] = []
        var начало = -1

        for i in 0..<x.count {
            if abs(x[i]) < порог {
                if начало < 0 { начало = i }
            } else if начало >= 0 {
                if i - начало >= минимум {
                    точки.append(Double(начало + i) / 2.0 / Double(rate))
                }
                начало = -1
            }
        }
        return точки
    }

    /// Границы кусков: не длиннее предела, разрез — по последней паузе перед ним.
    static func chunkBounds(total: Double, silences: [Double],
                            maxChunk: Double) -> [(Double, Double)] {
        var bounds: [(Double, Double)] = []
        var pos = 0.0
        while total - pos > maxChunk {
            let candidates = silences.filter { $0 > pos + 3 && $0 <= pos + maxChunk }
            let cut = candidates.last ?? (pos + maxChunk)
            bounds.append((pos, cut))
            pos = cut
        }
        bounds.append((pos, total))
        return bounds
    }
}
