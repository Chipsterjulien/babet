// Included by gui.cpp after ScopedWidgetCallback. No variadic GTK calls.
struct TextTagProperties {
    std::string foreground, background;
    bool has_foreground=false, has_background=false, has_underline=false;
    bool has_strike=false, has_weight=false, has_style=false, has_scale=false;
    bool underline=false, strike=false;
    int weight=400, style=0;
    double scale=1;
    std::string unknown;
    bool has_unknown=false;
};

bool tag_color(const char *s) noexcept
{
    if (std::strlen(s)!=7 || s[0]!='#') return false;
    for (int i=1;i<7;++i)
        if (!((s[i]>='0' && s[i]<='9') || (s[i]>='a' && s[i]<='f') ||
              (s[i]>='A' && s[i]<='F'))) return false;
    return true;
}

void read_tag_properties(lua_State *L, TextTagProperties &p)
{
    const char *keys[]={"foreground","background","underline","strikethrough",
                        "weight","style","scale",nullptr};
    lua_pushnil(L);
    while (lua_next(L,3)) {
        const char *key=file_string(L,-2,"gui textView:createTag");
        bool known=false;
        for (auto k=keys;*k;++k) if(std::strcmp(key,*k)==0) known=true;
        if (!known && !p.has_unknown) { p.unknown=key; p.has_unknown=true; }
        lua_pop(L,1);
    }
    for (int i=0;i<7;++i) {
        file_raw_field(L,3,keys[i]);
        if (lua_isnil(L,-1)) { lua_pop(L,1); continue; }
        if (i<2) {
            const char *s=file_string(L,-1,"gui textView:createTag");
            if (!tag_color(s)) luaL_error(L,"gui textView:createTag: %s expects a #rrggbb color",keys[i]);
            if(i==0) {p.foreground=s;p.has_foreground=true;}
            else {p.background=s;p.has_background=true;}
        } else if (i<4) {
            if (!lua_isboolean(L,-1)) luaL_error(L,"gui textView:createTag: %s expects a boolean",keys[i]);
            if(i==2) {p.underline=lua_toboolean(L,-1);p.has_underline=true;}
            else {p.strike=lua_toboolean(L,-1);p.has_strike=true;}
        } else if (i==4) {
            if (!lua_isinteger(L,-1) || lua_tointeger(L,-1)<100 || lua_tointeger(L,-1)>900)
                luaL_error(L,"gui textView:createTag: weight expects an integer from 100 to 900");
            p.weight=static_cast<int>(lua_tointeger(L,-1));p.has_weight=true;
        } else if (i==5) {
            const char *s=file_string(L,-1,"gui textView:createTag");
            if (std::strcmp(s,"normal")==0) p.style=0;
            else if (std::strcmp(s,"italic")==0) p.style=2;
            else luaL_error(L,"gui textView:createTag: style expects \"normal\" or \"italic\"");
            p.has_style=true;
        } else {
            if (lua_type(L,-1)!=LUA_TNUMBER || !std::isfinite(lua_tonumber(L,-1)) || lua_tonumber(L,-1)<=0)
                luaL_error(L,"gui textView:createTag: scale expects a finite positive number");
            p.scale=lua_tonumber(L,-1);p.has_scale=true;
        }
        lua_pop(L,1);
    }
}

class TagValue {
public:
    detail::NativeValue value{};
    explicit TagValue(const char *type) {
        const auto native_type=detail::rich_type_from_name(type);
        if (!native_type) throw std::runtime_error("babet.gui: GTK property type unavailable");
        detail::rich_g_value_init(&value,native_type);
    }
    ~TagValue() { detail::rich_g_value_unset(&value); }
    TagValue(const TagValue &)=delete;
    TagValue &operator=(const TagValue &)=delete;
};

void tag_property(void *tag,const char *key,const char *value)
{
    TagValue v("gchararray");detail::rich_g_value_set_string(&v.value,value);
    detail::rich_g_object_set_property(tag,key,&v.value);
}
void tag_integer_property(void *tag,const char *key,const char *type,int value)
{
    TagValue v(type);
    if(std::strcmp(type,"gboolean")==0) detail::rich_g_value_set_boolean(&v.value,value);
    else if(std::strcmp(type,"gint")==0) detail::rich_g_value_set_int(&v.value,value);
    else detail::rich_g_value_set_enum(&v.value,value);
    detail::rich_g_object_set_property(tag,key,&v.value);
}

