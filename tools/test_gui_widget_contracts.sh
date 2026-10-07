#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1
PASS=0
FAIL=0
ok(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
ko(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
check(){ local label="$1"; shift; if "$@"; then ok "$label"; else ko "$label"; fi; }
contains(){ grep -Fq -- "$2" "$1"; }

IMPL="src/lua_bindings/gui.cpp"
HEADER="src/lua_bindings/gui_gtk_loader.hpp"
LOADER="src/lua_bindings/gui_gtk_loader.cpp"
DESIGN="GUI_DESIGN.md"
RUN="run_tests.sh"

check "GUI window constructor is registered" contains "$IMPL" '"window"'
check "GUI box constructor is registered" contains "$IMPL" '"box"'
check "GUI label constructor is registered" contains "$IMPL" '"label"'
check "GUI button constructor is registered" contains "$IMPL" '"button"'
check "GUI widget userdata has a finalizer" contains "$IMPL" '"__gc"'
check "GUI widget handles carry explicit alive/native state" contains "$IMPL" 'native = nullptr'
check "GTK destroy invalidates native handles" contains "$IMPL" 'widget_destroyed'
check "dead widget use has a stable diagnostic" contains "$IMPL" 'has already been destroyed'
check "non-window widgets sink floating references" contains "$IMPL" 'gtk4_object_ref_sink'
check "parenting releases Babet construction ownership" contains "$IMPL" 'release_construction_reference'
check "container add rejects already-parented widgets" contains "$IMPL" 'gtk4_widget_get_parent'
check "widget callback belongs to the Lua handle" contains "$IMPL" 'lua_rawseti(L, -2, PRIMARY_CALLBACK)'
check "button callbacks run through lua_pcall" contains "$IMPL" 'lua_pcall'
check "button callback diagnostics are contained" contains "$IMPL" 'babet.gui callback error'
check "GUI event loop uses GLib main context" contains "$IMPL" 'gtk4_main_context_iteration'
check "GUI event loop has a bounded wake source" contains "$IMPL" 'gtk4_timeout_add'
check "GUI loop services Babet pending signals" contains "$IMPL" 'signal_dispatch_pending'
check "GUI quit is explicit" contains "$IMPL" '"quit"'
check "GUI run is explicit" contains "$IMPL" '"run"'
check "window show uses GTK present" contains "$IMPL" 'gtk4_window_present'
check "window close uses GTK destroy" contains "$IMPL" 'gtk4_window_destroy'
check "setText supports GTK labels" contains "$IMPL" 'gtk4_label_set_text'
check "setText supports GTK buttons" contains "$IMPL" 'gtk4_button_set_label'
check "ScrolledWindow constructor is registered" contains "$IMPL" '"scrolledWindow"'
check "SpinButton constructor is registered" contains "$IMPL" '"spinButton"'
check "Calendar constructor is registered" contains "$IMPL" '"calendar"'
check "Box child removal is exposed" contains "$IMPL" 'gtk4_box_remove'
check "container clear is exposed" contains "$IMPL" 'widget_clear'
check "removal reacquires native ownership before unparent" contains "$IMPL" 'acquire_construction_reference(child)'
check "SpinButton value access is exposed" contains "$IMPL" 'gtk4_spin_button_get_value'
check "Calendar date access is exposed" contains "$IMPL" 'gtk4_calendar_get_date'
check "common widget margins are exposed" contains "$IMPL" '"setMargins"'
check "common horizontal expansion is exposed" contains "$IMPL" '"setHExpand"'
check "common vertical expansion is exposed" contains "$IMPL" '"setVExpand"'
check "common visibility is exposed" contains "$IMPL" '"setVisible"'
check "common sensitivity is exposed" contains "$IMPL" '"setSensitive"'
check "loader resolves GtkBox append" contains "$LOADER" 'gtk_box_append'
check "loader resolves GtkBox remove" contains "$LOADER" 'gtk_box_remove'
check "loader resolves GtkScrolledWindow child setter" contains "$LOADER" 'gtk_scrolled_window_set_child'
check "loader resolves GtkSpinButton range constructor" contains "$LOADER" 'gtk_spin_button_new_with_range'
check "loader resolves GtkCalendar selection" contains "$LOADER" 'gtk_calendar_select_day'
check "loader resolves common widget sensitivity" contains "$LOADER" 'gtk_widget_set_sensitive'
check "loader resolves GObject signal bridge" contains "$LOADER" 'g_signal_connect_data'
check "GTK signal bridge exposes closure destroy notification" contains "$HEADER" 'GtkClosureNotify destroy_data'
check "button clicked signal retains WidgetState" contains "$IMPL" 'retain_state(userdata->state)'
check "button clicked signal installs lifetime notifier" contains "$IMPL" '&button_signal_released'
check "loader resolves GLib main-context iteration" contains "$LOADER" 'g_main_context_iteration'
check "runtime harness includes widget contract preflight" contains "$RUN" 'tools/test_gui_widget_contracts.sh'
check "runtime harness includes expanded GUI widget regression" contains "$RUN" 'tools/test_gui_widgets.py'
check "design requires safe dead handles" contains "$DESIGN" 'dead handle'

echo "GUI widget structural contracts: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ]
