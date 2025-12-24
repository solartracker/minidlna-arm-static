# minidlna-arm-static

This repository contains a build script (`minidlna-arm-static.sh`) for compiling **MiniDLNA** as a statically linked executable for ARMv7 Linux devices.

---

## What is MiniDLNA?

**MiniDLNA** (also known as _ReadyMedia_) is a lightweight, simple-to-configure media server that implements the DLNA/UPnP-AV standard. It allows you to stream music, videos, and photos from a Linux-based device, such as a Raspberry Pi, to DLNA-compatible clients like smart TVs, game consoles, or media players.

Key features:

- Supports a wide range of audio and video formats.
- Minimal system requirements; ideal for small devices like Raspberry Pi.
- Automatically updates its media library when new content is added.
- Can be compiled statically to include all dependencies in a single binary.
- Focused on stability and passive operation without a heavy web interface.

MiniDLNA is perfect for home media streaming setups where simplicity, efficiency, and low resource usage are priorities.

This is a statically linked version of MiniDLNA, built using Tomatoware. It runs on any ARMv7 Linux device without requiring shared libraries. MiniDLNA is a lightweight, fully compliant UPnP-AV media server that serves videos, music, and photos to compatible clients on your network.

## What is Tomatoware?

Tomatoware is a modern, self-contained ARM cross-compilation toolchain. It allows you to compile the latest open-source packages for older ARM systems that were previously stuck on out-of-date toolchains. It provides up-to-date compilers, libraries, and utilities in a single environment, fully isolated from your host system. Using Tomatoware ensures that builds are reproducible and safe, without modifying or interfering with host libraries or binaries.

---

## Setup Instructions

1. **Clone this repository**

   ```bash
   git clone https://github.com/solartracker/minidlna-arm-static
   cd minidlna-arm-static
   ```

2. **Run the build script**

   ```bash
   ./minidlna-arm-static.sh
   ```

   This will build `minidlnad` as a **statically linked binary** under `/mmc/sbin`. You can copy this binary directly to your ARM target device.

---

## Note on Building MiniDLNA

Compiling MiniDLNA (and especially FFmpeg) on ARM devices can generate significant heat, often exceeding safe limits when using all CPU cores. For Raspberry Pi, upgrading to an aluminum case with properly sized copper shims and good thermal paste provides effective passive cooling, improving heat dissipation, keeping CPU temperatures lower, and preventing thermal throttling during long builds.

For slower, cooler builds, you can compile using a single core by commenting/uncommenting the `MAKE` line in the build script.
