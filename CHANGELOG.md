# Changelog

All notable changes to GoyGI are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases up to and including 3.0.x predate this file.

Every number quoted below comes from the CI run on that release — the visual test
prints the same stats it checks (`blockiness` = wall smoothness, lower is
smoother; the GI-off/on luminance ratio; the number of chunks loaded). See
[Tests and CI](README.md#tests-and-ci).

## [3.1.0] - 2026-10-05

Fixes the three things that made GoyGI look like a voxel renderer with holes in
it, plus the GI-off regression and the per-pixel cost. Everything here was found
by reading the maths rather than by tuning knobs, and each item has a check in
the CI test so it cannot come back.

### Fixed

- **Voxels showing up as hard blocks on walls.** The sampler moved the sample
  point towards the visible voxels: that offset is a *discontinuous* function of
  the surface position, so the hardware trilinear blend flipped between two voxel
  neighbourhoods at every cell boundary — a hard, one-voxel-wide step aligned
  with the voxel grid. Replaced with plain trilinear interpolation plus a
  continuous occupancy leak guard
  ([§11](README.md#11-why-the-voxel-grid-used-to-show-up-as-boxes)). The same
  change removed the remaining light leaks around corners.
- **Areas of the map going dark ("missing chunks").** The per-chunk fade-in
  target was `passes / 3`, so a chunk that was recomputed (a lamp switched, the
  sun moved, geometry edited) dimmed to a third — or, when its pass counter was
  reset, to black. The fade now only goes up: a chunk that has been computed once
  keeps its light while it blends to the new one.
- **A map that grew after a rebuild silently lost its chunk cache.**
  `_setup_cache()` could change the chunk grid without reallocating the textures,
  after which the shader sampled a grid that no longer matched the texture. The
  cache is now reallocated whenever the grid key changes.
- **Editing the level showed raw, unconverged voxels.** `rebuild()` did a full
  `stop()` + `start()` — throwing away the near volume *and* the whole world
  cache — every time a prop moved. It now rebuilds **in place** when the
  occupancy grid keeps its size: occupancy, albedo and roof are re-uploaded into
  the live textures and the lighting is refreshed progressively.
- **Switching the GI off looked worse than plain Godot.** The GoyGI materials
  disable Godot's ambient light while the GI is on (so the sky is not counted
  twice), and with the GI off nothing gave it back — the scene collapsed to
  direct light. The Environment's ambient light (colour, sky contribution,
  energy) is now fed through the ambient fallback whenever the GI is off.
- **Two scripts did not parse** on current Godot: `var srgb := …get_format() != …`
  type inference, and a 4-argument `RenderingDevice.texture_update`. Found by the
  CI import step.
- **Stale `.glsl.import` files could disable the GI silently.** The committed
  import metadata pointed at a SPIR-V build from an older engine, so the editor
  treated the compute shaders as "already imported", never built them, and
  `GIManager` quietly fell back to direct light. CI now imports the shaders from
  scratch on every run and fails if any of the four is missing
  ([Troubleshooting](README.md#troubleshooting)).
- **Silent failure paths.** Every path that disables the GI now logs an explicit
  `ERROR: GIManager: ...` line instead of leaving you with a flat-looking scene
  and no explanation.

### Changed

- **Per-pixel cost: ~40 texture fetches → 6.** The sampling path was an
  8-iteration loop with 4–8 occupancy taps per pixel; it is now 3 trilinear
  fetches + 1–2 occupancy taps + 1 roof tap. On a fragmented-bound frame that is
  the difference between "the GI is the expensive part" and "the level shader is
  the expensive part".
- The **Low** and **Medium** presets now also enable `fast_triplanar` and disable
  `normal_maps`, because on a phone the level shader usually costs more than the
  GI.

### Added

- **CI that renders, not just builds.** `.github/workflows/ci.yml` imports the
  project (parses every script, compiles every shader) and then renders a test
  level on the `Mobile` rendering method over Mesa's software Vulkan, on **Godot
  4.7.2**, with no GPU and no phone. It fails the job on a script or shader
  error, on a compute shader that did not compile, on a GI that never starts, on
  a wall that shows voxel blocks, and on the GI-off regression.
- **Screenshots as artifacts** for every push and pull request, plus the
  `blockiness`, luminance and chunk statistics in the job summary.
- **`Leak Guard` debug view**, which colours a surface red where the leak guard
  removes light — the quickest way to see whether a wall is losing its indirect
  light.
- A written derivation of every constant in the shaders
  ([The maths](README.md#the-maths)), including why `0.25` / `0.5` are exact, the
  toroidal addressing proof and the mobile budget table.

[3.1.0]: https://github.com/GoyDevv/GoyGI-Godot/releases/tag/v3.1.0
