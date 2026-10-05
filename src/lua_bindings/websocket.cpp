#include "sigpipe_guard.hpp"
#include "websocket.hpp"
#include "lua_utils.hpp"
#include "signal.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <limits>
#include <new>
#include <stdexcept>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

namespace
{
constexpr const char *WS_META = "BabetWebSocket";
constexpr std::size_t DEFAULT_MAX_MESSAGE_BYTES = 16ULL * 1024ULL * 1024ULL;
constexpr std::size_t DEFAULT_MAX_FRAME_BYTES = 16ULL * 1024ULL * 1024ULL;
constexpr std::size_t MAX_CONFIGURED_BYTES = 2ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr std::size_t HANDSHAKE_HEADER_LIMIT = 64ULL * 1024ULL;
constexpr std::size_t SEND_FRAGMENT_BYTES = 64ULL * 1024ULL;
constexpr std::string_view WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

using Clock = std::chrono::steady_clock;
using Deadline = Clock::time_point;
constexpr Deadline NO_DEADLINE = Deadline::max();
constexpr int WAIT_INTERRUPTED = -2;

enum class Scheme : unsigned char
{
    Ws,
    Wss,
};

struct ParsedUrl
{
    Scheme scheme = Scheme::Ws;
    std::string host;
    std::string connect_host;
    std::string host_header;
    std::string target;
    std::string port;
};

struct WebSocket
{
    int fd = -1;
    SSL_CTX *ssl_ctx = nullptr;
    SSL *ssl = nullptr;
    int timeout_ms = 0;
    std::size_t max_message_bytes = DEFAULT_MAX_MESSAGE_BYTES;
    std::size_t max_frame_bytes = DEFAULT_MAX_FRAME_BYTES;
    bool sent_close = false;
    bool received_close = false;
    bool closed = false;
    std::string recv_pending;

    // Message receive state must survive recv() timeouts.  A timeout can occur
    // after one or more complete fragments have already been consumed.
    bool recv_fragmented = false;
    std::uint8_t recv_message_opcode = 0;
    std::string recv_message_data;
};

struct WebSocketUserdata
{
    bool constructed;
    alignas(WebSocket) std::byte storage[sizeof(WebSocket)];

    WebSocket *get() noexcept
    {
        return std::launder(reinterpret_cast<WebSocket *>(storage));
    }
};

struct ConnectOptions
{
    bool verify = true;
    std::string ca_cert;
    std::string ca_path;
    std::string hostname;
    std::string min_version;
    int timeout_ms = 0;
    std::size_t max_message_bytes = DEFAULT_MAX_MESSAGE_BYTES;
    std::size_t max_frame_bytes = DEFAULT_MAX_FRAME_BYTES;
};

struct Frame
{
    bool fin = false;
    std::uint8_t opcode = 0;
    std::string payload;
};

WebSocket *check_ws(lua_State *L, int idx)
{
    auto *userdata = static_cast<WebSocketUserdata *>(
        luaL_checkudata(L, idx, WS_META));
    if (!userdata->constructed)
        luaL_error(L, "websocket is not initialized");
    return userdata->get();
}

template <int (*Fn)(lua_State *)>
int websocket_lua_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "websocket: out of memory", "websocket: internal C++ failure",
        "websocket: unknown internal C++ failure");
}

Deadline make_deadline(int timeout_ms)
{
    if (timeout_ms <= 0)
        return NO_DEADLINE;
    return Clock::now() + std::chrono::milliseconds(timeout_ms);
}

int remaining_ms(Deadline deadline)
{
    if (deadline == NO_DEADLINE)
        return -1;
    const auto now = Clock::now();
    if (now >= deadline)
        return 0;
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - now);
    if (remaining.count() <= 0)
        return 1;
    return static_cast<int>(std::min<long long>(remaining.count(), INT_MAX));
}

int wait_ready(int fd, short events, Deadline deadline)
{
    for (;;)
    {
        pollfd pfd{};
        pfd.fd = fd;
        pfd.events = events;
        const int rc = ::poll(&pfd, 1, remaining_ms(deadline));
        if (rc > 0)
        {
            if (pfd.revents & POLLNVAL)
            {
                errno = EBADF;
                return -1;
            }
            if (pfd.revents & (events | POLLERR | POLLHUP))
                return 1;
            continue;
        }
        if (rc == 0)
            return 0;
        if (errno == EINTR)
        {
            if (signal_any_handled_pending())
                return WAIT_INTERRUPTED;
            continue;
        }
        return -1;
    }
}

bool parse_timeout_seconds(lua_State *L, int idx, int default_ms,
                           int &out_ms, std::string &err,
                           std::string_view prefix)
{
    out_ms = default_ms;
    if (lua_is_none_or_nil(L, idx))
        return true;
    if (!lua_is_strict_number(L, idx))
    {
        err = std::string(prefix) + ": timeout must be a number";
        return false;
    }
    const lua_Number seconds = lua_tonumber(L, idx);
    if (!std::isfinite(seconds) || seconds < 0)
    {
        err = std::string(prefix) + ": timeout must be finite and >= 0";
        return false;
    }
    const long double ms = static_cast<long double>(seconds) * 1000.0L;
    if (ms > static_cast<long double>(INT_MAX))
    {
        err = std::string(prefix) + ": timeout too large";
        return false;
    }
    out_ms = static_cast<int>(std::ceil(ms));
    return true;
}

bool parse_size_value(lua_State *L, int value_idx, const char *field,
                      std::size_t &value, std::string &err)
{
    if (!lua_is_strict_integer(L, value_idx))
    {
        err = "websocket: opts.";
        err += field;
        err += " must be an integer";
        return false;
    }
    const lua_Integer n = lua_tointeger(L, value_idx);
    if (n <= 0 || static_cast<unsigned long long>(n) > MAX_CONFIGURED_BYTES)
    {
        err = "websocket: opts.";
        err += field;
        err += " must be in [1, 2147483648]";
        return false;
    }
    value = static_cast<std::size_t>(n);
    return true;
}

bool parse_connect_options(lua_State *L, int idx, ConnectOptions &opts,
                           std::string &err)
{
    if (lua_is_none_or_nil(L, idx))
        return true;
    if (lua_type(L, idx) != LUA_TTABLE)
    {
        err = "websocket: opts must be a table";
        return false;
    }

    idx = lua_absindex(L, idx);
    lua_pushnil(L);
    while (lua_next(L, idx) != 0)
    {
        if (lua_type(L, -2) != LUA_TSTRING)
        {
            lua_pop(L, 2);
            err = "websocket: option names must be strings";
            return false;
        }
        std::size_t key_length = 0;
        const char *key_data = lua_tolstring(L, -2, &key_length);
        std::string key(key_data, key_length);
        if (key.find('\0') != std::string::npos)
        {
            lua_pop(L, 2);
            err = "websocket: option name contains NUL byte";
            return false;
        }

        if (key == "verify")
        {
            if (!lua_is_strict_boolean(L, -1))
            {
                lua_pop(L, 2);
                err = "websocket: opts.verify must be a boolean";
                return false;
            }
            opts.verify = lua_toboolean(L, -1) != 0;
        }
        else if (key == "timeout")
        {
            if (!parse_timeout_seconds(L, -1, 0, opts.timeout_ms, err,
                                       "websocket: opts"))
            {
                lua_pop(L, 2);
                return false;
            }
        }
        else if (key == "ca_cert" || key == "ca_path" ||
                 key == "hostname" || key == "min_version")
        {
            if (!lua_is_strict_string(L, -1))
            {
                lua_pop(L, 2);
                err = "websocket: opts." + key + " must be a string";
                return false;
            }
            std::string *target = nullptr;
            if (key == "ca_cert")
                target = &opts.ca_cert;
            else if (key == "ca_path")
                target = &opts.ca_path;
            else if (key == "hostname")
                target = &opts.hostname;
            else
                target = &opts.min_version;
            const std::string label = "websocket: opts." + key;
            if (!lua_string_without_nul(L, -1, *target, label, err))
            {
                lua_pop(L, 2);
                return false;
            }
        }
        else if (key == "max_message_bytes")
        {
            if (!parse_size_value(L, -1, "max_message_bytes",
                                  opts.max_message_bytes, err))
            {
                lua_pop(L, 2);
                return false;
            }
        }
        else if (key == "max_frame_bytes")
        {
            if (!parse_size_value(L, -1, "max_frame_bytes",
                                  opts.max_frame_bytes, err))
            {
                lua_pop(L, 2);
                return false;
            }
        }
        else
        {
            lua_pop(L, 2);
            err = "websocket: unknown option '" + key + "'";
            return false;
        }
        lua_pop(L, 1);
    }

    if (opts.max_frame_bytes > opts.max_message_bytes)
    {
        err = "websocket: opts.max_frame_bytes must be <= max_message_bytes";
        return false;
    }
    if (!opts.min_version.empty() && opts.min_version != "1.2" &&
        opts.min_version != "1.3")
    {
        err = "websocket: opts.min_version must be \"1.2\" or \"1.3\"";
        return false;
    }
    return true;
}

