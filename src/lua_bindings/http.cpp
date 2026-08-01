// CPPHTTPLIB_OPENSSL_SUPPORT doit être défini AVANT l'include de
// httplib.h, et UNIQUEMENT dans cette unité de compilation (seule TU
// qui inclut httplib.h) : la macro reste locale, pas de define global.
// Réutilise libssl/libcrypto déjà liés (cf. CMakeLists / build_local).
#define CPPHTTPLIB_OPENSSL_SUPPORT
#include <httplib.h>

#include "http_download_file.hpp"
#include "http.hpp"
#include "lua_utils.hpp"

#include <chrono>
#include <climits>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <ctime>
#include <exception>
#include <limits>
#include <new>
#include <string>
#include <utility>
#include <vector>

namespace
{

    constexpr std::size_t DEFAULT_MAX_BODY_SIZE =
        64ull * 1024ull * 1024ull;
    constexpr lua_Integer MAX_CONFIGURABLE_BODY_SIZE =
        2ll * 1024ll * 1024ll * 1024ll;
    constexpr std::uint64_t DEFAULT_MAX_FILE_SIZE =
        8ull * 1024ull * 1024ull * 1024ull;
    constexpr std::size_t HTTPLIB_MAX_PAYLOAD_LENGTH =
        (std::numeric_limits<std::size_t>::max)();

    bool is_ascii_alpha(unsigned char c)
    {
        return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
    }

    bool is_ascii_digit(unsigned char c)
    {
        return c >= '0' && c <= '9';
    }

    bool is_ascii_alnum(unsigned char c)
    {
        return is_ascii_alpha(c) || is_ascii_digit(c);
    }

    std::string to_lower(std::string s)
    {
        for (char &c : s)
        {
            const auto uc = static_cast<unsigned char>(c);
            if (uc >= 'A' && uc <= 'Z')
            {
                c = static_cast<char>(uc - 'A' + 'a');
            }
        }
        return s;
    }

    void to_upper_ascii(std::string &s)
    {
        for (char &c : s)
        {
            const auto uc = static_cast<unsigned char>(c);
            if (uc >= 'a' && uc <= 'z')
            {
                c = static_cast<char>(uc - 'a' + 'A');
            }
        }
    }

    bool contains_cr_or_lf(const std::string &value)
    {
        return value.find('\r') != std::string::npos ||
               value.find('\n') != std::string::npos;
    }

    bool is_http_token_char(unsigned char c)
    {
        return is_ascii_alnum(c) || c == '!' || c == '#' || c == '$' ||
               c == '%' || c == '&' || c == '\'' || c == '*' || c == '+' ||
               c == '-' || c == '.' || c == '^' || c == '_' || c == '`' ||
               c == '|' || c == '~';
    }

    bool valid_header_name(const std::string &name)
    {
        if (name.empty())
        {
            return false;
        }
        for (unsigned char c : name)
        {
            if (!is_http_token_char(c))
            {
                return false;
            }
        }
        return true;
    }

    bool is_unreserved(unsigned char c)
    {
        return is_ascii_alnum(c) || c == '-' || c == '_' ||
               c == '.' || c == '~';
    }

    // Première passe de percent-encodage : seuls les "unreserved"
    // passent tels quels. cpp-httplib 0.45.0 renormalise ensuite la
    // query avant envoi (espace -> '+', '/' et '?' laissés littéraux).
    // Cette première passe protège néanmoins les délimiteurs '&'/'='
    // et les octets non ASCII avant cette normalisation.
    std::string percent_encode(const std::string &in)
    {
        static const char *hex = "0123456789ABCDEF";
        std::string out;
        out.reserve(in.size() * 3);
        for (unsigned char c : in)
        {
            if (is_unreserved(c))
            {
                out.push_back(static_cast<char>(c));
            }
            else
            {
                out.push_back('%');
                out.push_back(hex[c >> 4]);
                out.push_back(hex[c & 0x0F]);
            }
        }
        return out;
    }

