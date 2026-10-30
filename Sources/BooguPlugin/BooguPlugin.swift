import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXBoogu
import MLXToolKit

// gaea-plugin-boogu: Boogu-Image 0.1 (Apache-2.0) as a Gaea plugin, on boogu-image-swift through MLXServeEngine
// (Gaea AB-T-0387). An OmniGen2-lineage DiT conditioned by Qwen3-VL-8B, with the FLUX.1 VAE.
//
// - boogu: the Base checkpoint, 30 steps at CFG 3.5, with negative prompts.
// - boogu-turbo: distilled to 4 steps without CFG.
// - boogu-edit: the Edit checkpoint, structure-preserving instruction edits of one image, 50 steps at true CFG 4.
//
// Every model has the package's DiT quants as lanes: bf16 (the default and the fastest), int8 and int4; Turbo has no
// int4, which its distilled DiT doesn't survive. The footprints are the package's, measured after the conditioner is
// evicted (boogu-image-swift 0.5.0, AB-R-0663): the 16 GB Qwen3-VL conditioner loads for each job, encodes, and is
// freed before the denoise, so it is activation, not residency. Weights come from the models root Gaea sends in
// configure (MLXEngine's store by default); the engine materializes a missing tier and the conditioner.
//
// Sizes are the package's measured envelope: 512–2048 px a side in multiples of 16, generation up to 1536² in area and
// editing up to 1024² (an edit at 1536² measured 53 GB of activation at 108 s a step, AB-T-0204).

public let minSide = 512, maxSide = 2048, grid = 16
public let maxGeneratePixels = BooguImagePackage.maxOutputPixels, maxEditPixels = BooguImagePackage.maxEditOutputPixels

public enum Variant: String, Sendable, CaseIterable {
    case base, turbo, edit

    public var modelID: String {
        switch self {
        case .base: "boogu"
        case .turbo: "boogu-turbo"
        case .edit: "boogu-edit"
        }
    }

    public var defaultSteps: Int {
        switch self {
        case .base: 30
        case .turbo: 4
        case .edit: 50
        }
    }

    public var defaultGuidance: Double {
        switch self {
        case .base: 3.5
        case .turbo: 1
        case .edit: 4
        }
    }

    /// The published tiers: Turbo has no int4.
    public var quants: [Quant] { self == .turbo ? [.bf16, .int8] : [.bf16, .int8, .int4] }

    /// The package configuration for one lane; boogu-inproc builds the same one.
    public func configuration(quant: Quant) -> BooguImageConfiguration {
        switch self {
        case .base: .base(quant: quant)
        case .turbo: .turbo(quant: quant)
        case .edit: .edit(quant: quant)
        }
    }

    /// The size an edit is drawn at when the request asks none: the package's.
    public var defaultEditSize: Int { configuration(quant: .bf16).defaultEditSize }
}

/// The MES size a job asks for (`size`, or `aspect` with `megapixels`, Image profile §2), else nil.
func requestedSize(_ job: Job) throws -> (Int, Int)? {
    if let size = job.param("size") {
        guard let w = size["width"]?.intValue, let h = size["height"]?.intValue, w > 0, h > 0 else {
            throw GPPError(.invalidRequest, "size is {width, height} in pixels.")
        }
        return (w, h)
    }
    if let aspect = job.param("aspect")?.stringValue {
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw GPPError(.invalidRequest, "aspect is W:H, e.g. 16:9.") }
        let pixels = (job.param("megapixels")?.doubleValue ?? 1.0) * 1_000_000
        let height = (pixels * parts[1] / parts[0]).squareRoot()
        return (Int(height * parts[0] / parts[1]), Int(height))
    }
    return nil
}

/// Fits a size to Boogu's envelope: scaled down to the area cap, keeping the aspect, then floored to multiples of 16.
/// A change is reported as `size_snapped`; a side outside 512–2048 is refused.
public func snapped(_ size: (Int, Int), maxPixels: Int) throws -> (width: Int, height: Int, warning: Warning?) {
    var (w, h) = (Double(size.0), Double(size.1))
    if w * h > Double(maxPixels) {
        let scale = (Double(maxPixels) / (w * h)).squareRoot()
        w *= scale
        h *= scale
    }
    let width = Int(w) / grid * grid, height = Int(h) / grid * grid
    let cap = Int(Double(maxPixels).squareRoot())
    guard min(width, height) >= minSide, max(width, height) <= maxSide else {
        throw GPPError(.invalidRequest, "Boogu draws \(minSide)–\(maxSide) px a side and at most \(cap)² in area; "
            + "\(size.0)×\(size.1) doesn't fit.", detail: ["param": "size"])
    }
    let warning = (width, height) == size ? nil : Warning(
        code: "size_snapped", message: "Drew \(width)×\(height) for \(size.0)×\(size.1): multiples of 16, at most \(cap)² in area.",
        param: "size")
    return (width, height, warning)
}

