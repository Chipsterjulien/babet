#ifndef BABET_PROCESS_TERMINAL_INTERNAL_HPP
#define BABET_PROCESS_TERMINAL_INTERNAL_HPP

#include "process_common.hpp"

#include <string>

namespace babet_process::detail
{


enum class TerminalOwnerState
{
    normal,
    curses,
    child_process,
    terminal_reclaimed_curses_pending,
};

// État partagé avec le binding curses. Ces helpers ne font jamais d'appel
// ncurses : ils ne manipulent que la source de vérité POSIX du terminal.
bool begin_curses_session(int fd, pid_t parent_pgid) noexcept;
void end_curses_session() noexcept;
bool curses_session_active() noexcept;
TerminalOwnerState terminal_owner_state() noexcept;

// À appeler après def_prog_mode()+endwin(), pendant que `token` possède la
// réservation de handoff. Le commit suivant transformera la transition en
// curses -> child_process.
bool mark_curses_handoff_prepared(unsigned long token) noexcept;
// Annule une suspension préparée si le lancement échoue avant commit.
void cancel_curses_handoff_prepared(unsigned long token) noexcept;
// Une fois reset_prog_mode()/redraw effectués sur le main thread, confirme la
// transition pending -> curses.
bool complete_curses_restore() noexcept;
// Variante stop/resume d'un handle process déjà existant (pas de nouvelle
// réservation de lancement).
bool mark_curses_foreground_resume_prepared() noexcept;
void cancel_curses_foreground_resume_prepared() noexcept;

enum class TerminalReservationResult
{
    acquired,
    unavailable,
    busy,
    error,
};

TerminalReservationResult reserve_terminal_handoff(
    int fd, pid_t parent_pgid, unsigned long &token,
    struct termios &restore_attributes, bool has_launch_deadline,
    long long launch_deadline_ms) noexcept;
void cancel_terminal_reservation(unsigned long token) noexcept;
bool commit_terminal_handoff(int fd, unsigned long token, pid_t child_pgid,
                             pid_t restore_pgid,
                             const struct termios &restore_attributes) noexcept;
bool start_terminal_exit_monitor(pid_t pid, const TerminalHandoff &terminal,
                                 std::string &err);
bool duplicate_terminal_fd(int &fd) noexcept;
void delay_terminal_reservation_for_test() noexcept;

} // namespace babet_process::detail

#endif // BABET_PROCESS_TERMINAL_INTERNAL_HPP
