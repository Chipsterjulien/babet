#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifndef _XOPEN_SOURCE_EXTENDED
#define _XOPEN_SOURCE_EXTENDED 1
#endif

#include "curses.hpp"
#include "gui.hpp"
#include "lua_utils.hpp"
#include "main_thread.hpp"
#include "process_terminal_internal.hpp"
#include "signal.hpp"

extern "C"
{
#include "lua.h"
#include "lauxlib.h"
}

#include <curses.h>
#include <term.h>

#include <atomic>
#include <chrono>
#include <cerrno>
#include <climits>
#include <clocale>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <langinfo.h>
#include <locale.h>
#include <pthread.h>
#include <signal.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace babet_curses
{
namespace
{

struct SavedSignalAction
{
    int signum = 0;
    struct sigaction logical{};
    bool valid = false;
};

struct CursesState
{
    SCREEN *screen = nullptr;
    locale_t locale = static_cast<locale_t>(0);
    locale_t previous_locale = static_cast<locale_t>(0);
    bool locale_installed = false;
    bool suspended_for_child = false;
    bool resize_event_pending = false;
    SavedSignalAction managed[3]{{SIGINT, {}, false},
                                 {SIGTERM, {}, false},
                                 {SIGHUP, {}, false}};
    SavedSignalAction winch{SIGWINCH, {}, false};
    SavedSignalAction tstp{SIGTSTP, {}, false};
    SavedSignalAction cont{SIGCONT, {}, false};
};

CursesState g_state;
std::atomic_bool g_active{false};
volatile sig_atomic_t g_resize_pending = 0;
volatile sig_atomic_t g_tstp_pending = 0;
volatile sig_atomic_t g_cont_pending = 0;
volatile sig_atomic_t g_default_termination_pending = 0;
unsigned long g_suspend_generation = 0;

bool managed_termination_signal(int signum) noexcept
{
    return signum == SIGINT || signum == SIGTERM || signum == SIGHUP;
}

SavedSignalAction *managed_action(int signum) noexcept
{
    for (auto &entry : g_state.managed)
        if (entry.signum == signum)
            return &entry;
    return nullptr;
}

extern "C" void curses_winch_handler(int) noexcept
{
    g_resize_pending = 1;
}

extern "C" void curses_tstp_handler(int) noexcept
{
    g_tstp_pending = 1;
}

extern "C" void curses_cont_handler(int) noexcept
{
    g_cont_pending = 1;
}

extern "C" void curses_default_termination_handler(int signum) noexcept
{
    if (signum == SIGINT || signum == SIGTERM || signum == SIGHUP)
        g_default_termination_pending = signum;
}

int raw_sigaction(int signum, const struct sigaction &action) noexcept
{
    if (::sigaction(signum, &action, nullptr) == 0)
        return 0;
    return errno;
}

struct sigaction simple_handler(void (*handler)(int)) noexcept
{
    struct sigaction action{};
    ::sigemptyset(&action.sa_mask);
    action.sa_handler = handler;
    action.sa_flags = 0;
    return action;
}

bool snapshot_signal(SavedSignalAction &slot) noexcept
{
    if (::sigaction(slot.signum, nullptr, &slot.logical) != 0)
        return false;
    slot.valid = true;
    return true;
}

void restore_saved_signal(const SavedSignalAction &slot) noexcept
{
    if (slot.valid)
        ::sigaction(slot.signum, &slot.logical, nullptr);
}

int install_managed_action(const SavedSignalAction &slot) noexcept
{
    if (!slot.valid)
        return EINVAL;
    if (slot.logical.sa_handler == SIG_DFL)
    {
        const struct sigaction deferred =
            simple_handler(curses_default_termination_handler);
        return raw_sigaction(slot.signum, deferred);
    }
    return raw_sigaction(slot.signum, slot.logical);
}

bool install_curses_signal_policy() noexcept
{
    const struct sigaction winch = simple_handler(curses_winch_handler);
    const struct sigaction tstp = simple_handler(curses_tstp_handler);
    const struct sigaction cont = simple_handler(curses_cont_handler);
    if (raw_sigaction(SIGWINCH, winch) != 0 ||
        raw_sigaction(SIGTSTP, tstp) != 0 ||
        raw_sigaction(SIGCONT, cont) != 0)
        return false;
    for (const auto &entry : g_state.managed)
        if (install_managed_action(entry) != 0)
            return false;
    return true;
}

void restore_pre_curses_signal_policy() noexcept
{
    for (const auto &entry : g_state.managed)
        restore_saved_signal(entry);
    restore_saved_signal(g_state.winch);
    restore_saved_signal(g_state.tstp);
    restore_saved_signal(g_state.cont);
}

bool same_tty(int left, int right) noexcept
{
    struct stat a{};
    struct stat b{};
    return ::fstat(left, &a) == 0 && ::fstat(right, &b) == 0 &&
           a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

bool utf8_codeset(locale_t locale) noexcept
{
    const char *codeset = ::nl_langinfo_l(CODESET, locale);
    return codeset && (::strcasecmp(codeset, "UTF-8") == 0 ||
                       ::strcasecmp(codeset, "UTF8") == 0);
}

locale_t create_utf8_locale() noexcept
{
    locale_t locale = ::newlocale(LC_CTYPE_MASK, "", nullptr);
    if (locale && utf8_codeset(locale))
        return locale;
    if (locale)
        ::freelocale(locale);

    static constexpr const char *fallbacks[] = {"C.UTF-8", "C.utf8"};
    for (const char *name : fallbacks)
    {
        locale = ::newlocale(LC_CTYPE_MASK, name, nullptr);
        if (locale && utf8_codeset(locale))
            return locale;
        if (locale)
            ::freelocale(locale);
    }
    return static_cast<locale_t>(0);
}

void release_locale() noexcept
{
    if (g_state.locale_installed)
    {
        ::uselocale(g_state.previous_locale);
        g_state.locale_installed = false;
    }
    if (g_state.locale)
    {
        ::freelocale(g_state.locale);
        g_state.locale = static_cast<locale_t>(0);
    }
    g_state.previous_locale = static_cast<locale_t>(0);
}

void reset_event_flags() noexcept
{
    g_resize_pending = 0;
    g_tstp_pending = 0;
    g_cont_pending = 0;
    g_default_termination_pending = 0;
    g_suspend_generation = 0;
    g_state.resize_event_pending = false;
}

bool restore_program_mode() noexcept
{
    if (!g_state.screen)
        return false;
    ::set_term(g_state.screen);
    if (::reset_prog_mode() == ERR)
        return false;
    ::clearok(stdscr, TRUE);
    if (::doupdate() == ERR)
        return false;
    g_state.suspended_for_child = false;
    return true;
}

void service_resize() noexcept
{
    if (!g_resize_pending || !g_state.screen)
        return;
    if (babet_process::detail::terminal_owner_state() !=
        babet_process::detail::TerminalOwnerState::curses)
        return;

    g_resize_pending = 0;
    struct winsize size{};
    if (::ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 &&
        size.ws_row > 0 && size.ws_col > 0)
    {
        ::set_term(g_state.screen);
        if (::resize_term(static_cast<int>(size.ws_row),
                          static_cast<int>(size.ws_col)) != ERR)
        {
            g_state.resize_event_pending = true;
        }
    }
}

void controlled_suspend() noexcept
{
    if (!g_tstp_pending || !g_state.screen)
        return;
    if (babet_process::detail::terminal_owner_state() !=
        babet_process::detail::TerminalOwnerState::curses)
        return;

    g_tstp_pending = 0;
    ::set_term(g_state.screen);
    (void)::def_prog_mode();
    (void)::endwin();

    // SIGTSTP peut avoir été livré à un autre thread, ou le masque du thread
    // principal peut avoir changé depuis l'installation de curses. Pour que la
    // suspension contrôlée ne dépende jamais de cet état implicite, on reproduit
    // le schéma POSIX classique : bloquer SIGTSTP, remettre son action par
    // défaut, en générer un exemplaire pending sur ce thread, puis le débloquer.
    // Le pthread_sigmask(SIG_UNBLOCK) ne revient qu'après le SIGCONT lorsque
    // l'action par défaut a effectivement arrêté le processus.
    sigset_t tstp_mask{};
    sigset_t previous_mask{};
    ::sigemptyset(&tstp_mask);
    ::sigaddset(&tstp_mask, SIGTSTP);
    const int mask_rc =
        ::pthread_sigmask(SIG_BLOCK, &tstp_mask, &previous_mask);

    const struct sigaction dfl = simple_handler(SIG_DFL);
    if (mask_rc == 0 && raw_sigaction(SIGTSTP, dfl) == 0 &&
        ::raise(SIGTSTP) == 0)
    {
        // La livraison du SIGTSTP pending avec SIG_DFL suspend ici. Le code
        // reprend au retour de pthread_sigmask() après SIGCONT.
        (void)::pthread_sigmask(SIG_UNBLOCK, &tstp_mask, nullptr);
    }

    // Fermer la petite fenêtre où SIGTSTP est encore à SIG_DFL avant de
    // réinstaller le handler Babet, puis restituer exactement le masque
    // d'entrée du thread principal.
    if (mask_rc == 0)
        (void)::pthread_sigmask(SIG_BLOCK, &tstp_mask, nullptr);
    const struct sigaction tstp = simple_handler(curses_tstp_handler);
    const struct sigaction cont = simple_handler(curses_cont_handler);
    (void)raw_sigaction(SIGTSTP, tstp);
    (void)raw_sigaction(SIGCONT, cont);
    if (mask_rc == 0)
        (void)::pthread_sigmask(SIG_SETMASK, &previous_mask, nullptr);

    g_cont_pending = 0;
    (void)restore_program_mode();
    ++g_suspend_generation;
}

[[noreturn]] void terminate_with_default_signal(int signum) noexcept
{
    cleanup_on_main_thread();
    const struct sigaction dfl = simple_handler(SIG_DFL);
    (void)raw_sigaction(signum, dfl);
    ::raise(signum);
    // Un signal bloqué ne doit pas permettre de continuer avec un état de
    // terminaison déjà consommé.
    ::_exit(128 + signum);
}

bool utf8_to_wide(const char *text, size_t length,
                  std::wstring &out)
{
    out.clear();
    std::mbstate_t state{};
    const char *p = text;
    size_t remaining = length;
    while (remaining > 0)
    {
        wchar_t wc = 0;
        const size_t n = ::mbrtowc(&wc, p, remaining, &state);
        if (n == static_cast<size_t>(-1) ||
            n == static_cast<size_t>(-2))
            return false;
        if (n == 0)
        {
            // Les chaînes Lua peuvent contenir NUL ; ncurses wide-string APIs
            // sont NUL-terminées, donc on refuse ce cas explicitement.
            return false;
        }
        out.push_back(wc);
        p += n;
        remaining -= n;
    }
    return true;
}

bool require_active_owner(lua_State *L, const char *api)
{
    babet_runtime::require_main_thread(L, api);
    service_terminal_events();
    if (!g_active.load(std::memory_order_acquire) || !g_state.screen)
        luaL_error(L, "%s: curses session is not active", api);
    const auto owner = babet_process::detail::terminal_owner_state();
    if (owner == babet_process::detail::TerminalOwnerState::child_process)
        luaL_error(L, "%s: an interactive child process owns the terminal", api);
    if (owner ==
        babet_process::detail::TerminalOwnerState::terminal_reclaimed_curses_pending)
    {
        service_terminal_events();
        if (babet_process::detail::terminal_owner_state() !=
            babet_process::detail::TerminalOwnerState::curses)
            luaL_error(L, "%s: curses terminal restoration is pending", api);
    }
    return true;
}

int l_start(lua_State *L)
{
    babet_runtime::require_main_thread(L, "curses.start");
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "curses.start expects no arguments");
    if (g_active.load(std::memory_order_acquire))
        return luaL_error(L, "curses.start: a curses session is already active");
    if (babet_gui::session_active())
        return luaL_error(L, "curses.start: a GUI session is already active");
    if (::isatty(STDIN_FILENO) != 1 || ::isatty(STDOUT_FILENO) != 1 ||
        !same_tty(STDIN_FILENO, STDOUT_FILENO))
        return luaL_error(L, "curses.start: stdin and stdout must be the same TTY");

    const char *term = ::getenv("TERM");
    if (!term || !*term)
        return luaL_error(L, "curses.start: TERM is missing or empty");

    if (!snapshot_signal(g_state.managed[0]) ||
        !snapshot_signal(g_state.managed[1]) ||
        !snapshot_signal(g_state.managed[2]) ||
        !snapshot_signal(g_state.winch) || !snapshot_signal(g_state.tstp) ||
        !snapshot_signal(g_state.cont))
        return luaL_error(L, "curses.start: cannot snapshot signal dispositions: %s",
                          std::strerror(errno));

    g_state.locale = create_utf8_locale();
    if (!g_state.locale)
        return luaL_error(L, "curses.start: no usable UTF-8 LC_CTYPE locale is available");
    g_state.previous_locale = ::uselocale(g_state.locale);
    if (g_state.previous_locale == static_cast<locale_t>(0))
    {
        const int saved = errno;
        release_locale();
        return luaL_error(L, "curses.start: cannot install thread-local UTF-8 locale: %s",
                          std::strerror(saved));
    }
    g_state.locale_installed = true;

    if (!babet_process::detail::begin_curses_session(STDIN_FILENO, ::getpgrp()))
    {
        const int saved = errno;
        release_locale();
        return luaL_error(L, "curses.start: terminal is not available: %s",
                          std::strerror(saved));
    }
    g_active.store(true, std::memory_order_release);

    int errret = 0;
    if (::setupterm(term, STDOUT_FILENO, &errret) == ERR)
    {
        babet_process::detail::end_curses_session();
        g_active.store(false, std::memory_order_release);
        release_locale();
        if (errret == -1)
            return luaL_error(L, "curses.start: terminfo database is unavailable for TERM=%s", term);
        if (errret == 0)
            return luaL_error(L, "curses.start: terminal type '%s' is unknown or too generic", term);
        return luaL_error(L, "curses.start: terminal type '%s' cannot be used by curses", term);
    }
    TERMINAL *probe = cur_term;
    if (probe)
        (void)::del_curterm(probe);

    g_state.screen = ::newterm(term, stdout, stdin);
    if (!g_state.screen)
    {
        // newterm() may already have touched signal dispositions before
        // reporting failure; restore Babet's pre-curses policy explicitly.
        restore_pre_curses_signal_policy();
        babet_process::detail::end_curses_session();
        g_active.store(false, std::memory_order_release);
        release_locale();
        return luaL_error(L, "curses.start: ncurses initialization failed for TERM=%s", term);
    }
    ::set_term(g_state.screen);

    if (::cbreak() == ERR || ::noecho() == ERR ||
        ::keypad(stdscr, TRUE) == ERR || ::intrflush(stdscr, FALSE) == ERR)
    {
        (void)::endwin();
        ::delscreen(g_state.screen);
        g_state.screen = nullptr;
        restore_pre_curses_signal_policy();
        babet_process::detail::end_curses_session();
        g_active.store(false, std::memory_order_release);
        release_locale();
        return luaL_error(L, "curses.start: cannot configure terminal program mode");
    }

    if (!install_curses_signal_policy())
    {
        const int saved = errno;
        (void)::endwin();
        ::delscreen(g_state.screen);
        g_state.screen = nullptr;
        restore_pre_curses_signal_policy();
        babet_process::detail::end_curses_session();
        g_active.store(false, std::memory_order_release);
        release_locale();
        return luaL_error(L, "curses.start: cannot install terminal signal policy: %s",
                          std::strerror(saved));
    }

    reset_event_flags();
    signal_ensure_dispatch_hook(L);
    lua_pushboolean(L, 1);
    return 1;
}

int l_stop(lua_State *L)
{
    babet_runtime::require_main_thread(L, "curses.stop");
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "curses.stop expects no arguments");
    service_terminal_events();
    // Si un enfant interactif possède actuellement le TTY, la session logique
    // curses peut tout de même être arrêtée : cleanup_on_main_thread() libère
    // le SCREEN sans endwin() (déjà fait avant le handoff) et le registre
    // conserve l'enfant comme propriétaire jusqu'à son reclaim POSIX.
    cleanup_on_main_thread();
    lua_pushboolean(L, 1);
    return 1;
}

int l_clear(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "curses.clear expects no arguments");
    require_active_owner(L, "curses.clear");
    if (::werase(stdscr) == ERR)
        return luaL_error(L, "curses.clear: ncurses failed");
    lua_pushboolean(L, 1);
    return 1;
}