bool is_ip_literal(const std::string &host)
{
    in_addr v4{};
    in6_addr v6{};
    return ::inet_pton(AF_INET, host.c_str(), &v4) == 1 ||
           ::inet_pton(AF_INET6, host.c_str(), &v6) == 1;
}

bool parse_url(std::string_view url, ParsedUrl &out, std::string &err)
{
    const auto starts_with_ascii_ci = [url](std::string_view prefix) noexcept
    {
        if (url.size() < prefix.size())
            return false;
        for (std::size_t i = 0; i < prefix.size(); ++i)
        {
            unsigned char a = static_cast<unsigned char>(url[i]);
            unsigned char b = static_cast<unsigned char>(prefix[i]);
            if (a >= 'A' && a <= 'Z')
                a = static_cast<unsigned char>(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z')
                b = static_cast<unsigned char>(b - 'A' + 'a');
            if (a != b)
                return false;
        }
        return true;
    };

    std::size_t scheme_len = 0;
    if (starts_with_ascii_ci("ws://"))
    {
        out.scheme = Scheme::Ws;
        out.port = "80";
        scheme_len = 5;
    }
    else if (starts_with_ascii_ci("wss://"))
    {
        out.scheme = Scheme::Wss;
        out.port = "443";
        scheme_len = 6;
    }
    else
    {
        err = "websocket: URL scheme must be ws:// or wss://";
        return false;
    }

    std::string_view rest = url.substr(scheme_len);
    if (rest.empty())
    {
        err = "websocket: URL host must not be empty";
        return false;
    }
    const std::size_t fragment = rest.find('#');
    if (fragment != std::string_view::npos)
    {
        err = "websocket: URL fragments are not allowed";
        return false;
    }
    const std::size_t path_pos = rest.find_first_of("/?");
    std::string_view authority = path_pos == std::string_view::npos
                                     ? rest
                                     : rest.substr(0, path_pos);
    std::string_view tail = path_pos == std::string_view::npos
                                ? std::string_view{}
                                : rest.substr(path_pos);
    if (authority.empty() || authority.find('@') != std::string_view::npos)
    {
        err = authority.empty() ? "websocket: URL host must not be empty"
                                : "websocket: URL userinfo is not supported";
        return false;
    }
    for (unsigned char c : authority)
    {
        if (c <= 0x20 || c == 0x7f)
        {
            err = "websocket: URL authority contains an unescaped control or space";
            return false;
        }
    }

    bool explicit_port = false;
    bool ipv6 = false;
    if (authority.front() == '[')
    {
        ipv6 = true;
        const std::size_t close = authority.find(']');
        if (close == std::string_view::npos || close == 1)
        {
            err = "websocket: invalid bracketed IPv6 host";
            return false;
        }
        out.host.assign(authority.substr(1, close - 1));
        out.connect_host = out.host;
        const std::string_view suffix = authority.substr(close + 1);
        if (!suffix.empty())
        {
            if (suffix.front() != ':' || suffix.size() == 1)
            {
                err = "websocket: invalid URL authority";
                return false;
            }
            out.port.assign(suffix.substr(1));
            explicit_port = true;
        }
    }
    else
    {
        const std::size_t colon = authority.rfind(':');
        if (colon != std::string_view::npos)
        {
            if (authority.find(':') != colon)
            {
                err = "websocket: IPv6 literals must use [brackets]";
                return false;
            }
            out.host.assign(authority.substr(0, colon));
            out.connect_host = out.host;
            out.port.assign(authority.substr(colon + 1));
            explicit_port = true;
        }
        else
        {
            out.host.assign(authority);
            out.connect_host = out.host;
        }
    }
    if (out.host.empty() || out.port.empty())
    {
        err = "websocket: URL host and port must not be empty";
        return false;
    }
    for (char c : out.port)
    {
        if (c < '0' || c > '9')
        {
            err = "websocket: URL port must be numeric";
            return false;
        }
    }
    const unsigned long port_num = std::strtoul(out.port.c_str(), nullptr, 10);
    if (port_num == 0 || port_num > 65535)
    {
        err = "websocket: URL port must be in [1, 65535]";
        return false;
    }

    const bool default_port = (out.scheme == Scheme::Ws && port_num == 80) ||
                              (out.scheme == Scheme::Wss && port_num == 443);
    out.host_header = ipv6 ? ("[" + out.host + "]") : out.host;
    if (explicit_port || !default_port)
    {
        out.host_header += ":";
        out.host_header += out.port;
    }

    if (tail.empty())
        out.target = "/";
    else if (tail.front() == '?')
        out.target = "/" + std::string(tail);
    else
        out.target.assign(tail);

    for (unsigned char c : out.target)
    {
        if (c <= 0x20 || c == 0x7f)
        {
            err = "websocket: URL path/query contains an unescaped control or space";
            return false;
        }
    }
    return true;
}

void close_transport(WebSocket *ws) noexcept
{
    if (ws->ssl != nullptr)
    {
        SSL_free(ws->ssl);
        ws->ssl = nullptr;
        ERR_clear_error();
    }
    if (ws->ssl_ctx != nullptr)
    {
        SSL_CTX_free(ws->ssl_ctx);
        ws->ssl_ctx = nullptr;
    }
    if (ws->fd >= 0)
    {
        ::close(ws->fd);
        ws->fd = -1;
    }
    ws->closed = true;
    ws->recv_pending.clear();
    ws->recv_fragmented = false;
    ws->recv_message_opcode = 0;
    ws->recv_message_data.clear();
}

// Frames and fragmented messages cannot be restarted with another buffer.
// These guards run in C++-only scopes, before any Lua signal callback/result.
class AbandonedSend
{
public:
    explicit AbandonedSend(WebSocket *ws) noexcept : ws_(ws) {}
    ~AbandonedSend() noexcept
    {
        if (started_)
            close_transport(ws_);
    }
    AbandonedSend(const AbandonedSend &) = delete;
    AbandonedSend &operator=(const AbandonedSend &) = delete;
    void start() noexcept { started_ = true; }
    void complete() noexcept { started_ = false; }

private:
    WebSocket *ws_;
    bool started_ = false;
};

WebSocket *push_empty_ws(lua_State *L)
{
    auto *userdata = static_cast<WebSocketUserdata *>(
        lua_newuserdata(L, sizeof(WebSocketUserdata)));
    userdata->constructed = false;
    luaL_getmetatable(L, WS_META);
    lua_setmetatable(L, -2);
    static_assert(std::is_nothrow_default_constructible_v<WebSocket>);
    WebSocket *ws = new (userdata->storage) WebSocket();
    userdata->constructed = true;
    return ws;
}

WebSocket *push_empty_ws_protected(lua_State *L)
{
    auto builder = [](lua_State *Ls) noexcept -> int
    {
        push_empty_ws(Ls);
        return 1;
    };
    lua_build_results_protected(L, builder, 1);
    auto *userdata = static_cast<WebSocketUserdata *>(lua_touserdata(L, -1));
    return userdata->get();
}

std::string openssl_error(std::string_view context)
{
    std::string msg = "websocket: TLS: ";
    msg.append(context);
    const unsigned long e = ERR_get_error();
    if (e != 0)
    {
        const char *reason = ERR_reason_error_string(e);
        msg += ": ";
        msg += reason ? reason : "OpenSSL error";
    }
    ERR_clear_error();
    return msg;
}

bool configure_ca(SSL_CTX *ctx, const ConnectOptions &opts, std::string &err)
{
    if (SSL_CTX_set_default_verify_paths(ctx) != 1)
        ERR_clear_error();

    struct Candidate
    {
        const char *file;
        const char *dir;
    };
    static const Candidate candidates[] = {
        {"/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/certs"},
        {"/etc/pki/tls/certs/ca-bundle.crt", "/etc/pki/tls/certs"},
        {"/etc/ssl/ca-bundle.pem", nullptr},
        {"/var/lib/ca-certificates/ca-bundle.pem", nullptr},
        {"/etc/openssl/certs/ca-certificates.crt", "/etc/openssl/certs"},
    };
    for (const auto &candidate : candidates)
    {
        const char *file = candidate.file && ::access(candidate.file, R_OK) == 0
                               ? candidate.file
                               : nullptr;
        const char *dir = nullptr;
        if (candidate.dir)
        {
            struct stat st{};
            if (::stat(candidate.dir, &st) == 0 && S_ISDIR(st.st_mode))
                dir = candidate.dir;
        }
        if ((file || dir) && SSL_CTX_load_verify_locations(ctx, file, dir) == 1)
            break;
        ERR_clear_error();
    }

    if (!opts.ca_cert.empty() || !opts.ca_path.empty())
    {
        const char *file = opts.ca_cert.empty() ? nullptr : opts.ca_cert.c_str();
        const char *dir = opts.ca_path.empty() ? nullptr : opts.ca_path.c_str();
        if (SSL_CTX_load_verify_locations(ctx, file, dir) != 1)
        {
            err = openssl_error("load_verify_locations failed");
            return false;
        }
    }
    return true;
}

bool make_nonblocking(int fd, std::string &err)
{
    const int flags = ::fcntl(fd, F_GETFL, 0);
    if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0)
    {
        err = "websocket: fcntl(O_NONBLOCK): ";
        err += std::strerror(errno);
        return false;
    }
    return true;
}

