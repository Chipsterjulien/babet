#include "time_format.hpp"

#include <array>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <limits>
#include <string>

// =====================================================================
// Design notes
// ---------------------------------------------------------------------
// All clock-related conversions are done by HAND, not via strptime() /
// strftime() / std::chrono::parse. Three reasons:
//   1. strptime is a BSD-ism; its handling of fractions, "Z" and
//      "+HH:MM" varies between glibc and musl, and Windows doesn't
//      ship it at all (not relevant here but still a smell).
//   2. std::chrono::parse / std::format with chrono types require
//      recent compilers and are still partially implemented on the
//      toolchains Babet targets (RPi0 armv6l + Ubuntu LTS + Arch).
//   3. The format we accept is small enough to parse manually with
//      total control: ~150 lines, zero hidden behaviour.
//
// timegm() is widely available (glibc / musl / BSD) but isn't strict
// POSIX. We implement our own days_from_civil() based on Howard
// Hinnant's well-known integer algorithm to avoid the dependency and
// guarantee identical results on all three architectures.
// =====================================================================

namespace
{

    // -- helpers -----------------------------------------------------------

    bool is_leap(int y) noexcept
    {
        return (y % 4 == 0) && ((y % 100 != 0) || (y % 400 == 0));
    }

    int days_in_month(int y, int m) noexcept
    {
        static constexpr std::array<int, 12> d{
            31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
        if (m == 2 && is_leap(y))
            return 29;
        return d[m - 1];
    }

    // Days from civil date (y-m-d) since 1970-01-01.
    // Howard Hinnant's algorithm. Range: years roughly -2^31 .. 2^31, far
    // beyond what int64_t seconds can represent.
    int64_t days_from_civil(int y, unsigned m, unsigned d) noexcept
    {
        y -= (m <= 2);
        const int era = (y >= 0 ? y : y - 399) / 400;
        const unsigned yoe = static_cast<unsigned>(y - era * 400);
        const unsigned doy = (153u * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
        const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return static_cast<int64_t>(era) * 146097 + static_cast<int64_t>(doe) - 719468;
    }

    // Inverse: from a count of days since 1970-01-01, recover (y, m, d).
    // CORRECTIF (audit v21, adjacent au correctif de borne int64 de
    // coerce_lua_integer) : l'année sort en int64_t, plus en int. Pour un
    // timestamp extrême mais VALIDE en int64 (ex : iso(-2^63), année
    // ~ -292 milliards), l'ancien code faisait
    // `int yi = int(yoe) + int(era) * 400` : narrowing de era (int64)
    // vers int, puis `* 400` en int = débordement signé -> comportement
    // indéfini dès |era| > ~5,3e6 (soit |ts| au-delà de ~2 milliards
    // d'années). En int64 : |era| max ≈ 7,3e11, era*400 ≈ 2,9e14, aucune
    // marge de débordement. NB : days_from_civil (l'inverse) garde son
    // année en int — son seul appelant est le parseur ISO, limité à des
    // années à 4 chiffres par le format.
    void civil_from_days(int64_t z, int64_t &y, unsigned &m, unsigned &d) noexcept
    {
        z += 719468;
        const int64_t era = (z >= 0 ? z : z - 146096) / 146097;
        const unsigned doe = static_cast<unsigned>(z - era * 146097);
        const unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        const int64_t yi = static_cast<int64_t>(yoe) + era * 400;
        const unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        const unsigned mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = yi + (m <= 2);
    }

    // -- ISO 8601 ----------------------------------------------------------

    // Pragmatic ISO 8601 parser. Accepts:
    //   YYYY-MM-DD<sep>HH:MM:SS[.frac]<tz>
    // where:
    //   <sep>     = 'T' or ' '
    //   <tz>      = 'Z' | '+HH:MM' | '-HH:MM'   (no other forms; required)
    //   [.frac]   = optional, ignored entirely
    //
    // Returns true and fills `out` on success. On failure, sets `err`
    // (already prefixed with "parse_iso: ") and returns false.
    bool parse_iso_string(const std::string &s, int64_t &out, std::string &err)
    {
        // Minimum reasonable length: "1970-01-01T00:00:00Z" = 20 chars.
        if (s.size() < 19)
        {
            err = "parse_iso: invalid format";
            return false;
        }

        int year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0;

        auto get_digit = [&](size_t pos) -> int
        {
            if (pos >= s.size() || !std::isdigit(static_cast<unsigned char>(s[pos])))
                return -1;
            return s[pos] - '0';
        };

        // YYYY-MM-DD
        if (s[4] != '-' || s[7] != '-')
        {
            err = "parse_iso: invalid format";
            return false;
        }
        for (size_t i : {0u, 1u, 2u, 3u, 5u, 6u, 8u, 9u})
        {
            if (get_digit(i) < 0)
            {
                err = "parse_iso: invalid format";
                return false;
            }
        }
        year = (s[0] - '0') * 1000 + (s[1] - '0') * 100 + (s[2] - '0') * 10 + (s[3] - '0');
        month = (s[5] - '0') * 10 + (s[6] - '0');
        day = (s[8] - '0') * 10 + (s[9] - '0');

        // Separator T or space
        if (s[10] != 'T' && s[10] != ' ')
        {
            err = "parse_iso: invalid format";
            return false;
        }

        // HH:MM:SS
        if (s[13] != ':' || s[16] != ':')
        {
            err = "parse_iso: invalid format";
            return false;
        }
        for (size_t i : {11u, 12u, 14u, 15u, 17u, 18u})
        {
            if (get_digit(i) < 0)
            {
                err = "parse_iso: invalid format";
                return false;
            }
        }
        hour = (s[11] - '0') * 10 + (s[12] - '0');
        minute = (s[14] - '0') * 10 + (s[15] - '0');
        second = (s[17] - '0') * 10 + (s[18] - '0');

        // Optional fractional seconds: ".ddd..." up to the tz suffix.
        size_t pos = 19;
        if (pos < s.size() && s[pos] == '.')
        {
            pos++;
            while (pos < s.size() && std::isdigit(static_cast<unsigned char>(s[pos])))
            {
                pos++;
            }
            // Must have had at least one digit after the dot.
            if (pos == 20)
            {
                err = "parse_iso: invalid format";
                return false;
            }
        }

        // Timezone suffix - REQUIRED. Either "Z" or "+HH:MM" / "-HH:MM".
        if (pos >= s.size())
        {
            err = "parse_iso: timezone required (Z or +/-HH:MM)";
            return false;
        }

        int tz_offset_sec = 0;
        if (s[pos] == 'Z')
        {
            if (pos + 1 != s.size())
            {
                err = "parse_iso: invalid format";
                return false;
            }
        }
        else if (s[pos] == '+' || s[pos] == '-')
        {
            // Need exactly "+HH:MM" or "-HH:MM" = 6 chars from pos.
            if (s.size() - pos != 6 || s[pos + 3] != ':')
            {
                err = "parse_iso: invalid format";
                return false;
            }
            for (size_t i : {pos + 1, pos + 2, pos + 4, pos + 5})
            {
                if (get_digit(i) < 0)
                {
                    err = "parse_iso: invalid format";
                    return false;
                }
            }
            int oh = (s[pos + 1] - '0') * 10 + (s[pos + 2] - '0');
            int om = (s[pos + 4] - '0') * 10 + (s[pos + 5] - '0');
            if (oh > 23 || om > 59)
            {
                err = "parse_iso: timezone offset out of range";
                return false;
            }
            tz_offset_sec = oh * 3600 + om * 60;
            if (s[pos] == '-')
                tz_offset_sec = -tz_offset_sec;
        }
        else
        {
            err = "parse_iso: timezone required (Z or +/-HH:MM)";
            return false;
        }

        // Validate date components.
        if (year < 1 || month < 1 || month > 12 || day < 1 || day > days_in_month(year, month))
        {
            err = "parse_iso: invalid date";
            return false;
        }
        // Validate time components.
        if (hour > 23 || minute > 59 || second > 60)
        {
            // second == 60 tolerated for leap-second strings, but we still
            // produce a sensible timestamp (we treat 60 as 59 + carry; for
            // simplicity in v1 we just reject it).
            err = "parse_iso: invalid time";
            return false;
        }
        if (second == 60)
        {
            err = "parse_iso: invalid time";
            return false;
        }

        // Compute Unix timestamp.
        int64_t days = days_from_civil(year,
                                       static_cast<unsigned>(month),
                                       static_cast<unsigned>(day));
        int64_t local_seconds = days * 86400 + static_cast<int64_t>(hour) * 3600 + static_cast<int64_t>(minute) * 60 + static_cast<int64_t>(second);
        out = local_seconds - tz_offset_sec;
        return true;
    }

    // Format a Unix timestamp as "YYYY-MM-DDTHH:MM:SSZ".
    std::string format_iso_utc(int64_t ts)
    {
        // Split into days and seconds-of-day, handling negative ts.
        int64_t days = ts / 86400;
        int64_t sod = ts % 86400;
        if (sod < 0)
        {
            sod += 86400;
            days -= 1;
        }
        int64_t y;
        unsigned m, d;
        civil_from_days(days, y, m, d);
        int hh = static_cast<int>(sod / 3600);
        int mm = static_cast<int>((sod % 3600) / 60);
        int ss = static_cast<int>(sod % 60);

        // CORRECTIF (audit v21) : l'année est un int64 (cf.
        // civil_from_days). Pire cas de largeur : année -292277022657
        // (ts = -2^63) -> "-292277022657-01-27T08:29:52Z" = 29 chars +
        // NUL = 30, buf[32] suffit.
        char buf[32];
        std::snprintf(buf, sizeof(buf),
                      "%04lld-%02u-%02uT%02d:%02d:%02dZ",
                      static_cast<long long>(y), m, d, hh, mm, ss);
        return std::string(buf);
    }

    // -- Durations ---------------------------------------------------------

    // Parses "5m", "1h30m", "2d12h", "45m30s", "0s" into a non-negative
    // integer count of seconds. Strict ordering (d > h > m > s), no
    // duplicate units, no signs, no whitespace. Empty input is rejected.
    bool parse_duration_string(const std::string &s,
                               int64_t &out,
                               std::string &err)
    {
        if (s.empty())
        {
            err = "parse_duration: empty input";
            return false;
        }

        // Per-unit weights in seconds. Sentinel rank lets us enforce
        // ordering and uniqueness in one pass.
        auto unit_info = [](char c, int64_t &w, int &rank) -> bool
        {
            switch (c)
            {
            case 'd':
                w = 86400;
                rank = 4;
                return true;
            case 'h':
                w = 3600;
                rank = 3;
                return true;
            case 'm':
                w = 60;
                rank = 2;
                return true;
            case 's':
                w = 1;
                rank = 1;
                return true;
            default:
                return false;
            }
        };

        int64_t total = 0;
        int last_rank = 5;       // strictly decreasing required.
        int last_rank_seen = -1; // for the "duplicate unit" message.
        size_t i = 0;
        bool got_any_chunk = false;

        while (i < s.size())
        {
            // Number part.
            size_t num_start = i;
            while (i < s.size() && std::isdigit(static_cast<unsigned char>(s[i])))
            {
                i++;
            }
            if (i == num_start)
            {
                err = "parse_duration: invalid format";
                return false;
            }
            // CORRECTIF (revue ChatGPT post-audit v21, vérifié) :
            // contrôle de débordement CHIFFRE PAR CHIFFRE au lieu de
            // l'ancienne règle « 18 chiffres max ». Cette règle
            // protégeait en réalité l'accumulation value*10+d
            // ci-dessous (la multiplication par le poids d'unité et
            // l'addition au total ont DÉJÀ leurs propres gardes plus
            // bas), mais rejetait à tort deux familles d'entrées
            // valides : "9223372036854775807s" (19 chiffres, ==
            // INT64_MAX, durée représentable) et les zéros de tête
            // ("00000000000000000001s", 20 chiffres, valeur 1). Le
            // test `value > (kMax - digit) / 10` garantit que
            // value*10+digit ne déborde jamais, quelle que soit la
            // longueur d'écriture.
            constexpr int64_t kMaxVal = std::numeric_limits<int64_t>::max();
            int64_t value = 0;
            for (size_t k = num_start; k < i; k++)
            {
                int digit = s[k] - '0';
                if (value > (kMaxVal - digit) / 10)
                {
                    err = "parse_duration: value out of range";
                    return false;
                }
                value = value * 10 + digit;
            }

            // Unit part.
            if (i >= s.size())
            {
                err = "parse_duration: missing unit";
                return false;
            }
            int64_t weight;
            int rank;
            if (!unit_info(s[i], weight, rank))
            {
                err = "parse_duration: unknown unit";
                return false;
            }
            // Ordering and uniqueness:
            if (rank == last_rank_seen)
            {
                err = "parse_duration: duplicate unit";
                return false;
            }
            if (rank >= last_rank)
            {
                err = "parse_duration: units out of order";
                return false;
            }
            last_rank = rank;
            last_rank_seen = rank;

            // Overflow-safe accumulation.
            constexpr int64_t kMax = std::numeric_limits<int64_t>::max();
            if (value != 0 && weight > kMax / value)
            {
                err = "parse_duration: value out of range";
                return false;
            }
            int64_t chunk = value * weight;
            if (total > kMax - chunk)
            {
                err = "parse_duration: value out of range";
                return false;
            }
            total += chunk;
            got_any_chunk = true;
            i++; // skip the unit char
        }

        if (!got_any_chunk)
        {
            err = "parse_duration: empty input";
            return false;
        }
        out = total;
        return true;
    }

    std::string format_duration_string(int64_t n)
    {
        if (n == 0)
            return "0s";

        int64_t d = n / 86400;
        int64_t r = n % 86400;
        int64_t h = r / 3600;
        r = r % 3600;
        int64_t m = r / 60;
        int64_t sec = r % 60;

        std::string out;
        char buf[32];
        if (d > 0)
        {
            std::snprintf(buf, sizeof(buf), "%lldd",
                          static_cast<long long>(d));
            out += buf;
        }
        if (h > 0)
        {
            std::snprintf(buf, sizeof(buf), "%lldh",
                          static_cast<long long>(h));
            out += buf;
        }
        if (m > 0)
        {
            std::snprintf(buf, sizeof(buf), "%lldm",
                          static_cast<long long>(m));
            out += buf;
        }
        if (sec > 0)
        {
            std::snprintf(buf, sizeof(buf), "%llds",
                          static_cast<long long>(sec));
            out += buf;
        }
        return out;
    }

    // -- Number coercion (Lua) --------------------------------------------

    // Accept an integer or a non-fractional float (e.g. 3.0). Returns true
    // and fills `out` on success.
    //
    // `truncate_frac`:
    //   true  -> floor() the value (used by iso(ts) "best-effort").
    //   false -> reject any fractional value (used by format_duration).
    //
    // NaN / Inf are always rejected. Out-of-int64_t-range is always
    // rejected.
    bool coerce_lua_integer(lua_State *L, int idx,
                            bool truncate_frac,
                            int64_t &out,
                            const char *err_prefix /* funcname for luaL_error */)
    {
        if (lua_isinteger(L, idx))
        {
            out = static_cast<int64_t>(lua_tointeger(L, idx));
            return true;
        }
        if (!lua_isnumber(L, idx))
        {
            luaL_error(L, "%s: expected a number", err_prefix);
            return false; // unreachable
        }
        lua_Number f = lua_tonumber(L, idx);
        if (!std::isfinite(f))
        {
            luaL_error(L, "%s: not a finite number", err_prefix);
            return false;
        }
        lua_Number target = truncate_frac ? std::floor(f) : f;
        if (!truncate_frac && std::floor(f) != f)
        {
            luaL_error(L, "%s: not an integer", err_prefix);
            return false;
        }
        constexpr lua_Number kMaxI64 =
            static_cast<lua_Number>(std::numeric_limits<int64_t>::max());
        constexpr lua_Number kMinI64 =
            static_cast<lua_Number>(std::numeric_limits<int64_t>::min());
        // CORRECTIF (audit v21) : `>=` pour la borne max. INT64_MAX
        // (2^63-1) n'est PAS représentable en double : le cast constexpr
        // ci-dessus s'arrondit à 2^63 exactement. Avec `>`, target ==
        // 2^63 (atteignable via babet.time.iso(2^63)) passait le test,
        // puis static_cast<int64_t>(2^63) était un comportement indéfini
        // (en pratique INT64_MIN sur x86-64 -> date absurde rendue SANS
        // erreur). Avec `>=`, tout double >= 2^63 est rejeté, et tout
        // double < 2^63 est représentable en int64 (le plus grand étant
        // 2^63 - 1024). La borne min reste `<` strict : -2^63 est
        // exactement représentable en double ET valide en int64.
        // (sleep.cpp applique la même précaution sur sa borne time_t.)
        if (target >= kMaxI64 || target < kMinI64)
        {
            luaL_error(L, "%s: value out of int64 range", err_prefix);
            return false;
        }
        out = static_cast<int64_t>(target);
        return true;
    }

} // namespace

// =====================================================================
// Lua bindings
// =====================================================================

int lua_time_iso(lua_State *L)
{
    int top = lua_gettop(L);
    int64_t ts = 0;

    if (top == 0)
    {
        // No argument: use current real-time clock.
        ts = static_cast<int64_t>(std::time(nullptr));
    }
    else if (top == 1)
    {
        // truncate_frac = true: iso(0.5) -> "1970-01-01T00:00:00Z".
        if (!coerce_lua_integer(L, 1, true, ts, "iso"))
            return 0; // unreachable, coerce raised
    }
    else
    {
        return luaL_error(L, "iso: expected 0 or 1 argument");
    }

    std::string formatted = format_iso_utc(ts);
    lua_pushstring(L, formatted.c_str());
    return 1;
}

int lua_time_parse_iso(lua_State *L)
{
    if (lua_gettop(L) != 1)
    {
        return luaL_error(L, "parse_iso: expected one argument");
    }
    if (!lua_isstring(L, 1))
    {
        return luaL_error(L, "parse_iso: expected a string");
    }

    size_t len = 0;
    const char *p = lua_tolstring(L, 1, &len);
    std::string s(p, len);

    int64_t ts;
    std::string err;
    if (parse_iso_string(s, ts, err))
    {
        lua_pushinteger(L, static_cast<lua_Integer>(ts));
        lua_pushnil(L);
    }
    else
    {
        lua_pushnil(L);
        lua_pushstring(L, err.c_str());
    }
    return 2;
}

int lua_time_parse_duration(lua_State *L)
{
    if (lua_gettop(L) != 1)
    {
        return luaL_error(L, "parse_duration: expected one argument");
    }
    if (!lua_isstring(L, 1))
    {
        return luaL_error(L, "parse_duration: expected a string");
    }

    size_t len = 0;
    const char *p = lua_tolstring(L, 1, &len);
    std::string s(p, len);

    int64_t sec;
    std::string err;
    if (parse_duration_string(s, sec, err))
    {
        lua_pushinteger(L, static_cast<lua_Integer>(sec));
        lua_pushnil(L);
    }
    else
    {
        lua_pushnil(L);
        lua_pushstring(L, err.c_str());
    }
    return 2;
}

int lua_time_format_duration(lua_State *L)
{
    if (lua_gettop(L) != 1)
    {
        return luaL_error(L, "format_duration: expected one argument");
    }

    int64_t n;
    // truncate_frac = false: 3.7 is rejected, 3.0 is OK.
    if (!coerce_lua_integer(L, 1, false, n, "format_duration"))
        return 0; // unreachable

    if (n < 0)
    {
        return luaL_error(L, "format_duration: negative duration");
    }

    std::string formatted = format_duration_string(n);
    lua_pushstring(L, formatted.c_str());
    return 1;
}