int l_refresh(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "curses.refresh expects no arguments");
    require_active_owner(L, "curses.refresh");
    if (::wrefresh(stdscr) == ERR)
        return luaL_error(L, "curses.refresh: ncurses failed");
    service_terminal_events();
    lua_pushboolean(L, 1);
    return 1;
}

int l_size(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "curses.size expects no arguments");
    require_active_owner(L, "curses.size");
    int rows = 0;
    int cols = 0;
    getmaxyx(stdscr, rows, cols);
    lua_pushinteger(L, rows);
    lua_pushinteger(L, cols);
    return 2;
}

int l_move(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_integer(L, 1) ||
        !lua_is_strict_integer(L, 2))
        return luaL_error(L, "curses.move expects integer row and column");
    const lua_Integer row = lua_tointeger(L, 1);
    const lua_Integer col = lua_tointeger(L, 2);
    if (row < 1 || col < 1 || row > INT_MAX || col > INT_MAX)
        return luaL_error(L, "curses.move: row and column are 1-based positive integers");
    require_active_owner(L, "curses.move");
    if (::wmove(stdscr, static_cast<int>(row - 1),
                static_cast<int>(col - 1)) == ERR)
        return luaL_error(L, "curses.move: position is outside the screen");
    lua_pushboolean(L, 1);
    return 1;
}