/// The run's settings shared by generate and edit: steps, guidance, seed, and the warnings for what the model ignores.
struct Shared {
    var steps: Int
    var guidance: Double
    var negative: String?
    var seed: UInt64
    var count: Int
    var warnings: [Warning] = []

    /// `counted`: image.generate takes MES `count`; image.edit has one output and no count.
    init(_ job: Job, variant: Variant, counted: Bool = true) throws {
        steps = job.param("x-boogu.steps")?.intValue ?? variant.defaultSteps
        guard (1...100).contains(steps) else { throw GPPError(.invalidRequest, "x-boogu.steps is 1–100.") }
        let distilled = variant == .turbo
        guidance = distilled ? 1 : job.param("x-boogu.guidance")?.doubleValue ?? variant.defaultGuidance
        guard (1...20).contains(guidance) else { throw GPPError(.invalidRequest, "x-boogu.guidance is 1–20.") }
        count = counted ? job.param("count")?.intValue ?? 1 : 1
        guard (1...8).contains(count) else { throw GPPError(.invalidRequest, "count is 1–8.") }
        let negative = job.param("negative_prompt")?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if distilled, negative != nil {
            warnings.append(Warning(code: "negative_prompt_ignored",
                                    message: "Boogu Turbo is distilled to run without CFG, so a negative prompt does nothing; "
                                        + "Boogu (Base) honours it.",
                                    param: "negative_prompt"))
        }
        self.negative = distilled ? nil : negative
        if job.param("prompt_enhance")?.stringValue == "on" {
            warnings.append(Warning(code: "prompt_enhance_ignored", message: "This plugin doesn't rewrite prompts; Gaea's enhancer does.",
                                    param: "prompt_enhance"))
        }
        // Image profile §2: a request without a seed still gets one, reported in effective.
        seed = job.seed ?? UInt64.random(in: 0..<(1 << 31))
    }

    func effective(width: Int, height: Int, counted: Bool = true) -> [String: JSONValue] {
        var values: [String: JSONValue] = [
            "size": ["width": .int(Int64(width)), "height": .int(Int64(height))],
            "seed": .int(Int64(seed)), "x-boogu.steps": .int(Int64(steps)),
        ]
        if counted { values["count"] = .int(Int64(count)) }
        if guidance > 1 { values["x-boogu.guidance"] = .double(guidance) }
        if let negative { values["negative_prompt"] = .string(negative) }
        return values
    }
}

/// MES image.generate: one engine call per image, each with seed + i.
func generate(_ variant: Variant) -> EngineOperation {
    EngineOperation("image.generate", outputNames: ["image": "images"]) { job in
        guard let prompt = try job.text("prompt"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GPPError(.invalidRequest, "image.generate needs a prompt.")
        }
        let size = try snapped(try requestedSize(job) ?? (1024, 1024), maxPixels: maxGeneratePixels)
        var shared = try Shared(job, variant: variant)
        if let warning = size.warning { shared.warnings.insert(warning, at: 0) }
        let effective = shared.effective(width: size.width, height: size.height)
        return (0..<shared.count).map { i in
            EngineCall(T2IRequest(prompt: prompt, negativePrompt: shared.negative, width: size.width, height: size.height,
                                  steps: shared.steps, guidanceScale: shared.guidance, seed: shared.seed + UInt64(i)),
                       effective: effective, warnings: shared.warnings)
        }
    }
}

/// MES image.edit: one image edited to the instruction, keeping its structure. At the size asked, else at the package's
/// 768² (as pixel-agency-image-engine v0.9.1, which sends none); the host brings the result back to the image's size
/// (Image profile §3). One output.
func edit(_ variant: Variant) -> EngineOperation {
    EngineOperation("image.edit", outputNames: ["image": "image"]) { job in
        guard let instruction = try job.text("instruction"), !instruction.isEmpty else {
            throw GPPError(.invalidRequest, "image.edit needs an instruction.")
        }
        let count = job.inputs["images"]?.count ?? 0
        guard count == 1 else {
            throw GPPError(.invalidRequest, "Boogu Edit edits one image; got \(count).", detail: ["param": "images"])
        }
        let asked = try requestedSize(job)
        let size = try snapped(asked ?? (variant.defaultEditSize, variant.defaultEditSize), maxPixels: maxEditPixels)
        var shared = try Shared(job, variant: variant, counted: false)
        if let warning = size.warning { shared.warnings.insert(warning, at: 0) }
        if job.param("strength") != nil {
            shared.warnings.append(Warning(code: "param_ignored",
                                           message: "Boogu Edit conditions on the whole image; strength does nothing.",
                                           param: "strength"))
        }
        let image = try job.image("images", index: 0)
        return [EngineCall(IEditRequest(images: [image], prompt: instruction, negativePrompt: shared.negative,
                                        width: asked == nil ? nil : size.width, height: asked == nil ? nil : size.height,
                                        steps: shared.steps, guidanceScale: shared.guidance, seed: shared.seed),
                           effective: shared.effective(width: size.width, height: size.height, counted: false),
                           warnings: shared.warnings)]
    }
}

