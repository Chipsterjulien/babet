# Releasing Babet

This checklist freezes the exact tree that will be tagged and published.

## 1. Set and verify the release version

Update `CMakeLists.txt`, user-facing version examples, both changelogs, and the
stable-release wording in the README files. Rebuild both PDF manuals after the
last documentation change, not before it:

```sh
cd docs
./build_doc.sh
cd ..
```

Confirm that `docs/manual-en.pdf` and `docs/manual-fr.pdf` were both regenerated
and render them for a final visual check before validating the release tree.

For 2.17.0, the expected source line is:

```cmake
project(babet VERSION 2.17.0 LANGUAGES CXX C)
```

## 2. Validate the exact release tree

```sh
./run_tests.sh --release
```

This command always replaces `babet-tests.txt` at the project root with the
complete validation output stripped of terminal colors. Keep that file as the
validation record and provide it for review when requested.

Each build first runs the network-free Zstandard, inotify-buffer,
worker-serialization, parent-side process-launch, and Lua/C++
exception-boundary preflights. After
compilation it also runs the inherited-terminal `babet.spawn` regression under
a real pseudo-terminal before the broader execution modes. The complete
release command then runs its three stages and must finish with:

```text
ASan + UBSan           : OK
Build normal final     : OK
Smoke tests réseau     : OK
Validation pré-release : OK
```

The blocking TLS checks are local. Public HTTPS probes are advisory by default.
To make those external probes blocking:

```sh
BABET_SMOKE_STRICT_EXTERNAL=1 ./run_tests.sh --release
```

Then verify the compiled version explicitly:

```sh
./test/babet --version
# expected: babet 2.17.0
```

## 3. Review the Git tree

```sh
git status --short
git diff --check
git diff --stat
git diff
```

Review every untracked file. Build products, `dist/`, local downloads,
temporary archives, and test binaries must not be staged.

## 4. Commit the validated tree

```sh
git add -A
git commit -m "Release Babet 2.17.0"
git status --short
```

`git status --short` must print nothing.

## 5. Create the annotated tag

```sh
git tag -a v2.17.0 -m "Babet 2.17.0"
git show --stat --oneline v2.17.0
```

## 6. Build and verify release artifacts

Run the release builder while `HEAD` is the tagged commit:

```sh
./release.sh --build --version 2.17.0
```

The script refuses a version that does not match the compiled binary. Verify all
generated checksums:

```sh
cd dist
sha256sum -c babet-2.17.0-linux-*.sha256
cd ..
```

## 7. Push the commit and tag

```sh
branch="$(git branch --show-current)"
git push origin "$branch"
git push origin v2.17.0
```

## 8. Publish the GitHub release

With GitHub CLI:

```sh
gh release create v2.17.0 \
  dist/babet-2.17.0-linux-* \
  --title "Babet 2.17.0" \
  --notes-file GITHUB_RELEASE_2.17.0.md
```

Otherwise create release `v2.17.0` in the GitHub web interface and upload the
four files from `dist/`: the tarball, its checksum, the standalone binary, and
its checksum.