int text_create_tag(lua_State *L)
{
    if (!lua_arity_is(L,3) || !lua_istable(L,3))
        return luaL_error(L,"gui textView:createTag expects a name and a properties table");
    auto *s=check_kind(L,1,WidgetKind::text_view,"gui textView:createTag");
    const char *raw_name=file_string(L,2,"gui textView:createTag",true);
    if (!*raw_name) return luaL_error(L,"gui textView:createTag: empty tag name");
    const ScopedStateReference keep(s);
    const std::string name(raw_name);
    TextTagProperties p;
    auto parse=[&p](lua_State *Ls) { read_tag_properties(Ls,p); };
    lua_run_protected(L,parse);
    if (p.has_unknown) return push_fail_protected(L,"babet.gui: unknown tag property: "+p.unknown);
    if (!detail::gtk4_text_tags_available()) return push_fail_protected(L,"babet.gui: requires GTK 4.0 (TextView tags)");
    const int result=push_ok_protected(L); // all allocating Lua work precedes native mutation
    if (!s->native || !s->handle_key) return push_fail_protected(L,"babet.gui: textView destroyed while creating the tag");
    void *table=detail::rich_gtk_text_buffer_get_tag_table(detail::gtk4_text_view_get_buffer(s->native));
    if (detail::rich_gtk_text_tag_table_lookup(table,name.c_str()))
        return push_fail_protected(L,"babet.gui: tag name already defined");
    GuiObject tag(detail::rich_gtk_text_tag_new(name.c_str()));
    if (!tag) return push_fail_protected(L,"babet.gui: cannot create tag");
    if(p.has_foreground) tag_property(tag.get(),"foreground",p.foreground.c_str());
    if(p.has_background) tag_property(tag.get(),"background",p.background.c_str());
    if(p.has_underline) tag_integer_property(tag.get(),"underline","PangoUnderline",p.underline?1:0);
    if(p.has_strike) tag_integer_property(tag.get(),"strikethrough","gboolean",p.strike);
    if(p.has_weight) tag_integer_property(tag.get(),"weight","gint",p.weight);
    if(p.has_style) tag_integer_property(tag.get(),"style","PangoStyle",p.style);
    if(p.has_scale) {
        TagValue v("gdouble");detail::rich_g_value_set_double(&v.value,p.scale);
        detail::rich_g_object_set_property(tag.get(),"scale",&v.value);
    }
    s->text_tags.push_back(name); // may throw; tag is still owned by this scope
    if (!detail::rich_gtk_text_tag_table_add(table,tag.get())) {
        s->text_tags.pop_back();
        return push_fail_protected(L,"babet.gui: cannot add tag");
    }
    return result;
}

std::string rich_text_snapshot(void *buffer)
{
    detail::TextIter begin{},end{};
    detail::rich_gtk_text_buffer_get_bounds(buffer,&begin,&end);
    const std::unique_ptr<char,decltype(&detail::gtk4_free)> text(
        detail::rich_gtk_text_buffer_get_text(buffer,&begin,&end,1), &detail::gtk4_free);
    if(!text) throw std::bad_alloc();
    return std::string(text.get());
}
bool text_boundary(const std::string &text,std::size_t offset) noexcept
{
    return offset<=text.size() && (offset==text.size() ||
        (static_cast<unsigned char>(text[offset]) & 0xc0)!=0x80);
}
bool text_index(const std::string &text,lua_Integer index) noexcept
{
    return index>=1 && static_cast<unsigned long long>(index)<=text.size() &&
        text_boundary(text,static_cast<std::size_t>(index-1));
}
int text_character_offset(const std::string &text,std::size_t byte)
{
    const auto count=detail::rich_g_utf8_pointer_to_offset(text.c_str(),text.c_str()+byte);
    if(count<0 || count>INT_MAX) throw std::length_error("babet.gui: text too long for GTK");
    return static_cast<int>(count);
}
std::size_t text_byte_offset(const std::string &text,int characters)
{
    std::size_t i=0;
    while(characters>0 && i<text.size()) {
        ++i;
        while(i<text.size() && !text_boundary(text,i)) ++i;
        --characters;
    }
    if(characters!=0) throw std::runtime_error("babet.gui: GTK position outside the text");
    return i;
}
void *text_lookup(void *buffer,const char *name) noexcept
{
    return detail::rich_gtk_text_tag_table_lookup(detail::rich_gtk_text_buffer_get_tag_table(buffer),name);
}

