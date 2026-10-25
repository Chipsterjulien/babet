// Included by gui.cpp inside its private namespace.
struct GuiObjectDeleter {
    void operator()(void *p) const noexcept { if (p) detail::gtk4_object_unref(p); }
};
struct GuiErrorDeleter {
    void operator()(void *p) const noexcept { if (p) detail::files_g_error_free(p); }
};
using GuiObject = std::unique_ptr<void, GuiObjectDeleter>;
using GuiError = std::unique_ptr<void, GuiErrorDeleter>;

void file_option_keys(lua_State *L, int table, const char *const *keys, const char *api)
{
    table = lua_absindex(L, table);
    lua_pushnil(L);
    while (lua_next(L, table)) {
        const char *key = nullptr;
        strict_c_string(L, -2, api, key);
        bool known = false;
        for (auto p = keys; *p; ++p) if (std::strcmp(key, *p) == 0) known = true;
        if (!known) luaL_error(L, "%s: unknown option '%s'", api, key);
        lua_pop(L, 1);
    }
}
void file_raw_field(lua_State *L, int table, const char *key)
{
    table = lua_absindex(L, table);
    lua_pushstring(L, key);
    lua_rawget(L, table);
}
const char *file_string(lua_State *L, int index, const char *api, bool utf8 = false)
{
    const char *text = nullptr;
    strict_c_string(L, index, api, text);
    if (utf8 && !detail::gtk4_utf8_valid(text, std::strlen(text)))
        luaL_error(L, "%s: invalid UTF-8 text", api);
    return text;
}
int picture_fit(lua_State *L, int index, const char *api)
{
    const char *s = file_string(L, index, api);
    const char *names[] = {"fill", "contain", "cover", "scale-down"};
    for (int i = 0; i != 4; ++i) if (std::strcmp(s, names[i]) == 0) return i;
    return luaL_error(L, "%s: unknown contentFit mode '%s'", api, s);
}
int l_picture(lua_State *L)
{
    if (lua_gettop(L) > 1 || (!lua_isnoneornil(L, 1) && !lua_istable(L, 1)))
        return luaL_error(L, "gui.picture expects an optional options table");
    require_gui_initialized(L, "gui.picture");
    const char *file = nullptr;
    int fit = 1;
    bool explicit_fit = false, shrink = true;
    if (lua_istable(L, 1)) {
        const char *keys[] = {"file", "contentFit", "canShrink", nullptr};
        file_option_keys(L, 1, keys, "gui.picture");
        file_raw_field(L, 1, "file");
        if (!lua_isnil(L, -1)) file = file_string(L, -1, "gui.picture");
        file_raw_field(L, 1, "contentFit");
        if (!lua_isnil(L, -1)) { fit = picture_fit(L, -1, "gui.picture"); explicit_fit = true; }
        file_raw_field(L, 1, "canShrink");
        if (!lua_isnil(L, -1)) {
            if (!lua_isboolean(L, -1)) return luaL_error(L, "gui.picture: canShrink expects a boolean");
            shrink = lua_toboolean(L, -1);
        }
    }
    if (!detail::gtk4_picture_available()) return push_fail_protected(L, "babet.gui: requires GTK 4.0 (GtkPicture)");
    if (explicit_fit && !detail::gtk4_content_fit_available()) return push_fail_protected(L, "babet.gui: requires GTK 4.8");
    if (file && !detail::gtk4_texture_file_available()) return push_fail_protected(L, "babet.gui: requires GTK 4.6");
    push_empty_widget_userdata(L); // all allocating setup precedes native ownership
    void *error = nullptr;
    GuiObject texture(file ? detail::files_gdk_texture_new_from_filename(file, &error) : nullptr);
    GuiError owned_error(error);
    if (file && !texture) return push_fail_protected(L,
        std::string("babet.gui: cannot load image: ") + detail::gtk4_error_message(error));
    void *native = detail::files_gtk_picture_new();
    const int count = push_native_widget(L, WidgetKind::picture, native, true);
    if (count != 1) return count;
    detail::files_gtk_picture_set_can_shrink(native, shrink ? 1 : 0);
    if (explicit_fit) detail::files_gtk_picture_set_content_fit(native, fit);
    if (texture) detail::files_gtk_picture_set_paintable(native, texture.get());
    return 1;
}
int picture_set_file(lua_State *L)
{
    if (!lua_arity_is(L, 2)) return luaL_error(L, "gui picture:setFile expects a path or nil");
    auto *s = check_kind(L, 1, WidgetKind::picture, "gui picture:setFile");
    const char *path = lua_isnil(L, 2) ? nullptr : file_string(L, 2, "gui picture:setFile");
    if (path && !detail::gtk4_texture_file_available()) return push_fail_protected(L, "babet.gui: requires GTK 4.6");
    void *error = nullptr;
    GuiObject texture(path ? detail::files_gdk_texture_new_from_filename(path, &error) : nullptr);
    GuiError owned_error(error);
    if (path && !texture) return push_fail_protected(L,
        std::string("babet.gui: cannot load image: ") + detail::gtk4_error_message(error));
    detail::files_gtk_picture_set_paintable(s->native, texture.get());
    return push_ok_protected(L);
}
int picture_set_fit(lua_State *L)
{
    if (!lua_arity_is(L, 2)) return luaL_error(L, "gui picture:setContentFit expects one mode string");
    auto *s = check_kind(L, 1, WidgetKind::picture, "gui picture:setContentFit");
    const int fit = picture_fit(L, 2, "gui picture:setContentFit");
    if (!detail::gtk4_content_fit_available()) return push_fail_protected(L, "babet.gui: requires GTK 4.8");
    detail::files_gtk_picture_set_content_fit(s->native, fit);
    return push_ok_protected(L);
}
int picture_set_shrink(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_isboolean(L, 2)) return luaL_error(L, "gui picture:setCanShrink expects one boolean");
    auto *s = check_kind(L, 1, WidgetKind::picture, "gui picture:setCanShrink");
    detail::files_gtk_picture_set_can_shrink(s->native, lua_toboolean(L, 2));
    return push_ok_protected(L);
}
int picture_set_alt(lua_State *L)
{
    if (!lua_arity_is(L, 2)) return luaL_error(L, "gui picture:setAlternativeText expects a string or nil");
    auto *s = check_kind(L, 1, WidgetKind::picture, "gui picture:setAlternativeText");
    const char *text = lua_isnil(L, 2) ? nullptr : file_string(L, 2, "gui picture:setAlternativeText", true);
    detail::files_gtk_picture_set_alternative_text(s->native, text);
    return push_ok_protected(L);
}
int picture_intrinsic_size(lua_State *L)
{
    if (!lua_arity_is(L, 1)) return luaL_error(L, "gui picture:getIntrinsicSize expects no arguments");
    auto *s = check_kind(L, 1, WidgetKind::picture, "gui picture:getIntrinsicSize", false);
    void *p = detail::files_gtk_picture_get_paintable(s->native);
    lua_pushinteger(L, p ? detail::files_gdk_paintable_get_intrinsic_width(p) : 0);
    lua_pushinteger(L, p ? detail::files_gdk_paintable_get_intrinsic_height(p) : 0);
    return 2;
}
