# minidlna-arm-static

This repository contains build scripts for compiling **MiniDLNA** as a **fully statically linked executable** for ARMv7 Linux devices.

Two build methods are provided. Both produce functionally identical MiniDLNA binaries, but use different toolchains and build environments.

---

## What is MiniDLNA?

**MiniDLNA** (also known as _ReadyMedia_) is a lightweight, simple-to-configure media server that implements the DLNA/UPnP-AV standard. It allows you to stream music, videos, and photos from a Linux-based device, such as a Raspberry Pi, to DLNA-compatible clients like smart TVs, game consoles, or media players.

Key features:

- Supports a wide range of audio and video formats
- Minimal system requirements; ideal for small ARM devices
- Automatically updates its media library when new content is added
- Can be compiled statically to include all dependencies in a single binary
- Focused on stability and passive operation without a heavy web interface

MiniDLNA is well suited for home media streaming setups where simplicity, efficiency, and low resource usage are priorities.

---

## Build Methods

### 1. Tomatoware-Based Static Build

- Build script: `minidlna-arm-tomatoware.sh`  
- Uses the Tomatoware cross-compilation environment  
- Produces a fully statically-linked MiniDLNA binary  
- Intended for Tomato/Tomatoware-based systems or users already invested in that ecosystem  

The resulting binary runs on ARMv7 Linux devices without requiring any shared libraries.

---

### 2. arm-linux-musleabi (musl) Static Build

- Build script: `minidlna-arm-musl.sh`  
- Uses a standalone `arm-linux-musleabi` cross-compiler based on musl libc  
- Produces a fully statically-linked MiniDLNA executable  
- Suitable for generic ARM Linux systems and embedded devices  

In practice, binaries produced with the musl-based toolchain are typically **smaller and more efficient**, particularly on **older or resource-constrained ARM hardware**. This is primarily due to musl’s smaller runtime footprint and cleaner static linking behavior.

Both build methods produce equivalent MiniDLNA functionality; the difference lies in toolchain dependency and output characteristics.

---

## What is Tomatoware?

Tomatoware is a modern, self-contained ARM cross-compilation toolchain. It allows you to compile up-to-date open-source software for older ARM systems that were previously limited to outdated toolchains.

Tomatoware provides compilers, libraries, and utilities in a single, isolated environment, ensuring reproducible builds without modifying or interfering with host system libraries.

---

## Setup Instructions

1. **Clone this repository**

   ```bash
   git clone https://github.com/solartracker/minidlna-arm-static
   cd minidlna-arm-static
   ```

2. **Run the build script of your choice**

   - **Tomatoware build**:

     ```bash
     ./minidlna-arm-tomatoware.sh
     ```

   - **Musl build**:

     ```bash
     ./minidlna-arm-musl.sh
     ```

Both scripts build `minidlnad` as a **statically linked binary** under `/mmc/sbin`. You can copy the binary directly to your ARM target device.

---

## Notes on Older ARM Hardware

Older ARM cores (ARM9, ARM11, early Cortex-A) are particularly sensitive to binary size, cache pressure, and memory overhead. For these systems, the **musl-based build** is generally the preferred option.

---

## Note on Building MiniDLNA

Compiling MiniDLNA—especially FFmpeg—on ARM devices can generate significant heat, often exceeding safe limits when using all CPU cores.

On Raspberry Pi systems, an aluminum case combined with **properly sized copper shims and thermal paste** provides effective passive cooling and prevents thermal throttling during long builds. Copper shims are particularly important because they create a low-resistance thermal path between the SoC and the case:

- Much higher thermal conductivity than thermal tape (~400 W/m·K vs. ~0.5–1 W/m·K)
- Consistent physical contact that eliminates insulating air gaps
- No long-term compression or degradation

In testing, this reduced Raspberry Pi 3B CPU temperatures from approximately **80 °C to under 50 °C** during compilation.

For slower, cooler builds, you can also limit parallelism by adjusting the `MAKE` line in the build script to use a single core.
