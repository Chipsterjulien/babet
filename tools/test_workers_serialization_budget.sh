#!/bin/bash
# Test hermétique de l'arithmétique des budgets de sérialisation workers.
# Les tests d'intégration Lua vérifient le câblage sur les cinq chemins ; ce
# préflight couvre les frontières sans construire un DOM JSON d'un million
# de valeurs, trop coûteux sous ASan et sur les petites plateformes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

cat > "${TMPDIR_TEST}/test.cpp" <<'CPP'
#include "lua_bindings/workers_serialization_budget.hpp"

#include <cstddef>
#include <iostream>
#include <limits>

using babet::workers_detail::MAX_SERIALIZATION_BYTES;
using babet::workers_detail::MAX_SERIALIZATION_NODES;
using babet::workers_detail::SERIALIZATION_NODE_OVERHEAD;
using babet::workers_detail::SERIALIZATION_STRING_MULTIPLIER;
using babet::workers_detail::SERIALIZATION_STRING_QUOTES;
using babet::workers_detail::SerializationBudget;
using babet::workers_detail::SerializationBudgetStatus;
using babet::workers_detail::consume_node;
using babet::workers_detail::consume_string;

namespace
{
    int passes = 0;
    int failures = 0;

    void check(const char *name, bool condition)
    {
        if (condition)
        {
            std::cout << "[PASS] " << name << '\n';
            ++passes;
        }
        else
        {
            std::cout << "[FAIL] " << name << '\n';
            ++failures;
        }
    }
}

int main()
{
    check("public defaults are stable",
          MAX_SERIALIZATION_NODES == 1'000'000 &&
              MAX_SERIALIZATION_BYTES == 64U * 1024U * 1024U &&
              SERIALIZATION_NODE_OVERHEAD == 32 &&
              SERIALIZATION_STRING_MULTIPLIER == 6 &&
              SERIALIZATION_STRING_QUOTES == 2);

    SerializationBudget nodes{2, 3 * SERIALIZATION_NODE_OVERHEAD};
    check("first node consumes one slot and its byte overhead",
          consume_node(nodes) == SerializationBudgetStatus::ok &&
              nodes.nodes_left == 1 &&
              nodes.bytes_left == 2 * SERIALIZATION_NODE_OVERHEAD);
    check("last available node is accepted",
          consume_node(nodes) == SerializationBudgetStatus::ok &&
              nodes.nodes_left == 0 &&
              nodes.bytes_left == SERIALIZATION_NODE_OVERHEAD);
    check("one node beyond the limit is rejected without mutation",
          consume_node(nodes) == SerializationBudgetStatus::node_limit &&
              nodes.nodes_left == 0 &&
              nodes.bytes_left == SERIALIZATION_NODE_OVERHEAD);

    SerializationBudget byte_starved{2, SERIALIZATION_NODE_OVERHEAD - 1};
    check("node byte overhead is enforced independently",
          consume_node(byte_starved) ==
                  SerializationBudgetStatus::byte_limit &&
              byte_starved.nodes_left == 2 &&
              byte_starved.bytes_left == SERIALIZATION_NODE_OVERHEAD - 1);

    constexpr std::size_t length = 7;
    constexpr std::size_t string_cost =
        length * SERIALIZATION_STRING_MULTIPLIER +
        SERIALIZATION_STRING_QUOTES;
    SerializationBudget strings{1, string_cost};
    check("string at the exact byte boundary is accepted",
          consume_string(strings, length) ==
                  SerializationBudgetStatus::ok &&
              strings.bytes_left == 0);

    SerializationBudget short_by_one{1, string_cost - 1};
    check("string one byte beyond the budget is rejected atomically",
          consume_string(short_by_one, length) ==
                  SerializationBudgetStatus::byte_limit &&
              short_by_one.bytes_left == string_cost - 1);

    const std::size_t overflowing_length =
        (std::numeric_limits<std::size_t>::max() -
         SERIALIZATION_STRING_QUOTES) /
            SERIALIZATION_STRING_MULTIPLIER +
        1;
    SerializationBudget overflow;
    check("string-cost multiplication cannot overflow",
          consume_string(overflow, overflowing_length) ==
                  SerializationBudgetStatus::string_too_large &&
              overflow.bytes_left == MAX_SERIALIZATION_BYTES);

    SerializationBudget sender{4, 256};
    SerializationBudget receiver{4, 256};
    const auto sender_node = consume_node(sender);
    const auto receiver_node = consume_node(receiver);
    const auto sender_key = consume_string(sender, 5);
    const auto receiver_key = consume_string(receiver, 5);
    const auto sender_value = consume_node(sender);
    const auto receiver_value = consume_node(receiver);
    const auto sender_string = consume_string(sender, 9);
    const auto receiver_string = consume_string(receiver, 9);
    check("sender and receiver accounting stays symmetric",
          sender_node == receiver_node &&
              sender_key == receiver_key &&
              sender_value == receiver_value &&
              sender_string == receiver_string &&
              sender.nodes_left == receiver.nodes_left &&
              sender.bytes_left == receiver.bytes_left);

    std::cout << "workers serialization budget regression tests: "
              << passes << " PASS / " << failures << " FAIL\n";
    return failures == 0 ? 0 : 1;
}
CPP

"${CXX:-c++}" -std=c++23 -Wall -Wextra -Wpedantic -Werror \
    -I"${PROJECT_DIR}/src" "${TMPDIR_TEST}/test.cpp" \
    -o "${TMPDIR_TEST}/test_workers_serialization_budget"
"${TMPDIR_TEST}/test_workers_serialization_budget"
