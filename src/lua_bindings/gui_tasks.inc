// Pending callbacks live entirely in Lua, never in a native callback holding L.
char gui_tasks_key;
lua_State *tasks_owner=nullptr;
std::atomic_int pending_gui_tasks{0};
lua_Integer next_gui_task=0; // process-wide; never recycle IDs
bool has_gui_tasks() noexcept { return pending_gui_tasks.load()!=0; }
void release_idle_gui_owner() noexcept {
    if (!has_gui_tasks() && !has_file_dialogs() &&
        g_live_widgets.load()==0 && !g_run_active.load()) g_gui_owner=nullptr;
}
lua_Number task_clock() noexcept {
    return std::chrono::duration<lua_Number,std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
void cancel_gui_tasks(lua_State *owner) noexcept {
    // The deletion step holds the table, iterator key, copied key and nil.
    if (tasks_owner != owner || !lua_checkstack(owner, 4)) return;
    const int base = lua_gettop(owner);
    lua_rawgetp(owner, LUA_REGISTRYINDEX, &gui_tasks_key);
    lua_pushnil(owner);
    while (lua_next(owner, -2)) {
        lua_pop(owner, 1);
        lua_pushvalue(owner, -1);
        lua_pushnil(owner);
        lua_rawset(owner, -4);
    }
    lua_settop(owner, base);
    tasks_owner = nullptr;
    pending_gui_tasks.store(0);
    release_idle_gui_owner();
}
void remove_task(lua_State *L,int table,lua_Integer id) {
    table=lua_absindex(L,table);
    lua_rawgeti(L,table,id); const bool exists=!lua_isnil(L,-1); lua_pop(L,1);
    if (exists) { lua_pushnil(L);lua_rawseti(L,table,id);pending_gui_tasks.fetch_sub(1); }
    if (!has_gui_tasks()) tasks_owner=nullptr;
    release_idle_gui_owner();
}
int add_task(lua_State *L,int callback,lua_Number due,int process=0,int poll=0) {
    callback=lua_absindex(L,callback);
    if (next_gui_task==LUA_MAXINTEGER) return push_fail_protected(L,"gui: task identifiers exhausted");
    auto *owner=main_lua_state(L);
    if (!lua_checkstack(owner,32)) return push_fail_protected(L,"gui: cannot reserve callback stack");
    lua_rawgetp(L,LUA_REGISTRYINDEX,&gui_tasks_key); const int tasks=lua_gettop(L);
    lua_createtable(L,4,0);
    lua_pushvalue(L,callback);lua_rawseti(L,-2,1);
    lua_pushnumber(L,due);lua_rawseti(L,-2,2);
    if (process) {lua_pushvalue(L,process);lua_rawseti(L,-2,3);lua_pushvalue(L,poll);lua_rawseti(L,-2,4);}
    const lua_Integer id=++next_gui_task;
    lua_rawseti(L,tasks,id); // counts/owner change only after successful publication
    pending_gui_tasks.fetch_add(1);tasks_owner=owner;g_gui_owner=owner;
    lua_pushinteger(L,id);lua_pushnil(L);return 2;
}
int l_timeout(lua_State *L) {
    if (!lua_arity_is(L,2)||!lua_isinteger(L,1)||!lua_isfunction(L,2)||lua_tointeger(L,1)<0||lua_tointeger(L,1)>INT_MAX)
        return luaL_error(L,"gui.timeout expects (milliseconds 0..INT_MAX, function)");
    require_gui_initialized(L,"gui.timeout",true);
    return add_task(L,2,task_clock()+static_cast<lua_Number>(lua_tointeger(L,1)));
}
int l_idle(lua_State *L) {
    if (!lua_arity_is(L,1)||!lua_isfunction(L,1)) return luaL_error(L,"gui.idle expects one function");
    require_gui_initialized(L,"gui.idle",true);return add_task(L,1,0);
}
int l_cancel(lua_State *L) {
    if (!lua_arity_is(L,1)||!lua_isinteger(L,1)) return luaL_error(L,"gui.cancel expects one identifier");
    require_gui_initialized(L,"gui.cancel",true);
    lua_rawgetp(L,LUA_REGISTRYINDEX,&gui_tasks_key);lua_rawgeti(L,-1,lua_tointeger(L,1));
    const bool exists=!lua_isnil(L,-1);lua_pop(L,1);remove_task(L,-1,lua_tointeger(L,1));
    lua_pushboolean(L,exists);lua_pushnil(L);return 2;
}
int l_on_error(lua_State *L) {
    if (!lua_arity_is(L,1)||(!lua_isnil(L,1)&&!lua_isfunction(L,1))) return luaL_error(L,"gui.onError expects function or nil");
    babet_runtime::require_main_thread(L,"gui.onError");
    lua_pushvalue(L,1);lua_rawsetp(L,LUA_REGISTRYINDEX,&babet_callbacks::handler_key);return push_ok_protected(L);
}
int gui_process_on_exit(lua_State *L) {
    if (!lua_arity_is(L,3)||(!lua_isfunction(L,2)&&!lua_isnil(L,2))||!lua_iscfunction(L,3))
        return luaL_error(L,"process:onExit expects function or nil");
    require_gui_initialized(L,"process:onExit",true);
    lua_rawgetp(L,LUA_REGISTRYINDEX,&gui_tasks_key);const int tasks=lua_gettop(L);lua_pushnil(L);
    while(lua_next(L,tasks)) {
        lua_rawgeti(L,-1,3);const bool match=lua_rawequal(L,-1,1);lua_pop(L,1);
        const auto id=lua_tointeger(L,-2);lua_pop(L,1);if(match)remove_task(L,tasks,id);
    }
    if(lua_isnil(L,2))return push_ok_protected(L);
    return add_task(L,2,0,1,3);
}
bool loop_can_dispatch() noexcept {return !g_quit_requested.load()&&(g_live_windows.load()>0||has_file_dialogs());}
// Called under gui.run's protected thunk, outside GTK drawing.
void dispatch_gui_tasks(lua_State *L) {
    if(!has_gui_tasks()||!loop_can_dispatch())return;
    const int base=lua_gettop(L);
    lua_rawgetp(L,LUA_REGISTRYINDEX,&gui_tasks_key);const int tasks=lua_gettop(L);
    lua_newtable(L);const int ready=lua_gettop(L);lua_Integer count=0;const auto now=task_clock();
    lua_pushnil(L);
    while(lua_next(L,tasks)) {
        lua_rawgeti(L,-1,2);const bool due=lua_tonumber(L,-1)<=now;lua_pop(L,1);
        if(due){lua_pushvalue(L,-2);lua_rawseti(L,ready,++count);}lua_pop(L,1);
    }
    for(lua_Integer i=1;i<=count&&loop_can_dispatch();++i) {
        lua_settop(L,ready);lua_rawgeti(L,ready,i);const auto id=lua_tointeger(L,-1);lua_pop(L,1);
        lua_rawgeti(L,tasks,id);if(!lua_istable(L,-1))continue;const int entry=lua_gettop(L);
        lua_rawgeti(L,entry,3);const bool process=!lua_isnil(L,-1);lua_pop(L,1);int result=0;
        if(process) {
            lua_rawgeti(L,entry,4);lua_rawgeti(L,entry,3);lua_pushinteger(L,0);
            if(babet_callbacks::pcall(L,2,2)!=LUA_OK){remove_task(L,tasks,id);report_callback_error(L);continue;}
            result=lua_gettop(L)-1;
            const char *err=lua_type(L,-1)==LUA_TSTRING?lua_tostring(L,-1):"";
            if(lua_isnil(L,result)&&(!std::strcmp(err,"timeout")||!std::strcmp(err,"stopped")||!std::strcmp(err,"interrupted")))continue;
            // wait(0) may dispatch signals which cancel or replace this observer.
            lua_rawgeti(L,tasks,id);const bool current=lua_rawequal(L,-1,entry);lua_pop(L,1);
            if(!current||!loop_can_dispatch())continue;
        }
        remove_task(L,tasks,id);lua_rawgeti(L,entry,1);
        if(process){lua_pushvalue(L,result);lua_pushvalue(L,result+1);}
        if(babet_callbacks::pcall(L,process?2:0,0)!=LUA_OK)report_callback_error(L);
    }
    lua_settop(L,base);
}
int window_on_resize(lua_State *L) {
    if(!lua_arity_is(L,2)||(!lua_isnil(L,2)&&!lua_isfunction(L,2)))return luaL_error(L,"window:onResize expects function or nil");
    auto *s=check_kind(L,1,WidgetKind::window,"window:onResize");
    lua_getiuservalue(L,1,1);lua_pushvalue(L,2);lua_rawseti(L,-2,RESIZE_CALLBACK);
    s->resize_width=s->resize_height=-1;return push_ok_protected(L);
}
void dispatch_window_sizes(lua_State *L) {
    const int base=lua_gettop(L);lua_newtable(L);const int handles=lua_gettop(L);lua_Integer count=0;
    // Strong snapshot: any callback may destroy another window or trigger GC.
    lua_rawgetp(L,LUA_REGISTRYINDEX,&widget_handles_key);lua_pushnil(L);
    while(lua_next(L,-2)) {
        auto *ud=static_cast<WidgetUserdata*>(luaL_testudata(L,-1,WIDGET_META));
        if(ud&&ud->state&&ud->state->kind==WidgetKind::window){lua_pushvalue(L,-1);lua_rawseti(L,handles,++count);}lua_pop(L,1);
    }
    for(lua_Integer i=1;i<=count&&loop_can_dispatch();++i) {
        lua_settop(L,handles);lua_rawgeti(L,handles,i);auto *ud=static_cast<WidgetUserdata*>(lua_touserdata(L,-1));auto *s=ud->state;
        if(!s||!s->native||!detail::gtk4_widget_get_mapped(s->native))continue;
        const int w=detail::gtk4_widget_get_width(s->native),h=detail::gtk4_widget_get_height(s->native);
        if(w<=0||h<=0||(w==s->resize_width&&h==s->resize_height))continue;
        s->resize_width=w;s->resize_height=h;
        lua_getiuservalue(L,-1,1);lua_rawgeti(L,-1,RESIZE_CALLBACK);if(!lua_isfunction(L,-1))continue;
        lua_pushinteger(L,w);lua_pushinteger(L,h);
        if(babet_callbacks::pcall(L,2,0)!=LUA_OK)report_callback_error(L);
    }
    lua_settop(L,base);
}
int window_request_close(lua_State *L) {
    if(!lua_arity_is(L,1))return luaL_error(L,"window:requestClose expects no arguments");
    auto *s=check_kind(L,1,WidgetKind::window,"window:requestClose");
    {ScopedWidgetCallback pin(s,L);detail::gtk4_window_close(pin.native());}
    return push_ok_protected(L);
}
