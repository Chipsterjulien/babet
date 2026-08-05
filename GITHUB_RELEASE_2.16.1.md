# Babet 2.16.1 — regenerated final documentation

Babet 2.16.1 is a documentation-only patch release.

The Babet 2.16.0 source code, runtime behavior, public API, and terminal
lifecycle implementation are unchanged. This patch republishes the generated
English and French PDF manuals from the final Markdown documentation that
includes the last terminal-handoff race fix.

## Fixed

- regenerated `docs/manual-en.pdf`;
- regenerated `docs/manual-fr.pdf`;
- updated current-version references and examples to 2.16.1;
- updated the release checklist and bilingual changelogs.

## Runtime compatibility

There is no runtime behavior change compared with Babet 2.16.0. Existing Lua
scripts and binaries keep the same API and process-management semantics.

The 2.16.0 terminal lifecycle work remains unchanged, including:

- explicit `running`, `stopped`, `exited`, and `closed` process states;
- `process:resume()`;
- asynchronous terminal reclamation after child exit;
- serialized handoff between immediate successive interactive spawns;
- protection against an older monitor reclaiming the terminal from a newer
  interactive child.

Babet remains Linux-only.
