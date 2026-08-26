// Запись с микрофона — по-висперному.
//
// Раньше мы просили у устройства сразу 16 кГц/16 бит (AVAudioRecorder
// с жёсткими настройками), и частоту на лету пересчитывал драйвер.
// Настоящие драйверы с этим справляются, а виртуальные (Parallels, VMware,
// UTM) на таком запросе теряют куски звука — диктовка приходила с дырками.
//
// Теперь берём звук в РОДНОМ формате устройства (драйверу — самая простая
// работа «отдай как есть»), а в 16 кГц для модели пересчитываем сами,
// штатным AVAudioConverter. Так пишут MacWhisper и остальные серьёзные
// диктовалки. Бонус: движок держим готовым между записями — старт быстрее,
// и начало фразы не съедается.

import AVFoundation

final class Mic {
    /// Движок живёт между записями: повторный старт заметно быстрее первого.
    /// Микрофон между записями НЕ открыт (оранжевой точки нет) — устройство
    /// включается только на время start()…stop().
    private var engine: AVAudioEngine?
    private var chunks: [[Float]] = []   // куски записи в родной частоте, моно
    private var nativeRate: Double = 0
    private let lock = NSLock()
    private(set) var isRecording = false

    init() {
        // Сменился микрофон или его формат (воткнули наушники, виртуалка
        // передёрнула устройство) — старый движок больше не годится,
        // следующая запись соберёт себе новый.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isRecording else { return }
            self.engine = nil
        }
    }

    /// Запускает запись. Бросает, если устройство не завелось, — тогда
    /// звука точно нет и надо честно сказать об этом человеку.
    func start() throws {
        guard !isRecording else { return }
        let e = engine ?? AVAudioEngine()
        let input = e.inputNode
        let fmt = input.inputFormat(forBus: 0) // родной формат устройства
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            engine = nil
            throw OrtError.failed("микрофон не отдал формат звука")
        }
        nativeRate = fmt.sampleRate
        lock.lock(); chunks = []; lock.unlock()

        input.removeTap(onBus: 0) // на случай хвоста от прошлого раза
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self, let data = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            guard n > 0 else { return }
            let каналов = Int(buf.format.channelCount)
            var mono = [Float](repeating: 0, count: n)
            for c in 0..<каналов {
                let p = data[c]
                for i in 0..<n { mono[i] += p[i] }
            }
            if каналов > 1 {
                let k = Float(каналов)
                for i in 0..<n { mono[i] /= k }
            }
            self.lock.lock(); self.chunks.append(mono); self.lock.unlock()
        }

        e.prepare()
        do {
            try e.start()
        } catch {
            input.removeTap(onBus: 0)
            engine = nil // сломанный движок не переиспользуем
            throw error
        }
        engine = e
        isRecording = true
    }

    /// Останавливает запись и отдаёт всё записанное: 16 кГц, моно.
    func stop() -> [Float] {
        guard isRecording, let e = engine else { return [] }
        e.inputNode.removeTap(onBus: 0)
        e.stop() // сам движок оставляем — следующий старт быстрее
        isRecording = false
        lock.lock()
        let native = chunks.flatMap { $0 }
        chunks = []
        lock.unlock()
        return Self.resample(native, from: nativeRate, to: 16000)
    }

    /// Пересчёт частоты штатным конвертером Apple — тем же классом качества,
    /// что делает система, только у нас, а не в драйвере.
    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard !x.isEmpty else { return [] }
        guard from != to else { return x }
        guard
            let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from,
                                      channels: 1, interleaved: false),
            let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to,
                                       channels: 1, interleaved: false),
            let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                         frameCapacity: AVAudioFrameCount(x.count)),
            let conv = AVAudioConverter(from: inFmt, to: outFmt)
        else { return [] }

        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer {
            inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count)
        }

        var out: [Float] = []
        out.reserveCapacity(Int(Double(x.count) * to / from) + 16)
        var подано = false
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 8192)
            else { break }
            var err: NSError?
            let st = conv.convert(to: outBuf, error: &err) { _, status in
                if подано {
                    status.pointee = .endOfStream
                    return nil
                }
                подано = true
                status.pointee = .haveData
                return inBuf
            }
            if let err { NSLog("Гига Писарь: ресемплинг — \(err)"); break }
            if outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(
                    start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            }
            if st == .endOfStream || st == .error || outBuf.frameLength == 0 { break }
        }
        return out
    }
}