    // Lit une valeur Lua (string OU number) à `idx` dans `out`.
    // Renvoie false si le type n'est ni l'un ni l'autre. Pour un
    // number, on copie d'abord (lua_pushvalue) : lua_tolstring
    // convertit en place, ce qui corromprait une clé pendant lua_next.
    bool lua_value_to_string(lua_State *L, int idx, std::string &out)
    {
        int t = lua_type(L, idx);
        if (t == LUA_TSTRING)
        {
            size_t len = 0;
            const char *s = lua_tolstring(L, idx, &len);
            out.assign(s, len);
            return true;
        }
        if (t == LUA_TNUMBER)
        {
            lua_pushvalue(L, idx);
            size_t len = 0;
            const char *s = lua_tolstring(L, -1, &len);
            out.assign(s, len);
            lua_pop(L, 1);
            return true;
        }
        return false;
    }

    struct UrlParts
    {
        std::string origin; // scheme://authority
        std::string target; // /path?query (fragment retiré)
    };

    // Découpe une URL http(s) absolue. Renvoie false + remplit `err`
    // sur URL malformée ou scheme non http(s) : condition runtime,
    // donc (nil, err), pas luaL_error.
    // Extrait le host depuis une authority (déjà sans scheme:// et
    // sans path/query/fragment). Gère IPv6 littéral entre crochets :
    //   "example.com"          -> host "example.com", port absent
    //   "example.com:8080"     -> host "example.com", port "8080"
    //   "example.com:"         -> host "example.com", port absent (vide accepté)
    //   "[::1]"                -> host "::1", port absent
    //   "[::1]:8080"           -> host "::1", port "8080"
    //   ":8080"                -> host "" (REJET attendu côté caller)
    //   "[]:8080"              -> host "" (REJET attendu côté caller)
    //   "[]"                   -> host "" (REJET attendu côté caller)
    //
    // Ne valide PAS le format du host (pas de check DNS/IP/RFC). On
    // détecte uniquement le cas "host vide", qui est le bug exact
    // qu'on visait (SU-1 : strictness minimaliste).
    std::string extract_host(const std::string &authority)
    {
        if (authority.empty())
        {
            return std::string();
        }
        if (authority.front() == '[')
        {
            // IPv6 littéral : host = entre [ et ]
            auto rb = authority.find(']');
            if (rb == std::string::npos || rb == 1)
            {
                // pas de ] fermante, ou [] (vide entre crochets)
                return std::string();
            }
            return authority.substr(1, rb - 1);
        }
        // Sinon : host = jusqu'au premier ':' ou toute l'authority.
        auto colon = authority.find(':');
        if (colon == std::string::npos)
        {
            return authority;
        }
        return authority.substr(0, colon);
    }

    bool split_url(const std::string &url, UrlParts &parts,
                   std::string &err)
    {
        auto scheme_end = url.find("://");
        if (scheme_end == std::string::npos)
        {
            err = "http: invalid url (missing scheme)";
            return false;
        }
        std::string scheme = to_lower(url.substr(0, scheme_end));
        if (scheme != "http" && scheme != "https")
        {
            err = "http: unsupported scheme '" + scheme +
                  "' (only http/https)";
            return false;
        }
        size_t authority_start = scheme_end + 3;
        size_t pos = authority_start;
        while (pos < url.size() && url[pos] != '/' &&
               url[pos] != '?' && url[pos] != '#')
        {
            ++pos;
        }
        if (pos == authority_start)
        {
            err = "http: invalid url (missing host)";
            return false;
        }

        // SU-1/SU-3 : durcir le check "host vide". Avant : seule
        // l'authority strictement vide (entre :// et /) était
        // détectée. Maintenant : on extrait le host de l'authority
        // (avec support IPv6 [::]) et on refuse si vide. Couvre :
        //   - "http://:8080/"      (port sans host)
        //   - "http://[]:8080/"    (brackets IPv6 vides)
        //   - "http://[]"          (brackets vides + pas de port)
        std::string authority = url.substr(authority_start,
                                           pos - authority_start);
        if (extract_host(authority).empty())
        {
            err = "http: invalid url (missing host)";
            return false;
        }

        parts.origin = url.substr(0, pos);

        std::string rest = url.substr(pos);
        auto frag = rest.find('#');
        if (frag != std::string::npos)
        {
            rest = rest.substr(0, frag); // jamais envoyé au serveur
        }
        if (rest.empty() || rest[0] != '/')
        {
            rest = "/" + rest;
        }
        parts.target = rest;
        return true;
    }

