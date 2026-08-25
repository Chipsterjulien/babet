#include "curses.hpp"

namespace babet_curses
{

HandoffPrepareResult prepare_reserved_terminal_handoff(
    unsigned long, std::string &)
{
    return HandoffPrepareResult::not_active;
}

void cancel_reserved_terminal_handoff(unsigned long) noexcept {}

void service_terminal_events() noexcept {}

} // namespace babet_curses
