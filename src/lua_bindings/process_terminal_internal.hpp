#ifndef BABET_PROCESS_TERMINAL_INTERNAL_HPP
#define BABET_PROCESS_TERMINAL_INTERNAL_HPP

#include "process_common.hpp"

#include <string>

namespace babet_process::detail
{

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
