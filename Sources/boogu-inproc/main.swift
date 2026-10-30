import BooguPlugin
import Foundation
import MLXBoogu
import MLXServeCore
import MLXToolKit

// The in-process reference for the plugin: one Boogu lane loaded by MLXServeEngine in this process, with the lane
// configuration the worker uses (BooguPlugin) and the request it would build. A cold run then a warm one; the first
// image is written to --out, and one JSON line of timings is printed. Not part of the plugin bundle.
//
//   boogu-inproc [--model boogu | boogu-turbo | boogu-edit] [--lane bf16 | int8 | int4] [--prompt <text>]
//                [--negative <text>] [--width 1024] [--height 1024] [--steps N] [--guidance G] [--seed 42]
//                [--image <png>] [--models-root <dir>] [--out <png>]
//
// boogu-edit takes one --image and the prompt as its instruction. Without --width and --height an edit is drawn at the
// package's size, as the worker sends none.

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let started = ContinuousClock.now
let modelID = option("--model") ?? "boogu"
guard let variant = Variant.allCases.first(where: { $0.modelID == modelID }) else {
    FileHandle.standardError.write(Data("unknown model \(modelID)\n".utf8))
    exit(2)
}
let quant = Quant(rawValue: option("--lane") ?? "bf16") ?? .bf16
let prompt = option("--prompt") ?? "a red fox sitting in a snowy forest at sunrise, photorealistic"
let negative = option("--negative")
let width = Int(option("--width") ?? "")
let height = Int(option("--height") ?? "")
let steps = Int(option("--steps") ?? "") ?? variant.defaultSteps
let guidance = Double(option("--guidance") ?? "") ?? variant.defaultGuidance
let seed = UInt64(option("--seed") ?? "") ?? 42
let imagePath = option("--image")
let outPath = option("--out")
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)

var result: [String: Any] = ["model": modelID, "lane": quant.rawValue, "steps": steps, "guidance": guidance, "seed": seed]
if let width { result["width"] = width }
if let height { result["height"] = height }

// The budget Gaea sends a worker on a large Mac (wiresWeights off, the automatic pool cap).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(modelID)
_ = try await engine.register(BooguImagePackage.registration, configuration: variant.configuration(quant: quant), id: id)

let edit = variant == .edit
var clock = ContinuousClock.now
_ = try await engine.prepare(edit ? .imageEdit : .textToImage, package: id)
result["prepare_s"] = seconds(since: clock)

let request: any CapabilityRequest
if edit {
    guard let imagePath else {
        FileHandle.standardError.write(Data("boogu-edit needs --image\n".utf8))
        exit(2)
    }
    let image = Image(format: imagePath.lowercased().hasSuffix(".png") ? .png : .jpeg,
                      data: try Data(contentsOf: URL(fileURLWithPath: imagePath)))
    request = IEditRequest(images: [image], prompt: prompt, negativePrompt: negative, width: width, height: height,
                           steps: steps, guidanceScale: guidance, seed: seed)
} else {
    request = T2IRequest(prompt: prompt, negativePrompt: negative, width: width ?? 1024, height: height ?? 1024, steps: steps,
                         guidanceScale: guidance, seed: seed)
}

for run in ["run1", "run2"] {
    clock = ContinuousClock.now
    let response = try await engine.run(request, package: id)
    result["\(run)_s"] = seconds(since: clock)
    let image = (response as? T2IResponse)?.image ?? (response as? IEditResponse)?.image
    if run == "run1", let image {
        result["out_width"] = image.width
        result["out_height"] = image.height
        if let outPath { try image.data.write(to: URL(fileURLWithPath: outPath)) }
    }
}
result["cold_s"] = seconds(since: started) - (result["run2_s"] as! Double)

let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
