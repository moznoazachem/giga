// Тонкая обёртка над C-интерфейсом onnxruntime.
// Умеет ровно то, что нужно распознаванию: загрузить модель и прогнать
// через неё несколько тензоров. Ничего лишнего.

import Foundation

let ortApi = OrtGetApiBase().pointee.GetApi(UInt32(ORT_API_VERSION))!

enum OrtError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        if case let .failed(m) = self { return m }
        return "неизвестная ошибка"
    }
}

@inline(__always)
func ortCheck(_ status: OpaquePointer?) throws {
    guard let status else { return }
    let msg = String(cString: ortApi.pointee.GetErrorMessage(status)!)
    ortApi.pointee.ReleaseStatus(status)
    throw OrtError.failed(msg)
}

/// Тензор: числа плюс их форма.
struct Tensor {
    var floats: [Float] = []
    var ints: [Int64] = []
    var shape: [Int64]
    var isInt: Bool { !ints.isEmpty || floats.isEmpty }

    init(floats: [Float], shape: [Int64]) { self.floats = floats; self.shape = shape }
    init(ints: [Int64], shape: [Int64]) { self.ints = ints; self.shape = shape }

    var count: Int { Int(shape.reduce(1, *)) }
}

/// Загруженная модель. Держит сессию открытой, имена входов и выходов узнаёт сама.
final class OrtSession {
    private let session: OpaquePointer
    private let memInfo: OpaquePointer
    let inputNames: [String]
    let outputNames: [String]
    private var inputC: [UnsafePointer<CChar>?] = []
    private var outputC: [UnsafePointer<CChar>?] = []

    init(env: OpaquePointer, path: String, options: OpaquePointer) throws {
        var s: OpaquePointer?
        try ortCheck(ortApi.pointee.CreateSession(env, path, options, &s))
        guard let s else { throw OrtError.failed("не создалась сессия: \(path)") }
        session = s

        var mi: OpaquePointer?
        try ortCheck(ortApi.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mi))
        memInfo = mi!

        var alloc: UnsafeMutablePointer<OrtAllocator>?
        try ortCheck(ortApi.pointee.GetAllocatorWithDefaultOptions(&alloc))

        var nIn = 0, nOut = 0
        try ortCheck(ortApi.pointee.SessionGetInputCount(session, &nIn))
        try ortCheck(ortApi.pointee.SessionGetOutputCount(session, &nOut))

        var ins: [String] = [], outs: [String] = []
        for i in 0..<nIn {
            var n: UnsafeMutablePointer<CChar>?
            try ortCheck(ortApi.pointee.SessionGetInputName(session, i, alloc, &n))
            ins.append(String(cString: n!))
        }
        for i in 0..<nOut {
            var n: UnsafeMutablePointer<CChar>?
            try ortCheck(ortApi.pointee.SessionGetOutputName(session, i, alloc, &n))
            outs.append(String(cString: n!))
        }
        inputNames = ins
        outputNames = outs
        // Имена нужны как C-строки при каждом прогоне — держим копии,
        // чтобы не пересоздавать их на каждое голосовое.
        inputC = ins.map { UnsafePointer(strdup($0)) }
        outputC = outs.map { UnsafePointer(strdup($0)) }
    }

    deinit {
        inputC.forEach { $0.map { free(UnsafeMutableRawPointer(mutating: $0)) } }
        outputC.forEach { $0.map { free(UnsafeMutableRawPointer(mutating: $0)) } }
        ortApi.pointee.ReleaseMemoryInfo(memInfo)
        ortApi.pointee.ReleaseSession(session)
    }

    /// Прогоняет входы в том порядке, в каком их объявляет модель.
    func run(_ inputs: [Tensor]) throws -> [Tensor] {
        precondition(inputs.count == inputNames.count,
                     "модель ждёт \(inputNames.count) входов, дали \(inputs.count)")

        var values: [OpaquePointer?] = []
        defer { values.forEach { ortApi.pointee.ReleaseValue($0) } }

        // Буферы должны жить до конца прогона — onnxruntime не копирует их.
        var floatBufs: [UnsafeMutablePointer<Float>] = []
        var intBufs: [UnsafeMutablePointer<Int64>] = []
        defer {
            floatBufs.forEach { $0.deallocate() }
            intBufs.forEach { $0.deallocate() }
        }

        for t in inputs {
            var v: OpaquePointer?
            var shape = t.shape
            if t.floats.isEmpty && !t.ints.isEmpty {
                let buf = UnsafeMutablePointer<Int64>.allocate(capacity: max(1, t.ints.count))
                buf.update(from: t.ints, count: t.ints.count)
                intBufs.append(buf)
                try ortCheck(ortApi.pointee.CreateTensorWithDataAsOrtValue(
                    memInfo, buf, t.ints.count * MemoryLayout<Int64>.size,
                    &shape, shape.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &v))
            } else {
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: max(1, t.floats.count))
                buf.update(from: t.floats, count: t.floats.count)
                floatBufs.append(buf)
                try ortCheck(ortApi.pointee.CreateTensorWithDataAsOrtValue(
                    memInfo, buf, t.floats.count * MemoryLayout<Float>.size,
                    &shape, shape.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &v))
            }
            values.append(v)
        }

        var outs = [OpaquePointer?](repeating: nil, count: outputNames.count)
        try ortCheck(ortApi.pointee.Run(session, nil,
                                        &inputC, &values, values.count,
                                        &outputC, outputC.count, &outs))
        defer { outs.forEach { ortApi.pointee.ReleaseValue($0) } }

        return try outs.map { try Self.read($0) }
    }

    private static func read(_ value: OpaquePointer?) throws -> Tensor {
        var info: OpaquePointer?
        try ortCheck(ortApi.pointee.GetTensorTypeAndShape(value, &info))
        defer { ortApi.pointee.ReleaseTensorTypeAndShapeInfo(info) }

        var dims = 0
        try ortCheck(ortApi.pointee.GetDimensionsCount(info, &dims))
        var shape = [Int64](repeating: 0, count: dims)
        try ortCheck(ortApi.pointee.GetDimensions(info, &shape, dims))

        var type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
        try ortCheck(ortApi.pointee.GetTensorElementType(info, &type))

        var count = 0
        try ortCheck(ortApi.pointee.GetTensorShapeElementCount(info, &count))

        var raw: UnsafeMutableRawPointer?
        try ortCheck(ortApi.pointee.GetTensorMutableData(value, &raw))

        if type == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 {
            let p = raw!.assumingMemoryBound(to: Int64.self)
            return Tensor(ints: Array(UnsafeBufferPointer(start: p, count: count)), shape: shape)
        }
        if type == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32 {
            let p = raw!.assumingMemoryBound(to: Int32.self)
            return Tensor(ints: UnsafeBufferPointer(start: p, count: count).map(Int64.init),
                          shape: shape)
        }
        let p = raw!.assumingMemoryBound(to: Float.self)
        return Tensor(floats: Array(UnsafeBufferPointer(start: p, count: count)), shape: shape)
    }
}
