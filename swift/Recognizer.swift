// Распознавание речи целиком на Swift: звук → признаки → энкодер →
// жадное декодирование RNN-T → текст. Питон больше не участвует.
//
// Повторяет питоновское ядро giga_core.py шаг в шаг. Расхождения
// проверяются сверкой на наборе записей — см. scripts/сверка-swift.sh.

import Foundation

/// Настройки, вычитанные из yaml рядом с моделью.
struct ModelConfig {
    var features = FeatureConfig()
    var predHidden = 320
    var predLayers = 1

    /// Разбор нужных строк yaml. Полноценный разбор здесь избыточен:
    /// нужны считаные числа, и все ключи в этом файле уникальны по смыслу.
    static func load(_ path: String) -> ModelConfig {
        var c = ModelConfig()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return c }

        func intValue(_ key: String) -> Int? {
            for line in text.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard s.hasPrefix(key + ":") else { continue }
                return Int(s.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
        func boolValue(_ key: String) -> Bool? {
            for line in text.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard s.hasPrefix(key + ":") else { continue }
                return s.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) == "true"
            }
            return nil
        }

        if let v = intValue("features") { c.features.nMels = v }
        if let v = intValue("sample_rate") { c.features.sampleRate = v }
        if let v = intValue("n_fft") { c.features.nFFT = v }
        if let v = intValue("win_length") { c.features.winLength = v }
        if let v = intValue("hop_length") { c.features.hopLength = v }
        if let v = boolValue("center") { c.features.center = v }
        if let v = intValue("pred_hidden") { c.predHidden = v }
        if let v = intValue("pred_rnn_layers") { c.predLayers = v }
        return c
    }
}

final class Recognizer {
    static let modelName = "v3_e2e_rnnt"
    static let maxChunk = 24.0          // предел одного прохода модели — 25 секунд
    static let maxSymbolsPerFrame = 3   // столько букв максимум с одного кадра

    private let encoder: OrtSession
    private let decoder: OrtSession
    private let joint: OrtSession
    private let tokenizer: Tokenizer
    private let features: Features
    private let cfg: ModelConfig
    let modelDir: String

    init(modelDir: String, threads: Int = 0) throws {
        self.modelDir = modelDir

        // Настройки нужны только пока создаются сессии — дальше отпускаем.
        var o: OpaquePointer?
        try ortCheck(ortApi.pointee.CreateSessionOptions(&o))
        guard let options = o else { throw OrtError.failed("не создались настройки сессии") }
        defer { ortApi.pointee.ReleaseSessionOptions(options) }
        let n = threads > 0 ? threads : min(8, ProcessInfo.processInfo.activeProcessorCount)
        try ortCheck(ortApi.pointee.SetIntraOpNumThreads(options, Int32(n)))
        try ortCheck(ortApi.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))

        cfg = ModelConfig.load("\(modelDir)/\(Self.modelName).yaml")
        features = Features(cfg.features)

        encoder = try OrtSession(path: "\(modelDir)/\(Self.modelName)_encoder.onnx", options: options)
        decoder = try OrtSession(path: "\(modelDir)/\(Self.modelName)_decoder.onnx", options: options)
        joint = try OrtSession(path: "\(modelDir)/\(Self.modelName)_joint.onnx", options: options)

