> **English** | [Français](README.fr.md)

<p align="center">
  <img src="docs/assets/babet-closed.png" alt="Babet — pine cone" width="200">
</p>

# Babet

> *Babet*, n.m. — regional word from south-eastern France
> (Lyonnais, Forez, Dauphiné, Savoie, and adjacent Swiss
> Romandy) for a pine cone. Small, light, packed with seeds,
> and good for starting a fire — like this binary.

A standalone Lua 5.5 binary for Linux scripting and automation, written
in C++23. Embeds OpenSSL, SQLite, miniz, nlohmann/json, cpp-httplib,
and tomlplusplus statically — one binary, no system dependencies
beyond glibc.

Current development version: **2.4.0**. Latest audited release: **2.3.0**. See the
[English changelog](CHANGELOG.md) or the
[French changelog](CHANGELOG.fr.md).

Can be used in three modes:

1. **As a Lua interpreter** : `babet script.lua` or `babet folder/`
   (looks for `main.lua` inside).
2. **As a packager** : `babet --create-exe ./myproject app` produces a
   self-contained executable with the script and its `require`d modules
   embedded as a ZIP appended to the binary.
3. **As a library of bindings** : Lua scripts get
   `babet.json`, `babet.http`, `babet.sqlite`,
   `babet.socket`, `babet.inotify`, `babet.workers`,
   `babet.user`, `babet.exec`, the streaming `babet.spawn`, and more.

## Quick start

```sh
git clone https://github.com/Chipsterjulien/babet.git
cd babet
./build_local.sh        # downloads deps and compiles (~5 min first time)
./run_tests.sh          # offline harness — should finish with 0 FAIL
./test/babet --help
```

The build script vendors and compiles all its dependencies. The only
prerequisites on your system are a C++23 compiler, CMake, `wget`, and
`unzip`.

## Pre-release validation

Before tagging a release, run the complete validation with one command:

```sh
./run_tests.sh --release
```

Babet's blocking TLS checks use a local HTTPS fixture generated at runtime.
Public HTTPS probes are advisory by default, so a third-party outage, proxy,
DNS filter, or TLS interception does not invalidate a release. To make those
probes blocking too:

```sh
BABET_SMOKE_STRICT_EXTERNAL=1 ./run_tests.sh --release
```

It automatically runs the ASan/UBSan suite, restores and revalidates the
normal build, then runs the network smoke tests against that final binary.
The normal build step is still attempted when the sanitizer stage fails, so
`test/babet` is not deliberately left instrumented. Internet access is
optional: without it, only the advisory public probes warn. The blocking TLS
checks use a local fixture; the bounded TCP check uses a reserved TEST-NET
address. The network stage requires the `python3` and `openssl` commands.

The individual commands remain available for diagnosis:

```sh
./run_tests.sh --sanitizers
./run_tests.sh
./smoke_test_network.sh ./test/babet
```

Valgrind is optional; ASan and UBSan are the primary memory and undefined
behaviour checks used by the project.

## Documentation

- **English** : [`docs/en/README.md`](docs/en/README.md)
- **Français** : [`docs/fr/README.md`](docs/fr/README.md)

The docs are split per module under `docs/en/modules/` (and `docs/fr/`).
You can generate a single PDF manual with:

```sh
cd docs && ./build_doc.sh en   # or: ./build_doc.sh fr
```

Requires `pandoc` and a LaTeX engine (`texlive-xetex` is fine).

## Releases

The maintainer release checklist is documented in
[`RELEASING.md`](RELEASING.md).

Download prebuilt binaries from the
[releases page](https://github.com/Chipsterjulien/babet/releases).

## Development methodology

Babet was developed by a single human author with substantial AI
assistance, primarily Claude (Anthropic) for design discussions,
code generation, and documentation drafting. Cross-audits were
performed regularly with ChatGPT (OpenAI), Gemini (Google), and
Mistral, and the suggestions from these audits were applied only
after verification against the actual source code — AI tools
occasionally hallucinate bugs that aren't there, or invent APIs
that don't exist, so every suggestion was treated as a hypothesis
to test, not a fix to apply blindly.

The pine cone illustrations in `docs/assets/` were generated with
ChatGPT (image model gpt-image-1).

All architectural decisions, the comprehensive test harness across folder
and embedded modes, and the validation of every change before tagging are
the author's responsibility. The AI tools accelerated drafting
and exploration; they did not replace human judgement.

## License

See [LICENSE](LICENSE).
