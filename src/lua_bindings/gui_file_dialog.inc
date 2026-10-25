// Included by gui.cpp. GIO completions retain a native state, never lua_State.
constexpr const char *FILE_DIALOG_META = "BabetGuiFileDialog";
char file_dialog_roots_key;
struct FileDialogState {
    int refs = 1; // userdata + one reference until GIO completion
    lua_State *owner = nullptr;
    WidgetState *parent = nullptr;
    FileDialogState *next = nullptr;
    bool linked = false, multiple = false, save = false;
    void *dialog = nullptr, *cancel = nullptr, *filters = nullptr, *temporary = nullptr;
    void *result = nullptr, *error = nullptr;
    char *path = nullptr;
};
FileDialogState *file_dialogs = nullptr;
std::atomic_int pending_file_dialogs{0};
bool has_file_dialogs() noexcept { return pending_file_dialogs.load() != 0; }
void file_dialog_clear(FileDialogState *s) noexcept
{
    if (s->path) { detail::gtk4_free(s->path); s->path = nullptr; }
    if (s->error) { detail::files_g_error_free(s->error); s->error = nullptr; }
    void **objects[] = {&s->result, &s->temporary, &s->filters, &s->dialog, &s->cancel};
    for (auto **p : objects) if (*p) {
        void *object = *p; *p = nullptr; // detach before native reentrancy
        detail::gtk4_object_unref(object);
    }
    if (s->parent) { release_state(s->parent); s->parent = nullptr; }
}
void file_dialog_release(FileDialogState *s) noexcept
{
    if (--s->refs == 0) { file_dialog_clear(s); delete s; }
}
void file_dialog_unlink(FileDialogState *s) noexcept
{
    if (!s->linked) return;
    auto **p = &file_dialogs;
    while (*p && *p != s) p = &(*p)->next;
    if (*p) *p = s->next;
    s->next = nullptr; s->linked = false;
    pending_file_dialogs.fetch_sub(1);
}
void file_dialog_unroot(lua_State *L, FileDialogState *s) noexcept
{
    if (!L || !lua_checkstack(L, 2)) return;
    const int base = lua_gettop(L);
    lua_rawgetp(L, LUA_REGISTRYINDEX, &file_dialog_roots_key);
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        lua_rawsetp(L, -2, s); // removal from an existing table does not allocate
    }
    lua_settop(L, base);
}
void file_dialog_cancel(FileDialogState *s, bool unroot = true) noexcept
{
    ++s->refs; // cancellation can cause reentrant native callbacks
    lua_State *owner = s->owner;
    s->owner = nullptr;
    file_dialog_unlink(s);
    if (unroot) file_dialog_unroot(owner, s);
    void *cancellable = s->cancel;
    s->cancel = nullptr;
    if (cancellable) {
        detail::files_g_cancellable_cancel(cancellable);
        detail::gtk4_object_unref(cancellable);
    }
    file_dialog_clear(s);
    if (!has_file_dialogs() && g_live_widgets.load() == 0) g_gui_owner = nullptr;
    file_dialog_release(s);
}
void cancel_file_dialogs(lua_State *owner, WidgetState *parent) noexcept
{
    for (;;) {
        auto *s = file_dialogs;
        while (s && ((owner && s->owner != owner) || (parent && s->parent != parent))) s = s->next;
        if (!s) return;
        file_dialog_cancel(s);
    }
}
int file_dialog_gc(lua_State *L) noexcept
{
    auto **p = static_cast<FileDialogState **>(luaL_testudata(L, 1, FILE_DIALOG_META));
    if (p && *p) {
        auto *s = *p; *p = nullptr;
        file_dialog_cancel(s, false);
        file_dialog_release(s);
    }
    return 0;
}
// All Lua allocations, including path strings and the multiple-selection table,
// take place in this protected thunk. Temporary GLib copies belong to s.
int file_dialog_invoke(lua_State *L)
{
    auto *s = static_cast<FileDialogState *>(lua_touserdata(L, 1));
    lua_rawgetp(L, LUA_REGISTRYINDEX, &file_dialog_roots_key);
    lua_rawgetp(L, -1, s);
    if (!lua_isuserdata(L, -1)) return 0;
    lua_getiuservalue(L, -1, 1);
    if (!lua_isfunction(L, -1)) return 0;
    int argc = 1;
    if (!s->result) {
        lua_pushnil(L);
        if (!detail::gtk4_dialog_dismissed(s->error)) {
            lua_pushfstring(L, "babet.gui: file selection failed: %s", detail::gtk4_error_message(s->error));
            argc = 2;
        }
    } else if (!s->multiple) {
        s->path = detail::files_g_file_get_path(s->result);
        if (s->path) lua_pushstring(L, s->path);
        else { lua_pushnil(L); lua_pushliteral(L, "babet.gui: file is not local"); argc = 2; }
    } else {
        const unsigned int count = detail::files_g_list_model_get_n_items(s->result);
        lua_newtable(L);
        for (unsigned int i = 0; i < count; ++i) {
            s->temporary = detail::files_g_list_model_get_item(s->result, i);
            s->path = s->temporary ? detail::files_g_file_get_path(s->temporary) : nullptr;
            if (!s->path) {
                lua_pop(L, 1); // discard partial table: never silently lose a selection
                lua_pushnil(L); lua_pushliteral(L, "babet.gui: file is not local"); argc = 2;
                break;
            }
            lua_pushstring(L, s->path);
            lua_rawseti(L, -2, static_cast<lua_Integer>(i) + 1);
            detail::gtk4_free(s->path); s->path = nullptr;
            detail::gtk4_object_unref(s->temporary); s->temporary = nullptr;
        }
    }
    lua_call(L, argc, 0);
    return 0;
}
void file_dialog_done(void *source, void *result, void *data) noexcept
{
    auto *s = static_cast<FileDialogState *>(data);
    // Finish even a cancelled request to consume the native result. The source
    // is kept alive by GIO even after Babet has released its own dialog ref.
    s->result = s->save ? detail::files_gtk_file_dialog_save_finish(source, result, &s->error)
        : s->multiple ? detail::files_gtk_file_dialog_open_multiple_finish(source, result, &s->error)
                      : detail::files_gtk_file_dialog_open_finish(source, result, &s->error);
    lua_State *L = s->owner;
    s->owner = nullptr;
    file_dialog_unlink(s); // callback may close its parent, quit, or open another dialog
    if (L) {
        const int base = lua_gettop(L);
        if (lua_checkstack(L, 4)) {
            lua_pushcfunction(L, file_dialog_invoke);
            lua_pushlightuserdata(L, s);
            if (lua_pcall(L, 1, 0, 0) != LUA_OK) report_callback_error(L);
            lua_settop(L, base);
        } else std::fputs("babet.gui callback error: cannot grow file dialog stack\n", stderr);
        file_dialog_unroot(L, s);
    }
    file_dialog_clear(s);
    if (!has_file_dialogs() && g_live_widgets.load() == 0) g_gui_owner = nullptr;
    file_dialog_release(s);
}

