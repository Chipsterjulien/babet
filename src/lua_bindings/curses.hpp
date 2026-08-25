#ifndef BABET_CURSES_HPP
#define BABET_CURSES_HPP

#include <signal.h>
#include <string>

struct lua_State;

namespace babet_curses
{

enum class HandoffPrepareResult
{
    not_active,
    suspended,
    error,
};

// Enregistre la sous-table babet.curses.
void register_curses(lua_State *L);

// État logique lisible depuis les workers sans appeler ncurses.
bool session_active() noexcept;

// Pont process/spawn. L'appel suspend ncurses uniquement sur le main thread et
// seulement après qu'une réservation terminal ait été obtenue.
HandoffPrepareResult prepare_reserved_terminal_handoff(
    unsigned long reservation_token, std::string &error);
void cancel_reserved_terminal_handoff(unsigned long reservation_token) noexcept;

// Même principe pour process:resume(true), qui réutilise un handle terminal
// existant plutôt qu'une nouvelle réservation de launch().
HandoffPrepareResult prepare_foreground_resume(std::string &error);
void cancel_foreground_resume() noexcept;

// Point central main-thread : restauration après enfant, resize, Ctrl-Z et
// terminaison contrôlée. No-op hors main thread / session inactive.
void service_terminal_events() noexcept;

// Nettoyage top-level/idempotent. Ne vole jamais un terminal encore détenu par
// un enfant interactif.
void cleanup_on_main_thread() noexcept;

// babet.signal passe toutes ses dispositions logiques ici. Quand curses est
// inactif, c'est un simple sigaction(). Quand curses est actif, SIGINT/TERM/HUP
// en mode default sont différés pour rendre le terminal sur le main thread.
// Retourne 0 ou un code errno.
int install_logical_signal_action(int signum,
                                  const struct sigaction &logical) noexcept;

} // namespace babet_curses

#endif // BABET_CURSES_HPP