int l_write(lua_State *L)
{
    if (!lua_arity_is(L, 1) || !lua_is_strict_string(L, 1))
        return luaL_error(L, "curses.write expects one UTF-8 string");
    size_t length = 0;
    const char *text = lua_tolstring(L, 1, &length);
    require_active_owner(L, "curses.write");

    bool converted = false;
    bool too_large = false;
    bool written = false;
    {
        std::wstring wide;
        converted = utf8_to_wide(text, length, wide);
        too_large = converted &&
                    wide.size() > static_cast<std::size_t>(INT_MAX);
        if (converted && !too_large)
            written = ::waddnwstr(stdscr, wide.c_str(),
                                  static_cast<int>(wide.size())) != ERR;
    }
    if (!converted)
        return luaL_error(L, "curses.write: invalid UTF-8 text (or embedded NUL)");
    if (too_large)
        return luaL_error(L, "curses.write: text is too large");
    if (!written)
        return luaL_error(L, "curses.write: ncurses failed");
    lua_pushboolean(L, 1);
    return 1;
}

const char *special_key_name(wint_t key) noexcept
{
    switch (key)
    {
    case KEY_UP: return "up";
    case KEY_DOWN: return "down";
    case KEY_LEFT: return "left";
    case KEY_RIGHT: return "right";
    case KEY_HOME: return "home";
    case KEY_END: return "end";
    case KEY_NPAGE: return "page_down";
    case KEY_PPAGE: return "page_up";
    case KEY_BACKSPACE: return "backspace";
    case KEY_DC: return "delete";
    case KEY_IC: return "insert";
#ifdef KEY_ENTER
    case KEY_ENTER: return "enter";
#endif
#ifdef KEY_RESIZE
    case KEY_RESIZE: return "resize";
#endif
    default: return nullptr;
    }
}

