# Babet embedding examples

These examples are intentionally small and each focuses on one part of the
experimental C embedding API. The complete English and French guides are
[`../../EMBEDDING.md`](../../EMBEDDING.md) and
[`../../EMBEDDING.fr.md`](../../EMBEDDING.fr.md).

When this directory comes from the standalone SDK:

```sh
cmake -S . -B build -DBABET_SDK_DIR=../..
cmake --build build
ctest --test-dir build --output-on-failure
```

Examples 01–06 cover lifecycle, module roots, scalar values, direct Lua calls,
errors and threading. `07_host_functions.c` shows the Lot 10 reverse direction:
a C callback is registered as `babet.host.greet()` and returns a copied scalar
string to Lua.

The examples are also compiled and executed by Babet's embedding regression.