    // Ajoute opts.query (table à `qidx`) au target. (nil, err) si une
    // clé/valeur n'est pas string/number.
    bool append_query(lua_State *L, int qidx, std::string &target,
                      std::string &err)
    {
        qidx = lua_absindex(L, qidx);
        std::string qs;
        lua_pushnil(L);
        while (lua_next(L, qidx) != 0)
        {
            if (!lua_is_strict_string(L, -2))
            {
                lua_pop(L, 2);
                err = "http: query keys must be strings";
                return false;
            }
            size_t klen = 0;
            const char *ks = lua_tolstring(L, -2, &klen);
            std::string k(ks, klen);
            std::string v;
            if (!lua_value_to_string(L, -1, v))
            {
                lua_pop(L, 2);
                err = "http: query values must be strings or numbers";
                return false;
            }
            if (!qs.empty())
            {
                qs.push_back('&');
            }
            qs += percent_encode(k);
            qs.push_back('=');
            qs += percent_encode(v);
            lua_pop(L, 1); // garde la clé pour lua_next
        }
        if (qs.empty())
        {
            return true;
        }
        target.push_back(target.find('?') != std::string::npos ? '&' : '?');
        target += qs;
        return true;
    }

    void push_status_and_headers(lua_State *L, const httplib::Result &res)
    {
        lua_pushinteger(L, res->status);
        lua_setfield(L, -2, "status");

        // Table rétrocompatible : une chaîne par nom, dernière valeur
        // rencontrée gagnante.
        lua_newtable(L);
        int headers_idx = lua_absindex(L, -1);

        // Vue complète : chaque nom est toujours associé à un tableau,
        // même lorsqu'il n'apparaît qu'une seule fois. Cela permet de
        // traiter Set-Cookie et les autres en-têtes répétés sans changer
        // le contrat historique de `headers`.
        lua_newtable(L);
        int multi_idx = lua_absindex(L, -1);

        for (const auto &h : res->headers)
        {
            std::string key = to_lower(h.first);

            lua_pushlstring(L, h.second.data(), h.second.size());
            lua_setfield(L, headers_idx, key.c_str());

            lua_getfield(L, multi_idx, key.c_str());
            if (lua_isnil(L, -1))
            {
                lua_pop(L, 1);
                lua_newtable(L);
                lua_pushvalue(L, -1);
                lua_setfield(L, multi_idx, key.c_str());
            }
            lua_Integer next =
                static_cast<lua_Integer>(lua_rawlen(L, -1)) + 1;
            lua_pushlstring(L, h.second.data(), h.second.size());
            lua_seti(L, -2, next);
            lua_pop(L, 1);
        }

        lua_setfield(L, -3, "headers_multi");
        lua_setfield(L, -2, "headers");
    }

    // Empile (result, nil). Pile inchangée par ailleurs.
    int push_response(lua_State *L, const httplib::Result &res)
    {
        lua_newtable(L);
        push_status_and_headers(L, res);

        // Binaire-safe : le corps peut contenir des octets nuls.
        lua_pushlstring(L, res->body.data(), res->body.size());
        lua_setfield(L, -2, "body");

        lua_pushnil(L);
        return 2;
    }

    int push_download_response(lua_State *L, const httplib::Result &res,
                               const std::string &destination,
                               std::uint64_t bytes, bool saved)
    {
        lua_newtable(L);
        push_status_and_headers(L, res);

        lua_pushboolean(L, saved);
        lua_setfield(L, -2, "saved");

        lua_pushinteger(L, static_cast<lua_Integer>(bytes));
        lua_setfield(L, -2, "bytes");

        if (saved)
        {
            lua_pushlstring(L, destination.data(), destination.size());
            lua_setfield(L, -2, "path");
        }

        lua_pushnil(L);
        return 2;
    }