int l_read_key(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1))
        return luaL_error(L, "curses.readKey expects an optional timeout in seconds");
    double timeout = -1.0;
    if (lua_gettop(L) == 1 && !lua_isnil(L, 1))
    {
        if (!lua_is_strict_number(L, 1))
            return luaL_error(L, "curses.readKey: timeout must be a number or nil");
        timeout = lua_tonumber(L, 1);
        if (timeout < 0.0 || timeout > static_cast<double>(INT_MAX) / 1000.0)
            return luaL_error(L, "curses.readKey: timeout is out of range");
    }
    require_active_owner(L, "curses.readKey");

    const int timeout_ms = timeout < 0.0
                               ? -1
                               : static_cast<int>(timeout * 1000.0 + 0.5);
    constexpr int signal_poll_slice_ms = 50;
    using monotonic_clock = std::chrono::steady_clock;
    const auto deadline = timeout_ms > 0
                              ? monotonic_clock::now() +
                                    std::chrono::milliseconds(timeout_ms)
                              : monotonic_clock::time_point{};
    bool zero_timeout_polled = false;
    const unsigned long suspend_generation = g_suspend_generation;
    wint_t value = 0;
    int rc = ERR;

    while (true)
    {
        // Les handlers curses POSIX ne font que poser des flags. Les servir
        // avant chaque attente ferme le cas où le signal est déjà pending.
        // La tranche bornée ferme ensuite la course inverse : un signal qui
        // arrive juste après ce safe-point ne peut pas laisser wget_wch()
        // bloqué indéfiniment sans rendre la main au thread principal.
        const bool handled_pending = signal_any_handled_pending();
        signal_dispatch_pending(L);

        // A signal can arrive after the pending snapshot, and its Lua
        // callback can stop curses. Never touch the released screen again.
        if (!g_active.load(std::memory_order_acquire) || !g_state.screen)
        {
            lua_pushnil(L);
            lua_pushstring(L, "interrupted");
            return 2;
        }

        if (g_state.resize_event_pending)
        {
            g_state.resize_event_pending = false;
            lua_pushstring(L, "resize");
            return 1;
        }
        if (g_suspend_generation != suspend_generation || handled_pending)
        {
            lua_pushnil(L);
            lua_pushstring(L, "interrupted");
            return 2;
        }

        int wait_ms = signal_poll_slice_ms;
        if (timeout_ms == 0)
        {
            if (zero_timeout_polled)
            {
                lua_pushnil(L);
                lua_pushstring(L, "timeout");
                return 2;
            }
            wait_ms = 0;
            zero_timeout_polled = true;
        }
        else if (timeout_ms > 0)
        {
            const auto now = monotonic_clock::now();
            if (now >= deadline)
            {
                lua_pushnil(L);
                lua_pushstring(L, "timeout");
                return 2;
            }
            const auto remaining =
                std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
            const auto remaining_count = remaining.count();
            wait_ms = static_cast<int>(remaining_count <= 0
                                           ? 1
                                           : (remaining_count < signal_poll_slice_ms
                                                  ? remaining_count
                                                  : signal_poll_slice_ms));
        }

        errno = 0;
        ::wtimeout(stdscr, wait_ms);
        rc = ::wget_wch(stdscr, &value);
        const int read_errno = errno;
        ::wtimeout(stdscr, -1);

        const bool handled_after_read = signal_any_handled_pending();
        signal_dispatch_pending(L);

        if (!g_active.load(std::memory_order_acquire) || !g_state.screen)
        {
            lua_pushnil(L);
            lua_pushstring(L, "interrupted");
            return 2;
        }

        if (g_state.resize_event_pending)
        {
            g_state.resize_event_pending = false;
            lua_pushstring(L, "resize");
            return 1;
        }
        if (g_suspend_generation != suspend_generation)
        {
            lua_pushnil(L);
            lua_pushstring(L, "interrupted");
            return 2;
        }
        if (rc != ERR)
            break;
        if (handled_after_read || read_errno == EINTR)
        {
            lua_pushnil(L);
            lua_pushstring(L, "interrupted");
            return 2;
        }

        // ERR sans événement est simplement l'expiration de notre tranche
        // interne. Pour un timeout public, la deadline monotone décide seule
        // quand rendre nil,"timeout" ; sans timeout, on repart attendre.
        if (timeout_ms == 0 ||
            (timeout_ms > 0 && monotonic_clock::now() >= deadline))
        {
            lua_pushnil(L);
            lua_pushstring(L, "timeout");
            return 2;
        }
    }

    if (rc == KEY_CODE_YES)
    {
        if (const char *name = special_key_name(value))
        {
            lua_pushstring(L, name);
            return 1;
        }
        if (value >= KEY_F(1) && value <= KEY_F(63))
        {
            lua_pushfstring(L, "f%d", static_cast<int>(value - KEY_F(0)));
            return 1;
        }
        lua_pushstring(L, "special");
        return 1;
    }

    char buffer[MB_LEN_MAX];
    std::mbstate_t state{};
    const size_t n = ::wcrtomb(buffer, static_cast<wchar_t>(value), &state);
    if (n == static_cast<size_t>(-1))
        return luaL_error(L, "curses.readKey: cannot encode input as UTF-8");
    lua_pushlstring(L, buffer, n);
    return 1;
}

} // namespace