bool connect_tcp(WebSocket *ws, const ParsedUrl &url, Deadline deadline,
                 std::string &err)
{
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo *res = nullptr;
    const int gai = ::getaddrinfo(url.connect_host.c_str(), url.port.c_str(),
                                  &hints, &res);
    if (gai != 0)
    {
        err = "websocket: getaddrinfo: ";
        err += gai_strerror(gai);
        return false;
    }

    int last_error = ECONNREFUSED;
    for (addrinfo *ai = res; ai != nullptr; ai = ai->ai_next)
    {
        const int fd = ::socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC,
                                ai->ai_protocol);
        if (fd < 0)
        {
            last_error = errno;
            continue;
        }
        ws->fd = fd;
        if (!make_nonblocking(fd, err))
        {
            ::close(fd);
            ws->fd = -1;
            continue;
        }

        const int rc = ::connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0)
        {
            ::freeaddrinfo(res);
            return true;
        }
        if (errno != EINPROGRESS)
        {
            last_error = errno;
            ::close(fd);
            ws->fd = -1;
            continue;
        }

        const int ready = wait_ready(fd, POLLOUT, deadline);
        if (ready == WAIT_INTERRUPTED)
        {
            ::freeaddrinfo(res);
            err = "interrupted";
            return false;
        }
        if (ready == 0)
        {
            ::freeaddrinfo(res);
            err = "timeout";
            return false;
        }
        if (ready < 0)
        {
            last_error = errno;
            ::close(fd);
            ws->fd = -1;
            continue;
        }
        int so_error = 0;
        socklen_t so_len = sizeof(so_error);
        if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_error, &so_len) != 0)
        {
            last_error = errno;
            ::close(fd);
            ws->fd = -1;
            continue;
        }
        if (so_error == 0)
        {
            ::freeaddrinfo(res);
            return true;
        }
        last_error = so_error;
        ::close(fd);
        ws->fd = -1;
    }
    ::freeaddrinfo(res);
    err = "websocket: connect: ";
    err += std::strerror(last_error);
    return false;
}

bool setup_tls(WebSocket *ws, const ParsedUrl &url, const ConnectOptions &opts,
               Deadline deadline, std::string &err)
{
    OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS |
                         OPENSSL_INIT_LOAD_CRYPTO_STRINGS,
                     nullptr);
    ws->ssl_ctx = SSL_CTX_new(TLS_client_method());
    if (!ws->ssl_ctx)
    {
        err = openssl_error("SSL_CTX_new failed");
        return false;
    }
    const int min_version = opts.min_version == "1.3" ? TLS1_3_VERSION
                                                       : TLS1_2_VERSION;
    if (SSL_CTX_set_min_proto_version(ws->ssl_ctx, min_version) != 1)
    {
        err = openssl_error("set minimum TLS version failed");
        return false;
    }
    if (!configure_ca(ws->ssl_ctx, opts, err))
        return false;
    SSL_CTX_set_verify(ws->ssl_ctx, opts.verify ? SSL_VERIFY_PEER : SSL_VERIFY_NONE,
                       nullptr);

    ws->ssl = SSL_new(ws->ssl_ctx);
    if (!ws->ssl)
    {
        err = openssl_error("SSL_new failed");
        return false;
    }
    if (SSL_set_fd(ws->ssl, ws->fd) != 1)
    {
        err = openssl_error("SSL_set_fd failed");
        return false;
    }

    const std::string verify_host = opts.hostname.empty() ? url.host : opts.hostname;
    if (!is_ip_literal(verify_host) &&
        SSL_set_tlsext_host_name(ws->ssl, verify_host.c_str()) != 1)
    {
        err = openssl_error("setting SNI failed");
        return false;
    }
    if (opts.verify)
    {
        X509_VERIFY_PARAM *param = SSL_get0_param(ws->ssl);
        if (is_ip_literal(verify_host))
        {
            if (X509_VERIFY_PARAM_set1_ip_asc(param, verify_host.c_str()) != 1)
            {
                err = "websocket: TLS: cannot configure IP verification";
                return false;
            }
        }
        else if (SSL_set1_host(ws->ssl, verify_host.c_str()) != 1)
        {
            err = "websocket: TLS: cannot configure hostname verification";
            return false;
        }
    }

    SSL_set_connect_state(ws->ssl);
    for (;;)
    {
        ERR_clear_error();
        const int rc = babet_io::without_sigpipe([&] {
            return SSL_connect(ws->ssl);
        });
        if (rc == 1)
            break;
        const int ssl_error = SSL_get_error(ws->ssl, rc);
        short events = 0;
        if (ssl_error == SSL_ERROR_WANT_READ)
            events = POLLIN;
        else if (ssl_error == SSL_ERROR_WANT_WRITE)
            events = POLLOUT;
        else
        {
            const long verify_result = SSL_get_verify_result(ws->ssl);
            if (opts.verify && verify_result != X509_V_OK)
            {
                err = "websocket: TLS certificate verify failed: ";
                err += X509_verify_cert_error_string(verify_result);
            }
            else
                err = openssl_error("SSL_connect failed");
            return false;
        }
        const int ready = wait_ready(ws->fd, events, deadline);
        if (ready == WAIT_INTERRUPTED)
        {
            err = "interrupted";
            return false;
        }
        if (ready == 0)
        {
            err = "timeout";
            return false;
        }
        if (ready < 0)
        {
            err = "websocket: TLS poll: ";
            err += std::strerror(errno);
            return false;
        }
    }
    return true;
}