    // Cœur partagé. `opts_idx` = table d'options sur la pile.
    // Lorsque download_destination != nullptr, le corps est écrit dans un
    // temporaire adjacent puis remplacé atomiquement pour une réponse 2xx.
    int http_perform(lua_State *L, int opts_idx,
                     const std::string *download_destination = nullptr)
    {
        opts_idx = lua_absindex(L, opts_idx);

        // --- url (requis) ---------------------------------------------
        lua_getfield(L, opts_idx, "url");
        if (!lua_is_strict_string(L, -1))
        {
            lua_pop(L, 1);
            return push_fail(L, "http: 'url' (string) is required");
        }
        std::string url;
        std::string string_err;
        if (!lua_string_without_nul(L, -1, url, "http: url", string_err))
        {
            lua_pop(L, 1);
            return push_fail(L, string_err);
        }
        if (contains_cr_or_lf(url))
        {
            lua_pop(L, 1);
            return push_fail(L, "http: url must not contain CR or LF");
        }
        lua_pop(L, 1);

        // --- method (optionnel, défaut GET) ---------------------------
        std::string method = "GET";
        lua_getfield(L, opts_idx, "method");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_string(L, -1))
            {
                lua_pop(L, 1);
                return push_fail(L, "http: 'method' must be a string");
            }
            if (!lua_string_without_nul(L, -1, method,
                                        "http: method", string_err))
            {
                lua_pop(L, 1);
                return push_fail(L, string_err);
            }
            to_upper_ascii(method);
        }
        lua_pop(L, 1);

        // --- body (optionnel) -----------------------------------------
        std::string body;
        bool has_body = false;
        lua_getfield(L, opts_idx, "body");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_string(L, -1))
            {
                lua_pop(L, 1);
                return push_fail(L, "http: 'body' must be a string");
            }
            size_t blen = 0;
            const char *bs = lua_tolstring(L, -1, &blen);
            body.assign(bs, blen);
            has_body = true;
        }
        lua_pop(L, 1);

        // --- timeout (optionnel, secondes > 0) ------------------------
        bool has_timeout = false;
        double timeout_s = 0.0;
        lua_getfield(L, opts_idx, "timeout");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_number(L, -1))
            {
                lua_pop(L, 1);
                return push_fail(L, "http: 'timeout' must be a number");
            }
            timeout_s = lua_tonumber(L, -1);
            has_timeout = true;
        }
        lua_pop(L, 1);
        // CORRECTIF (audit v21) : rejeter NaN/±Inf et borner AVANT les
        // casts effectués plus bas (set_max_timeout : ms -> size_t ;
        // set_connection_timeout : timeout_s -> time_t). L'ancien test
        // `!(timeout_s > 0.0)` rejetait NaN par accident (toute
        // comparaison avec NaN est fausse) mais avec un message
        // trompeur, et laissait passer +Inf ainsi que des finis
        // énormes (1e300) : static_cast<size_t>(Inf) est un
        // comportement indéfini. Borne alignée sur socket.set_timeout :
        // INT_MAX ms (~24,8 jours), largement au-delà de tout usage
        // HTTP légitime, et sans risque pour les deux casts
        // (INT_MAX ms ≈ 2,1e6 s). NB : timeout_s * 1000.0 peut
        // déborder en +Inf pour timeout_s proche de DBL_MAX — Inf >
        // INT_MAX reste vrai, le rejet tient. INT_MAX est exactement
        // représentable en double (< 2^53), le `>` strict est correct
        // ici, contrairement au cas int64 de time_format.
        if (has_timeout)
        {
            if (!std::isfinite(timeout_s))
            {
                return push_fail(
                    L, "http: timeout must be finite (not NaN or inf)");
            }
            if (!(timeout_s > 0.0))
            {
                return push_fail(L, "http: timeout must be > 0");
            }
            if (timeout_s * 1000.0 > static_cast<double>(INT_MAX))
            {
                return push_fail(L, "http: timeout too large");
            }
        }

        // --- verify (optionnel, défaut true) --------------------------
        bool verify = true;
        lua_getfield(L, opts_idx, "verify");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
            {
                lua_pop(L, 1);
                return push_fail(L, "http: 'verify' must be a boolean");
            }
            verify = lua_toboolean(L, -1) != 0;
        }
        lua_pop(L, 1);

        // --- ca_cert (optionnel) --------------------------------------
        std::string ca_cert;
        bool has_ca = false;
        lua_getfield(L, opts_idx, "ca_cert");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_string(L, -1))
            {
                lua_pop(L, 1);
                return push_fail(L, "http: 'ca_cert' must be a string");
            }
            if (!lua_string_without_nul(L, -1, ca_cert,
                                        "http: ca_cert", string_err))
            {
                lua_pop(L, 1);
                return push_fail(L, string_err);
            }
            has_ca = true;
        }
        lua_pop(L, 1);

        // --- follow_redirects (optionnel, défaut false) ---------------
        bool follow = false;
        lua_getfield(L, opts_idx, "follow_redirects");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
            {
                lua_pop(L, 1);
                return push_fail(
                    L, "http: 'follow_redirects' must be a boolean");
            }
            follow = lua_toboolean(L, -1) != 0;
        }
        lua_pop(L, 1);

        // --- limite de réponse -----------------------------------------
        // request/get/post gardent leur corps en mémoire et utilisent
        // max_body_size (64 Mio par défaut, 2 Gio maximum).
        // download écrit en streaming et utilise max_file_size (8 Gio par
        // défaut, configurable jusqu'à math.maxinteger).
        std::size_t max_body_size = DEFAULT_MAX_BODY_SIZE;
        std::uint64_t max_file_size = DEFAULT_MAX_FILE_SIZE;
        const char *limit_field = download_destination != nullptr
                                      ? "max_file_size"
                                      : "max_body_size";
        lua_getfield(L, opts_idx, limit_field);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_integer(L, -1))
            {
                lua_pop(L, 1);
                return push_fail(L, std::string("http: '") + limit_field +
                                        "' must be an integer");
            }
            lua_Integer raw_limit = lua_tointeger(L, -1);
            if (raw_limit <= 0)
            {
                lua_pop(L, 1);
                return push_fail(L, std::string("http: '") + limit_field +
                                        "' must be > 0");
            }
            if (download_destination == nullptr &&
                raw_limit > MAX_CONFIGURABLE_BODY_SIZE)
            {
                lua_pop(L, 1);
                return push_fail(
                    L, "http: 'max_body_size' too large (maximum is 2 GiB)");
            }
            if (download_destination != nullptr)
            {
                max_file_size = static_cast<std::uint64_t>(raw_limit);
            }
            else
            {
                max_body_size = static_cast<std::size_t>(raw_limit);
            }
        }
        lua_pop(L, 1);

        // --- headers (table optionnelle) ------------------------------
        // Content-Type est extrait pour les méthodes à corps : il est
        // passé via l'argument content_type dédié de httplib (évite un
        // header dupliqué). Pour les méthodes sans corps, tous les
        // headers passent tels quels.
        std::vector<std::pair<std::string, std::string>> hdrs;
        std::string content_type;
        bool has_ct = false;
        lua_getfield(L, opts_idx, "headers");
        if (!lua_isnil(L, -1))
        {
            if (lua_type(L, -1) != LUA_TTABLE)
            {
                lua_pop(L, 1);
                return push_fail(L, "http: 'headers' must be a table");
            }
            int hidx = lua_absindex(L, -1);
            lua_pushnil(L);
            while (lua_next(L, hidx) != 0)
            {
                if (!lua_is_strict_string(L, -2))
                {
                    lua_pop(L, 2);
                    return push_fail(L, "http: header names must be strings");
                }
                std::string hk;
                if (!lua_string_without_nul(L, -2, hk,
                                            "http: header name", string_err))
                {
                    lua_pop(L, 2);
                    return push_fail(L, string_err);
                }
                if (!valid_header_name(hk))
                {
                    lua_pop(L, 2);
                    return push_fail(
                        L, "http: invalid header name");
                }
                std::string hv;
                if (!lua_value_to_string(L, -1, hv))
                {
                    lua_pop(L, 2);
                    return push_fail(
                        L, "http: header values must be strings or numbers");
                }
                if (hv.find('\0') != std::string::npos)
                {
                    lua_pop(L, 2);
                    return push_fail(
                        L, "http: header value must not contain NUL byte");
                }
                if (contains_cr_or_lf(hv))
                {
                    lua_pop(L, 2);
                    return push_fail(
                        L, "http: header value must not contain CR or LF");
                }
                bool is_body_method =
                    (method == "POST" || method == "PUT" ||
                     method == "PATCH" || method == "DELETE");
                if (is_body_method && to_lower(hk) == "content-type")
                {
                    content_type = hv;
                    has_ct = true;
                }
                else
                {
                    hdrs.emplace_back(hk, hv);
                }
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);

        // --- url + query ----------------------------------------------
        UrlParts parts;
        std::string err;
        if (!split_url(url, parts, err))
        {
            return push_fail(L, err);
        }
        lua_getfield(L, opts_idx, "query");
        if (!lua_isnil(L, -1))
        {
            if (lua_type(L, -1) != LUA_TTABLE)
            {
                lua_pop(L, 1);
                return push_fail(L, "http: 'query' must be a table");
            }
            if (!append_query(L, -1, parts.target, err))
            {
                lua_pop(L, 1);
                return push_fail(L, err);
            }
        }
        lua_pop(L, 1);

        // --- méthode autorisée ? --------------------------------------
        if (method != "GET" && method != "HEAD" && method != "OPTIONS" &&
            method != "POST" && method != "PUT" && method != "PATCH" &&
            method != "DELETE")
        {
            return push_fail(L, "http: unsupported method '" + method + "'");
        }

        // Pas de comportement muet : un body sur une méthode sans
        // corps est signalé, pas silencieusement ignoré.
        if (has_body &&
            (method == "GET" || method == "HEAD" || method == "OPTIONS"))
        {
            return push_fail(L,
                             "http: body not allowed for " + method);
        }

        // --- exécution -------------------------------------------------
        // try/catch : aucune exception C++ ne doit traverser vers Lua
        // (invariant de correction). Le ctor Client peut lever, les
        // appels réseau aussi selon les cas.
        try
        {
            HttpDownloadFile download_file;
            if (download_destination != nullptr)
            {
                std::string open_error;
                if (!download_file.open(*download_destination, max_file_size,
                                        open_error))
                {
                    return push_fail(L, open_error);
                }
            }

            httplib::Client cli(parts.origin);
            cli.set_follow_location(follow);
            cli.enable_server_certificate_verification(verify);

            // La limite du corps est appliquée par Babet via un
            // ContentReceiver ci-dessous. cpp-httplib 0.45.0 ne traite
            // PAS 0 comme « illimité » ici : sur une réponse HTTP
            // chunked non vide, set_payload_max_length(0) fait échouer
            // la lecture avec Error::Read (« Failed to read connection »).
            // Le même piège touche les réponses sans Content-Length,
            // dont le corps est délimité par la fermeture de connexion.
            //
            // On neutralise donc sa borne interne de 100 Mio avec la
            // plus grande valeur représentable. Le receiver de Babet
            // reste l'unique autorité pour max_body_size/max_file_size :
            // il conserve le diagnostic précis, ne publie jamais de
            // corps partiel et permet les limites documentées > 100 Mio.
            cli.set_payload_max_length(HTTPLIB_MAX_PAYLOAD_LENGTH);
            if (has_ca)
            {
                cli.set_ca_cert_path(ca_cert);
            }
            if (has_timeout)
            {
                // Timeout GLOBAL de bout en bout, équivalent --max-time
                // de curl (cpp-httplib v0.45.0+).
                double ms = timeout_s * 1000.0;
                size_t ms_int = (ms < 1.0) ? 1 : static_cast<size_t>(ms);
                cli.set_max_timeout(ms_int);

                // CORRECTIF (diagnostic terrain Ubuntu) : set_max_timeout
                // couvre les phases applicatives de cpp-httplib (envoi
                // requête, réception réponse) mais PAS toujours la phase
                // connect() qui peut bloquer dans le noyau bien plus
                // longtemps. Cas reproduit : http://[::1]:1/ sur Ubuntu
                // avec IPv6 loopback partiellement configuré -> connect()
                // bloque ~60s+ malgré set_max_timeout(1s).
                //
                // Solution belt+suspenders : poser AUSSI un connection
                // timeout dédié. cpp-httplib v0.45.0 expose
                // set_connection_timeout(seconds, microseconds).
                // En cumulé : la première limite atteinte gagne.
                time_t conn_s = static_cast<time_t>(timeout_s);
                time_t conn_us =
                    static_cast<time_t>((timeout_s - conn_s) * 1e6);
                // Plancher 1 ms : si timeout_s < 0.001, conn_s et
                // conn_us seraient tous deux à 0 -> connection_timeout
                // de 0 = pas de timeout, on évite ce piège.
                if (conn_s == 0 && conn_us < 1000)
                {
                    conn_us = 1000;
                }
                cli.set_connection_timeout(conn_s, conn_us);
            }

            httplib::Headers headers;
            for (const auto &kv : hdrs)
            {
                headers.emplace(kv.first, kv.second);
            }

            if (has_body && !has_ct)
            {
                content_type = "application/octet-stream";
            }

            // Utiliser Request + ContentReceiver donne à Babet une
            // détection non ambiguë du dépassement, indépendamment de la
            // manière dont cpp-httplib traduit l'annulation interne.
            // Le buffer reste local : si la limite est dépassée, aucun
            // corps partiel n'est jamais exposé à Lua.
            std::string response_body;
            bool body_too_large = false;

            httplib::Request request;
            request.method = method;
            request.path = parts.target;
            request.headers = headers;

            // L'overload générique Client::send(Request) de
            // cpp-httplib 0.45.0 n'initialise pas start_time_ lui-même.
            // Sans cette affectation, set_max_timeout() reste inopérant
            // pour les requêtes construites manuellement ici.
            if (has_timeout)
            {
                request.start_time_ = std::chrono::steady_clock::now();
            }

            if (has_body)
            {
                request.body = body;
            }
            // Préserve aussi un Content-Type fourni explicitement sur
            // une méthode à corps même si le corps est vide, comme les
            // anciens overloads Post/Put/Patch/Delete de cpp-httplib.
            if (!content_type.empty())
            {
                request.set_header("Content-Type", content_type);
            }

            if (download_destination != nullptr)
            {
                request.content_receiver =
                    [&](const char *data, std::size_t data_length,
                        std::size_t /*offset*/,
                        std::size_t /*total_length*/) -> bool
                    {
                        return download_file.write(data, data_length);
                    };
            }
            else
            {
                request.content_receiver =
                    [&](const char *data, std::size_t data_length,
                        std::size_t /*offset*/,
                        std::size_t /*total_length*/) -> bool
                    {
                        // Forme soustractive : aucune addition ne peut
                        // déborder avant le contrôle.
                        if (response_body.size() > max_body_size ||
                            data_length >
                                max_body_size - response_body.size())
                        {
                            body_too_large = true;
                            return false;
                        }
                        response_body.append(data, data_length);
                        return true;
                    };
            }

            httplib::Result res = cli.send(request);
            if (!res)
            {
                if (download_destination != nullptr)
                {
                    std::string download_error;
                    if (download_file.limit_exceeded())
                    {
                        download_error =
                            "http: response body exceeds max_file_size";
                    }
                    else if (!download_file.write_error().empty())
                    {
                        download_error = download_file.write_error();
                    }
                    download_file.discard();
                    if (!download_error.empty())
                    {
                        return push_fail(L, download_error);
                    }
                }
                if (body_too_large)
                {
                    return push_fail(
                        L, "http: response body exceeds max_body_size");
                }
                return push_fail(L, std::string("http: ") +
                                        httplib::to_string(res.error()));
            }

            if (download_destination != nullptr)
            {
                const bool save = res->status >= 200 && res->status < 300;
                const std::uint64_t downloaded_bytes =
                    download_file.bytes_written();
                if (save)
                {
                    std::string commit_error;
                    if (!download_file.commit(commit_error))
                    {
                        download_file.discard();
                        return push_fail(L, commit_error);
                    }
                }
                else
                {
                    download_file.discard();
                }
                return push_download_response(
                    L, res, *download_destination, downloaded_bytes, save);
            }

            // Avec un ContentReceiver, cpp-httplib ne remplit pas
            // res->body : transférer explicitement le buffer validé.
            res->body = std::move(response_body);
            return push_response(L, res);
        }
        catch (const std::bad_alloc &)
        {
            return push_fail(L, "http: out of memory");
        }
        catch (const std::exception &)
        {
            return push_fail(L, "http: internal failure");
        }
        catch (...)
        {
            return push_fail(L, "http: unknown error");
        }
    }

    // Copie superficielle d'une table source (index `src`) dans la
    // table au sommet de la pile (`dst` absolu). Utilisé par get/post
    // pour fusionner les opts fournies.
    void shallow_merge(lua_State *L, int src, int dst)
    {
        src = lua_absindex(L, src);
        lua_pushnil(L);
        while (lua_next(L, src) != 0)
        {
            lua_pushvalue(L, -2); // copie de la clé
            lua_insert(L, -2);    // ... clé, clécopie, valeur
            lua_settable(L, dst); // dst[clécopie] = valeur
        }
    }

} // namespace