lua_Integer file_array_size(lua_State *L, int index, const char *api)
{
    index = lua_absindex(L, index);
    if (!lua_istable(L, index)) luaL_error(L, "%s: expected an array", api);
    const auto count = lua_rawlen(L, index);
    if (count > INT_MAX) luaL_error(L, "%s: array is too large", api);
    size_t seen = 0;
    lua_pushnil(L);
    while (lua_next(L, index)) {
        if (!lua_isinteger(L, -2) || lua_tointeger(L, -2) < 1 ||
            static_cast<lua_Unsigned>(lua_tointeger(L, -2)) > count)
            luaL_error(L, "%s: expected a dense array", api);
        ++seen; lua_pop(L, 1);
    }
    if (seen != count) luaL_error(L, "%s: expected a dense array", api);
    return static_cast<lua_Integer>(count);
}
void file_copy_string_list(lua_State *L, int source, const char *api)
{
    source = lua_absindex(L, source);
    const auto count = file_array_size(L, source, api);
    lua_newtable(L);
    for (lua_Integer i = 1; i <= count; ++i) {
        lua_rawgeti(L, source, i); file_string(L, -1, api, true); lua_rawseti(L, -2, i);
    }
}
// Snapshot raw options before any native acquisition. GC/finalizers cannot
// mutate a previously validated table between validation and GTK setters.
void file_dialog_options(lua_State *L, bool save)
{
    const char *open_keys[] = {"title", "parent", "folder", "multiple", "filters", nullptr};
    const char *save_keys[] = {"title", "parent", "folder", "name", "filters", nullptr};
    const char *api = save ? "gui.saveFile" : "gui.openFile";
    file_option_keys(L, 1, save ? save_keys : open_keys, api);
    lua_newtable(L);
    const int copy = lua_gettop(L);
    for (const char *key : {"title", "folder", "name", "multiple", "parent"}) {
        file_raw_field(L, 1, key);
        if (!lua_isnil(L, -1)) {
            if (std::strcmp(key, "parent") == 0) check_kind(L, -1, WidgetKind::window, save ? "gui.saveFile parent" : "gui.openFile parent");
            else if (std::strcmp(key, "multiple") == 0) {
                if (!lua_isboolean(L, -1)) luaL_error(L, "%s: multiple expects a boolean", api);
            } else file_string(L, -1, api, std::strcmp(key, "folder") != 0);
        }
        lua_setfield(L, copy, key);
    }
    file_raw_field(L, 1, "filters");
    if (lua_isnil(L, -1)) { lua_pop(L, 1); return; }
    const int source = lua_gettop(L);
    const auto count = file_array_size(L, source, api);
    lua_newtable(L);
    const int filters = lua_gettop(L);
    for (lua_Integer i = 1; i <= count; ++i) {
        lua_rawgeti(L, source, i);
        if (!lua_istable(L, -1)) luaL_error(L, "%s: each filter must be a table", api);
        const int filter = lua_gettop(L);
        const char *keys[] = {"name", "patterns", "mimeTypes", nullptr};
        file_option_keys(L, filter, keys, api);
        lua_newtable(L);
        file_raw_field(L, filter, "name");
        if (!lua_isnil(L, -1)) file_string(L, -1, api, true);
        lua_setfield(L, -2, "name");
        for (const char *key : {"patterns", "mimeTypes"}) {
            file_raw_field(L, filter, key);
            if (!lua_isnil(L, -1)) {
                file_copy_string_list(L, -1, api);
                lua_remove(L, -2);
            }
            lua_setfield(L, -2, key);
        }
        lua_rawseti(L, filters, i);
        lua_pop(L, 1);
    }
    lua_setfield(L, copy, "filters");
    lua_pop(L, 1); // original filters
}
int file_dialog_native_oom(lua_State *L)
{ lua_pushnil(L); lua_pushliteral(L, "babet.gui: out of memory for file dialog"); return 2; }
int file_dialog_configure(lua_State *L)
{
    auto *s = *static_cast<FileDialogState **>(lua_touserdata(L, 1));
    s->dialog = detail::files_gtk_file_dialog_new();
    s->cancel = detail::files_g_cancellable_new();
    if (!s->dialog || !s->cancel) { lua_pushnil(L); lua_pushliteral(L, "babet.gui: out of memory for file dialog"); return 2; }
    detail::files_gtk_file_dialog_set_modal(s->dialog, 1);
    file_raw_field(L, 2, "title");
    if (!lua_isnil(L, -1)) detail::files_gtk_file_dialog_set_title(s->dialog, lua_tostring(L, -1));
    lua_pop(L, 1);
    file_raw_field(L, 2, "name");
    if (!lua_isnil(L, -1)) detail::files_gtk_file_dialog_set_initial_name(s->dialog, lua_tostring(L, -1));
    lua_pop(L, 1);
    file_raw_field(L, 2, "folder");
    if (!lua_isnil(L, -1)) {
        s->temporary = detail::files_g_file_new_for_path(lua_tostring(L, -1));
        if (!s->temporary) return file_dialog_native_oom(L);
        detail::files_gtk_file_dialog_set_initial_folder(s->dialog, s->temporary);
        detail::gtk4_object_unref(s->temporary); s->temporary = nullptr;
    }
    lua_pop(L, 1);
    file_raw_field(L, 2, "filters");
    if (lua_istable(L, -1)) {
        const int filters = lua_gettop(L);
        s->filters = detail::files_g_list_store_new(detail::files_gtk_file_filter_get_type());
        if (!s->filters) return file_dialog_native_oom(L);
        const auto count = lua_rawlen(L, filters);
        for (lua_Unsigned i = 1; i <= count; ++i) {
            lua_rawgeti(L, filters, static_cast<lua_Integer>(i));
            const int filter = lua_gettop(L);
            s->temporary = detail::files_gtk_file_filter_new();
            if (!s->temporary) return file_dialog_native_oom(L);
            file_raw_field(L, filter, "name");
            if (!lua_isnil(L, -1)) detail::files_gtk_file_filter_set_name(s->temporary, lua_tostring(L, -1));
            lua_pop(L, 1);
            for (int mime = 0; mime != 2; ++mime) {
                file_raw_field(L, filter, mime ? "mimeTypes" : "patterns");
                const int list = lua_gettop(L);
                if (lua_istable(L, list)) for (lua_Unsigned j = 1; j <= lua_rawlen(L, list); ++j) {
                    lua_rawgeti(L, list, static_cast<lua_Integer>(j));
                    if (mime) detail::files_gtk_file_filter_add_mime_type(s->temporary, lua_tostring(L, -1));
                    else detail::files_gtk_file_filter_add_pattern(s->temporary, lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
                lua_pop(L, 1);
            }
            detail::files_g_list_store_append(s->filters, s->temporary);
            detail::gtk4_object_unref(s->temporary); s->temporary = nullptr;
            lua_pop(L, 1);
        }
        detail::files_gtk_file_dialog_set_filters(s->dialog, s->filters);
    }
    lua_pushboolean(L, 1); lua_pushnil(L); return 2;
}
int file_dialog_start(lua_State *L, bool save)
{
    if (!lua_arity_is(L, 2) || !lua_istable(L, 1) || !lua_isfunction(L, 2))
        return luaL_error(L, save ? "gui.saveFile expects (options, callback)" : "gui.openFile expects (options, callback)");
    require_gui_initialized(L, save ? "gui.saveFile" : "gui.openFile");
    file_dialog_options(L, save);
    const int options = lua_gettop(L);
    if (!detail::gtk4_file_dialog_available()) return push_fail_protected(L, "babet.gui: requires GTK 4.10");
    auto *owner = main_lua_state(L);
    if (!lua_checkstack(owner, 32)) return push_fail_protected(L, "babet.gui: out of memory for callback");
    file_raw_field(L, options, "parent");
    auto *parent = lua_isnil(L, -1) ? nullptr : check_kind(L, -1, WidgetKind::window, save ? "gui.saveFile parent" : "gui.openFile parent");
    lua_pop(L, 1);
    file_raw_field(L, options, "multiple");
    const bool multiple = lua_toboolean(L, -1); lua_pop(L, 1);
    auto **handle = static_cast<FileDialogState **>(lua_newuserdatauv(L, sizeof(FileDialogState *), 1));
    *handle = nullptr;
    const int ud = lua_gettop(L);
    luaL_getmetatable(L, FILE_DIALOG_META); lua_setmetatable(L, ud);
    lua_pushvalue(L, 2); lua_setiuservalue(L, ud, 1);
    auto *s = new (std::nothrow) FileDialogState();
    if (!s) return push_fail_protected(L, "babet.gui: out of memory for file dialog");
    *handle = s; s->save = save; s->multiple = multiple; s->owner = owner;
    s->parent = parent; if (parent) retain_state(parent);
    // The userdata owns s before the next allocation; GC covers any Lua OOM.
    lua_rawgetp(L, LUA_REGISTRYINDEX, &file_dialog_roots_key);
    lua_pushvalue(L, ud); lua_rawsetp(L, -2, s); lua_pop(L, 1);
    lua_pushcfunction(L, file_dialog_configure);
    lua_pushvalue(L, ud); lua_pushvalue(L, options);
    const int status = lua_pcall(L, 2, 2, 0);
    if (status != LUA_OK) {
        file_dialog_cancel(s);
        return lua_error(L);
    }
    if (!lua_toboolean(L, -2)) { file_dialog_cancel(s); return 2; }
    if (parent && !parent->native) {
        file_dialog_cancel(s);
        return push_fail_protected(L, "babet.gui: parent window destroyed");
    }
    s->next = file_dialogs; file_dialogs = s; s->linked = true;
    pending_file_dialogs.fetch_add(1); g_gui_owner = owner;
    ++s->refs;
    void *native_parent = parent ? parent->native : nullptr;
    if (save) detail::files_gtk_file_dialog_save(s->dialog, native_parent, s->cancel, file_dialog_done, s);
    else if (multiple) detail::files_gtk_file_dialog_open_multiple(s->dialog, native_parent, s->cancel, file_dialog_done, s);
    else detail::files_gtk_file_dialog_open(s->dialog, native_parent, s->cancel, file_dialog_done, s);
    return 2; // success pair was allocated before starting the async operation
}
int l_open_file(lua_State *L) { return file_dialog_start(L, false); }
int l_save_file(lua_State *L) { return file_dialog_start(L, true); }
