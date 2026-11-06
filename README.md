# How to use

This is how this script was intended to be used:
1. Install Davinci Resolve on the PS5 running Bazzite or other Linux operating system via Distrobox. For example on Bazzite:
```
  ujust install-resolve 
```
2. Open up a terminal and list Distrobox containers
```
   distrobox list
```
3. Enter the distrobox container with Davinci Resolve installed
```
   distrobox enter $container_name
```
So for example:
```
distrobox enter davincibox
```
4. Then clone this repo
```
   git clone https://github.com/gameodysseypl/PS5-Resolve
```
5. Enter the PS5-Resolve folder
```
   cd PS5-Resolve
```
6. And run the setup script
```
   bash ./setup.sh
```

After the setup is finished You Should see the second Davinci Resolve icon with the "Davinci Resolve (Rusticl) name. This one should work just fine and not crash the whole system, like a standard installation does.
# Running DaVinci Resolve on PlayStation 5 with Bazzite: The Problem and the Fix

## 1. The original problem

Running DaVinci Resolve on Linux installed on a PlayStation 5 is not straightforward because of the console's custom AMD APU and its GPU compute support.

The PS5 uses a custom AMD Oberon APU, identified by Linux as:

```text
AMD Custom Zen 2 (Oberon)
Architecture: GFX1013
GPU driver: amdgpu
```

The initial problem was that DaVinci Resolve caused the display to stop responding shortly after launch. Interestingly, the same issue could be reproduced without Resolve by simply running:

```bash
clinfo
```

Even filtering its output with `grep` did not help, because `clinfo` still initializes and queries the OpenCL runtime before producing any output.

Kernel logs revealed AMDGPU GPU ring timeouts, failed compute queue creation and unsuccessful GPU recovery attempts:

```text
ring gfx_0.0.0 timeout
DQM create queue type 0 failed
Ring gfx_0.0.0 reset failed
GPU Recovery Failed: -110
```

The system itself remained accessible over SSH, but the graphical display was lost.

The host system had AMD ROCm OpenCL 7.2.x installed, with its ICD pointing to:

```text
libamdocl64.so.7.2
```

This strongly implicated the AMD ROCm OpenCL runtime and its interaction with the PS5's GFX1013 GPU compute implementation.

## 2. Switching from ROCm to Mesa Rusticl

Instead of using AMD's ROCm OpenCL implementation, the solution was to use **Mesa Rusticl**.

Rusticl is Mesa's OpenCL implementation and uses the RadeonSI graphics driver for AMD GPUs.

The important difference is that Rusticl provides an alternative OpenCL execution path that works with the PS5's GFX1013 GPU without triggering the original GPU reset issue during device enumeration.

Rusticl was installed inside a Fedora Distrobox container using:

```bash
sudo dnf install mesa-libOpenCL clinfo
```

The GPU could then be detected successfully:

```text
Platform #0: rusticl
 `-- Device #0: AMD Custom Zen 2 (Oberon)
     (radeonsi, gfx1013, ACO, DRM 3.64)
