# gaea-plugin-boogu

**Boogu-Image 0.1** (an OmniGen2-lineage DiT conditioned by Qwen3-VL-8B, with the FLUX.1 VAE, Apache-2.0) as a
[Gaea](https://github.com/xocialize-code/gaea) plugin. It is built on [GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit)
over [boogu-image-swift](https://github.com/xocialize/boogu-image-swift), runs in its own process, and speaks the Gaea
Plugin Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-boogu
```

## What it offers

| Model | MES operation | Quality tiers | Notes |
|---|---|---|---|
| `boogu` | `image.generate` | standard, best | The Base checkpoint: 30 steps with CFG 3.5, and negative prompts. |
| `boogu-turbo` | `image.generate` | draft, standard | Distilled to 4 steps without CFG. A negative prompt does nothing and is reported `negative_prompt_ignored`. |
| `boogu-edit` | `image.edit` | standard, best | Structure-preserving instruction edits of one image ("make it night with snow"): 50 steps with true CFG 4. Drawn at 768² unless a size is asked (as pixel-agency-image-engine v0.9.1 draws it), and returned at the image's size; `strength` does nothing (`param_ignored`). |

None of them is a default: Gaea's normalizer keeps its own routes (Z-Image Turbo for generation, FLUX.2 Klein for
editing), so a request reaches Boogu by naming it, or when no other plugin offers the operation.

- **Sizes.** 512–2048 px a side in multiples of 16; generation up to 1536² in area, editing up to 1024². A larger size
  is scaled down to fit and reported `size_snapped`; a side under 512 is refused. These are the sizes the package's
  footprints were measured at (boogu-image-swift 0.5.0): an edit at 1536² took 53 GB of activation at 108 s a step.
- **`count`** on `image.generate`: 1–8 images, each with `seed + i`. A request without a seed gets one, reported in
  `effective`. `image.edit` has one output.
- **Options**, as MES extensions: `x-boogu.steps` (every model) and `x-boogu.guidance` (Base and Edit).

## Lanes and memory

Each model has the package's DiT quants as lanes. Turbo has no int4: its distilled DiT doesn't survive it.

| Lane | Resident | Peak while running | Gaea schedules at 1024² |
|---|---|---|---|
| `bf16` (default) | 21.0 GB | 19.8 GB | 40.8 GB |
| `int8` | 12.9 GB | 19.8 GB | 32.7 GB |
| `int4` | 8.3 GB | 19.8 GB | 28.1 GB |

The 16 GB Qwen3-VL conditioner loads for each job, encodes the prompt (and the image, for an edit), and is freed
before the denoise, so it counts as activation, not residency. Activation grows with the output area (16.6 GB plus
3000 bytes a pixel, up to 23.7 GB at 1536²), and Gaea reserves for each job's own size. bf16 is the default and also
the fastest: at 1024², 8 steps take 37 s at bf16, 68 s at int8 and 81 s at int4, so the smaller lanes only save memory.
When bf16 doesn't fit, Gaea loads a smaller lane and warns (`lane_fallback`, G-23); `gaea models lane boogu int8` makes
another lane the default. A request naming a lane (`x-gaea.lane`) never falls back.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default, `gaea models root` to change it). Each lane
reads its published tier, `mlx-community/Boogu-Image-0.1-{Base,Turbo,Edit}-{bf16,8bit,4bit}`, and the stock
`Qwen/Qwen3-VL-8B-Instruct` conditioner there, and downloads what is missing on `prepare` or `materialize`. The package
refuses a snapshot whose DiT quant isn't the lane's.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` generates one 512² image with Boogu int4 in 8 steps against the weights in MLXEngine's store
(`CHECK_MODELS_ROOT` moves it), with every `.build` folder hidden so MLX can find its metallib only inside the
bundle. A control then shows that the bare worker, outside the bundle, can't. `scripts/release.sh` builds, checks,
notarizes with the fleet's `mlx-notary` profile, and publishes the GitHub release. See the
[demo plugin](https://github.com/xocialize-code/gaea-plugin-demo) for signing, notarization and CI secrets.

`boogu-inproc` (its header lists the options) is not part of the plugin: it runs the same lane in-process through
MLXServeEngine, the reference that Gaea's runs are compared against byte for byte.

```bash
scripts/golden.sh <out-dir>
```

`golden.sh` runs three seeded jobs over GPP on the signed bundle (`gaea-plugin-check`) and through `boogu-inproc`, and
needs each pair byte for byte the same: Boogu bf16 at 768², Boogu Turbo int8 at 1024², and Boogu Edit bf16 on
`fixtures/fox-256.png` (from gaea-plugin-forge) at the package's 768².

## Licence

The plugin is Apache-2.0 (Gaea G-21). Boogu-Image 0.1's weights are Apache-2.0, as is boogu-image-swift, and the
Qwen3-VL-8B-Instruct conditioner is Apache-2.0 (Qwen).
