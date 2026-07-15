# Babet 2.5.0

Babet 2.5.0 is the pipelines and secure ZIP release. It also closes the
filesystem race conditions found during the final pre-release audit.

## Highlights

- Added `babet.pipeline()` for shell-free synchronous pipelines.
- Added `babet.spawnPipeline()` for streaming stdin, final stdout, and separate
  stderr per stage.
- Added secure ZIP creation, inspection, full extraction, and single-file
  extraction through `babet.archive`.
- Added deterministic ZIP creation, ZIP64 support, anti-bomb limits, CRC
  validation, strict path confinement, source mutation detection, and atomic
  publication.
- Hardened `setAttributes()`, `touch()`, and `--create-exe` against destructive
  pathname replacement races.
- Added strict Lua type validation for `setAttributes()` and documented the
  unbounded-backtracking risk of untrusted `std::regex` patterns in
  `babet.find()`.

## Validation

- 2235 PASS / 0 FAIL in folder mode.
- 2222 PASS / 0 FAIL in embedded mode.
- 2222 PASS / 0 FAIL in embedded mode through `PATH`.
- 9/9 runtime modes under ASan + UBSan.
- 9/9 runtime modes again with the final normal build.
- The tagged tree must also pass `./run_tests.sh --release`, including the local
  TLS and network smoke-test stage.

## Compatibility notes

- Pipelines never invoke a shell; commands and arguments are separate strings.
- A pipeline's global code is the last stage's code. Inspect the per-stage
  result fields for intermediate failures.
- `touch()` refuses dangling final symlinks.
- `setAttributes()` requires strict Lua integers for UID, GID, and mode.
- Newly created ZIP entry names must be valid UTF-8.
- Do not pass untrusted regular expressions directly to `babet.find()`.

Full details are available in `CHANGELOG.md`, `CHANGELOG.fr.md`, and the English
and French PDF manuals.

---

# Babet 2.5.0 - résumé français

Babet 2.5.0 est la version des pipelines et des archives ZIP sécurisées. Elle
supprime également les courses destructrices sur les chemins découvertes lors
de l'audit final.

Principales nouveautés :

- pipelines synchrones et en streaming sans shell ;
- création, inspection et extraction ZIP sécurisées ;
- création déterministe, ZIP64, limites anti-bombe, contrôle CRC et publication
  atomique ;
- durcissement de `setAttributes()`, `touch()` et `--create-exe` ;
- validation stricte des types Lua et documentation du risque ReDoS de
  `babet.find()`.

La validation finale attendue est de 2235 PASS en mode dossier, 2222 PASS en
mode embarqué, 2222 PASS via `PATH`, et 9/9 modes aussi bien sous ASan + UBSan
qu'avec le build normal final.