```

However, this only solved the initial GPU detection and application startup problem.

DaVinci Resolve could launch, but actual image processing still failed.

## 3. The second problem: broken libclc / SPIR-V compilation

After switching to Rusticl, Resolve started normally but displayed:

```text
GPU failed to perform image processing
Error code: -1
```

Video playback, timeline operations and certain Fusion effects did not work correctly.

The Resolve debug log revealed the actual problem:

```text
Failed to build OpenCL program:
- Error: CL_BUILD_PROGRAM_FAILURE
- Build log: Internal compilation error: nir_shader not fully linked
```

The errors occurred in kernels such as:

```text
ApplyMask
ImageCrop
ClearFull
```

The container was using the upstream Fedora LLVM 22.1.8 libclc packages:

```text
libclc-22.1.8
libclc-spirv-22.1.8
```

Rusticl also displayed this warning:

```text
Patched Mesa libclc not detected.
Upstream libclc may contain known bugs or breaking changes
and isn't guaranteed to work reliably.
```

The issue was related to a known incompatibility in upstream libclc's generated SPIR-V implementation. Certain OpenCL kernels could not be linked correctly by Mesa's shader compiler.

In other words, GPU detection worked, but Resolve's actual OpenCL programs could not be compiled.

## 4. The solution: patched Mesa libclc

The solution was to build a patched version of libclc:

**mesa-libclc 22.1.8.3**

Source:

https://gitlab.freedesktop.org/karolherbst/mesa-libclc

Instead of replacing the entire Mesa installation or modifying the host operating system, the script builds the required SPIR-V files inside the Distrobox container.

The following targets are compiled:

```text
spirv-mesa3d-
spirv64-mesa3d-
```

The resulting files are:

```text
spirv-mesa3d-.spv
spirv64-mesa3d-.spv
```

They replace the corresponding upstream files used by Rusticl:

```text
/usr/lib64/clc/spirv-mesa3d-.spv
/usr/lib64/clc/spirv64-mesa3d-.spv
```

The original files are backed up before replacement, allowing the changes to be reverted.

The Mesa shader cache is also cleared to ensure that previously compiled, potentially problematic shaders are not reused.

After applying this patch, DaVinci Resolve was able to compile its OpenCL kernels and perform image processing correctly.

## 5. Keeping ROCm and Intel OpenCL out of the way

The container may contain multiple OpenCL implementations, including ROCm and Intel OpenCL.

To prevent Resolve from accidentally loading the wrong implementation, the script creates a separate ICD directory:

```text
~/rusticl-only/
    rusticl.icd
```

It then launches Resolve with:

```bash
RUSTICL_ENABLE=radeonsi
OCL_ICD_VENDORS="$HOME/rusticl-only"
```

This explicitly enables RadeonSI in Rusticl and restricts the OpenCL ICD loader to the Rusticl implementation.

The application is launched through the `davincibox` wrapper:

```bash
run-davinci -c /opt/resolve/bin/resolve
```

## 6. What the setup script automates

The setup script automates the entire Rusticl configuration and patched libclc installation process:

1. Installs Mesa Rusticl and OpenCL diagnostic tools.
2. Creates an isolated OpenCL ICD directory.
3. Installs the build dependencies required for libclc.
4. Downloads the patched mesa-libclc source archive.
5. Verifies the archive using its SHA256 checksum.
6. Compiles the required SPIR-V targets using LLVM 22.
7. Backs up the original SPIR-V files.
8. Installs the patched SPIR-V files into the location used by Rusticl.
9. Clears the Mesa shader cache.
10. Tests OpenCL device detection.
11. Creates a desktop launcher for DaVinci Resolve.

The entire configuration is performed inside Distrobox. The host Bazzite installation, host Mesa packages and PS5 kernel do not need to be modified.

## 7. Final result

The final configuration uses:

| Component | Implementation |
|---|---|
| Hardware | PlayStation 5 AMD Oberon APU |
| GPU architecture | GFX1013 |
| Operating system | Bazzite |
| Container | Fedora 44 / Distrobox |
| Video driver | AMDGPU |
| OpenCL implementation | Mesa Rusticl |
| GPU backend | RadeonSI |
| Shader compiler support | Patched mesa-libclc 22.1.8.3 |
| Application | DaVinci Resolve 21.2 |

After applying both fixes, DaVinci Resolve successfully launches, detects the PS5 GPU through Rusticl and performs OpenCL image-processing operations, including timeline playback and effects.

### Why this approach?

The main idea is to avoid the problematic ROCm OpenCL execution path on the PS5's custom GPU, use Mesa Rusticl as an alternative, and provide Rusticl with patched libclc SPIR-V binaries so Resolve can successfully compile its image-processing kernels.

**The important part is that installing Rusticl alone is not sufficient. Both the alternative OpenCL runtime and the patched libclc files are required for this tested configuration.**
