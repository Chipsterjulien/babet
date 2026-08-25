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
dependency, while the standalone embedding SDK can be moved outside the source
tree and used to compile, link and run a fresh external C host. This is a
validated pre-release implementation datapoint and does not replace the
published-release row at the top of this file.
