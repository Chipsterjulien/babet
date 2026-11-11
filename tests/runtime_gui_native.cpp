// Focused runner: production bindings, with only unrelated terminal UI stubbed.
#include "lua_bindings/gui.hpp"
#include "lua_bindings/main_thread.hpp"
#include "lua_bindings/curses.hpp"
#include "lua_bindings/process.hpp"
#include "lua_bindings/signal.hpp"
#include "lua_bindings/fileExists.hpp"
#include "lua_bindings/lua_utils.hpp"
#include "project_core/runtime_info.hpp"
#include "project_core/zip_utils.hpp"
#include "project_core/executable_path.hpp"
#include <lua.hpp>
#include <filesystem>
#include <iostream>
#include <unistd.h>
#include <cerrno>
namespace babet_curses {
bool session_active() noexcept{return false;}
void service_terminal_events() noexcept{}
HandoffPrepareResult prepare_reserved_terminal_handoff(unsigned long,std::string&){return HandoffPrepareResult::not_active;}
void cancel_reserved_terminal_handoff(unsigned long) noexcept{}
HandoffPrepareResult prepare_foreground_resume(std::string&){return HandoffPrepareResult::not_active;}
void cancel_foreground_resume() noexcept{}
int install_logical_signal_action(int n,const struct sigaction &s) noexcept{return sigaction(n,&s,nullptr)==0?0:errno;}
}
static int pid(lua_State *L){lua_pushinteger(L,getpid());return 1;}
int main(int argc,char **argv){
    namespace fs=std::filesystem;babet_runtime::register_main_thread();lua_State *L=nullptr;
    try{
        if(argc==4&&std::string(argv[1])=="-c"){
            std::string zip=std::string(argv[3])+".zip";
            if(!createZipFromDirectory(argv[2],zip,argv[3]))return 2;
            mergeFiles("/proc/self/exe",zip,argv[3]);fs::remove(zip);return 0;
        }
        std::string error;const auto layout=runningEmbeddedImageLayout(&error);if(!layout)throw std::runtime_error(error);
        const bool embedded=layout->generated;if(!embedded&&argc<2)return 2;
        const fs::path target=embedded?fs::path("main.lua"):fs::absolute(argv[1]);
        const bool directory=!embedded&&fs::is_directory(target);const fs::path script=directory?target/"main.lua":target;
        const std::string dir=embedded?"":script.parent_path().string(),executable=getExecutablePath();
        L=luaL_newstate();if(!L)return 3;
        auto setup=[&](lua_State *s){
            luaL_openlibs(s);lua_newtable(s);babet_gui::register_gui(s);register_process(s);register_signal(s);register_babet_runtime_info(s);
            lua_pushcfunction(s,lua_exists);lua_setfield(s,-2,"exists");lua_pushcfunction(s,lua_fileExists);lua_setfield(s,-2,"fileExists");
            lua_pushcfunction(s,pid);lua_setfield(s,-2,"pid");lua_setglobal(s,"babet");
            set_babet_runtime_info(s,embedded?"embedded":directory?"directory":"file",dir.c_str(),script.c_str(),executable.c_str());
            lua_newtable(s);const int start=embedded?0:1;
            for(int i=start;i<argc;++i){lua_pushstring(s,argv[i]);lua_rawseti(s,-2,i-start);}lua_setglobal(s,"arg");
        };
        if(!lua_run_setup_protected(L,setup,"setup",error))throw std::runtime_error(error);
        int status;
        if(embedded){auto bytes=readEmbeddedFile("/proc/self/exe","main.lua",&error,&*layout);if(!bytes)throw std::runtime_error(error);status=luaL_loadbuffer(L,bytes->data(),bytes->size(),"main.lua");}
        else status=luaL_loadfile(L,script.c_str());
        if(!status)status=lua_pcall(L,0,0,0);
        if(status)std::cerr<<lua_tostring(L,-1)<<'\n';
        babet_gui::cleanup_on_main_thread(L);lua_close(L);return status?1:0;
    }catch(const std::exception &e){if(L){babet_gui::cleanup_on_main_thread(L);lua_close(L);}std::cerr<<e.what()<<'\n';return 1;}
}
