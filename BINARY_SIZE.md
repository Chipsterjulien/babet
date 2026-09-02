# Babet release binary size history

This file is a lightweight release-size baseline. It exists to detect an
unexpected long-term size drift, not to make binary size an optimisation goal.

Measure the **actual published stripped x86_64 release binary**, rather than a
local development/test build.

| Version | Commit | Architecture | Stripped size |
|---|---|---|---:|
| 2.22.2 | `1b88628` | x86_64 | 14,997,128 bytes |

## 2.22.2 reference inspection

Published binary SHA-256:

```text
b1d4bd91d98614c23b2935458dc1ecdb9ff66e55acec92e3250763a3431cd361
```

`file` reports a stripped 64-bit x86-64 PIE ELF executable for GNU/Linux.
`ldd` shows only the glibc runtime (`libc`, `libm`, and the ELF loader) as
dynamic dependencies; Babet's bundled third-party libraries remain embedded in
the release binary.

No `.debug_*` or `.zdebug_*` section is present.

The largest reported `size -A` sections are:

| Section | Size (bytes) |
|---|---:|
| `.text` | 10,420,114 |
| `.eh_frame` | 1,487,384 |
| `.rodata` | 1,211,344 |
| `.rela.dyn` | 783,792 |
| `.data.rel.ro` | 577,040 |
| `.eh_frame_hdr` | 311,244 |

The `.rela.dyn` section is relatively visible at 783,792 bytes (about 5% of
the file). This is expected for the PIE build: removing PIE could recover much
of that relocation data, but would also give up ASLR for the executable itself.
That security-for-size trade-off is explicitly **not** justified by this
baseline measurement.

The unwind/exception metadata is also expected for the current C++23 design:
`.eh_frame`, `.eh_frame_hdr`, and `.gcc_except_table` together account for
roughly 1.9 MB. These tables support stack unwinding and the exception-boundary
work used throughout Babet; they are not treated as accidental bloat.

The `size -A` total (15,036,337 bytes) is larger than the on-disk file size
(14,997,128 bytes). This is expected, notably because sections such as `.bss`
are counted by `size` even though they do not occupy corresponding bytes in the
file. `size -A` must therefore not be used as a replacement for `stat`.

The explicit belt-and-suspenders check
`readelf -S <binary> | grep -E '\.symtab|\.strtab'` was also run against the
**published** v2.22.2 artifact and returned no `.symtab`/`.strtab`. This matters
because `size -A` does not list non-allocated sections; the release is therefore
confirmed stripped both by `file` and by direct section inspection.

## Lot 5 ncursesw maintainer validation

The Lot 5 ncursesw implementation was validated on the maintainer Linux
machine on 2026-08-24. The stripped validation binary measured:

| Build | Architecture | Stripped size | Delta vs 2.22.2 baseline |
|---|---|---:|---:|
| Lot 5 ncursesw validation | x86_64 | 15,436,616 bytes | +439,488 bytes (+2.93%) |

The PTY/runtime regression also confirmed that ncursesw/terminfo add **no
dynamic runtime dependency** and that a `--create-exe` generated application
retains an autonomous curses runtime. This measurement is a validated
pre-release implementation datapoint; it does not replace the published
2.22.2 release baseline above until a future release artifact is published and
measured itself.

The +439,488-byte delta is consistent with the deliberately small static
ncursesw integration plus the compiled fallback terminfo set and does not
justify size-optimisation work.

### Decision

Nothing in the 2.22.2 release inspection indicates accidental debug data,
failed stripping, or an abnormal size contribution. The 14,997,128-byte
release is therefore the baseline and no size-optimisation work is justified
by Lot 1.

Only investigate with an unstripped binary, `nm`, a linker map, Bloaty, LTO,
section garbage collection, or dependency-specific trimming if a future
release shows a meaningful unexplained drift.

## Lot 6 embedding maintainer validation

