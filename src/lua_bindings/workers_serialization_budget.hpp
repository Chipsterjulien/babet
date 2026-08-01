#ifndef WORKERS_SERIALIZATION_BUDGET_HPP
#define WORKERS_SERIALIZATION_BUDGET_HPP

#include <cstddef>
#include <limits>

namespace babet::workers_detail
{
    constexpr std::size_t MAX_SERIALIZATION_NODES = 1'000'000;
    constexpr std::size_t MAX_SERIALIZATION_BYTES =
        64U * 1024U * 1024U;
    constexpr std::size_t SERIALIZATION_NODE_OVERHEAD = 32;
    constexpr std::size_t SERIALIZATION_STRING_MULTIPLIER = 6;
    constexpr std::size_t SERIALIZATION_STRING_QUOTES = 2;

    enum class SerializationBudgetStatus
    {
        ok,
        node_limit,
        byte_limit,
        string_too_large,
    };

    struct SerializationBudget
    {
        std::size_t nodes_left = MAX_SERIALIZATION_NODES;
        std::size_t bytes_left = MAX_SERIALIZATION_BYTES;

        constexpr SerializationBudget() = default;
        constexpr SerializationBudget(
            std::size_t nodes,
            std::size_t bytes) noexcept
            : nodes_left(nodes), bytes_left(bytes)
        {
        }
    };

    [[nodiscard]] inline SerializationBudgetStatus consume_node(
        SerializationBudget &budget) noexcept
    {
        if (budget.nodes_left == 0)
        {
            return SerializationBudgetStatus::node_limit;
        }
        if (budget.bytes_left < SERIALIZATION_NODE_OVERHEAD)
        {
            return SerializationBudgetStatus::byte_limit;
        }

        --budget.nodes_left;
        budget.bytes_left -= SERIALIZATION_NODE_OVERHEAD;
        return SerializationBudgetStatus::ok;
    }

    [[nodiscard]] inline SerializationBudgetStatus consume_string(
        SerializationBudget &budget,
        std::size_t length) noexcept
    {
        if (length >
            (std::numeric_limits<std::size_t>::max() -
             SERIALIZATION_STRING_QUOTES) /
                SERIALIZATION_STRING_MULTIPLIER)
        {
            return SerializationBudgetStatus::string_too_large;
        }

        const std::size_t cost =
            length * SERIALIZATION_STRING_MULTIPLIER +
            SERIALIZATION_STRING_QUOTES;
        if (budget.bytes_left < cost)
        {
            return SerializationBudgetStatus::byte_limit;
        }

        budget.bytes_left -= cost;
        return SerializationBudgetStatus::ok;
    }
}

#endif // WORKERS_SERIALIZATION_BUDGET_HPP