int lua_http_request(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    return http_perform(L, 1);
}

int lua_http_get(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TSTRING);

    lua_newtable(L);
    int dst = lua_gettop(L);
    if (!lua_is_none_or_nil(L, 2))
    {
        luaL_checktype(L, 2, LUA_TTABLE);
        shallow_merge(L, 2, dst);
    }
    lua_pushvalue(L, 1);
    lua_setfield(L, dst, "url");
    lua_pushstring(L, "GET");
    lua_setfield(L, dst, "method");
    return http_perform(L, dst);
}

int lua_http_post(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TSTRING);

    int body_type = lua_type(L, 2);
    int opts_arg = 3;
    bool have_body = false;
    if (body_type == LUA_TSTRING)
    {
        have_body = true;
    }
    else if (body_type == LUA_TTABLE)
    {
        // forme post(url, opts) : 2e arg = opts, pas de corps
        opts_arg = 2;
    }
    else if (body_type != LUA_TNONE && body_type != LUA_TNIL)
    {
        return luaL_error(L, "http: post body must be a string");
    }

    lua_newtable(L);
    int dst = lua_gettop(L);
    if (!lua_is_none_or_nil(L, opts_arg))
    {
        luaL_checktype(L, opts_arg, LUA_TTABLE);
        shallow_merge(L, opts_arg, dst);
    }
    lua_pushvalue(L, 1);
    lua_setfield(L, dst, "url");
    lua_pushstring(L, "POST");
    lua_setfield(L, dst, "method");
    if (have_body)
    {
        size_t blen = 0;
        const char *bs = lua_tolstring(L, 2, &blen);
        lua_pushlstring(L, bs, blen);
        lua_setfield(L, dst, "body");
    }
    return http_perform(L, dst);
}

