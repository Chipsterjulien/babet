# Babet 2.9.0

Babet 2.9.0 makes process-driven automation and concurrent Lua workers safer,
more predictable, and easier to integrate with tools such as Selenium. It adds
configurable `spawn()` redirections, native binary Base64, secure atomic file
publication, bounded worker lifecycle operations, and direct shared channels
between workers.

Historical calls keep their previous defaults: `babet.spawn()` still creates
three non-blocking pipes unless redirections are requested, and worker arguments
and results keep the same JSON-based transfer rules.

## Configure process standard streams

`babet.spawn(command, args, opts)` now accepts `pipe`, `inherit`, and `null` for
standard streams, regular-file redirections for stdout and stderr, and
`stderr = "stdout"` merging. Destinations are opened before `fork()`, symbolic
outputs and non-regular files are refused, and unavailable streaming methods
return the stable `not_piped` reason.

A WebDriver can therefore run without an undrained output pipe:

```lua
local driver = assert(babet.spawn("bin/geckodriver", {
    "--port=4444",
}, {
    stdin = "null",
    stdout = {
        file = "logs/geckodriver.log",
        append = true,
        permissions = tonumber("600", 8),
    },
    stderr = "stdout",
}))
```

## Encode and decode binary Base64 natively

`babet.base64.encode()` and `babet.base64.decode()` support arbitrary Lua byte
strings, standard and URL-safe alphabets, optional padding, strict canonical
validation, optional ASCII whitespace, and an inclusive decoded-output limit.
The module is available in both the main state and workers and needs no external
`base64` command.

## Publish files atomically

`babet.writeFileAtomic(path, data, opts)` writes binary data through a private
same-directory temporary file, refuses overwrites by default, applies bounded
permissions, rejects symbolic path components and special destinations, and
synchronizes the file and parent directory by default.

## Control worker lifetime without forced cancellation

Workers now reject unknown spawn options and expose:

- `job:status()` with `running`, `done`, and `error`;
- `job:join(timeout?)`, including non-blocking `0` and `(nil, "timeout")`;
- idempotent cooperative `job:cancel()`;
- `worker.cancelled()` inside the worker.

Timeouts do not consume results or close queues. Cancellation wakes blocked
worker inbox and channel operations while leaving the outbox drainable for a
final message. Babet deliberately does not use unsafe `pthread_cancel()`.

## Connect workers directly

`babet.workers.channel({ capacity = 64 })` creates a bounded FIFO, thread-safe,
multi-producer/multi-consumer channel. Handles are passed explicitly through
`workers.spawn(..., { channels = ... })` and appear in `worker.channels`.

Channels support timed `send()` and `recv()`, idempotent close, draining after
close, typed `full`, `empty`, `timeout`, `closed`, and `cancelled` reasons, and
reference-counted lifetime across independent Lua states. Messages use the same
bounded JSON-compatible transport contract as existing workers.

## Validation

The final release candidate passed:

- 3319 PASS / 0 FAIL in folder mode;
- 3306 PASS / 0 FAIL in embedded mode;
- 3306 PASS / 0 FAIL in embedded mode through `PATH`;
- 9/9 runtime modes under ASan + UBSan;
- 9/9 runtime modes with the final normal build.

The complete release gate, including local TLS and network smoke tests, is:

```sh
./run_tests.sh --release
```
