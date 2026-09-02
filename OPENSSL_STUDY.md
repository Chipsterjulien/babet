# Babet OpenSSL size study — Candidate 9

Candidate 9 is an **observation and protection** lot. It changes no OpenSSL
`Configure no-*` option and creates no public `minimal`, `standard` or `full`
Babet edition.

## Security baseline first

Candidate 8 used vendored OpenSSL 3.5.6. Before collecting any new composition
data, Candidate 9 updates the pinned dependency to OpenSSL **3.5.8**.

Source archive SHA-256:

```text
a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
```

The build cache now checks the exact pinned OpenSSL directory. An older
`build/openssl/openssl-3.5.x/libssl.a` can no longer make the builder believe the
current version is already compiled.

Candidate 8's eight 3.5.6 measurements remain historical and are not silently
rebased.

## Exact map, no comparison rebuild

`./build_local.sh --size-audit` already emits the GNU ld map for the exact Babet
link that produces `build/size-audit-babet`.

Candidate 9 therefore analyses that map directly. It does **not** create a
second CMake build with injected linker flags. This simultaneously:

- keeps all flags identical to the baseline by construction;
- avoids CMake `try_compile` issues when the project path contains spaces;
- removes a redundant source of measurement drift.

`tools/measure_openssl_map.sh` copies the exact map into
`build/openssl-study/babet.map` and records baseline SHA-256, byte size, Git
commit when available, architecture, compiler, ld, strip and OpenSSL provenance.

## Questions

1. Which `libcrypto.a` / `libssl.a` members enter the x86_64 Babet link?
2. How many mapped input-section bytes do they contribute?
3. Why did GNU ld extract them, where the map exposes that relationship?
4. What is the review-only upper bound represented by PQC, legacy-provider and
   historical-algorithm families?
5. Does deterministic local TLS coverage protect a real certificate chain,
   TLS 1.2/1.3, RSA/ECDSA, RSA-PSS, X25519/P-256/P-384,
   AES-GCM/ChaCha20-Poly1305 and `X25519MLKEM768` when available?
6. Does the current runtime trust-store probing contract remain visible and
   functional on the maintainer host?

## TLS protection matrix

The local fixture creates:

```text
root CA -> intermediate CA -> server leaf
```

The client trusts only the root. The server sends the intermediate, so chain
building and intermediate validation are exercised.

Targeted handshakes force representative capabilities instead of relying on
OpenSSL's default negotiation:

- TLS 1.2 + RSA + PKCS#1 + X25519 + AES-GCM;
- TLS 1.2 + ECDSA + P-256 + AES-GCM;
- TLS 1.3 + RSA-PSS + X25519 + AES-GCM;
- TLS 1.3 + RSA-PSS + P-384 + AES-GCM;
- TLS 1.3 + ECDSA + P-256 + ChaCha20-Poly1305;
- TLS 1.3 + RSA-PSS + X25519MLKEM768 + AES-GCM when the vendored OpenSSL CLI
  exposes the hybrid group.

These tests are deterministic and local. Existing public HTTPS probes remain
useful reality checks but are not turned into blocking third-party dependencies.

## Trust store

The vendored OpenSSL build keeps:

```text
./Configure no-shared --openssldir=/etc/ssl
```

Babet's TLS runtime also calls `SSL_CTX_set_default_verify_paths()` and probes
common Linux trust-bundle locations, including Debian/Ubuntu/Arch,
Fedora/RHEL and openSUSE paths. Candidate 9 audits this existing contract and
runs a public HTTPS verification smoke on the maintainer host.

Cross-distribution container validation remains a separate portability check;
Candidate 9 does not claim that source inspection alone proves every distro.

## Guardrails

- No OpenSSL `no-*` size option is introduced in Candidate 9.
- `no-err` is rejected as a release-size optimisation if it degrades
  user-visible TLS diagnostics, regardless of byte savings.
- Filename-family classification is heuristic and never means "safe to remove".
- The reported PQC + legacy + historical total is a **review-only upper bound**,
  not a predicted Configure saving.
- A Configure experiment is considered only if at least **512 KiB of plausibly
  removable bytes** survive capability review.
- Final acceptance would still require at least **512 KiB realised**, all
  deterministic TLS tests green, no public capability loss and no useful
  diagnostic degradation.
- All size conclusions in this campaign are x86_64-specific. ARM must be
  measured separately before any optimisation is generalised.

## Run

Candidate 9 is deliberately one command:

```sh
./tools/run_candidate9_openssl_study.sh
```

The runner checks its contracts, builds a fresh OpenSSL 3.5.8 size-audit
baseline, analyses that exact map, executes the TLS capability matrix and audits
the trust-store contract.

## Candidate 9 measured conclusion

The x86_64 OpenSSL 3.5.8 baseline measured 15,563,592 stripped bytes. The exact
link map attributed 5,079,501 mapped input-section bytes to `libcrypto.a` and
834,788 to `libssl.a`. The protected TLS matrix completed at 7 PASS / 0 FAIL /
0 SKIP, including `X25519MLKEM768`; PQC is therefore part of the protected
current capability set, not a free trimming candidate.

After reviewing QUIC/DTLS/SRP/CMP/CMS/CT/OCSP/compression and other plausibly
optional families, the capability-safe review ceiling remains below the 512 KiB
entry gate even before any mapped-bytes/file-bytes conversion. Candidate 9
therefore closes with **STOP: no OpenSSL `Configure no-*` size experiment**.
OpenSSL 3.5.8 and the deterministic TLS protections are retained.

Candidate 10 follows a different path: section garbage collection without
removing public cryptographic capabilities.