bool session_active() noexcept
{
    return g_active.load(std::memory_order_acquire);
}

HandoffPrepareResult prepare_reserved_terminal_handoff(
    unsigned long reservation_token, std::string &error)
{
    if (!session_active())
        return HandoffPrepareResult::not_active;
    if (!babet_runtime::is_main_thread())
    {
        error = "interactive terminal handoff is unavailable from a worker while curses is active";
        return HandoffPrepareResult::error;
    }
    service_terminal_events();
    if (babet_process::detail::terminal_owner_state() !=
        babet_process::detail::TerminalOwnerState::curses)
    {
        error = "curses terminal is not available for an interactive child";
        return HandoffPrepareResult::error;
    }
    ::set_term(g_state.screen);
    if (::def_prog_mode() == ERR || ::endwin() == ERR)
    {
        error = "cannot suspend curses before interactive child launch";
        return HandoffPrepareResult::error;
    }
    if (!babet_process::detail::mark_curses_handoff_prepared(reservation_token))
    {
        (void)restore_program_mode();
        error = "terminal handoff reservation changed while suspending curses";
        return HandoffPrepareResult::error;
    }
    g_state.suspended_for_child = true;
    return HandoffPrepareResult::suspended;
}

void cancel_reserved_terminal_handoff(unsigned long reservation_token) noexcept
{
    if (!session_active() || !babet_runtime::is_main_thread() ||
        !g_state.suspended_for_child)
        return;
    babet_process::detail::cancel_curses_handoff_prepared(reservation_token);
    (void)restore_program_mode();
}