The final Lot 6 normal maintainer run on 2026-08-25 measured the stripped Babet
CLI at **15,440,712 bytes**. Relative to the published v2.22.2 baseline this is
**+443,584 bytes (+2.96%)**. Relative to the final Lot 5 ncurses validation
datapoint (15,436,616 bytes), the increase is only **4,096 bytes**.

The same validation proves that the official CLI has no runtime `libbabet.so`
dependency, while the standalone developer SDK can be moved outside the source
tree and used to compile, link and run a fresh external C host. This is a
validated pre-release implementation datapoint and does not replace the
published-release row at the top of this file.


## Post-2.23 GTK4 dynamic GUI maintainer validation

The first `babet.gui` GTK4 MVP was validated on the maintainer x86_64 Linux
machine on 2026-08-26. GTK4 is not linked into Babet: the bridge uses lazy
`dlopen()` / `dlsym()` and the runtime regression confirms that the normal Babet
ELF has no direct GTK/GObject/GLib GUI dependency.

| Build | Architecture | Stripped size | Delta vs published 2.23.0 measurement |
|---|---|---:|---:|
| GTK4 dynamic GUI MVP | x86_64 | 15,559,496 bytes | +36,864 bytes (+0.24%) |

The published 2.23.0 CLI measurement recorded in the 2.23.0 changelog is
15,522,632 bytes. The small delta therefore represents the Babet-side dynamic
loader, Lua binding, widget-handle/lifetime code and event-loop bridge rather
than GTK itself. GUI-generated applications remain one file, but GTK4 is an
explicit target-system runtime requirement when `babet.gui` is actually used.
Non-GUI Babet remains autonomous.

## Post-2.23 build-profile measurement methodology

Before introducing Gentoo-style feature switches, Babet now has an opt-in
`./build_local.sh --size-audit` mode. It emits a GNU linker map and a stripped
measurement copy, then writes `build/size-audit.txt` with coarse attribution by
component/dependency family. These figures are explicitly non-additive and are
not treated as removable-size deltas. They only shortlist candidates for later
one-feature-at-a-time differential builds; see `SIZE_PROFILES_STUDY.md`.

## Post-2.23 differential size measurements — Candidate 8

Candidate 8 is an **experimental maintainer campaign**, not a release-size
history row. It ran on x86_64 on 2026-08-26 with vendored OpenSSL 3.5.6 and a
stripped baseline of **15,559,496 bytes**.

The original differential report did not record the exact Git commit, GCC
version or binutils version. Those fields are therefore deliberately marked as
unavailable rather than reconstructed after the fact. Candidate 9 records this
provenance automatically for its new OpenSSL 3.5.8 baseline. Do not compare the
percentages below directly with the published-release table at the top of this
file.

| Experimental removal | Stripped size | Real delta | Baseline |
|---|---:|---:|---:|
| SQLite | 14,247,816 bytes | 1,311,680 bytes | 8.43% |
| `find` + RE2 | 14,719,392 bytes | 840,104 bytes | 5.40% |
| network | 13,405,672 bytes | 2,153,824 bytes | 13.84% |
| archive/compression | 13,741,704 bytes | 1,817,792 bytes | 11.68% |
| hashing only | 15,526,728 bytes | 32,768 bytes | 0.21% |
| network + hashing | 7,828,840 bytes | 7,730,656 bytes | 49.68% |
| four large blocks | 9,407,392 bytes | 6,152,104 bytes | 39.54% |
| four large blocks + hashing | 3,830,560 bytes | 11,728,936 bytes | 75.38% |

The individual network and hashing deltas isolate a shared
network/hashing/OpenSSL effect of **5,544,064 bytes**:

```text
7,730,656 - 2,153,824 - 32,768 = 5,544,064
```

The same marginal amount appears when hashing is removed after the four large
blocks are already absent. This demonstrates that the observed interaction is
between network and OpenSSL-backed hashing; SQLite, `find`/RE2 and
archive/compression do not participate in that interaction.

