# Optional GUI study — Lot 7

Status: reviewed design decision, no GUI runtime is added to the `babet` CLI.

## 1. Goal

Lot 7 answers one architectural question before any GUI implementation is
started:

> How can Babet gain an optional graphical host without turning the normal
> `babet` executable into a heavy GUI runtime?

The answer must preserve the existing product contracts:

- the normal CLI remains autonomous and does not gain GUI dependencies;
- `babet --create-exe` remains the existing one-file CLI/application builder;
- GUI work must consume the validated `libbabet` embedding boundary instead of
  being pushed into the CLI;
- Linux remains the reference platform, while a future Windows port remains
  plausible;
- no generic `.so` plugin ABI is introduced as a side effect of GUI work.

This document is a technology and architecture study only. It deliberately does
not add GUI bindings or a GUI executable yet.

## 2. Architecture decision

A future GUI is a **separate companion host**, provisionally named
`babet-gui`, built against the standalone `libbabet` SDK.

Conceptually:

```text
babet                    babet-gui (optional, separate program)
-----                    --------------------------------------
CLI / --create-exe       GUI toolkit + libbabet SDK
same current binary      owns the desktop event loop
no GUI dependency        hosts the same Babet/Lua runtime
```

The normal `babet` executable must not link GTK, Qt, FLTK, wxWidgets or any
other GUI toolkit, either statically or dynamically. Therefore the GUI cost of
the ordinary Babet CLI remains exactly zero.

The companion may live in a separate source project/repository when real
implementation starts. Keeping the GUI consumer separate also prevents a GUI
toolkit, its build system and its transitive dependencies from becoming
prerequisites for building or testing Babet itself.

## 3. Candidate comparison

The comparison is about Babet's use case, not a claim that one toolkit is
universally better.

| Candidate | Strengths for Babet | Costs / risks for Babet | Lot 7 decision |
| --- | --- | --- | --- |
| **FLTK 1.4.x** | Small/modular by design; static linking explicitly supported by its licence; C++ API fits a C++ host; Linux X11/Wayland plus Windows; no Qt-style plugin deployment model | Less native-looking/richer than wxWidgets/Qt for complex desktop applications; modern Linux Wayland support still brings graphics/text dependencies such as Cairo/Pango/libdecor; exact final size must be measured from a real prototype | **Preferred first prototype** |
| **wxWidgets 3.2.x** | Mature C++; native controls/look on supported platforms; Linux + Windows; licence allows static or dynamic binary distribution on application terms | On Linux the common port is wxGTK, so GTK remains a substantial runtime/build dependency; generally a larger abstraction surface than FLTK | **Fallback if native desktop look becomes a stronger requirement than minimal deployment** |
| **GTK 4** | Excellent Linux/GNOME fit; C ABI; mature widget/event model; Windows backend exists; LGPL-2.1-or-later | Linux build/runtime pulls the GTK/GLib/GObject/Pango/Gdk stack; Windows deployment is a secondary path compared with native Win32-oriented toolkits; would couple the optional GUI closely to the GNOME stack | **Not selected as Babet's default GUI host** |
| **Qt 6** | Very complete, mature and strongly cross-platform; excellent tooling and widgets | Large framework and deployment surface; platform plugins and additional assets matter at deployment; open-source Qt is primarily LGPLv3/GPL and static distribution requires careful compliance (or commercial licensing); disproportionate for a small optional Babet host | **Rejected for the first Babet GUI host** |
| SDL / Dear ImGui-style stacks | Good rendering/game/tool UIs | Not a conventional desktop widget toolkit; would make Babet own more layout/widget behaviour and does not match the requested general GUI direction | **Out of scope for the first desktop GUI** |

No absolute binary-size number is frozen here. Package-manager sizes do not
measure the final application cost correctly, and static/dynamic configurations
change the result. A real GUI implementation must measure its own stripped host
binary and dynamic dependency closure before the toolkit choice is promoted
from "preferred prototype" to a long-term product decision.

## 4. Why FLTK is the first prototype candidate

FLTK currently best matches the constraints that made GUI work interesting in
the first place:

1. Babet should not grow simply because GUI support exists.
2. A future Windows port should not require replacing the entire GUI layer.
3. Static linkage should be a technically and legally normal option rather than
   an exceptional deployment mode.
4. A small conventional widget toolkit is sufficient for the first real use
   case; Babet does not need a web engine, multimedia framework, designer
   runtime or large application framework in its core.

FLTK 1.4 supports a hybrid Wayland/X11 Unix build that selects the available
backend at runtime. This is preferable to deliberately freezing a new GUI to
X11 merely to save dependencies.

The choice is not permanent. If a real prototype proves that widget richness,
accessibility integration or native visual integration matters more than the
size/deployment target, wxWidgets is the first alternative to benchmark.

## 5. Event-loop and threading model

The current embedding contract allows one live `babet_context` per process and
requires create/use/destroy on the same host thread. Desktop GUI toolkits also
normally own their event loop on the process main thread, so the constraints
align naturally:

```text
GUI main thread
  -> create babet_context
  -> load/bootstrap Lua application
  -> enter GUI event loop
  -> GUI event calls Lua callback on the same thread
  -> destroy babet_context before GUI host exits
```

GUI toolkit calls remain main-thread-only. Babet workers may still perform
background/non-GUI work, but a worker must never manipulate GUI widgets
directly.

