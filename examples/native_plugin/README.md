# Babet native plugin examples

Build both standalone shared objects:

```sh
cmake -S examples/native_plugin -B build/native-plugin-examples
cmake --build build/native-plugin-examples
```

Run one explicitly with the original Babet CLI:

```sh
./test/babet examples/native_plugin \
  ./build/native-plugin-examples/babet-example-c.so
```

The `.so` files intentionally do not link against `libbabet.so`. At load time
they resolve only the narrow `babet_host_call_*` C surface exported by the Babet
executable. The C++ example exposes an `extern "C"` `noexcept` callback, catches
its own C++ exceptions, and uses `std::string` internally before copying the
result through `babet_host_call_set_result()`. Babet does not rely on catching
C++ exceptions across the plugin DSO boundary.

Generated `--create-exe` applications, workers and external embedding hosts do
not load native plugins in Lot 11.
