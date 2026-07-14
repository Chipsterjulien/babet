# Releasing Babet

This checklist is intentionally short. The complete pre-release validation is
available through one command.

## 1. Set the release version

Update the version in `CMakeLists.txt` and the examples in the documentation.
Regenerate both PDF manuals after a documentation change.

## 2. Validate the exact release tree

```sh
./run_tests.sh --release
```

This must finish with:

```text
ASan + UBSan        : OK
Build normal final  : OK
Smoke tests réseau  : OK
Validation pré-release : OK
```

The blocking TLS checks are local. Public HTTPS probes are advisory by
default. To make those external probes blocking:

```sh
BABET_SMOKE_STRICT_EXTERNAL=1 ./run_tests.sh --release
```

The network stage requires the `python3` and `openssl` commands. Its blocking
TLS checks use a local fixture; public HTTPS probes remain advisory unless
strict mode is enabled.

## 3. Review the Git tree

```sh
git status --short
git diff --check
git diff --stat
```

Review every untracked file and ensure build products, local downloads,
temporary archives, and test binaries are not staged.

## 4. Commit and push

```sh
git add -A
git commit -m "Release Babet 2.4.0"
git push
```

## 5. Tag the validated commit

```sh
git tag -a v2.4.0 -m "Babet 2.4.0"
git push origin v2.4.0
```

## 6. Build release artifacts

Run the project release script from the tagged commit:

```sh
./release.sh --version 2.4.0
```

Verify the generated checksums before uploading artifacts to GitHub Releases.