bool transport_send_all(WebSocket *ws, const char *data, std::size_t size,
                        Deadline deadline, std::string &err)
{
    std::size_t offset = 0;
    while (offset < size)
    {
        if (ws->ssl)
        {
            ERR_clear_error();
            const int chunk = static_cast<int>(std::min<std::size_t>(
                size - offset, static_cast<std::size_t>(INT_MAX)));
            const int rc = babet_io::without_sigpipe([&] {
                return SSL_write(ws->ssl, data + offset, chunk);
            });
            if (rc > 0)
            {
                offset += static_cast<std::size_t>(rc);
                continue;
            }
            const int ssl_error = SSL_get_error(ws->ssl, rc);
            short events = 0;
            if (ssl_error == SSL_ERROR_WANT_READ)
                events = POLLIN;
            else if (ssl_error == SSL_ERROR_WANT_WRITE)
                events = POLLOUT;
            else if (ssl_error == SSL_ERROR_ZERO_RETURN ||
                     (ssl_error == SSL_ERROR_SYSCALL && errno == 0))
            {
                err = "closed";
                return false;
            }
            else
            {
                err = openssl_error("SSL_write failed");
                return false;
            }
            const int ready = wait_ready(ws->fd, events, deadline);
            if (ready == WAIT_INTERRUPTED)
            {
                err = "interrupted";
                return false;
            }
            if (ready == 0)
            {
                err = "timeout";
                return false;
            }
            if (ready < 0)
            {
                err = "websocket: send poll: ";
                err += std::strerror(errno);
                return false;
            }
            continue;
        }

        const int ready = wait_ready(ws->fd, POLLOUT, deadline);
        if (ready == WAIT_INTERRUPTED)
        {
            err = "interrupted";
            return false;
        }
        if (ready == 0)
        {
            err = "timeout";
            return false;
        }
        if (ready < 0)
        {
            err = "websocket: send poll: ";
            err += std::strerror(errno);
            return false;
        }
        const ssize_t rc = ::send(ws->fd, data + offset, size - offset,
                                  MSG_NOSIGNAL | MSG_DONTWAIT);
        if (rc > 0)
        {
            offset += static_cast<std::size_t>(rc);
            continue;
        }
        if (rc < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
            continue;
        if (rc < 0 && (errno == EPIPE || errno == ECONNRESET))
            err = "closed";
        else
        {
            err = "websocket: send: ";
            err += std::strerror(errno);
        }
        return false;
    }
    return true;
}

bool transport_recv_some(WebSocket *ws, char *buffer, std::size_t capacity,
                         Deadline deadline, std::size_t &received,
                         std::string &err)
{
    received = 0;
    for (;;)
    {
        if (ws->ssl)
        {
            if (SSL_pending(ws->ssl) == 0)
            {
                const int ready = wait_ready(ws->fd, POLLIN, deadline);
                if (ready == WAIT_INTERRUPTED)
                {
                    err = "interrupted";
                    return false;
                }
                if (ready == 0)
                {
                    err = "timeout";
                    return false;
                }
                if (ready < 0)
                {
                    err = "websocket: recv poll: ";
                    err += std::strerror(errno);
                    return false;
                }
            }
            ERR_clear_error();
            const int cap = static_cast<int>(std::min<std::size_t>(
                capacity, static_cast<std::size_t>(INT_MAX)));
            const int rc = babet_io::without_sigpipe([&] {
                return SSL_read(ws->ssl, buffer, cap);
            });
            if (rc > 0)
            {
                received = static_cast<std::size_t>(rc);
                return true;
            }
            const int ssl_error = SSL_get_error(ws->ssl, rc);
            if (ssl_error == SSL_ERROR_WANT_READ)
                continue;
            if (ssl_error == SSL_ERROR_WANT_WRITE)
            {
                const int ready = wait_ready(ws->fd, POLLOUT, deadline);
                if (ready == WAIT_INTERRUPTED)
                    err = "interrupted";
                else if (ready == 0)
                    err = "timeout";
                else if (ready < 0)
                {
                    err = "websocket: recv poll: ";
                    err += std::strerror(errno);
                }
                if (ready <= 0)
                    return false;
                continue;
            }
            if (ssl_error == SSL_ERROR_ZERO_RETURN ||
                (ssl_error == SSL_ERROR_SYSCALL && errno == 0))
                err = "closed";
            else
                err = openssl_error("SSL_read failed");
            return false;
        }

        const int ready = wait_ready(ws->fd, POLLIN, deadline);
        if (ready == WAIT_INTERRUPTED)
        {
            err = "interrupted";
            return false;
        }
        if (ready == 0)
        {
            err = "timeout";
            return false;
        }
        if (ready < 0)
        {
            err = "websocket: recv poll: ";
            err += std::strerror(errno);
            return false;
        }
        const ssize_t rc = ::recv(ws->fd, buffer, capacity, MSG_DONTWAIT);
        if (rc > 0)
        {
            received = static_cast<std::size_t>(rc);
            return true;
        }
        if (rc == 0)
        {
            err = "closed";
            return false;
        }
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
            continue;
        err = "websocket: recv: ";
        err += std::strerror(errno);
        return false;
    }
}

bool recv_exact(WebSocket *ws, char *destination, std::size_t size,
                Deadline deadline, std::string &err)
{
    std::size_t offset = 0;
    if (!ws->recv_pending.empty())
    {
        const std::size_t take = std::min(size, ws->recv_pending.size());
        std::memcpy(destination, ws->recv_pending.data(), take);
        ws->recv_pending.erase(0, take);
        offset = take;
    }
    while (offset < size)
    {
        std::size_t got = 0;
        if (!transport_recv_some(ws, destination + offset, size - offset,
                                 deadline, got, err))
        {
            // recv_frame() is retryable after timeout/interruption.  Do not
            // permanently consume the prefix read by this recv_exact() call:
            // otherwise the next recv() starts parsing in the middle of a
            // WebSocket frame.
            if (offset != 0)
                ws->recv_pending.insert(0, destination, offset);
            return false;
        }
        offset += got;
    }
    return true;
}

std::string base64_encode(const unsigned char *data, std::size_t size)
{
    const std::size_t encoded_size = 4 * ((size + 2) / 3);
    std::string out(encoded_size, '\0');
    const int rc = EVP_EncodeBlock(
        reinterpret_cast<unsigned char *>(out.data()), data,
        static_cast<int>(size));
    if (rc < 0)
        throw std::runtime_error("base64 encoding failed");
    out.resize(static_cast<std::size_t>(rc));
    return out;
}

bool sha1_bytes(std::string_view input, std::array<unsigned char, 20> &digest)
{
    unsigned int length = 0;
    return EVP_Digest(input.data(), input.size(), digest.data(), &length,
                      EVP_sha1(), nullptr) == 1 && length == digest.size();
}

std::string trim_ascii(std::string_view value)
{
    std::size_t begin = 0;
    while (begin < value.size() && (value[begin] == ' ' || value[begin] == '\t'))
        ++begin;
    std::size_t end = value.size();
    while (end > begin && (value[end - 1] == ' ' || value[end - 1] == '\t'))
        --end;
    return std::string(value.substr(begin, end - begin));
}

std::string lower_ascii(std::string_view value)
{
    std::string out(value);
    for (char &c : out)
    {
        if (c >= 'A' && c <= 'Z')
            c = static_cast<char>(c - 'A' + 'a');
    }
    return out;
}

bool is_http_token_char(unsigned char c) noexcept
{
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
           (c >= 'a' && c <= 'z') || c == '!' || c == '#' || c == '$' ||
           c == '%' || c == '&' || c == '\'' || c == '*' || c == '+' ||
           c == '-' || c == '.' || c == '^' || c == '_' || c == '`' ||
           c == '|' || c == '~';
}

bool valid_http_header_name(std::string_view name) noexcept
{
    if (name.empty())
        return false;
    for (unsigned char c : name)
    {
        if (!is_http_token_char(c))
            return false;
    }
    return true;
}

bool header_has_token(std::string_view value, std::string_view wanted)
{
    std::size_t start = 0;
    while (start <= value.size())
    {
        const std::size_t comma = value.find(',', start);
        const std::size_t end = comma == std::string_view::npos ? value.size() : comma;
        if (lower_ascii(trim_ascii(value.substr(start, end - start))) == wanted)
            return true;
        if (comma == std::string_view::npos)
            break;
        start = comma + 1;
    }
    return false;
}

bool perform_handshake(WebSocket *ws, const ParsedUrl &url, Deadline deadline,
                       std::string &err)
{
    std::array<unsigned char, 16> nonce{};
    if (RAND_bytes(nonce.data(), static_cast<int>(nonce.size())) != 1)
    {
        err = openssl_error("RAND_bytes failed");
        return false;
    }
    const std::string key = base64_encode(nonce.data(), nonce.size());
    std::string accept_source = key;
    accept_source.append(WS_GUID);
    std::array<unsigned char, 20> digest{};
    if (!sha1_bytes(accept_source, digest))
    {
        err = openssl_error("SHA-1 handshake digest failed");
        return false;
    }
    const std::string expected_accept = base64_encode(digest.data(), digest.size());

    std::string request;
    request.reserve(256 + url.target.size() + url.host_header.size());
    request += "GET ";
    request += url.target;
    request += " HTTP/1.1\r\nHost: ";
    request += url.host_header;
    request += "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n";
    request += "Sec-WebSocket-Key: ";
    request += key;
    request += "\r\nSec-WebSocket-Version: 13\r\n\r\n";
    if (!transport_send_all(ws, request.data(), request.size(), deadline, err))
        return false;

    std::string response;
    response.reserve(1024);
    std::array<char, 4096> buffer{};
    std::size_t header_end = std::string::npos;
    while ((header_end = response.find("\r\n\r\n")) == std::string::npos)
    {
        if (response.size() >= HANDSHAKE_HEADER_LIMIT)
        {
            err = "websocket: handshake headers exceed 64 KiB limit";
            return false;
        }
        std::size_t got = 0;
        if (!transport_recv_some(ws, buffer.data(), buffer.size(), deadline, got, err))
            return false;
        if (got > HANDSHAKE_HEADER_LIMIT - response.size())
        {
            err = "websocket: handshake headers exceed 64 KiB limit";
            return false;
        }
        response.append(buffer.data(), got);
    }

    const std::size_t body_start = header_end + 4;
    if (body_start < response.size())
        ws->recv_pending.assign(response.data() + body_start,
                                response.size() - body_start);
    response.resize(header_end);

    const std::size_t first_line_end = response.find("\r\n");
    const std::string_view status_line(response.data(),
                                       first_line_end == std::string::npos
                                           ? response.size()
                                           : first_line_end);
    if (!(status_line.rfind("HTTP/1.1 101 ", 0) == 0 ||
          status_line == "HTTP/1.1 101"))
    {
        err = "websocket: handshake rejected (expected HTTP/1.1 101)";
        return false;
    }

    std::optional<std::string> upgrade;
    std::optional<std::string> connection;
    std::optional<std::string> accept;
    std::optional<std::string> extensions;
    std::optional<std::string> protocol;
    std::size_t pos = first_line_end == std::string::npos ? response.size()
                                                           : first_line_end + 2;
    while (pos < response.size())
    {
        const std::size_t end = response.find("\r\n", pos);
        const std::size_t line_end = end == std::string::npos ? response.size() : end;
        const std::string_view line(response.data() + pos, line_end - pos);
        const std::size_t colon = line.find(':');
        if (colon == std::string_view::npos ||
            !valid_http_header_name(line.substr(0, colon)))
        {
            err = "websocket: malformed HTTP response header";
            return false;
        }
        // Do not trim the field-name: whitespace before ':' is invalid HTTP
        // syntax and accepting it creates parser ambiguity around Upgrade.
        const std::string name = lower_ascii(line.substr(0, colon));
        const std::string value = trim_ascii(line.substr(colon + 1));
        auto set_single = [&](std::optional<std::string> &slot) -> bool
        {
            if (slot)
            {
                err = "websocket: duplicate handshake header: " + name;
                return false;
            }
            slot = value;
            return true;
        };
        if (name == "upgrade")
        {
            if (!set_single(upgrade))
                return false;
        }
        else if (name == "connection")
        {
            if (connection)
                *connection += "," + value;
            else
                connection = value;
        }
        else if (name == "sec-websocket-accept")
        {
            if (!set_single(accept))
                return false;
        }
        else if (name == "sec-websocket-extensions")
        {
            if (!set_single(extensions))
                return false;
        }
        else if (name == "sec-websocket-protocol")
        {
            if (!set_single(protocol))
                return false;
        }
        pos = line_end == response.size() ? response.size() : line_end + 2;
    }

    if (!upgrade || lower_ascii(*upgrade) != "websocket" ||
        !connection || !header_has_token(*connection, "upgrade") ||
        !accept || *accept != expected_accept)
    {
        err = "websocket: invalid opening handshake response";
        return false;
    }
    // The client offered neither extensions nor a subprotocol. Presence of
    // either response field is therefore unsolicited, even if its value is
    // empty or otherwise malformed. Fail closed instead of normalizing it.
    if (extensions)
    {
        err = "websocket: server negotiated an unsupported extension";
        return false;
    }
    if (protocol)
    {
        err = "websocket: server selected an unsolicited subprotocol";
        return false;
    }
    return true;
}

bool is_valid_utf8(std::string_view text)
{
    std::size_t i = 0;
    while (i < text.size())
    {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        if (c <= 0x7f)
        {
            ++i;
            continue;
        }
        int continuation = 0;
        std::uint32_t code = 0;
        std::uint32_t minimum = 0;
        if ((c & 0xe0) == 0xc0)
        {
            continuation = 1;
            code = c & 0x1f;
            minimum = 0x80;
        }
        else if ((c & 0xf0) == 0xe0)
        {
            continuation = 2;
            code = c & 0x0f;
            minimum = 0x800;
        }
        else if ((c & 0xf8) == 0xf0)
        {
            continuation = 3;
            code = c & 0x07;
            minimum = 0x10000;
        }
        else
            return false;
        if (i + static_cast<std::size_t>(continuation) >= text.size())
            return false;
        for (int j = 0; j < continuation; ++j)
        {
            const unsigned char d = static_cast<unsigned char>(text[++i]);
            if ((d & 0xc0) != 0x80)
                return false;
            code = (code << 6) | (d & 0x3f);
        }
        if (code < minimum || code > 0x10ffff ||
            (code >= 0xd800 && code <= 0xdfff))
            return false;
        ++i;
    }
    return true;
}

bool valid_close_code(std::uint16_t code)
{
    if (code < 1000 || code >= 5000)
        return false;
    if (code == 1004 || code == 1005 || code == 1006 || code == 1015)
        return false;
    if (code >= 1016 && code <= 2999)
        return false;
    return true;
}

bool send_frame(WebSocket *ws, std::uint8_t opcode, bool fin,
                std::string_view payload, Deadline deadline, std::string &err)
{
    if (ws->closed || ws->fd < 0)
    {
        err = "closed";
        return false;
    }
    const bool control = (opcode & 0x08U) != 0;
    // max_frame_bytes bounds application data frames. RFC control frames have
    // their own fixed 125-byte ceiling and must remain usable even when the
    // application chooses a smaller data-frame cap (notably for Close 1009).
    if (!control && payload.size() > ws->max_frame_bytes)
    {
        err = "websocket: outgoing frame exceeds max_frame_bytes";
        return false;
    }
    if (control && (!fin || payload.size() > 125))
    {
        err = "websocket: invalid outgoing control frame";
        return false;
    }

    std::array<unsigned char, 14> header{};
    std::size_t header_size = 0;
    header[header_size++] = static_cast<unsigned char>((fin ? 0x80U : 0U) | opcode);
    const std::uint64_t length = payload.size();
    if (length <= 125)
        header[header_size++] = static_cast<unsigned char>(0x80U | length);
    else if (length <= 0xffff)
    {
        header[header_size++] = 0x80U | 126U;
        header[header_size++] = static_cast<unsigned char>((length >> 8) & 0xffU);
        header[header_size++] = static_cast<unsigned char>(length & 0xffU);
    }
    else
    {
        header[header_size++] = 0x80U | 127U;
        for (int shift = 56; shift >= 0; shift -= 8)
            header[header_size++] = static_cast<unsigned char>((length >> shift) & 0xffU);
    }

    std::array<unsigned char, 4> mask{};
    if (RAND_bytes(mask.data(), static_cast<int>(mask.size())) != 1)
    {
        err = openssl_error("RAND_bytes mask failed");
        return false;
    }
    for (unsigned char c : mask)
        header[header_size++] = c;

    AbandonedSend pending_frame(ws);
    pending_frame.start();
    if (!transport_send_all(ws, reinterpret_cast<const char *>(header.data()),
                            header_size, deadline, err))
        return false;

    std::array<char, 4096> chunk{};
    std::size_t offset = 0;
    while (offset < payload.size())
    {
        const std::size_t count = std::min(chunk.size(), payload.size() - offset);
        for (std::size_t i = 0; i < count; ++i)
            chunk[i] = static_cast<char>(
                static_cast<unsigned char>(payload[offset + i]) ^
                mask[(offset + i) % mask.size()]);
        if (!transport_send_all(ws, chunk.data(), count, deadline, err))
            return false;
        offset += count;
    }
    pending_frame.complete();
    return true;
}

bool send_message(WebSocket *ws, std::uint8_t opcode, std::string_view payload,
                  Deadline deadline, std::string &err)
{
    if (ws->sent_close)
    {
        err = "websocket: cannot send data after close";
        return false;
    }
    if (payload.size() > ws->max_message_bytes)
    {
        err = "websocket: outgoing message exceeds max_message_bytes";
        return false;
    }
    if (opcode == 0x1 && !is_valid_utf8(payload))
    {
        err = "websocket: text message is not valid UTF-8";
        return false;
    }

    if (payload.empty())
        return send_frame(ws, opcode, true, {}, deadline, err);

    AbandonedSend pending_message(ws);
    std::size_t offset = 0;
    bool first = true;
    while (offset < payload.size())
    {
        const std::size_t count = std::min<std::size_t>(
            {SEND_FRAGMENT_BYTES, ws->max_frame_bytes, payload.size() - offset});
        const bool fin = offset + count == payload.size();
        const std::uint8_t frame_opcode = first ? opcode : 0x0;
        if (!send_frame(ws, frame_opcode, fin, payload.substr(offset, count),
                        deadline, err))
            return false;
        // A completed non-final fragment still commits this message. Failure
        // before the next frame's first byte (e.g. RAND_bytes) must close too.
        pending_message.start();
        first = false;
        offset += count;
    }
    pending_message.complete();
    return true;
}

bool recv_frame(WebSocket *ws, Deadline deadline, Frame &frame, std::string &err)
{
    // Header bytes may have been fully consumed before a later read of the
    // extended length or payload times out.  Keep at most the 10-byte RFC
    // header so it can be put back in front of recv_pending on failure.
    std::string consumed_header;
    consumed_header.reserve(10);

    auto recv_header_piece = [&](char *destination, std::size_t size)
    {
        if (!recv_exact(ws, destination, size, deadline, err))
        {
            if (!consumed_header.empty())
                ws->recv_pending.insert(0, consumed_header);
            return false;
        }
        consumed_header.append(destination, size);
        return true;
    };

    std::array<unsigned char, 2> first{};
    if (!recv_header_piece(reinterpret_cast<char *>(first.data()), first.size()))
        return false;

    frame.fin = (first[0] & 0x80U) != 0;
    const unsigned char rsv = first[0] & 0x70U;
    frame.opcode = first[0] & 0x0fU;
    const bool masked = (first[1] & 0x80U) != 0;
    std::uint64_t length = first[1] & 0x7fU;

    if (rsv != 0)
    {
        err = "protocol: received frame uses unsupported RSV bits";
        return false;
    }
    if (masked)
    {
        err = "protocol: server frames must not be masked";
        return false;
    }
    const bool known_opcode = frame.opcode == 0x0 || frame.opcode == 0x1 ||
                              frame.opcode == 0x2 || frame.opcode == 0x8 ||
                              frame.opcode == 0x9 || frame.opcode == 0xa;
    if (!known_opcode)
    {
        err = "protocol: received reserved opcode";
        return false;
    }

    if (length == 126)
    {
        std::array<unsigned char, 2> ext{};
        if (!recv_header_piece(reinterpret_cast<char *>(ext.data()), ext.size()))
            return false;
        length = (static_cast<std::uint64_t>(ext[0]) << 8) | ext[1];
        if (length < 126)
        {
            err = "protocol: non-minimal frame length encoding";
            return false;
        }
    }
    else if (length == 127)
    {
        std::array<unsigned char, 8> ext{};
        if (!recv_header_piece(reinterpret_cast<char *>(ext.data()), ext.size()))
            return false;
        if ((ext[0] & 0x80U) != 0)
        {
            err = "protocol: invalid 63-bit frame length";
            return false;
        }
        length = 0;
        for (unsigned char c : ext)
            length = (length << 8) | c;
        if (length <= 0xffff)
        {
            err = "protocol: non-minimal frame length encoding";
            return false;
        }
    }

    const bool control = (frame.opcode & 0x08U) != 0;
    if (control && (!frame.fin || length > 125))
    {
        err = "protocol: invalid fragmented/oversized control frame";
        return false;
    }
    if ((!control && length > ws->max_frame_bytes) ||
        length > static_cast<std::uint64_t>(std::numeric_limits<std::size_t>::max()))
    {
        err = "too_large: incoming frame exceeds max_frame_bytes";
        return false;
    }
    frame.payload.resize(static_cast<std::size_t>(length));
    if (length != 0 && !recv_exact(ws, frame.payload.data(), frame.payload.size(),
                                    deadline, err))
    {
        if (!consumed_header.empty())
            ws->recv_pending.insert(0, consumed_header);
        return false;
    }
    return true;
}

bool send_close_payload(WebSocket *ws, std::string_view payload,
                        Deadline deadline, std::string &err)
{
    if (ws->sent_close)
        return true;
    if (!send_frame(ws, 0x8, true, payload, deadline, err))
        return false;
    ws->sent_close = true;
    return true;
}

void shutdown_transport_write(WebSocket *ws) noexcept
{
    if (ws->fd < 0)
        return;

    // A protocol violation may be detected from the frame header before the
    // remaining offending bytes have been consumed. Closing a TCP socket with
    // unread receive data can generate RST and discard the Close frame we just
    // sent. Half-close the write side first so the peer can observe the RFC
    // close status before the local descriptor is released.
    while (::shutdown(ws->fd, SHUT_WR) != 0 && errno == EINTR)
    {
    }
}

bool fail_protocol(WebSocket *ws, std::uint16_t code, std::string_view reason,
                   Deadline deadline, std::string &err)
{
    std::string payload;
    payload.push_back(static_cast<char>((code >> 8) & 0xffU));
    payload.push_back(static_cast<char>(code & 0xffU));
    payload.append(reason.substr(0, std::min<std::size_t>(reason.size(), 123)));
    std::string ignored;
    const bool close_sent = send_close_payload(ws, payload, deadline, ignored);
    if (close_sent)
        shutdown_transport_write(ws);
    close_transport(ws);
    err = "websocket: protocol error: ";
    err += reason;
    return false;
}

bool parse_close_payload(std::string_view payload, std::optional<std::uint16_t> &code,
                         std::string &reason, std::string &err)
{
    code.reset();
    reason.clear();
    if (payload.empty())
        return true;
    if (payload.size() == 1)
    {
        err = "close payload of length 1 is invalid";
        return false;
    }
    const std::uint16_t value =
        (static_cast<std::uint16_t>(static_cast<unsigned char>(payload[0])) << 8) |
        static_cast<unsigned char>(payload[1]);
    if (!valid_close_code(value))
    {
        err = "invalid close status code";
        return false;
    }
    reason.assign(payload.substr(2));
    if (!is_valid_utf8(reason))
    {
        err = "close reason is not valid UTF-8";
        return false;
    }
    code = value;
    return true;
}

bool recv_message(WebSocket *ws, Deadline deadline, std::string &type,
                  std::string &data, std::optional<std::uint16_t> &close_code,
                  std::string &close_reason, std::string &err)
{
    data.clear();

    for (;;)
    {
        Frame frame;
        if (!recv_frame(ws, deadline, frame, err))
        {
            if (err.rfind("protocol: ", 0) == 0)
            {
                const std::string detail = err.substr(std::string("protocol: ").size());
                return fail_protocol(ws, 1002, detail, deadline, err);
            }
            if (err.rfind("too_large: ", 0) == 0)
            {
                const std::string detail = err.substr(std::string("too_large: ").size());
                std::string ignored;
                (void)fail_protocol(ws, 1009, detail, deadline, ignored);
                err = "websocket: " + detail;
                return false;
            }
            return false;
        }

        if (frame.opcode == 0x9)
        {
            if (!send_frame(ws, 0xa, true, frame.payload, deadline, err))
                return false;
            continue;
        }
        if (frame.opcode == 0xa)
            continue;
        if (frame.opcode == 0x8)
        {
            std::string parse_error;
            if (!parse_close_payload(frame.payload, close_code, close_reason,
                                     parse_error))
            {
                const std::uint16_t close_error_code =
                    parse_error == "close reason is not valid UTF-8" ? 1007 : 1002;
                return fail_protocol(ws, close_error_code, parse_error, deadline, err);
            }
            ws->received_close = true;
            if (!ws->sent_close)
            {
                if (!send_close_payload(ws, frame.payload, deadline, err))
                {
                    close_transport(ws);
                    return false;
                }
            }
            close_transport(ws);
            type = "close";
            return true;
        }

        if (frame.opcode == 0x0)
        {
            if (!ws->recv_fragmented)
                return fail_protocol(ws, 1002, "unexpected continuation frame",
                                     deadline, err);
        }
        else
        {
            if (ws->recv_fragmented)
                return fail_protocol(ws, 1002,
                                     "new data frame during fragmented message",
                                     deadline, err);
            ws->recv_message_opcode = frame.opcode;
            ws->recv_message_data.clear();
            ws->recv_fragmented = !frame.fin;
        }

        if (frame.payload.size() >
            ws->max_message_bytes - ws->recv_message_data.size())
        {
            std::string ignored;
            (void)fail_protocol(ws, 1009, "message exceeds max_message_bytes",
                                deadline, ignored);
            err = "websocket: incoming message exceeds max_message_bytes";
            return false;
        }
        ws->recv_message_data.append(frame.payload);

        if (frame.fin)
        {
            if (ws->recv_message_opcode == 0x1 &&
                !is_valid_utf8(ws->recv_message_data))
                return fail_protocol(ws, 1007, "text message is not valid UTF-8",
                                     deadline, err);
            type = ws->recv_message_opcode == 0x1 ? "text" : "binary";
            data = std::move(ws->recv_message_data);
            ws->recv_message_data.clear();
            ws->recv_message_opcode = 0;
            ws->recv_fragmented = false;
            return true;
        }
        ws->recv_fragmented = true;
    }
}

int push_message_table(lua_State *L, const std::string &type,
                       const std::string &data,
                       const std::optional<std::uint16_t> &close_code,
                       const std::string &close_reason)
{
    auto builder = [&](lua_State *Ls) noexcept -> int
    {
        lua_createtable(Ls, 0, 4);
        lua_pushlstring(Ls, type.data(), type.size());
        lua_setfield(Ls, -2, "type");
        if (type == "text" || type == "binary")
        {
            lua_pushlstring(Ls, data.data(), data.size());
            lua_setfield(Ls, -2, "data");
        }
        else if (type == "close")
        {
            if (close_code)
            {
                lua_pushinteger(Ls, *close_code);
                lua_setfield(Ls, -2, "code");
            }
            lua_pushlstring(Ls, close_reason.data(), close_reason.size());
            lua_setfield(Ls, -2, "reason");
        }
        return 1;
    };
    return lua_build_results_protected(L, builder, 1);
}

int ws_send_common(lua_State *L, std::uint8_t opcode, const char *name)
{
    WebSocket *ws = check_ws(L, 1);
    if (!lua_arity_between(L, 2, 3))
        return luaL_error(L, "%s expects data and optional timeout", name);
    luaL_checktype(L, 2, LUA_TSTRING);
    std::size_t length = 0;
    const char *data = lua_tolstring(L, 2, &length);
    int timeout_ms = 0;
    std::string err;
    if (!parse_timeout_seconds(L, 3, ws->timeout_ms, timeout_ms, err, name))
        return push_fail_protected(L, err);
    if (ws->closed)
        return push_fail_protected(L, "closed");
    const Deadline deadline = make_deadline(timeout_ms);
    if (!send_message(ws, opcode, std::string_view(data, length), deadline, err))
    {
        if (err == "interrupted")
            signal_dispatch_pending(L);
        return push_fail_protected(L, err);
    }
    lua_pushinteger(L, static_cast<lua_Integer>(length));
    return 1;
}

int ws_send_text(lua_State *L)
{
    return ws_send_common(L, 0x1, "websocket: send_text");
}

int ws_send_binary(lua_State *L)
{
    return ws_send_common(L, 0x2, "websocket: send_binary");
}

int ws_recv(lua_State *L)
{
    WebSocket *ws = check_ws(L, 1);
    if (!lua_arity_between(L, 1, 2))
        return luaL_error(L, "websocket.recv expects optional timeout");
    int timeout_ms = 0;
    std::string err;
    if (!parse_timeout_seconds(L, 2, ws->timeout_ms, timeout_ms, err,
                               "websocket: recv"))
        return push_fail_protected(L, err);
    if (ws->closed)
        return push_fail_protected(L, "closed");

    std::string type;
    std::string data;
    std::optional<std::uint16_t> code;
    std::string reason;
    if (!recv_message(ws, make_deadline(timeout_ms), type, data, code, reason, err))
    {
        if (err == "interrupted")
            signal_dispatch_pending(L);
        return push_fail_protected(L, err);
    }
    return push_message_table(L, type, data, code, reason);
}

int ws_ping(lua_State *L)
{
    WebSocket *ws = check_ws(L, 1);
    if (!lua_arity_between(L, 1, 3))
        return luaL_error(L, "websocket.ping expects optional data and timeout");
    std::string_view payload;
    if (!lua_is_none_or_nil(L, 2))
    {
        luaL_checktype(L, 2, LUA_TSTRING);
        std::size_t length = 0;
        const char *data = lua_tolstring(L, 2, &length);
        payload = std::string_view(data, length);
    }
    if (payload.size() > 125)
        return push_fail_protected(L, "websocket: ping payload exceeds 125 bytes");
    int timeout_ms = 0;
    std::string err;
    if (!parse_timeout_seconds(L, 3, ws->timeout_ms, timeout_ms, err,
                               "websocket: ping"))
        return push_fail_protected(L, err);
    if (ws->sent_close || ws->closed)
        return push_fail_protected(L, "closed");
    if (!send_frame(ws, 0x9, true, payload, make_deadline(timeout_ms), err))
    {
        if (err == "interrupted")
            signal_dispatch_pending(L);
        return push_fail_protected(L, err);
    }
    return push_ok_protected(L);
}

int ws_set_timeout(lua_State *L)
{
    WebSocket *ws = check_ws(L, 1);
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "websocket.set_timeout expects seconds");
    int timeout_ms = 0;
    std::string err;
    if (!parse_timeout_seconds(L, 2, 0, timeout_ms, err,
                               "websocket: set_timeout"))
        return push_fail_protected(L, err);
    ws->timeout_ms = timeout_ms;
    return push_ok_protected(L);
}

