import Foundation
import CoreML
import Darwin

// A separate helper keeps Python's Blender runtime independent of Core ML's
// native dependencies. Models are compiled during release packaging.
struct PredictionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw PredictionFailure(message: "Usage: ppm_predict <compiled.mlmodelc> <float32-input-file>")
    }
    let configuration = MLModelConfiguration()
    // Retain float32 CPU behavior across machines; GPU/ANE is a separate
    // numerical change and is deliberately not selected implicitly.
    configuration.computeUnits = .cpuOnly
    let model = try MLModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), configuration: configuration)
    guard let constraint = model.modelDescription.inputDescriptionsByName["images"]?.multiArrayConstraint else {
        throw PredictionFailure(message: "The model has no images tensor")
    }
    let shape = constraint.shape.map(\.intValue)
    guard shape.count == 4, shape[0] == 1, [1, 3, 9, 25, 2, 6, 18, 50].contains(shape[1]),
          shape[2] == 256, shape[3] == 256, constraint.dataType == .float32 else {
        throw PredictionFailure(message: "Unexpected Core ML input shape or precision")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let count = shape.reduce(1, *)
    guard data.count == count * MemoryLayout<Float>.stride else {
        throw PredictionFailure(message: "Input byte count does not match the selected model")
    }
    let input = try MLMultiArray(shape: constraint.shape, dataType: .float32)
    var stride = 1
    for index in shape.indices.reversed() {
        guard input.strides[index].intValue == stride else {
            throw PredictionFailure(message: "Core ML allocated a non-contiguous input")
        }
        stride *= shape[index]
    }
    data.withUnsafeBytes { bytes in
        input.dataPointer.copyMemory(from: bytes.baseAddress!, byteCount: data.count)
    }
    let provider = try MLDictionaryFeatureProvider(dictionary: ["images": MLFeatureValue(multiArray: input)])
    let prediction = try model.prediction(from: provider)
    guard let output = prediction.featureValue(for: "parameters")?.multiArrayValue,
          output.count == 188, output.dataType == .float32 else {
        throw PredictionFailure(message: "The model did not return 188 float32 parameters")
    }
    let values = (0..<output.count).map { output[$0].doubleValue }
    guard values.allSatisfy(\.isFinite) else {
        throw PredictionFailure(message: "Core ML produced non-finite parameters")
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: values))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Core ML prediction failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