The four one-feature deltas sum to 6,123,400 bytes, while removing those four
blocks together saves 6,152,104 bytes: only 28,704 bytes of additional
interaction in this build.

### Candidate 8 decision

The measurements cross the project's numerical threshold for *studying*
configuration, but they do **not** satisfy the second criterion needed for a
public product split. `--create-exe` embeds the runtime used as its builder; it
does not relink per application. A 3,830,560-byte experimental runtime is
therefore a deliberately reduced Babet installation, not an automatically
trimmed small application.

Public `minimal` / `standard` / `full` editions would add permanent capability,
test, distribution and downstream-dependency complexity. Candidate 8 therefore
closes with **no public build-profile range**. The experimental CMake switches
remain maintainer measurement scaffolding and may also document what custom
self-builds can achieve.

The large shared OpenSSL contribution instead motivates Candidate 9:
composition/protection analysis first, without changing OpenSSL `Configure`
options. Candidate 9 is rebased on OpenSSL 3.5.8 for security before collecting
new map data.


## Post-2.23 OpenSSL composition — Candidate 9 conclusion

Candidate 9 rebased the x86_64 baseline on vendored OpenSSL 3.5.8. The stripped
baseline measured **15,563,592 bytes** (only one 4 KiB file-size step above the
3.5.6 Candidate 8 baseline). Its exact size-audit map attributed 5,079,501 input-
section bytes to `libcrypto.a` and 834,788 to `libssl.a`.

The deterministic TLS fixture is green at **7 PASS / 0 FAIL / 0 SKIP**, including
a real root→intermediate→leaf chain, TLS 1.2/1.3, RSA/ECDSA, RSA-PSS, X25519,
P-256/P-384, AES-GCM, ChaCha20-Poly1305 and `X25519MLKEM768`. PQC is therefore
part of the currently protected capability surface rather than a free size target.

After capability review, the plausible `Configure no-*` removal ceiling remains
below the precommitted **512 KiB** entry threshold even in mapped input-section
bytes. Candidate 9 therefore closes with **STOP: no OpenSSL capability trimming**.
The strengthened TLS tests and OpenSSL 3.5.8 security baseline are retained.

Candidate 10 studies section garbage collection instead, with no capability
removal and a separately precommitted 256 KiB realised-saving gate.


## Post-2.23 section-GC measurements — Candidate 10 / Candidate 11 gate

Candidate 10's x86_64 Ubuntu/GCC 13.3 baseline with OpenSSL 3.5.8 is
**15,563,592 bytes**. Linker-only section GC (A) reaches **14,445,384 bytes**,
a real saving of **1,118,208 bytes (7.18%)**. Adding function/data sections to
Babet-owned code (B) saves only another **61,440 bytes**, so B is rejected.

Candidate 11 closes the attribution question with a fresh production-control
witness: the control reproduces A **byte-for-byte** at 14,445,384 bytes, while D
(A + OpenSSL built with `-ffunction-sections -fdata-sections`, without Babet
source splitting) measures **13,842,952 bytes**. D therefore saves **1,720,640
bytes (11.06%)** versus the 15,563,592-byte Candidate 11 baseline and **602,432
bytes** versus A.

The independent Candidate 10/11 cross-check is exact: C (A+B+OpenSSL split) is
13,781,512 bytes and D (A+OpenSSL split) is 13,842,952 bytes; their **61,440-byte**
difference is exactly B's marginal saving. B remains rejected.

The full Candidate 11 audit, real-locale run, deterministic TLS matrix,
ASan/UBSan, release/network validation and performance gate all pass. Production
therefore adopts linker `--gc-sections` plus OpenSSL function/data sections while
leaving Babet-owned source splitting disabled.

On the x86_64 Ubuntu/GCC 13.3 reference build, D is **1,154,176 bytes (7.70%)
smaller** than the published 2.22.2 stripped artifact (14,997,128 bytes) despite
functionality added since that release. This is a reference-machine result; the final native architecture
measurements are recorded below.

## Final native production measurements — Babet 2.23.0