int text_change_tag(lua_State *L,bool remove)
{
    if(!lua_arity_is(L,4) || !lua_isinteger(L,3) || !lua_isinteger(L,4))
        return luaL_error(L,remove ? "gui textView:removeTag expects a name and two integer indices" : "gui textView:applyTag expects a name and two integer indices");
    const char *api=remove ? "gui textView:removeTag" : "gui textView:applyTag";
    auto *s=check_kind(L,1,WidgetKind::text_view,api);
    const char *name=file_string(L,2,api,true);
    const lua_Integer first=lua_tointeger(L,3),last=lua_tointeger(L,4);
    if(!detail::gtk4_text_tags_available()) return push_fail_protected(L,"babet.gui: requires GTK 4.0 (TextView tags)");
    // Reserve the success result before reading iterators: allocating Lua can
    // run finalizers which mutate or destroy another widget's text buffer.
    const ScopedStateReference keep(s);
    const int result=push_ok_protected(L);
    if(!s->native || !s->handle_key) return push_fail_protected(L,"babet.gui: textView destroyed during the operation");
    const ScopedWidgetCallback pin(s,L);
    void *buffer=detail::gtk4_text_view_get_buffer(pin.native());
    void *tag=text_lookup(buffer,name);
    if(!tag) return push_fail_protected(L,"babet.gui: unknown tag");
    const std::string text=rich_text_snapshot(buffer);
    if(!detail::gtk4_utf8_valid(text.c_str(),text.size()) || !text_index(text,first) ||
       last<first || static_cast<unsigned long long>(last)>text.size() ||
       !text_boundary(text,static_cast<std::size_t>(last)))
        return push_fail_protected(L,"babet.gui: indices out of range or splitting a UTF-8 character");
    detail::TextIter a{},b{};
    detail::rich_gtk_text_buffer_get_iter_at_offset(buffer,&a,text_character_offset(text,static_cast<std::size_t>(first-1)));
    detail::rich_gtk_text_buffer_get_iter_at_offset(buffer,&b,text_character_offset(text,static_cast<std::size_t>(last)));
    if(remove) detail::rich_gtk_text_buffer_remove_tag(buffer,tag,&a,&b);
    else detail::rich_gtk_text_buffer_apply_tag(buffer,tag,&a,&b);
    return result;
}
int text_apply_tag(lua_State *L) {return text_change_tag(L,false);}
int text_remove_tag(lua_State *L) {return text_change_tag(L,true);}

int text_remove_all_tags(lua_State *L)
{
    if(!lua_arity_is(L,1)) return luaL_error(L,"gui textView:removeAllTags expects no arguments");
    auto *s=check_kind(L,1,WidgetKind::text_view,"gui textView:removeAllTags");
    if(!detail::gtk4_text_tags_available()) return push_fail_protected(L,"babet.gui: requires GTK 4.0 (TextView tags)");
    const ScopedStateReference keep(s);
    const int result=push_ok_protected(L);
    if(!s->native || !s->handle_key) return push_fail_protected(L,"babet.gui: textView destroyed during the operation");
    const ScopedWidgetCallback pin(s,L);
    void *buffer=detail::gtk4_text_view_get_buffer(pin.native());
    detail::TextIter a{},b{};detail::rich_gtk_text_buffer_get_bounds(buffer,&a,&b);
    detail::rich_gtk_text_buffer_remove_all_tags(buffer,&a,&b);
    return result;
}

