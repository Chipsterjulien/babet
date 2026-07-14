#ifndef HTTP_HPP
#define HTTP_HPP

#include <lua.hpp>

/**
 * @brief Synchronous HTTP/HTTPS client exposed as `babet.http`.
 *
 * Entry points:
 *   request(opts)                     -> response | (nil, err)
 *   get(url, opts?)                   -> response | (nil, err)
 *   post(url, body?, opts?)           -> response | (nil, err)
 *   post(url, opts)                   -> response | (nil, err)
 *
 * Supported methods are GET, HEAD, OPTIONS, POST, PUT, PATCH and DELETE.
 * A received HTTP status, including 3xx/4xx/5xx, is a successful transport
 * result. DNS, TCP, TLS, timeout, response-limit and validation failures
 * return `(nil, err)`.
 *
 * The response table is:
 *   {
 *     status = integer,
 *     body = binary_string,
 *     headers = { [lower_name] = last_value },
 *     headers_multi = { [lower_name] = { all_values... } },
 *   }
 *
 * Important option fields:
 *   url              required absolute http(s) URL
 *   method           default GET; case-insensitive supported method
 *   headers          string names, string/number values
 *   body             binary string; forbidden on GET/HEAD/OPTIONS
 *   query            string keys, string/number values, RFC3986-encoded
 *   timeout          finite seconds > 0; connect + global request budget
 *   verify           strict boolean, default true
 *   ca_cert          CA bundle path for HTTPS
 *   follow_redirects strict boolean, default false
 *   max_body_size    1..2 GiB, default 64 MiB
 *
 * URL and header lines reject CR/LF; C-string fields reject embedded NUL.
 * Request and response bodies are binary-safe. The whole response body is
 * accumulated in memory; exceeding max_body_size exposes no partial body.
 *
 * Wrong positional argument types raise a Lua error. Invalid option fields
 * and runtime failures return `(nil, err)`. Unknown option fields are
 * currently ignored.
 */
int lua_http_request(lua_State *L);
int lua_http_get(lua_State *L);
int lua_http_post(lua_State *L);

/**
 * @brief Attaches the `http` subtable to the Babet table at the top of the
 * Lua stack.
 */
void register_http(lua_State *L);

#endif // HTTP_HPP