The adopted production configuration — linker `--gc-sections` plus vendored
OpenSSL built with `-ffunction-sections -fdata-sections`, without Babet-owned
source section splitting — has now been validated natively on all three official
Linux release/SDK architectures.

The three final validations were performed from the **same source tree**. The
ARMHF-validated source snapshot used to propagate that exact tree to x86_64 and
AArch64 has SHA-256:

```text
8757524730661e81bb3e26cde1c0226d8140fa57227900e4fdad52f07213ce73
```

| Native release tag | Sanitizer gate | Stripped production size | Status |
|---|---|---:|---|
| `linux-x86_64` | ASan + UBSan | 13,842,952 bytes | validated natively |
| `linux-aarch64` | ASan + UBSan | 12,487,256 bytes | validated natively |
| `linux-armhf` | UBSan only | 9,861,000 bytes | validated natively |

These measurements are architecture-specific native results rather than
cross-compiled projections.

### linux-x86_64

Native validation host: Ubuntu, GCC 13.3.0, GNU ld 2.42.

```text
production_sha256=98340269ced1c84ddeccbe7708572a3f0b16cb9e6d25d79daf9ce336aede1b76
release_tarball_sha256=4159115b0ebc4e38bfd1db798aaabbcda8f2555b8eb647eede0bdf586f7894ca
sdk_tarball_sha256=023bcdeaf4f53ac319e1b434db2eab03fedf380ca2231cc2dc9e1e8f7dcc023b
```

The deterministic TLS matrix passes at **7 PASS / 0 FAIL / 0 SKIP**, and all
seven examples rebuilt from the packaged SDK execute natively.

### linux-aarch64

Native validation host: AArch64 Debian, GCC 12.2.0, GNU ld 2.40, vendored
OpenSSL 3.5.8.

```text
production_sha256=4c75175ef4d1f71f61de53d700ed7c164c6fa4ef196e8ba77f9e97287960867a
release_tarball_sha256=7b156518a8d538438c471188afedf8328610908ef515b6bd9c1d76c66dd86519
sdk_tarball_sha256=75224706619a6facb5ac9f6106e7b1dbf2e3b674adc70d1dc06013a2aceb2f5d
```

The deterministic TLS matrix passes at **7 PASS / 0 FAIL / 0 SKIP**, and all
seven examples rebuilt from the packaged SDK execute natively.

### linux-armhf

Native validation host: Raspberry Pi Zero, ARMv6 hard-float, GCC 12.2.0,
GNU ld 2.40, vendored OpenSSL 3.5.8.

```text
production_sha256=2ba942ecfa1012f66300ca9f4ea445c9fc3ee703069fc4ab8b1aa121196d4f2a
release_tarball_sha256=b813f7289fb1d3adb752fd8a6057250540002b7b65463cb6f99ea3afd4871c2e
sdk_tarball_sha256=9393559d2debf0e89ec5ca0410a9ef57b7a59a6700679e67a0163af7a5d08515
```

The ARMHF release gate deliberately uses **UBSan only**. GCC 12 ASan was
isolated as failing before `main()` on the ARMv6 system through the
ASan/libatomic runtime independently of Babet, while standalone UBSan succeeds.
This sanitizer-policy exception does not affect the production binary.

The runner also verifies the ARM hard-float ABI. The deterministic TLS matrix
passes at **7 PASS / 0 FAIL / 0 SKIP**, all seven packaged-SDK examples execute
natively, and the temporary hardware-watchdog suspension used for the
resource-constrained validation is restored successfully.

### Final decision

Native release-size follow-up for Babet 2.23.0 is complete.

No architecture remains pending. The final production measurements are:

```text
linux-x86_64  13,842,952 bytes
linux-aarch64 12,487,256 bytes
linux-armhf    9,861,000 bytes
```

Future size work should start from these native measurements and should not
reopen the completed Candidate 8–11 optimisation campaign without new evidence
of meaningful unexplained growth.