## 6. Minimal bridge required before a GUI prototype

Lot 6 intentionally deferred arbitrary host callbacks. A useful Lua-driven GUI
cannot be implemented cleanly with only C-to-Lua calls: Lua also needs a narrow
way to request host operations such as creating a window or changing a label.

A GUI prototype therefore justifies reopening **one narrowly scoped embedding
feature**, not the generic plugin roadmap:

- register one or more host functions in the main embedded Lua state without
  exposing `lua_State *`;
- keep the first callback boundary scalar/binary-safe, consistent with
  `babet_value`;
- represent GUI object identity with opaque integer IDs rather than C++ widget
  pointers;
- represent an event callback initially by the name of a Lua global function;
  the GUI host can invoke it through the already validated
  `babet_context_call_global()` path;
- do not add retained Lua function handles, generic `.so` loading or arbitrary
  C ABI objects merely for the GUI.

A first prototype can therefore expose a small Lua surface such as
`babet.gui.window(...)`, `babet.gui.button(...)`, `babet.gui.setText(...)`,
with host-owned integer handles and named Lua callbacks. The exact widget API is
not designed in Lot 7.

## 7. Interaction with `--create-exe`

The existing `babet --create-exe` contract does **not** change.

A CLI application generated by the ordinary Babet builder does not suddenly
acquire a GUI toolkit, GUI launcher, toolkit resources or platform plugins.
That protects both the one-file application contract and the current binary
size/dependency baseline.

If a future GUI project needs one-file GUI packaging, it must solve that as a
separate `babet-gui` build/release problem after a real GUI host exists. It must
not silently overload the semantics of the current CLI builder.

## 8. Deployment consequences

### Normal Babet

No change:

- no GUI library in `ldd`;
- no GUI source required by `build_local.sh`;
- no GUI toolkit download in the normal bootstrap;
- no GUI asset/plugin directory next to `babet`;
- no increase attributable to GUI support in the normal stripped binary.

### Optional GUI host

The GUI host may have its own build/deployment profile. For the preferred FLTK
prototype, test both:

- a normal Linux hybrid Wayland/X11 build;
- the exact stripped host size and `ldd` dependency closure;
- the same source on Windows when Windows work is eventually reopened.

Do not claim a fully static Linux desktop executable before its actual system
library boundary has been measured and documented.

## 9. Rejected architectures

Lot 7 rejects the following shapes:

- linking a GUI toolkit directly into the normal `babet` executable;
- making GTK/Qt/FLTK/wxWidgets a prerequisite for the ordinary Babet build;
- adding `babet --gui` to the CLI by dynamically loading a toolkit at runtime;
- inventing a generic `.so` plugin loader to smuggle GUI support into the CLI;
- using a second Babet process plus IPC merely to avoid a clean embedding host;
- changing `--create-exe` so every generated application carries GUI runtime
  machinery it did not request;
- exposing `lua_State *` just to make a GUI binding convenient.

## 10. Decision and next gate

Lot 7 concludes:

1. **Do not add GUI code to the Babet CLI.**
2. A GUI, if implemented, is a separate companion host consuming the existing
   standalone `libbabet` SDK.
3. **FLTK 1.4.x is the preferred first prototype backend.**
4. **wxWidgets 3.2.x is the first fallback** if a real prototype shows that
   native widget integration matters more than the smallest practical
   dependency/deployment surface.
5. GTK 4 and Qt 6 remain technically capable but are not selected as the
   default Babet GUI host under the current constraints.
6. Before any GUI widget API, add only the minimal host-function registration
   boundary that the concrete companion needs; this is not permission to start
   generic plugin work.
7. Measure the actual prototype before promoting FLTK from preferred candidate
   to a permanent product dependency.

This closes the **study**. It does not commit the project to shipping a GUI.

## 11. Sources checked for the 2026-08-25 study

Primary upstream documentation consulted:

- FLTK 1.4.5 project/manual: https://www.fltk.org/ and
  https://www.fltk.org/doc-1.4/
- wxWidgets current releases/licence: https://wxwidgets.org/downloads/ and
  https://wxwidgets.org/about/licence/
- GTK 4 overview/Windows documentation: https://docs.gtk.org/gtk4/overview.html
  and https://docs.gtk.org/gtk4/windows.html
- Qt 6 supported platforms/licensing/deployment: https://doc.qt.io/qt-6/
  supported-platforms.html, licensing.html and deployment.html

Versions and upstream deployment/licensing details are time-sensitive; recheck
these sources when a real GUI implementation starts.

## 12. Lot 9 sequencing refinement

The Lot 7 study originally expected the Lua -> host function boundary to be
added before the first GUI implementation. Before starting Lot 9, that order was
refined deliberately: the first FLTK consumer is smaller and more informative
if it uses only the already validated host -> Lua `babet_context_call_global()`
path.

Lot 9 therefore builds a one-window/one-button companion and records exactly
what cannot be expressed without Lua -> host calls. It must not hide those
limits behind polled globals or other temporary bridges. That concrete missing-
capability list becomes the Lot 10 design input, after which the FLTK prototype
will be rewritten on the public host-function API.

This refinement does not change the Lot 7 architecture decision: FLTK remains
outside the normal CLI and the future Lua -> host boundary remains narrow and
independent from generic native-plugin loading.
