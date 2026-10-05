# Contributing to GoyGI

Thanks for wanting to help. GoyGI is a **visual** system: almost every bug anyone has ever reported about it is something you can only judge by *looking at the result*, and almost every "fix" that gets accepted without pictures turns out to be a regression somewhere else.

So the rule here is short and non-negotiable:

> **A pull request is not reviewed until it carries evidence.** Screenshots. Before and after. Numbers. From CI, from the test scene, or from a real device with the dump attached.
>
> A PR that says "should fix the artefact", with no images and no numbers, is closed with a pointer to this file.

That is not bureaucracy. It is the only way to keep a GPU renderer honest against a codebase where a single wrong constant turns walls into checkerboards.

---

## Quick checklist for a pull request

Copy this into the PR description and fill it in. Incomplete checklist = not reviewed.

```markdown
## What this changes
(one paragraph, plain language)

## Why
(the problem, how you reproduced it, what the root cause is)

## Evidence

### Before / after pictures  (REQUIRED)
| before | after |
|---|---|
| ![before](URL) | ![after](URL) |

### How these pictures were made  (REQUIRED)
- scene / map used:
- exact steps to reproduce it (node setup, options, camera position):
- Godot version + renderer:
- device / GPU (or "CI lavapipe"):

### Numbers  (REQUIRED when the change touches cost or quality)
| metric | before | after |
|---|---|---|
| frame time / GPU ms | | |
| `get_stats()["cpu_ms"]` | | |
| `voxels_full`, `voxels_fast` per update | | |
| CI `summary.txt` blockiness | | |
| mean luminance (GI on / GI off) | | |

### For a shader change  (REQUIRED)
- the maths that changed, written out (the README derives everything - point at the equation you are altering and show the new one)
- why the new formula is *exact* rather than tuned, or, if it is tuned, the calibration data you used:

## Risk / what else this touches
(which features, which renderers, which tiers)

## Checklist
- [ ] I ran `test/gi_test_scene.tscn` and CI is green on my branch
- [ ] I attached the `artifacts/` screenshots (or CI links)
- [ ] I did not break `Compatibility` (GI off, game keeps running)
- [ ] I did not break the `Forward+` path
- [ ] Docs/README updated if an option, default or formula changed
```

---

## What counts as evidence

**Screenshots — always required.**

* Minimum: the same camera, same options, before vs after.
* For a GI-quality change, include the relevant **debug view** too (`Voxels`, `Chunks`, `Leak Guard`) — an artefact that is hidden in the beauty shot but visible in `Leak Guard` is still an artefact.
* For anything about **leaks, banding, popping or voxel blockiness**, include a *still camera* shot and a *moving camera* shot (or a short clip). Half of GoyGI's bugs are temporal.
* Full-resolution PNGs, please. Crops are fine *in addition to* the full frame, with the crop region marked.
* No phone photos of a monitor. `screencap`/`adb` dumps, editor screenshots or CI artifacts only.

**Numbers — required when you touch cost, defaults, or the update loop.**

`GIManager.get_stats()` is the source of truth; `developer_stats = true` adds the GPU timestamps. Include at least `cpu_ms`, `rate`, `voxels_full`, `voxels_fast`, `chunks_required_loaded`/`chunks_required`, `vpls`. Say which device (or "lavapipe in CI") produced them, because a desktop number says nothing about a Mali-G52.

**The maths — required for anything in `shaders/`.**

Every quantity in the GI has a derivation (see the [README's maths section](README.md#the-maths)): the L1 projection constants `0.25`/`0.5`, why the volume stores `E/π`, the VPL integral, the leak guard. If you change a formula, write out the new derivation in the PR. If you are adding an approximation, show the error it introduces. "It looks better" is a valid observation but not a valid *argument*; attach it to a derivation or to a measurement.

---

## Running the tests

The test scene needs no GPU — CI runs it on Mesa's software Vulkan:

```bash
apt-get install -y xvfb mesa-vulkan-drivers        # lavapipe = software Vulkan
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json \
  xvfb-run -a godot --path . --rendering-method mobile --rendering-driver vulkan
```

It writes `artifacts/*.png` and `artifacts/summary.txt`, then exits non-zero if a check fails. On a PR, `.github/workflows/ci.yml` does the same and uploads the screenshots as artifacts — link those in your PR description.

Add a check to `test/gi_test.gd` whenever your change could regress silently. Every historical GoyGI bug (voxel blocks, GI-off going dark, chunks fading out, leaks through ceilings) is worth a metric that would have caught it.

## Areas that need help

* **Cost on real phones.** If you have an Adreno 6xx / Mali-G5x device, a profile capture (frame time, GPU ms, tier) is *extremely* welcome — even without a code change.
* **More StandardMaterial3D feature coverage** in `goygi_standard.gdshader` (transparency, clearcoat, detail maps, billboards).
* **Sky models**: `PhysicalSkyMaterial` and custom `ShaderMaterial` skies are read heuristically right now; better extraction is very welcome.
* **Better initial occupancy for big levels** (the mesh → collider pass at startup).
* **Documentation** of your own setup if it is unusual (large worlds, streaming, vehicles).

## Ground rules

* Keep GoyGI's public surface stable: exported property names, `GoyGIConfig` keys and `goygi/*` Project Settings are API. Adding is fine, renaming is a breaking change that needs a good reason and a migration note.
* New defaults must be safe on a Mali-G52 with 3 GB of RAM. Quality goes up per *option* and per preset tier, not per default.
* No new required dependency, no new required Project Setting, and GoyGI must never stop a game from running: if there is no `RenderingDevice`, no occupancy, or the shader fails to compile, it has to disable itself and leave direct lighting alone.
* Match the existing code style: tabs, `:=` for inferred types, doc comments (`##`) on public functions, and a comment that explains *why* wherever the code does something surprising. The existing comments are the specification — keep them true.
* One idea per pull request. A refactor bundled with a behaviour change will be asked to split.

## Review

Maintainers will ask for the OSD (observation, steps, data) rather than for code. Expected turnaround is a few days; a PR with weak evidence may sit longer, and that is the price of the rule above.

## Code of conduct

Be decent. Technical criticism of the maths, the method or the evidence is welcome and expected; criticism of the person is not. Anything else that makes contributors not want to come back is a reason to be removed from the project.