int ws_close(lua_State *L)
{
    WebSocket *ws = check_ws(L, 1);
    if (!lua_arity_between(L, 1, 4))
        return luaL_error(L, "websocket.close expects optional code, reason and timeout");
    if (ws->closed)
        return push_ok_protected(L);

    std::uint16_t code = 1000;
    if (!lua_is_none_or_nil(L, 2))
    {
        if (!lua_is_strict_integer(L, 2))
            return luaL_argerror(L, 2, "close code must be an integer");
        const lua_Integer requested = lua_tointeger(L, 2);
        if (requested < 0 || requested > 65535 ||
            !valid_close_code(static_cast<std::uint16_t>(requested)))
            return push_fail_protected(L, "websocket: invalid close status code");
        code = static_cast<std::uint16_t>(requested);
    }

    if (!lua_is_none_or_nil(L, 3) && !lua_is_strict_string(L, 3))
        return luaL_typeerror(L, 3, "string");

    std::string reason;
    if (!lua_is_none_or_nil(L, 3))
    {
        std::string err;
        if (!lua_string_without_nul(L, 3, reason, "websocket: close reason", err))
            return push_fail_protected(L, err);
        if (!is_valid_utf8(reason))
            return push_fail_protected(L, "websocket: close reason is not valid UTF-8");
    }
    if (reason.size() > 123)
        return push_fail_protected(L, "websocket: close reason exceeds 123 bytes");

    int timeout_ms = 0;
    std::string err;
    if (!parse_timeout_seconds(L, 4, ws->timeout_ms, timeout_ms, err,
                               "websocket: close"))
        return push_fail_protected(L, err);
    const Deadline deadline = make_deadline(timeout_ms);

    std::string payload;
    payload.push_back(static_cast<char>((code >> 8) & 0xffU));
    payload.push_back(static_cast<char>(code & 0xffU));
    payload += reason;
    if (!send_close_payload(ws, payload, deadline, err))
    {
        close_transport(ws);
        if (err == "interrupted")
            signal_dispatch_pending(L);
        return push_fail_protected(L, err);
    }

    while (!ws->received_close && !ws->closed)
    {
        std::string type;
        std::string data;
        std::optional<std::uint16_t> peer_code;
        std::string peer_reason;
        if (!recv_message(ws, deadline, type, data, peer_code, peer_reason, err))
        {
            close_transport(ws);
            if (err == "interrupted")
                signal_dispatch_pending(L);
            return push_fail_protected(L, err);
        }
        if (type == "close")
            break;
    }
    close_transport(ws);
    return push_ok_protected(L);
}