public func lanes(_ variant: Variant) -> [LaneDefinition] {
    variant.quants.map { quant in
        LaneDefinition(id: quant.rawValue, default: quant == .bf16, configuration: variant.configuration(quant: quant))
    }
}

let apache: JSONValue = ["spdx": "Apache-2.0", "commercial_use": true, "terms_url": "https://www.apache.org/licenses/LICENSE-2.0"]
let generateLimits = PluginManifest.Limits(maxPixels: maxGeneratePixels, minSide: minSide, maxSide: maxSide, sizeMultiple: grid)
let editLimits = PluginManifest.Limits(maxPixels: maxEditPixels, minSide: minSide, maxSide: maxSide, sizeMultiple: grid,
                                       maxImages: 1)

func params(_ variant: Variant) -> JSONValue {
    var properties: [String: JSONValue] = [
        "x-boogu.steps": [
            "type": "integer", "minimum": 1, "maximum": 100, "default": .int(Int64(variant.defaultSteps)),
            "description": .string(variant == .turbo ? "Denoising steps. Boogu Turbo is distilled for 4."
                                                     : "Denoising steps; more is slower and finer."),
            "x-mes-ui": ["widget": "slider", "label": "Steps", "advanced": true],
        ],
    ]
    if variant != .turbo {
        properties["x-boogu.guidance"] = [
            "type": "number", "minimum": 1, "maximum": 20, "default": .double(variant.defaultGuidance),
            "description": "Classifier-free guidance: how strongly the prompt (and against the negative prompt) steers. 1 turns CFG off.",
            "x-mes-ui": ["widget": "slider", "label": "Guidance", "advanced": true],
        ]
    }
    return ["type": "object", "properties": .object(properties), "additionalProperties": false]
}

func offerModel(_ variant: Variant) -> JSONValue {
    var model: [String: JSONValue] = ["id": .string(variant.modelID), "license": apache, "memory_class": "large"]
    switch variant {
    case .base:
        model["title"] = "Boogu Image"
        model["speed_class"] = "slow"
        model["quality_tiers"] = ["standard", "best"]
        model["notes"] = "Photorealistic generation with Qwen3-VL instruction conditioning: 30 steps with CFG, honours negative prompts. Up to 1536² in area."
    case .turbo:
        model["title"] = "Boogu Image Turbo"
        model["speed_class"] = "fast"
        model["quality_tiers"] = ["draft", "standard"]
        model["notes"] = "Distilled to 4 steps without CFG: negative prompts do nothing. Up to 1536² in area."
    case .edit:
        model["title"] = "Boogu Image Edit"
        model["speed_class"] = "slow"
        model["quality_tiers"] = ["standard", "best"]
        model["notes"] = .string("Structure-preserving instruction edits of one image (\"make it night with snow\"): 50 steps with true CFG. "
            + "Drawn at 768² unless a size is asked, up to 1024², and returned at the image's size; strength does nothing.")
    }
    return .object(model)
}

public let booguPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.boogu",
    version: "0.1.0",
    minGaea: "0.7.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-boogu",
    title: "Boogu Image",
    summary: "Boogu-Image 0.1 (Apache-2.0): an OmniGen2-lineage DiT conditioned by Qwen3-VL-8B, with the FLUX.1 VAE. "
        + "Generation (Base, and the 4-step Turbo) and structure-preserving instruction editing.",
    license: "Apache-2.0",
    executable: "gaea-boogu-worker",
    models: [
        .engine(BooguImagePackage.self, id: Variant.base.modelID, title: "Boogu Image", lanes: lanes(.base),
                operations: [generate(.base)]),
        .engine(BooguImagePackage.self, id: Variant.turbo.modelID, title: "Boogu Image Turbo", lanes: lanes(.turbo),
                operations: [generate(.turbo)]),
        .engine(BooguImagePackage.self, id: Variant.edit.modelID, title: "Boogu Image Edit", lanes: lanes(.edit),
                operations: [edit(.edit)]),
    ],
    offers: [
        PluginManifest.Offer(operation: "image.generate", profile: "image", model: offerModel(.base),
                             params: params(.base), defaults: ["count": 1], limits: generateLimits),
        PluginManifest.Offer(operation: "image.generate", profile: "image", model: offerModel(.turbo),
                             params: params(.turbo), defaults: ["count": 1], limits: generateLimits),
        PluginManifest.Offer(operation: "image.edit", profile: "image", model: offerModel(.edit),
                             params: params(.edit), limits: editLimits),
    ])
