# Babet section-GC size study — Candidate 10

Candidate 10 is a **measurement-only** follow-up to Candidate 9. Candidate 9
closed the OpenSSL `Configure no-*` path: the safely reviewable removal ceiling
remains below 512 KiB, while modern TLS/PQC capabilities and diagnostics are
kept. Candidate 10 changes the question from “which capability can we remove?”
to “what code is already unreachable at final link time?”

At Candidate 10 measurement time, no GC flag was enabled in the normal Babet build.

## Decision rule fixed before measurement

- realised total saving **below 256 KiB**: STOP; do not adopt section GC;
- saving **at or above 256 KiB**: adoption review allowed, not automatic;
- adoption still requires the exact `babet.*` runtime surface, native plugins,
  embedding/packaging and deterministic TLS capabilities to remain protected.

The lower threshold than Candidate 9 reflects the lower permanent complexity,
while still rejecting tiny savings that would not justify a latent dead-section
registration risk.

## Variants

### Variant A

`-Wl,--gc-sections` only. This measures the benefit already available from
archives whose producers have split functions/data into separate sections. The
first link also records `--print-gc-sections` output for inspection.

### Variant B

Variant A plus `-ffunction-sections -fdata-sections` on **Babet-owned source
files only**. Bundled sqlite/miniz and other third-party archives are deliberately
not reclassified into B, so the marginal A→B delta remains attributable.

### Variant C

Variant B plus a separate OpenSSL 3.5.8 build configured with the same two
compiler flags. OpenSSL capabilities and normal `Configure` options stay
unchanged. At Candidate 10 measurement time, production `build_local.sh` was not modified to use those flags.

## Registration protection

Candidate 10 adds an explicit runtime regression containing the expected
top-level `babet.*` surface. It fails on both missing and unexpected entries.
This guard is useful even if section GC is ultimately rejected: future static
registration changes cannot disappear silently.

Each A/B/C binary is also exercised by the native-plugin runtime regression,
the existing `--create-exe` packaging regression, and Candidate 9's deterministic
TLS capability matrix. Full normal/sanitizer/release campaigns are required only
if the measured saving crosses the gate and adoption is considered.

## Architecture scope

Candidate 10's size result is x86_64-specific. Archive sectioning and OpenSSL
assembly differ by architecture, so no ARM size conclusion is inferred from it.


## Candidate 10 measured result and decision

The x86_64/Ubuntu 13.3 Candidate 10 run used the OpenSSL 3.5.8 baseline of
**15,563,592 bytes** and produced:

| Variant | Stripped size | Gain vs baseline | Marginal gain |
|---|---:|---:|---:|
| A — linker `--gc-sections` only | 14,445,384 | 1,118,208 (7.18%) | 1,118,208 |
| B — A + Babet function/data sections | 14,383,944 | 1,179,648 (7.58%) | 61,440 vs A |
| C — B + section-split OpenSSL | 13,781,512 | 1,782,080 (11.45%) | 602,432 vs B |

A crosses the precommitted 256 KiB review gate by a wide margin. B is **STOP**:
its 61,440-byte marginal saving does not justify permanently splitting
Babet-owned translation units. C is not an adoption measurement because its
experimental OpenSSL build did not prove configuration identity with the
production OpenSSL build. Candidate 11 therefore isolates the OpenSSL effect
without B and adds an explicit fresh-production control witness.

Variant A does **not** compile Babet-owned sources with
`-ffunction-sections`, but C++ templates, inline functions, RTTI and other COMDAT
entities already live in independently collectible sections. The Candidate 11
`--print-gc-sections` audit therefore records many removals from `libbabet.a`
itself as well as libstdc++/libarchive. This corrects the initial assumption
that A could only collect third-party sections. Ordinary non-COMDAT Babet code
remains grouped according to the compiler's normal layout. The exact gain is
toolchain- and architecture-dependent.

## Candidate 11 — adoption review

Candidate 11 does not enable GC in normal builds. It performs the final review:

1. rebuild A and audit its `--print-gc-sections` log, failing if one of the six
   exported C symbols (`babet_version`, `babet_status_name`, four `babet_host_call_*`)
   or an init/fini array, constructor or destructor section is discarded. Internal C++
   names containing `babet_` and COMDAT groups are not treated as exported surface;
2. rebuild OpenSSL 3.5.8 from the pinned tarball with the **literal production**
   `./Configure no-shared --openssldir=/etc/ssl` command and require the resulting
   control-linked A binary to reproduce A's stripped size exactly;