        // Токенизатор ищем рядом с моделью: в yaml прописан путь с той машины,
        // где делали экспорт, и на любой другой он не существует.
        tokenizer = try Tokenizer(path: "\(modelDir)/\(Self.modelName)_tokenizer.model")
    }

    /// Распознаёт готовый wav-файл: 16 кГц, моно, 16 бит — ровно такой пишет
    /// само приложение. Длинные записи режутся по паузам.
    func transcribe(wavPath: String) throws -> String {
        let (samples, rate) = try Audio.readWav(wavPath)
        return try transcribe(samples: samples, rate: rate)
    }

    /// Распознаёт запись любой длины: если не влезает в один проход модели,
    /// режется по паузам между фразами, а не посреди слова, и склеивается.
    func transcribe(samples: [Float], rate: Int) throws -> String {
        // Модель обучена на 16 кГц. Другой частоте здесь взяться неоткуда —
        // приложение пишет именно так, — но если придёт, лучше сказать
        // об этом прямо, чем выдать бессмыслицу.
        guard rate == cfg.features.sampleRate else {
            throw OrtError.failed("нужен звук \(cfg.features.sampleRate) Гц, а пришёл \(rate)")
        }
        let total = Double(samples.count) / Double(rate)
        if total <= Self.maxChunk + 1 {
            return try transcribe(wave: samples)
        }
        let bounds = Audio.chunkBounds(total: total,
                                       silences: Audio.silences(samples, rate: rate),
                                       maxChunk: Self.maxChunk)
        var parts: [String] = []
        for (a, b) in bounds {
            let from = min(samples.count, Int(a * Double(rate)))
            let to = min(samples.count, Int(b * Double(rate)))
            if to > from {
                parts.append(try transcribe(wave: Array(samples[from..<to])))
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Распознаёт одну волну (не длиннее предела модели). 16 кГц, моно.
    func transcribe(wave: [Float]) throws -> String {
        let (feats, frames) = features.compute(wave)
        guard frames > 0 else { return "" }

        let encOut = try encoder.run([
            Tensor(floats: feats, shape: [1, Int64(cfg.features.nMels), Int64(frames)]),
            Tensor(ints: [Int64(features.outLen(wave.count))], shape: [1]),
        ])

        let encoded = encOut[0].floats
        let encT = Int(encOut[0].shape[2])
        let encD = Int(encOut[0].shape[1])
        let encLen = min(Int(encOut[1].ints.first ?? Int64(encT)), encT)

        return tokenizer.decode(try greedyRNNT(encoded: encoded, encD: encD,
                                               encT: encT, encLen: encLen))
    }

    /// Жадное декодирование RNN-T для одной записи.
    private func greedyRNNT(encoded: [Float], encD: Int, encT: Int, encLen: Int) throws -> [Int] {
        var hyp: [Int] = []
        let zeros = [Float](repeating: 0, count: cfg.predLayers * cfg.predHidden)
        var h = zeros, c = zeros
        var label = Int64(tokenizer.blankId)
        var started = false      // до первой буквы состояние декодера нулевое

        let stateShape: [Int64] = [Int64(cfg.predLayers), 1, Int64(cfg.predHidden)]

        // кадр энкодера: элемент (0, d, t) лежит по адресу d*encT + t
        var frame = [Float](repeating: 0, count: encD)

        for t in 0..<encLen {
            for d in 0..<encD { frame[d] = encoded[d * encT + t] }

            for _ in 0..<Self.maxSymbolsPerFrame {
                let decOut = try decoder.run([
                    Tensor(ints: [started ? label : Int64(tokenizer.blankId)], shape: [1, 1]),
                    Tensor(floats: started ? h : zeros, shape: stateShape),
                    Tensor(floats: started ? c : zeros, shape: stateShape),
                ])

                // dec приходит как [1,1,320], джойнту нужен [1,320,1] —
                // числа те же, меняется только объявленная форма
                let jointOut = try joint.run([
                    Tensor(floats: frame, shape: [1, Int64(encD), 1]),
                    Tensor(floats: decOut[0].floats, shape: [1, Int64(cfg.predHidden), 1]),
                ])

                let logits = jointOut[0].floats
                var best = 0
                var bestValue = -Float.greatestFiniteMagnitude
                for i in 0..<logits.count where logits[i] > bestValue {
                    bestValue = logits[i]; best = i
                }
                if best == tokenizer.blankId { break }

                hyp.append(best)
                label = Int64(best)
                h = decOut[1].floats
                c = decOut[2].floats
                started = true
            }
        }
        return hyp
    }
}