int lua_http_download(lua_State *L)
{
    const int argc = lua_gettop(L);
    luaL_argcheck(L, argc == 2 || argc == 3, 1,
                  "Expected two or three arguments");
    luaL_checktype(L, 1, LUA_TSTRING);
    luaL_checktype(L, 2, LUA_TSTRING);
    if (argc == 3)
    {
        luaL_checktype(L, 3, LUA_TTABLE);
    }

    const std::string_view url_view =
        luaL_checkstring_view_without_nul(L, 1, "url");
    const std::string_view destination_view =
        luaL_checkstring_view_without_nul(L, 2, "destination");
    const std::string destination(destination_view);

    lua_newtable(L);
    const int dst = lua_gettop(L);
    if (argc == 3)
    {
        shallow_merge(L, 3, dst);
    }

    lua_pushlstring(L, url_view.data(), url_view.size());
    lua_setfield(L, dst, "url");
    lua_pushstring(L, "GET");
    lua_setfield(L, dst, "method");

    return http_perform(L, dst, &destination);
}

void register_http(lua_State *L)
{
    // Précondition : table babet au sommet (-1), comme register_json.
    lua_newtable(L);

    lua_pushcfunction(L, lua_http_request);
    lua_setfield(L, -2, "request");

    lua_pushcfunction(L, lua_http_get);
    lua_setfield(L, -2, "get");

    lua_pushcfunction(L, lua_http_post);
    lua_setfield(L, -2, "post");

    lua_pushcfunction(L, lua_http_download);
    lua_setfield(L, -2, "download");

    lua_setfield(L, -2, "http");
}