3. build D as A plus OpenSSL compiled with only
   `-ffunction-sections -fdata-sections`, with Babet section splitting disabled;
4. retain the 256 KiB realised-saving review gate;
5. run the deterministic TLS matrix on A and D;
6. benchmark baseline/A/D against the same local TLS fixture using warm-up and
   twelve balanced interleaved blocks covering all six execution orders. The
   workload is calibrated to about one second per sample (with an automatic
   longer retry if needed), and the fixed 10% regression gate is applied to
   both global medians and block-paired medians; minima and relative MAD are
   reported as noise diagnostics;
7. run the complete A suite once under a real non-C UTF-8 locale, then perform
   full normal + ASan/UBSan + pre-release/network validation for both A and D.

The locale pass specifically targets the C++ runtime facets that A is expected
to discard. Candidate 11 adds an internal prebuilt-binary hook to the test
harness so the full campaign really exercises A/D rather than silently
rebuilding the ordinary product. Ordinary `run_tests.sh` behaviour is unchanged
when those maintainer-only environment variables are absent.


Candidate 11 witness-build note: the fresh OpenSSL control and section-split builds use the standard `build_libs` target only. This produces the required `libcrypto.a`/`libssl.a` archives without building OpenSSL applications or its test executables; the `Configure` contract remains identical to production apart from the two section flags in D. The work trees live under `build/gc-sections-study/candidate11/` rather than `/tmp` and are removed after the two archives are copied. `mkinstallvars.pl` warnings emitted by `build_libs` for unused install-only variables are not treated as configuration drift: `configure.log` must stay clean and the fresh control must still reproduce A byte-for-byte.

If a Candidate 11 run stopped after the A/control/D measurement but before final
validation, `tools/run_candidate11_gc_adoption.sh --resume` reuses only existing
artifacts after requiring `matches_A_size=yes` and all four normal/sanitizer build
trees. It does not rebuild the baseline or OpenSSL in that mode.


## Production adoption

Candidate 11 completed successfully on the x86_64 Ubuntu/GCC 13.3 reference
machine. The fresh production-control witness reproduced A **byte-for-byte** at
**14,445,384 bytes**, while D (A plus section-split OpenSSL, without Babet source
splitting) measured **13,842,952 bytes**. D therefore saves **1,720,640 bytes
(11.06%)** versus the 15,563,592-byte Candidate 11 baseline. Its OpenSSL-only
marginal gain over A is **602,432 bytes**.

The Candidate 10/11 arithmetic also cross-checks exactly: Candidate 10 C is
13,781,512 bytes and Candidate 11 D is 13,842,952 bytes; the **61,440-byte**
difference is exactly the independently measured marginal saving of rejected
variant B. This confirms the three size levers are additive on the reference
build.

The adoption gates all passed:

- no exported Babet C symbol and no init/fini/ctor/dtor section was discarded;
- deterministic TLS remained 7/7 on A and D, including X25519MLKEM768;
- the original local TLS benchmark remained under the precommitted 10% median
  regression threshold. A first final-integration replay exposed that the old
  24-request samples lasted only about 50–90 ms and were dominated by scheduler/CPU
  noise despite balanced ordering. The permanent cross-check therefore keeps the
  same 10% gate but calibrates samples to about one second, retries with a longer
  target when necessary, and requires both global and within-block paired medians
  to pass while reporting minima and relative MAD;
- a complete A campaign under a real `fr_FR.utf8` locale passed;
- complete normal + ASan/UBSan + release/network validation passed for A and D.

The production decision for Babet 2.23.0 is therefore:

- **adopt** linker `-Wl,--gc-sections`;
- **adopt** `-ffunction-sections -fdata-sections` for the vendored OpenSSL build;
- **do not adopt** those compiler flags on Babet-owned sources (variant B);
- keep one full-featured official runtime; no `minimal`/`standard`/`full` product
  profiles and no OpenSSL capability trimming.

`build_local.sh` fingerprints the exact OpenSSL Configure contract and rebuilds
the cached 3.5.8 archives when the stamp is absent or differs, so an older
unsectioned cache cannot silently defeat the adopted D configuration. The normal
OpenSSL bootstrap uses `build_libs` because Babet needs only `libcrypto.a` and
`libssl.a`.

The x86_64 D reference is **1,154,176 bytes (7.70%) smaller** than the published
2.22.2 stripped artifact (14,997,128 bytes) despite functionality added since
that release. This percentage is a reference-machine result, not an
architecture-independent guarantee. Re-measurement remains required for the
future aarch64/armhf release builds.
