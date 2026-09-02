# Babet architecture

This document gives the short product-level model. Detailed contracts remain in
`INVARIANTS.md`, `EMBEDDING_DESIGN.md`, `NATIVE_PLUGIN_DESIGN.md` and
`GUI_DESIGN.md`.

## Core product: Lua -> one executable

Babet's primary model is still:

```text
Lua project
   |
   v
Babet --create-exe
   |
   v
one generated executable
```

The generated application contains the complete runtime of the Babet binary
that created it plus the embedded Lua project. `--create-exe` does not invoke a
compiler or linker on the machine where it runs. A generated application is
final and cannot itself create another executable; keep/copy the original Babet
binary when a builder is required.

Except for explicitly documented system integrations such as `babet.gui`, this
model is intended to remain deployable by copying that one file.

## Native plugins: Babet loads external native code

```text
original Babet CLI -> plugin.so
```

Native plugins are trusted in-process extensions for the original CLI. They are
useful for specialised/vendor native SDKs, not for reducing Babet's binary size.
They are external shared objects and generated `--create-exe` applications
explicitly refuse them, preserving the generated application's one-file model.

## libbabet: another native program embeds Babet

```text
native host application
        |
        +-- libbabet.a
                |
                +-- Babet + Lua runtime
```

`libbabet.a` is the opposite direction from a plugin: the external C/C++ (or
other C-ABI-capable native) program is the main application and embeds Babet as
an engine. The standalone developer SDK contains the public C headers, one
flattened static `libbabet.a`, documentation, examples, Babet's licence and
third-party notices.

After final static linking, `libbabet.a` is not a separate runtime file beside
the host executable.

Official release builds package this SDK per architecture, for example:

```text
babet-X.Y.Z-linux-x86_64-sdk.tar.gz
babet-X.Y.Z-linux-aarch64-sdk.tar.gz
babet-X.Y.Z-linux-armhf-sdk.tar.gz
```

A static SDK is architecture-specific; an x86_64 archive cannot be reused as an
AArch64 or armhf library.

## Optional system GUI: Lua uses GTK 4 through Babet

```text
Lua -> babet.gui -> lazy dlopen/dlsym -> system GTK 4
```

GTK is not linked into or downloaded by the normal Babet build. A script that
does not use `babet.gui` keeps the normal Babet deployment contract and works
without GTK installed.

A script that uses `babet.gui` remains compatible with `--create-exe` and still
produces one application file, but GTK 4 becomes an explicit runtime dependency
on the target machine. If GTK 4 is unavailable, Babet reports a controlled
error with installation guidance.

This is a deliberate, GUI-only exception to the normal autonomy promise. GTK 4
is the only supported GUI backend today; the API does not promise multiple
interchangeable toolkits.

## Size measurement before build profiles

The active maintainer methodology is documented in
[`SIZE_PROFILES_STUDY.md`](SIZE_PROFILES_STUDY.md). Linker-map attribution is
only Phase 1; supported feature switches are deliberately not introduced until
one-feature-at-a-time differential builds measure actual removable size.

## Build-time modularity: future study, not current behaviour

Babet currently builds one main statically featured runtime. A future
Gentoo-style build may make selected native components optional at Babet build
time. If retained, generated applications would inherit exactly the feature set
of the Babet builder, so `--create-exe` would still require no external
toolchain. No such profile system is part of the current contract yet.

## Native release validation for architecture-specific artifacts

The official static SDK and release binary are architecture-specific artifacts.
A successful x86_64 build or a cross-compile is not accepted as evidence for an
AArch64 or armhf release.

Maintainers validate each native release builder with:

```bash
./tools/run_native_arch_release_validation.sh
```

The runner identifies the local architecture, executes the full pre-release
campaign, verifies the adopted production linker/OpenSSL section-GC contract and
deterministic TLS capabilities on the final native binary, then packages that
same build and checks the binary tarball and SDK tarball. The packaged SDK
examples are rebuilt and executed after extraction. For `linux-armhf`, the ELF
attributes must also advertise the hard-float VFP calling convention.

The complete console stream is also kept automatically in
`native-arch-validation.log` at the project root so an SSH disconnect does not
lose the diagnostic from a long validation run.

Release sanitizer coverage is architecture-aware: x86_64/AArch64 run ASan +
UBSan, while `linux-armhf` runs UBSan only. This is not a silent skip: the
compact report records `pre_release_sanitizers=UBSAN_ONLY`. The ARMHF exception
was established on the ARMv6 reference builder with minimal programs outside
Babet: dynamic ASan aborts before `main()`, preload/static workarounds segfault,
whereas standalone `libatomic` and UBSan probes succeed.

On small ARM systems a sanitizer compile can also starve a hardware watchdog
feeder long enough to reset the machine. The native runner therefore offers an
explicit safe mode:

```bash
sudo -v
./tools/run_native_arch_release_validation.sh --suspend-watchdog
```

It saves the initially active `watchdog.service`/`wd_keepalive.service` state in
a persistent marker before stopping anything, never disables or masks units,
and verifies hardware disarm when sysfs exposes it. Before the stop, it also
launches a detached root restore guard, so restoration does not depend on the
sudo timestamp still being valid hours later and also runs if the parent is
killed with SIGKILL. The persistent marker remains the fallback after power
loss, reboot, or a failed guard; the next run repairs that state before doing
anything expensive. Machines without a watchdog treat the option as a no-op.

The command is intentionally the same on x86_64, AArch64 and armhf. The
final 2.23.0 native release matrix has now been completed on all three official
Linux architectures from the same source tree.

Final native results:

- `linux-x86_64`: 13,842,952 stripped bytes, ASan+UBSan, production
  GC/OpenSSL contract PASS, deterministic TLS 7/0/0 and packaged SDK examples
  7/7 PASS.
- `linux-aarch64`: 12,487,256 stripped bytes, ASan+UBSan, production
  GC/OpenSSL contract PASS, deterministic TLS 7/0/0 and packaged SDK examples
  7/7 PASS.
- `linux-armhf`: 9,861,000 stripped bytes, UBSan-only on the ARMv6 builder,
  hard-float ABI PASS, production GC/OpenSSL contract PASS, deterministic TLS
  7/0/0 and packaged SDK examples 7/7 PASS. The optional watchdog suspension
  used on the constrained builder is restored successfully after validation.

The identical source snapshot propagated between the native builders has
SHA-256
`8757524730661e81bb3e26cde1c0226d8140fa57227900e4fdad52f07213ce73`.
No official native architecture remains pending.