HandoffPrepareResult prepare_foreground_resume(std::string &error)
{
    if (!session_active())
        return HandoffPrepareResult::not_active;
    if (!babet_runtime::is_main_thread())
    {
        error = "foreground process resume is unavailable from a worker while curses is active";
        return HandoffPrepareResult::error;
    }
    service_terminal_events();
    if (babet_process::detail::terminal_owner_state() !=
        babet_process::detail::TerminalOwnerState::curses)
    {
        error = "curses terminal is not available for foreground resume";
        return HandoffPrepareResult::error;
    }
    ::set_term(g_state.screen);
    if (::def_prog_mode() == ERR || ::endwin() == ERR)
    {
        error = "cannot suspend curses before foreground resume";
        return HandoffPrepareResult::error;
    }
    if (!babet_process::detail::mark_curses_foreground_resume_prepared())
    {
        (void)restore_program_mode();
        error = "terminal state changed while suspending curses";
        return HandoffPrepareResult::error;
    }
    g_state.suspended_for_child = true;
    return HandoffPrepareResult::suspended;
}

void cancel_foreground_resume() noexcept
{
    if (!session_active() || !babet_runtime::is_main_thread() ||
        !g_state.suspended_for_child)
        return;
    babet_process::detail::cancel_curses_foreground_resume_prepared();
    (void)restore_program_mode();
}

