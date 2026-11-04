# Windows releases (this fork)

This fork adds a prebuilt Windows engine to Basalt. The engine itself, its Windows port and its limitations are
upstream's: see [platforms](platforms.md). What is added here is the packaging, the release build and one entry
point a person can double-click.

## Tracking upstream

The author releases often, so a scheduled workflow does the work: `upstream-windows.yml` runs every six hours,
asks upstream for its latest release and publishes Windows binaries for it under the same number with a `-win1`
suffix - upstream's `v0.2.2` becomes this fork's `v0.2.2-win1`. When that release already exists here the run
does nothing.

Nothing is merged into the fork's `main`. The run merges the upstream tag into its own working tree and builds
that, and the zip's `VERSION` records the upstream tag, the upstream commit and this fork's commit; the release
notes link the run, so the merge commit named in `VERSION` is reachable from them.

A merge conflict stops the machine: the run opens one issue listing the conflicting files and publishes nothing.
Fixing that merge on `main` is a person's job, and the next scheduled run - or a manual one with
`upstream_tag=<tag>` - builds it.

Publishing uses the workflow's own token: the release is authored by `github-actions[bot]` and the repository
holds no secrets. A manual run with `publish` unchecked builds the zip as a workflow artifact and publishes
nothing, which is how a change to this pipeline is tested without shipping a release.

## What a user does

Double-click **START-HERE.bat** in the unpacked release folder. It checks the card, sets up Python in `.venv`,
helps choose a model (files on the machine, the packs on Hugging Face with their sizes, or choose later), writes
`basalt_config.json` and starts the server. Re-running it starts the server again.

    START-HERE.bat --plan     print every step, change nothing
    START-HERE.bat --yes      take the shown default for every question

The same script runs from a source checkout: it takes `build/bin/basalt.exe` when you built one, offers to build
it, or offers the prebuilt zip. Flags: `--model`, `--gpu`, `--port`, `--engine-bin`, `--build`, `--no-download`,
`--no-serve` (`tools/windows/setup_basalt.py --help`).

## What is in a release

`release-windows.yml` builds on a tag (`v0.2.1-win1`) and attaches to that release:

    basalt-<version>-windows-x64-cuda13.zip
    basalt-<version>-windows-x64-cuda13.zip.SHA256SUMS

The zip carries `bin/` (the four programs, the CUDA runtime `cudart64_13.dll` / `cublas64_13.dll` /
`cublasLt64_13.dll` and the MSVC runtime), `serve/`, `tools/`, `data/`, `docs/`, `START-HERE.bat`, `VERSION`
(commit, toolkit, architecture) and `README-WINDOWS.md`. Unpack it anywhere; a current NVIDIA driver for a
Blackwell card is all the machine needs. `tools/windows/package.ps1` assembles it, and the workflow checks that
the zip carries the engine, the CUDA DLLs, `serve/server.py`, `data/profiles`, `START-HERE.bat` and `VERSION`.

The CUDA runtime DLLs come from NVIDIA's own redistributable index, not from the toolkit on the build machine:
`tools/windows/fetch_cuda_redist.ps1` reads `redistrib_<toolkit>.json`, checks the SHA-256 the index publishes
for every file and writes the DLLs and a `REDIST.txt`, which `VERSION` copies, so a release says which
`cuda_cudart` and `libcublas` it carries. A toolkit install is often dev-only (import libraries and headers, no
DLLs), and which component names the installer accepts changes between toolkit versions.

After packaging the workflow unpacks the zip and starts `bin/basalt.exe --help` with only `C:\Windows` on
`PATH`: the libraries beside the binary have to be enough, which is the claim a user depends on.

Making one, the path verified end to end:

    git tag v0.2.1-win1
    gh workflow run release-windows.yml --ref v0.2.1-win1     # builds from the tag and publishes the release

The publish step names the release after the ref the run is on, so dispatching on a tag is what
publishes. A manual run on a branch only uploads the zip as a workflow artifact:

    gh workflow run release-windows.yml                        # the zip as an artifact, no release

Pushing the tag is meant to trigger the same workflow on its own. On this repository it did not, with
the tag itself in place: the tag reached GitHub and peels to the commit that carries the workflow, the
workflow is active, and the runs for the `push` event stayed at the four runs of the pushes to `main`,
with nothing queued. Nothing in the repository explains it. The published release was built from the
tag by the dispatch, so the commit in `VERSION` and the release's tag agree; retest the tag push with
the next tag.

A fork carries none of the upstream's tags, so a build that is not a tag is named after the version in
`CMakeLists.txt` and the commit: `basalt-0.2.1-dev617a7534-windows-x64-cuda13.zip`. A tag is the version.

The build is `CMAKE_BUILD_TYPE=Release` with `CMAKE_CUDA_ARCHITECTURES=120`, the configuration upstream's CI
compiles and CPU-tests on every pull request. No compiler flag is added, so the binaries are the ones the
upstream tests describe.

## Why the zip runs anywhere

The engine reads `serve/` and `data/profiles` from a folder. `platform::tree_root` (in
`include/basalt/platform/system.hpp`) answers that question by walking up from the binary's own folder and
looking for `serve/server.py`: an installed engine gets the folder it was unpacked into, and a build in a source
tree gets the tree it was compiled in, as before. `basalt serve` enters that folder and runs the Python server
from it, and the expert profile lookup uses it too. The tests are in `tests/platform/tree_root_test.cpp`
(`platform_tree_root_test`, runs on Linux and Windows).

## What is checked, and what is not

    python tools/test_setup_basalt.py     the starter's decisions: the card rows, the pack listing, the release
                                          manifest, a zip, the settings file (no GPU, no network, no install)

The fork's CI compiles the engine and runs the CPU tests on Windows on every pull request (upstream's `ci.yml`),
and `release-windows.yml` builds the release and checks the zip's contents. Nothing in this fork's CI has a GPU:
the GPU tests, the quality gate and the first real load of a pack on Windows are run by whoever has a Blackwell
card. Upstream reports the Windows limitations (pinned-memory cap under WDDM, large pages, TDR, no measured
perplexity on Windows) in [platforms](platforms.md#windows-limitations); they apply to these binaries unchanged.