int ws_tostring(lua_State *L)
{
    WebSocket *ws = check_ws(L, 1);
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "websocket (%s, fd=%d)",
                  ws->closed ? "closed" : "open", ws->fd);
    lua_pushstring(L, buffer);
    return 1;
}

int ws_gc(lua_State *L) noexcept
{
    auto *userdata = static_cast<WebSocketUserdata *>(
        luaL_testudata(L, 1, WS_META));
    if (!userdata || !userdata->constructed)
        return 0;
    WebSocket *ws = userdata->get();
    close_transport(ws);
    ws->~WebSocket();
    userdata->constructed = false;
    return 0;
}

int websocket_connect(lua_State *L)
{
    if (!lua_arity_between(L, 1, 2))
        return luaL_error(L, "websocket.connect expects URL and optional options");
    luaL_checktype(L, 1, LUA_TSTRING);
    std::string url_string;
    std::string err;
    if (!lua_string_without_nul(L, 1, url_string, "websocket: URL", err))
        return push_fail_protected(L, err);

    ConnectOptions opts;
    if (!parse_connect_options(L, 2, opts, err))
        return push_fail_protected(L, err);
    ParsedUrl url;
    if (!parse_url(url_string, url, err))
        return push_fail_protected(L, err);

    WebSocket *ws = push_empty_ws_protected(L);
    ws->timeout_ms = opts.timeout_ms;
    ws->max_message_bytes = opts.max_message_bytes;
    ws->max_frame_bytes = opts.max_frame_bytes;
    const Deadline deadline = make_deadline(opts.timeout_ms);

    if (!connect_tcp(ws, url, deadline, err))
    {
        close_transport(ws);
        if (err == "interrupted")
            signal_dispatch_pending(L);
        return push_fail_protected(L, err);
    }
    if (url.scheme == Scheme::Wss && !setup_tls(ws, url, opts, deadline, err))
    {
        close_transport(ws);
        if (err == "interrupted")
            signal_dispatch_pending(L);
        return push_fail_protected(L, err);
    }
    if (!perform_handshake(ws, url, deadline, err))
    {
        close_transport(ws);
        if (err == "interrupted")
            signal_dispatch_pending(L);
        return push_fail_protected(L, err);
    }
    return 1;
}

