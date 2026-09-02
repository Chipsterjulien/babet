# Binary-size and build-profile study

Status: Candidate 8 measurement campaign closed; no public profile range is
planned. Candidate 9 now studies the OpenSSL contribution without changing
public capabilities.

## Product invariant

Babet remains centred on `--create-exe`: one Lua project can become one
self-contained executable without a compiler/linker on the machine that runs
`--create-exe`.

`--create-exe` embeds the Babet runtime used as its builder. It does **not**
analyse the Lua application and relink a smaller native runtime. This distinction
is central to the profile decision below.

## Phase 1 — attribution, without changing features

`./build_local.sh --size-audit` builds the normal Babet feature set and asks GNU
ld for `build/project_build/babet-link.map`. It also produces the stripped
measurement binary `build/size-audit-babet` and the coarse attribution report
`build/size-audit.txt`.

The report groups linked input-section bytes into areas such as GUI, ncursesw,
SQLite, archive/compression, network/TLS/WebSocket, RE2/Abseil, plugins,
embedding, workers, process/pipeline and `--create-exe` packaging.

This attribution is **not** removable-size measurement. Shared code, static
dependencies, alignment, linker-generated data and cross-feature references
make categories non-additive. Phase 1 exists only to shortlist candidates.

The first real x86_64 attribution run used a 15,559,496-byte stripped binary and
identified SQLite, `find`+RE2, network and archive/compression as the four
largest clean feature candidates. The OpenSSL crypto/TLS dependency was also
large but shared by network and file hashing.

## Phase 2 — real differential measurements

`tools/measure_size_deltas.sh` performs maintainer-only builds against the same
stripped baseline. Candidate 8 completed eight measurements:

| Variant | Size | Saved | Baseline |
|---|---:|---:|---:|
| `without-sqlite` | 14,247,816 | 1,311,680 | 8.43% |
| `without-find-re2` | 14,719,392 | 840,104 | 5.40% |
| `without-network` | 13,405,672 | 2,153,824 | 13.84% |
| `without-archive-compression` | 13,741,704 | 1,817,792 | 11.68% |
| `without-hashing` | 15,526,728 | 32,768 | 0.21% |
| `without-network-hashing` | 7,828,840 | 7,730,656 | 49.68% |
| `without-four-large` | 9,407,392 | 6,152,104 | 39.54% |
| `without-four-large-hashing` | **3,830,560** | **11,728,936** | **75.38%** |

The network-only and hashing-only rows show that hashing code itself costs only
32,768 bytes while OpenSSL remains needed by the network stack. Removing both
allows a much larger shared dependency effect:

```text
7,730,656 - 2,153,824 - 32,768 = 5,544,064 bytes
```

The identical marginal effect after the four large blocks are removed shows
that SQLite, `find`/RE2 and archive/compression are not part of that
network↔hashing/OpenSSL interaction.

The four one-feature deltas total 6,123,400 bytes; `without-four-large` saves
6,152,104 bytes, only 28,704 bytes more. Those four blocks are therefore highly
separable in this x86_64 build.

## Candidate 8 decision — no public profiles

The study deliberately used an asymmetric rule:

- a small measured gain can reject an externalisation/profile idea immediately;
- a large measured gain merely permits further study;
- adoption still requires the permanent complexity to remain low.

Candidate 8 passes the numerical gate but fails the product-complexity gate.

A user who downloads a reduced Babet gets a reduced runtime. An executable made
with that builder inherits the same reduced runtime; it does not become small
because its Lua source happened not to use SQLite, HTTP or archives.

Public `minimal` / `standard` / `full` profiles would therefore require a
permanent capability matrix, profile-specific validation, documentation and
downstream requirements for Babet Lua projects and libraries. That complexity
is not justified by a reported user problem.

**No public `minimal` / `standard` / `full` profiles are introduced.**

The experimental CMake switches remain maintainer measurement tools and can
also describe custom self-build possibilities. They are not supported product
editions and do not imply a future `--features` command.

## Candidate 9 — OpenSSL composition before optimisation

Candidate 8 exposed a large shared OpenSSL contribution. The next question is
whether any meaningful part can be removed **without** reducing Babet's public
TLS, cryptographic or diagnostic capabilities.

Candidate 9 therefore changes no OpenSSL `Configure no-*` option. It first:

1. updates the vendored security baseline from OpenSSL 3.5.6 to 3.5.8;
2. analyses the exact linker map emitted by the fresh `--size-audit` build;
3. attributes `libcrypto.a` / `libssl.a` input sections by archive member and
   records GNU ld extraction reasons where available;
4. strengthens deterministic local TLS coverage with a root → intermediate →
   leaf chain and forced TLS/cipher/group/signature cases;
5. audits the existing default trust-store probing contract.

Any size conclusion is x86_64-specific. ARM composition may differ and must be
measured independently before an optimisation is generalised.

See `OPENSSL_STUDY.md` for Candidate 9's detailed guardrails.
