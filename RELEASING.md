# Releasing Babet

This checklist freezes the exact tree that will be tagged and published.

## 1. Set the release version

`CMakeLists.txt` is the single source of truth:

~~~cmake
project(babet VERSION X.Y.Z LANGUAGES CXX C)
~~~

Update that line first.

Then update both changelogs, the current-release wording in `README.md` and
`README.fr.md`, and the French/English manual landing pages.

`release.sh --version X.Y.Z` does not override the compiled version.
It is only an assertion and must match `CMakeLists.txt`.

## 2. Regenerate documentation

After the final Markdown change:

~~~sh
cd docs
./build_doc.sh en fr
cd ..
~~~

Confirm both PDFs were regenerated:

~~~sh
ls -lh docs/manual-en.pdf docs/manual-fr.pdf
~~~

## 3. Validate the exact release tree

~~~sh
./run_tests.sh --release
~~~

The optional sudo PTY layer is enabled only when `sudo -n true` succeeds from
the same fresh PTY used by the regression.

A normal password-based sudo configuration may therefore report one SKIP.
This is not a release failure.

Verify the compiled runtime explicitly:

~~~sh
./test/babet --version
~~~

It must match the version declared in `CMakeLists.txt`.

## 4. Review the Git tree

~~~sh
git status --short
git diff --check
git diff --stat
~~~

Build products, `dist/`, temporary archives, release-note scratch files and
packaging inventories must not be staged.

`GITHUB_RELEASE_*.md` and `MODIFIED_FILES.txt` are intentionally ignored.

## 5. Commit the validated tree

~~~sh
git add -A
git diff --cached --check
git diff --cached --stat
git commit
~~~

The working tree must then be clean.

## 6. Create the annotated tag

~~~sh
git tag -a vX.Y.Z -m "Babet X.Y.Z"
git show --stat --oneline vX.Y.Z
~~~

## 7. Build release artifacts

Run the builder from the exact tagged commit:

~~~sh
./release.sh --build --version X.Y.Z
~~~

The explicit version is only an assertion against the CMake source version.

Verify checksums:

~~~sh
cd dist
sha256sum -c babet-X.Y.Z-linux-*.sha256
cd ..
~~~

## 8. Push commit and tag

Prefer an atomic push:

~~~sh
branch="$(git branch --show-current)"
git push --atomic origin "$branch" vX.Y.Z
~~~

## 9. Publish the GitHub release

Release notes are publishing material, not tracked source files.

If a temporary notes file is useful, create it under the ignored `dist/`
directory:

~~~sh
$EDITOR dist/release-notes.md
~~~

Then publish with GitHub CLI or the GitHub web interface.

Do not add versioned `GITHUB_RELEASE_*.md` files to the repository.