int ws_gc_boundary(lua_State *L) noexcept
{
    return ws_gc(L);
}
} // namespace

void register_websocket(lua_State *L)
{
    if (luaL_newmetatable(L, WS_META))
    {
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, ws_gc_boundary);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, websocket_lua_boundary<ws_tostring>);
        lua_setfield(L, -2, "__tostring");
        lua_pushcfunction(L, websocket_lua_boundary<ws_send_text>);
        lua_setfield(L, -2, "send_text");
        lua_pushcfunction(L, websocket_lua_boundary<ws_send_binary>);
        lua_setfield(L, -2, "send_binary");
        lua_pushcfunction(L, websocket_lua_boundary<ws_recv>);
        lua_setfield(L, -2, "recv");
        lua_pushcfunction(L, websocket_lua_boundary<ws_ping>);
        lua_setfield(L, -2, "ping");
        lua_pushcfunction(L, websocket_lua_boundary<ws_close>);
        lua_setfield(L, -2, "close");
        lua_pushcfunction(L, websocket_lua_boundary<ws_set_timeout>);
        lua_setfield(L, -2, "set_timeout");
    }
    lua_pop(L, 1);

    lua_newtable(L);
    lua_pushcfunction(L, websocket_lua_boundary<websocket_connect>);
    lua_setfield(L, -2, "connect");
    lua_setfield(L, -2, "websocket");
}
