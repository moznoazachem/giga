// Превращение номеров, которые выдаёт модель, обратно в текст.
//
// Модель говорит кусочками слов (SentencePiece). Чтобы собрать из них текст,
// нужен только список этих кусочков — он лежит в файле v3_e2e_rnnt_tokenizer.model.
// Файл записан в формате protobuf, но нам нужно одно поле, поэтому разбираем
// его сами: тащить ради этого целую библиотеку на C++ незачем.
//
//   ModelProto  { repeated SentencePiece pieces = 1 }
//   SentencePiece { optional string piece = 1 }

import Foundation

struct Tokenizer {
    let pieces: [String]
    /// Номер «пустышки» — модель выдаёт его, когда сказать нечего.
    var blankId: Int { pieces.count }

    init(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var out: [String] = []
        var i = 0

        while i < data.count {
            guard let (tag, next) = Tokenizer.varint(data, i) else { break }
            i = next
            let field = tag >> 3
            let wire = tag & 7

            if field == 1 && wire == 2 {
                guard let (len, afterLen) = Tokenizer.varint(data, i) else { break }
                i = afterLen
                let end = i + Int(len)
                guard end <= data.count else { break }
                out.append(Tokenizer.piece(data, i, end))
                i = end
            } else {
                guard let skipped = Tokenizer.skip(data, i, wire) else { break }
                i = skipped
            }
        }

        guard !out.isEmpty else {
            throw OrtError.failed("не разобрал токенизатор: \(path)")
        }
        pieces = out
    }

    /// Внутри SentencePiece берём первое поле — саму строку кусочка.
    private static func piece(_ d: Data, _ from: Int, _ to: Int) -> String {
        var i = from
        while i < to {
            guard let (tag, next) = varint(d, i) else { break }
            i = next
            let field = tag >> 3, wire = tag & 7
            if field == 1 && wire == 2 {
                guard let (len, afterLen) = varint(d, i) else { break }
                i = afterLen
                let end = min(i + Int(len), to)
                return String(data: d.subdata(in: i..<end), encoding: .utf8) ?? ""
            }
            guard let skipped = skip(d, i, wire) else { break }
            i = skipped
        }
        return ""
    }

    private static func varint(_ d: Data, _ from: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0, shift: UInt64 = 0, i = from
        while i < d.count {
            let b = d[d.startIndex + i]
            result |= UInt64(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private static func skip(_ d: Data, _ from: Int, _ wire: UInt64) -> Int? {
        switch wire {
        case 0: return varint(d, from)?.1
        case 1: return from + 8 <= d.count ? from + 8 : nil
        case 2:
            guard let (len, after) = varint(d, from) else { return nil }
            let end = after + Int(len)
            return end <= d.count ? end : nil
        case 5: return from + 4 <= d.count ? from + 4 : nil
        default: return nil
        }
    }

    /// Собирает текст: кусочки склеиваются, знак ▁ означает пробел перед словом.
    func decode(_ ids: [Int]) -> String {
        var s = ""
        for id in ids where id >= 0 && id < pieces.count { s += pieces[id] }
        return s.replacingOccurrences(of: "\u{2581}", with: " ")
                .trimmingCharacters(in: .whitespaces)
    }
}
