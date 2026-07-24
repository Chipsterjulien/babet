# Babet 2.9.1

Babet 2.9.1 is a targeted corrective release for the HTTP client.

## Fixed

- Restored responses using `Transfer-Encoding: chunked` with the bundled
  cpp-httplib 0.45.0. Babet 2.9.0 could fail on the first non-empty chunk with
  `http: Failed to read connection`.
- Restored responses without `Content-Length` whose body ends when the
  connection closes; they were affected by the same internal-limit setting.
- Kept `max_body_size` and `max_file_size` fully enforced by Babet's own
  receivers, including explicit limit errors, no partial in-memory body,
  preservation of an existing destination, and removal of staging files.

## Regression coverage

The local test server now covers:

- 128 KiB chunked responses in memory and direct-to-file downloads;
- exact and one-byte-below limits;
- fragmented chunks, chunk extensions, and trailers;
- connection-close-delimited bodies;
- truncated chunked streams and atomic-download cleanup.

The release smoke suite also contains independent required local tests through
both receivers: HTTPS for chunked framing, and HTTP for connection-close
framing. Public AUR probing remains advisory; the blocking regression coverage
is fully local and deterministic.

The local dependency bootstrap was also hardened for Zstandard. Partial
installations now require rebuilding, incomplete source trees are re-extracted
cleanly, and the release gate runs a network-free regression preflight before
compilation.

## Compatibility

No Lua API changed. This release is a drop-in corrective update for Babet 2.9.0.
