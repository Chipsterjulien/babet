#!/usr/bin/env python3
"""GTK4 drag source running in its own process for the external DnD regression.

Usage: real_gtk_dnd_source.py files|uris ACTIONS ITEM...

- files: a GdkFileList of local paths, as a GTK4 file manager offers it.
- uris: text/uri-list and text/plain bytes, as a browser offers a link.

ACTIONS uses GdkDragAction bits (1 = COPY, 2 = MOVE). The process prints
EXTERNAL_SOURCE_READY, then "EXTERNAL_SOURCE_END delete=<0|1> selected=<bits>"
when GTK reports drag-end, and exits.
"""
import ctypes
import sys

P = ctypes.c_void_p
gtk = ctypes.CDLL("libgtk-4.so.1")
gio = ctypes.CDLL("libgio-2.0.so.0")
glib = ctypes.CDLL("libglib-2.0.so.0")
gobject = ctypes.CDLL("libgobject-2.0.so.0")


def declare(lib, name, restype, argtypes):
    function = getattr(lib, name)
    function.restype = restype
    function.argtypes = argtypes
    return function


declare(gtk, "gtk_init", None, [])
declare(gtk, "gtk_window_new", P, [])
declare(gtk, "gtk_window_set_title", None, [P, ctypes.c_char_p])
declare(gtk, "gtk_window_set_default_size", None, [P, ctypes.c_int, ctypes.c_int])
declare(gtk, "gtk_window_set_child", None, [P, P])
declare(gtk, "gtk_window_present", None, [P])
declare(gtk, "gtk_label_new", P, [ctypes.c_char_p])
declare(gtk, "gtk_drag_source_new", P, [])
declare(gtk, "gtk_drag_source_set_actions", None, [P, ctypes.c_uint])
declare(gtk, "gtk_drag_source_set_content", None, [P, P])
declare(gtk, "gtk_widget_add_controller", None, [P, P])
declare(gtk, "gdk_drag_get_selected_action", ctypes.c_uint, [P])
declare(gtk, "gdk_file_list_get_type", ctypes.c_size_t, [])
declare(gtk, "gdk_file_list_new_from_array", P, [ctypes.POINTER(P), ctypes.c_size_t])
declare(gtk, "gdk_content_provider_new_typed", P, [ctypes.c_size_t, P])
declare(gtk, "gdk_content_provider_new_for_bytes", P, [ctypes.c_char_p, P])
declare(gtk, "gdk_content_provider_new_union", P, [ctypes.POINTER(P), ctypes.c_size_t])
declare(gio, "g_file_new_for_path", P, [ctypes.c_char_p])
declare(glib, "g_bytes_new", P, [ctypes.c_char_p, ctypes.c_size_t])
declare(glib, "g_main_context_iteration", ctypes.c_int, [P, ctypes.c_int])
declare(gobject, "g_signal_connect_data", ctypes.c_ulong, [P, ctypes.c_char_p, P, P, P, ctypes.c_int])

DRAG_END = ctypes.CFUNCTYPE(None, P, P, ctypes.c_int, P)
finished = False


def on_drag_end(source, drag, delete_data, user_data):
    global finished
    selected = gtk.gdk_drag_get_selected_action(drag)
    print(f"EXTERNAL_SOURCE_END delete={1 if delete_data else 0} selected={selected}", flush=True)
    finished = True


def provider(kind, items):
    if kind == "files":
        files = (P * len(items))(*[gio.g_file_new_for_path(item.encode()) for item in items])
        file_list = gtk.gdk_file_list_new_from_array(files, len(items))
        return gtk.gdk_content_provider_new_typed(gtk.gdk_file_list_get_type(), file_list)
    if kind == "uris":
        uri_list = ("\r\n".join(items) + "\r\n").encode()
        text = "\n".join(items).encode()
        parts = (P * 2)(
            gtk.gdk_content_provider_new_for_bytes(b"text/uri-list", glib.g_bytes_new(uri_list, len(uri_list))),
            gtk.gdk_content_provider_new_for_bytes(b"text/plain;charset=utf-8", glib.g_bytes_new(text, len(text))),
        )
        return gtk.gdk_content_provider_new_union(parts, 2)
    raise SystemExit("unknown source kind: " + kind)


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    kind, actions, items = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    gtk.gtk_init()
    window = gtk.gtk_window_new()
    gtk.gtk_window_set_title(window, b"Babet external drag source")
    gtk.gtk_window_set_default_size(window, 200, 200)
    label = gtk.gtk_label_new(b"source")
    gtk.gtk_window_set_child(window, label)
    source = gtk.gtk_drag_source_new()
    gtk.gtk_drag_source_set_actions(source, actions)
    gtk.gtk_drag_source_set_content(source, provider(kind, items))
    callback = DRAG_END(on_drag_end)
    gobject.g_signal_connect_data(source, b"drag-end", ctypes.cast(callback, P), None, None, 0)
    gtk.gtk_widget_add_controller(label, source)
    gtk.gtk_window_present(window)
    print("EXTERNAL_SOURCE_READY", flush=True)
    while not finished:
        glib.g_main_context_iteration(None, 1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