int text_tags_at(lua_State *L)
{
    if(!lua_arity_is(L,2) || !lua_isinteger(L,2)) return luaL_error(L,"gui textView:tagsAt expects one integer index");
    auto *s=check_kind(L,1,WidgetKind::text_view,"gui textView:tagsAt",false);
    const auto index=lua_tointeger(L,2);
    if(!detail::gtk4_text_tags_available()) return push_fail_protected(L,"babet.gui: requires GTK 4.0 (TextView tags)");
    void *buffer=detail::gtk4_text_view_get_buffer(s->native);
    const std::string text=rich_text_snapshot(buffer);
    if(!text_index(text,index)) return push_fail_protected(L,"babet.gui: index out of range or inside a UTF-8 character");
    detail::TextIter iter{};
    detail::rich_gtk_text_buffer_get_iter_at_offset(buffer,&iter,text_character_offset(text,static_cast<std::size_t>(index-1)));
    std::vector<std::string> names;
    for(const auto &name:s->text_tags) {
        void *tag=text_lookup(buffer,name.c_str());
        if(tag && detail::rich_gtk_text_iter_has_tag(&iter,tag)) names.push_back(name);
    }
    auto result=[&names](lua_State *Ls) noexcept {
        lua_newtable(Ls);lua_Integer i=1;
        for(const auto &name:names) {lua_pushlstring(Ls,name.data(),name.size());lua_rawseti(Ls,-2,i++);}
        return 1;
    };
    return lua_build_results_protected(L,result,1);
}

int text_tag_range(lua_State *L)
{
    if(!lua_arity_is(L,3) || !lua_isinteger(L,3)) return luaL_error(L,"gui textView:tagRange expects a name and one integer index");
    auto *s=check_kind(L,1,WidgetKind::text_view,"gui textView:tagRange",false);
    const char *name=file_string(L,2,"gui textView:tagRange",true);const auto index=lua_tointeger(L,3);
    if(!detail::gtk4_text_tags_available()) return push_fail_protected(L,"babet.gui: requires GTK 4.0 (TextView tags)");
    void *buffer=detail::gtk4_text_view_get_buffer(s->native);
    void *tag=text_lookup(buffer,name);
    if(!tag) return push_fail_protected(L,"babet.gui: unknown tag");
    const std::string text=rich_text_snapshot(buffer);
    if(!text_index(text,index)) return push_fail_protected(L,"babet.gui: index out of range or inside a UTF-8 character");
    detail::TextIter begin{};
    detail::rich_gtk_text_buffer_get_iter_at_offset(buffer,&begin,text_character_offset(text,static_cast<std::size_t>(index-1)));
    if(!detail::rich_gtk_text_iter_has_tag(&begin,tag)) {lua_pushnil(L);return 1;}
    detail::TextIter end=begin;
    if(!detail::rich_gtk_text_iter_starts_tag(&begin,tag))
        detail::rich_gtk_text_iter_backward_to_tag_toggle(&begin,tag);
    detail::rich_gtk_text_iter_forward_to_tag_toggle(&end,tag);
    lua_pushinteger(L,static_cast<lua_Integer>(text_byte_offset(text,detail::rich_gtk_text_iter_get_offset(&begin))+1));
    lua_pushinteger(L,static_cast<lua_Integer>(text_byte_offset(text,detail::rich_gtk_text_iter_get_offset(&end))));
    return 2;
}

int text_offset_at(lua_State *L)
{
    if(!lua_arity_is(L,3) || lua_type(L,2)!=LUA_TNUMBER || lua_type(L,3)!=LUA_TNUMBER)
        return luaL_error(L,"gui textView:offsetAt expects two numeric coordinates");
    auto *s=check_kind(L,1,WidgetKind::text_view,"gui textView:offsetAt",false);
    const double x=lua_tonumber(L,2),y=lua_tonumber(L,3);
    if(!std::isfinite(x) || !std::isfinite(y)) return luaL_error(L,"gui textView:offsetAt: coordinates must be finite");
    if(!detail::gtk4_text_tags_available()) return push_fail_protected(L,"babet.gui: requires GTK 4.0 (TextView tags)");
    if(x<0 || y<0 || x>=detail::gtk4_widget_get_width(s->native) || y>=detail::gtk4_widget_get_height(s->native)) {lua_pushnil(L);return 1;}
    int bx=0,by=0;
    detail::rich_gtk_text_view_window_to_buffer_coords(s->native,1,static_cast<int>(x),static_cast<int>(y),&bx,&by);
    detail::TextIter iter{};
    if(!detail::rich_gtk_text_view_get_iter_at_location(s->native,&iter,bx,by)) {lua_pushnil(L);return 1;}
    const std::string text=rich_text_snapshot(detail::gtk4_text_view_get_buffer(s->native));
    const auto byte=text_byte_offset(text,detail::rich_gtk_text_iter_get_offset(&iter));
    if(byte>=text.size()) {lua_pushnil(L);return 1;}
    lua_pushinteger(L,static_cast<lua_Integer>(byte+1));return 1;
}
