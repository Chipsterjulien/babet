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

The examples are also compiled and executed by Babet's embedding regression.