void service_terminal_events() noexcept
{
    if (!session_active() || !babet_runtime::is_main_thread() || !g_state.screen)
        return;

    const int terminate_signal = g_default_termination_pending;
    if (terminate_signal != 0)
    {
        g_default_termination_pending = 0;
        terminate_with_default_signal(terminate_signal);
    }

    if (babet_process::detail::terminal_owner_state() ==
        babet_process::detail::TerminalOwnerState::terminal_reclaimed_curses_pending)
    {
        if (restore_program_mode())
            (void)babet_process::detail::complete_curses_restore();
    }

    controlled_suspend();
    service_resize();
}

void cleanup_on_main_thread() noexcept
{
    if (!session_active() || !babet_runtime::is_main_thread())
        return;

    const auto owner = babet_process::detail::terminal_owner_state();
    if (g_state.screen)
    {
        ::set_term(g_state.screen);
        if (owner != babet_process::detail::TerminalOwnerState::child_process &&
            !g_state.suspended_for_child)
            (void)::endwin();
        ::delscreen(g_state.screen);
        g_state.screen = nullptr;
    }

    restore_pre_curses_signal_policy();
    babet_process::detail::end_curses_session();
    g_active.store(false, std::memory_order_release);
    g_state.suspended_for_child = false;
    reset_event_flags();
    release_locale();
}

