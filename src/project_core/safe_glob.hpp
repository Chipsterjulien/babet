#ifndef BABET_SAFE_GLOB_HPP
#define BABET_SAFE_GLOB_HPP

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace babet::safe_glob
{

constexpr std::size_t kMaxPatternBytes = 4096;

enum class TokenKind
{
    Literal,
    AnyByte,
    Star,
    GlobStar,
};

struct Token
{
    TokenKind kind = TokenKind::Literal;
    unsigned char literal = 0;
};

class Pattern
{
  public:
    Pattern() = default;

    [[nodiscard]] bool matches(std::string_view text) const;
    [[nodiscard]] bool case_insensitive() const noexcept
    {
        return case_insensitive_;
    }

  private:
    friend std::optional<std::string> compile(std::string_view, bool,
                                               Pattern &);

    std::vector<Token> tokens_;
    bool case_insensitive_ = false;
};

// Compiles a deliberately small, bounded glob language:
//   *   zero or more bytes except '/'
//   **  zero or more bytes, including '/'
//   ?   exactly one byte except '/'
//   \\x  literal byte x
// Matching is anchored to the complete text and uses a dynamic-programming
// NFA simulation. Its runtime is O(pattern_bytes * text_bytes), without
// recursive backtracking.
std::optional<std::string> compile(std::string_view source,
                                   bool case_insensitive,
                                   Pattern &out);

} // namespace babet::safe_glob

#endif // BABET_SAFE_GLOB_HPP
