#include "safe_glob.hpp"

#include <algorithm>
#include <utility>

namespace babet::safe_glob
{
namespace
{

unsigned char fold_ascii(unsigned char value) noexcept
{
    if (value >= static_cast<unsigned char>('A') &&
        value <= static_cast<unsigned char>('Z'))
    {
        return static_cast<unsigned char>(value - 'A' + 'a');
    }
    return value;
}

bool literal_equal(unsigned char lhs, unsigned char rhs,
                   bool case_insensitive) noexcept
{
    if (case_insensitive)
    {
        lhs = fold_ascii(lhs);
        rhs = fold_ascii(rhs);
    }
    return lhs == rhs;
}

void epsilon_closure(const std::vector<Token> &tokens,
                     std::vector<unsigned char> &states)
{
    // A Star/GlobStar may consume zero bytes, so reachability propagates from
    // state i to i+1. One forward pass is sufficient because every epsilon
    // edge points strictly to the right.
    for (std::size_t index = 0; index < tokens.size(); ++index)
    {
        if (states[index] == 0)
        {
            continue;
        }

        if (tokens[index].kind == TokenKind::Star ||
            tokens[index].kind == TokenKind::GlobStar)
        {
            states[index + 1] = 1;
        }
    }
}

} // namespace

std::optional<std::string> compile(std::string_view source,
                                   bool case_insensitive,
                                   Pattern &out)
{
    if (source.size() > kMaxPatternBytes)
    {
        return "glob pattern exceeds " + std::to_string(kMaxPatternBytes) +
               " bytes";
    }

    Pattern compiled;
    compiled.case_insensitive_ = case_insensitive;
    compiled.tokens_.reserve(source.size());

    for (std::size_t index = 0; index < source.size(); ++index)
    {
        const unsigned char byte =
            static_cast<unsigned char>(source[index]);

        if (byte == static_cast<unsigned char>('\\'))
        {
            if (index + 1 >= source.size())
            {
                return "invalid glob pattern: trailing escape";
            }

            ++index;
            compiled.tokens_.push_back(
                {TokenKind::Literal,
                 static_cast<unsigned char>(source[index])});
            continue;
        }

        if (byte == static_cast<unsigned char>('*'))
        {
            std::size_t run_end = index;
            while (run_end + 1 < source.size() &&
                   source[run_end + 1] == '*')
            {
                ++run_end;
            }

            // One star is component-local. Two or more consecutive stars are
            // normalized to one GlobStar; this keeps the automaton compact
            // even for hostile inputs such as thousands of '*'.
            compiled.tokens_.push_back(
                {run_end == index ? TokenKind::Star : TokenKind::GlobStar,
                 0});
            index = run_end;
            continue;
        }

        if (byte == static_cast<unsigned char>('?'))
        {
            compiled.tokens_.push_back({TokenKind::AnyByte, 0});
            continue;
        }

        compiled.tokens_.push_back({TokenKind::Literal, byte});
    }

    out = std::move(compiled);
    return std::nullopt;
}

bool Pattern::matches(std::string_view text) const
{
    std::vector<unsigned char> current(tokens_.size() + 1, 0);
    std::vector<unsigned char> next(tokens_.size() + 1, 0);
    current[0] = 1;
    epsilon_closure(tokens_, current);

    for (const char raw_byte : text)
    {
        std::fill(next.begin(), next.end(), 0);
        const unsigned char byte = static_cast<unsigned char>(raw_byte);

        for (std::size_t index = 0; index < tokens_.size(); ++index)
        {
            if (current[index] == 0)
            {
                continue;
            }

            const Token &token = tokens_[index];
            switch (token.kind)
            {
            case TokenKind::Literal:
                if (literal_equal(token.literal, byte, case_insensitive_))
                {
                    next[index + 1] = 1;
                }
                break;

            case TokenKind::AnyByte:
                if (byte != static_cast<unsigned char>('/'))
                {
                    next[index + 1] = 1;
                }
                break;

            case TokenKind::Star:
                if (byte != static_cast<unsigned char>('/'))
                {
                    // Remain on the star so it may consume more bytes.
                    next[index] = 1;
                }
                break;

            case TokenKind::GlobStar:
                // Remain on the globstar so it may consume more bytes,
                // including directory separators.
                next[index] = 1;
                break;
            }
        }

        epsilon_closure(tokens_, next);
        current.swap(next);
    }

    epsilon_closure(tokens_, current);
    return current[tokens_.size()] != 0;
}

} // namespace babet::safe_glob