int install_logical_signal_action(int signum,
                                  const struct sigaction &logical) noexcept
{
    if (!session_active() || !managed_termination_signal(signum))
    {
        if (::sigaction(signum, &logical, nullptr) == 0)
            return 0;
        return errno;
    }
    SavedSignalAction *slot = managed_action(signum);
    if (!slot)
        return EINVAL;
    slot->logical = logical;
    slot->valid = true;
    return install_managed_action(*slot);
}

template <int (*Fn)(lua_State *)>
int curses_lua_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "curses: out of memory", "curses: internal C++ failure",
        "curses: unknown internal C++ failure");
}

void register_curses(lua_State *L)
{
    lua_newtable(L);
    lua_pushcfunction(L, curses_lua_boundary<l_start>);
    lua_setfield(L, -2, "start");
    lua_pushcfunction(L, curses_lua_boundary<l_stop>);
    lua_setfield(L, -2, "stop");
    lua_pushcfunction(L, curses_lua_boundary<l_clear>);
    lua_setfield(L, -2, "clear");
    lua_pushcfunction(L, curses_lua_boundary<l_refresh>);
    lua_setfield(L, -2, "refresh");
    lua_pushcfunction(L, curses_lua_boundary<l_size>);
    lua_setfield(L, -2, "size");
    lua_pushcfunction(L, curses_lua_boundary<l_move>);
    lua_setfield(L, -2, "move");
    lua_pushcfunction(L, curses_lua_boundary<l_write>);
    lua_setfield(L, -2, "write");
    lua_pushcfunction(L, curses_lua_boundary<l_read_key>);
    lua_setfield(L, -2, "readKey");
    lua_setfield(L, -2, "curses");
}

} // namespace babet_curses
