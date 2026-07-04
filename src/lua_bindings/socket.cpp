#include "socket.hpp"
#include "lua_utils.hpp"
#include "signal.hpp"

#include <cerrno>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

// OpenSSL : sous-étape 1 du Chantier 7 (TLS sockets). Les libs sont
// déjà liées (libssl.a + libcrypto.a, cf. CMakeLists.txt ligne 67-70 :
// déjà utilisées par http via cpp-httplib). Aucun changement de build
// nécessaire pour TLS.
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

namespace
{

    constexpr const char *SOCK_META = "LuapilotSocket";

    // État porté par l'userdata. Tenu minimal : fd, mode listen,
    // timeout en ms. Le buffer de readline est externalisé hors
    // userdata pour ne pas alourdir la structure (chaque appel
    // recv_line alloue son propre std::string temporaire).
    //
    // Champ ssl (sous-étape 1 du Chantier 7) :
    //   nullptr  = socket TCP brut (cas par défaut).
    //   non-null = socket TLS connecté. Toutes les méthodes send/recv/
    //              recv_line/recv_all/close/... testeront ce champ et
    //              utiliseront SSL_read/SSL_write au lieu de recv/send
    //              (sous-étape 3). Pour l'instant, le champ existe
    //              mais aucune fonction ne le branche encore.
    struct Sock
    {
        int fd;         // -1 si fermé
        bool listening; // true si listen(), false si connect()/accept()
        int timeout_ms; // 0 = pas de timeout (bloquant infini)
        SSL *ssl;       // nullptr en TCP brut, non-null après TLS handshake

        // CORRECTIF (post-bug bot IRC) : buffer persistant pour recv_line.
        // Si recv_line a lu N octets puis tombe en timeout (pas de \n vu),
        // les octets DOIVENT être conservés pour le prochain appel —
        // sinon ils sont perdus (déjà consommés du socket par recv()).
        // Bug reproductible : mettre set_timeout(1) sur un flux IRC et
        // les premiers octets de certaines lignes étaient mangés. Le
        // contrat (nil, "closed", partial) sur EOF documentait déjà
        // l'intention de "ne pas perdre les octets déjà lus" ; on
        // étend cette garantie au timeout, de façon TRANSPARENTE
        // côté script (le buffer est interne, pas un partial à gérer).
        std::string recv_line_pending;
    };

    Sock *check_sock(lua_State *L, int idx)
    {
        return static_cast<Sock *>(luaL_checkudata(L, idx, SOCK_META));
    }

    // Pousse un nouveau userdata Sock initialisé, métatable posée.
    // CORRECTIF (placement new) : Sock contient maintenant un
    // std::string (recv_line_pending) dont le constructeur doit être
    // appelé explicitement, lua_newuserdata ne faisant qu'un malloc.
    // Le destructeur est appelé symétriquement dans sock_gc.
    Sock *push_new_sock(lua_State *L, int fd, bool listening)
    {
        void *raw = lua_newuserdata(L, sizeof(Sock));
        Sock *s = new (raw) Sock(); // placement new : init du std::string
        s->fd = fd;
        s->listening = listening;
        s->timeout_ms = 0;
        s->ssl = nullptr; // TCP brut par défaut, TLS posé après par connect_tls/starttls
        // recv_line_pending : déjà initialisé à "" par le constructeur par défaut.
        luaL_getmetatable(L, SOCK_META);
        lua_setmetatable(L, -2);
        return s;
    }

    // Helpers d'erreur format-friendly.
    int push_errno_fail(lua_State *L, const char *prefix)
    {
        int saved = errno;
        std::string msg = "socket: ";
        msg += prefix;
        msg += ": ";
        msg += std::strerror(saved);
        return push_fail(L, msg);
    }

    // -----------------------------------------------------------------
    // FD_CLOEXEC : empêche les sockets d'être hérités par les
    // sous-processus (babet.exec). Sans ça, un socket d'écoute peut
    // « survivre » à un Ctrl+C dans un process enfant et bloquer le
    // port (EADDRINUSE) malgré SO_REUSEADDR — qui ne couvre que les
    // FDs vraiment fermés, pas les FDs encore vivants ailleurs.
    //
    // Méthode primaire (utilisée en pratique sur Linux) : SOCK_CLOEXEC
    // dans socket() / accept4() — atomique (Linux >= 2.6.27, glibc >=
    // 2.9 ; FreeBSD >= 10). Pas de fenêtre de race, peu importe le
    // nombre de threads (workers compris).
    //
    // Méthode fallback : fcntl(F_SETFD | FD_CLOEXEC). Présente une
    // fenêtre de race entre socket()/accept() et le fcntl() : un fork
    // concurrent (babet.exec) pourrait hériter du fd avant qu'il
    // soit marqué close-on-exec. Avec l'arrivée des workers, cette
    // race n'est plus seulement théorique — mais sur Linux on prend
    // toujours le chemin atomique, donc ce fallback n'est jamais
    // emprunté. À reconsidérer si un jour Babet vise macOS/BSD
    // sans SOCK_CLOEXEC (cf. notes.md section 5).
    //
    // ensure_cloexec() est appelé même après SOCK_CLOEXEC pour
    // robustesse : aucun coût observable, et garde la même surface
    // de code que la branche fallback.
    void ensure_cloexec(int fd)
    {
        int flags = ::fcntl(fd, F_GETFD, 0);
        if (flags >= 0 && (flags & FD_CLOEXEC) == 0)
        {
            ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
        }
    }

    // -----------------------------------------------------------------
    // Deadline globale par appel (décision post-revue ChatGPT)
    // -----------------------------------------------------------------
    //
    // Avant : à chaque tour de boucle dans send/recv/..., on passait
    // s->timeout_ms à wait_ready(). Un gros transfert qui tournait en
    // plusieurs morceaux pouvait donc dépasser largement la valeur
    // promise par set_timeout(t).
    //
    // Maintenant : chaque opération (send, recv, recv_line, recv_all,
    // accept) calcule une DEADLINE absolue au début, puis recalcule
    // le temps restant à chaque tour. Si remaining_ms() retourne 0,
    // on appelle quand même poll(fd, 1, 0) une dernière fois : POSIX
    // garantit que c'est un check non bloquant qui rend tout de
    // suite l'état du fd (prêt ou pas). Court-circuiter avant ce
    // poll ferait rater des octets/connexions qui sont arrivés
    // pendant le temps imparti mais juste avant qu'on regarde.
    //
    // Cohérent avec http qui utilise set_max_timeout (cpp-httplib
    // v0.45.0+) = "durée max bout-en-bout". Sémantique unifiée dans
    // tout Babet : timeout = durée max de l'APPEL courant.
    //
    // L'horloge utilisée est steady_clock (monotone, immune aux
    // ajustements wall clock NTP).

    using Clock = std::chrono::steady_clock;
    using Deadline = Clock::time_point;

    // Sentinelle : Deadline::max() = "pas de timeout" (timeout_ms == 0).
    constexpr Deadline NO_DEADLINE = Deadline::max();

    Deadline make_deadline(int timeout_ms)
    {
        if (timeout_ms <= 0)
        {
            return NO_DEADLINE; // bloquant infini
        }
        return Clock::now() + std::chrono::milliseconds(timeout_ms);
    }

    // Renvoie le timeout effectif à passer à poll() :
    //   < 0  = bloquant infini (deadline == NO_DEADLINE)
    //   0    = deadline dépassée (poll() non bloquant : rend
    //          tout de suite ce qui est prêt, ou 0 si rien)
    //   > 0  = millisecondes restantes
    int remaining_ms(Deadline deadline)
    {
        if (deadline == NO_DEADLINE)
        {
            return -1; // poll bloquant infini
        }
        auto now = Clock::now();
        if (now >= deadline)
        {
            return 0;
        }
        auto delta = std::chrono::duration_cast<std::chrono::milliseconds>(
                         deadline - now)
                         .count();
        // delta est positif par construction (now < deadline) ; on
        // borne à INT_MAX pour le cast vers int de poll().
        if (delta > INT_MAX)
        {
            return INT_MAX;
        }
        return static_cast<int>(delta);
    }

    // Attend que `fd` devienne prêt pour POLLIN (recv) ou POLLOUT
    // (send/connect), AVEC respect de la deadline globale. Renvoie :
    //   1   = prêt
    //   0   = deadline dépassée
    //   -1  = erreur (errno positionné)
    // Boucle sur EINTR.
    // Codes de retour de wait_ready_deadline :
    //   > 0  : FD prêt (revents non-vide après poll)
    //   == 0 : timeout par deadline (avant tout event)
    //   == -1: erreur fatale (errno renseigné, à passer à push_errno_fail)
    //   == WAIT_INTERRUPTED : interrompu par un signal géré par
    //          babet.signal. Le callback Lua N'EST PAS encore
    //          dispatché (cette fonction n'a pas accès à la
    //          lua_State) : c'est au CALLER d'appeler
    //          signal_dispatch_pending(L) puis de renvoyer
    //          (nil, "interrupted"), en sauvegardant son buffer si
    //          nécessaire. (Commentaire corrigé — revue ChatGPT :
    //          l'ancienne formulation affirmait le contraire.)
    constexpr int WAIT_INTERRUPTED = -2;

    int wait_ready_deadline(int fd, short events, Deadline deadline)
    {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = events;
        for (;;)
        {
            // CORRECTIF (option A validée, revues ChatGPT lots
            // 13/14) : ferme la race PRÉ-poll. Le chemin EINTR
            // ci-dessous ne couvre que les signaux arrivant PENDANT
            // poll() ; un signal géré livré juste AVANT l'entrée
            // (flag posé, poll non interrompu) laissait l'attente
            // aller à son terme et retardait le dispatch du callback
            // jusqu'au hook Lua. Priorité assumée : un signal en
            // attente passe avant une opération réseau qui serait
            // prête à réussir — c'est le contrat "interrupted" du
            // module. Placé DANS la boucle : les réitérations (EINTR
            // étranger -> continue) re-vérifient aussi. La protection
            // main-thread est déjà dans signal_any_handled_pending
            // (no-op hors main thread, cf. signal.cpp), et le
            // dispatch reste fait par le caller, comme pour le chemin
            // EINTR.
            if (signal_any_handled_pending())
            {
                return WAIT_INTERRUPTED;
            }

            // Note : on ne court-circuite PAS quand t == 0. POSIX
            // garantit que poll(..., 0) retourne immédiatement avec
            // les fd déjà prêts (sans bloquer). Court-circuiter avant
            // poll() ferait rater des octets/connexions déjà
            // disponibles dans le cas où la deadline expire juste
            // avant l'entrée dans la boucle (très petits timeouts
            // configurés via set_timeout, ou délai de scheduling).
            int t = remaining_ms(deadline);
            pfd.revents = 0;
            int r = ::poll(&pfd, 1, t);
            if (r < 0)
            {
                if (errno == EINTR)
                {
                    // CORRECTIF (chantier signal phase B) : avant de
                    // retry silencieusement, on vérifie si l'EINTR
                    // vient d'un signal QU'ON GÈRE via
                    // babet.signal. Si oui, on doit propager
                    // l'interruption au caller (qui retournera
                    // (nil, "interrupted")) ET dispatcher le
                    // callback Lua avant de revenir, pour que le
                    // user voie ses handlers s'exécuter sans devoir
                    // attendre un timeout/event.
                    //
                    // Si l'EINTR vient d'un signal non géré (un
                    // SIGWINCH si l'utilisateur redimensionne son
                    // terminal, par exemple), on retry comme avant :
                    // ce serait surprenant qu'un signal non
                    // intercepté par babet fasse retourner un
                    // recv() en "interrupted".
                    if (signal_any_handled_pending())
                    {
                        // Récupérer la lua_State courante pour
                        // appeler le callback : on n'a pas accès à
                        // L ici, donc le dispatch est fait par le
                        // caller via signal_dispatch_pending(L).
                        // Voir les sites d'appel.
                        return WAIT_INTERRUPTED;
                    }
                    // Sur EINTR (signal non géré), le temps écoulé
                    // compte ; remaining_ms sera recalculé au
                    // prochain tour. Pas de risque d'attente
                    // infinie.
                    continue;
                }
                return -1;
            }
            return r; // 0 = timeout (peut être par deadline), > 0 = prêt
        }
    }

    // Active SO_REUSEADDR (décision ChatGPT validée : indispensable
    // pour relancer un serveur tué sans buter sur TIME_WAIT, non
    // exposé dans l'API v1).
    bool enable_reuseaddr(int fd)
    {
        int yes = 1;
        return ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
                            &yes, sizeof(yes)) == 0;
    }

    // =================================================================
    // TLS infrastructure (Chantier 7, sous-étape 1)
    // =================================================================
    //
    // Politique : OpenSSL >= 1.1.0 — autoload via OPENSSL_init_ssl()
    // (premier appel suffit, idempotent). Pas de SSL_library_init()
    // explicite (déprécié). Pas de SSL_load_error_strings() (idem).
    //
    // SSL_CTX global créé en lazy au premier connect_tls/starttls. Un
    // seul context partagé pour toutes les connexions client : pas de
    // raison d'en avoir plusieurs, OpenSSL est thread-safe sur SSL_CTX
    // partagé. Le SSL_CTX est protégé par la durée de vie du processus
    // (jamais détruit explicitement : libéré à l'exit, négligeable).
    //
    // Versions : TLS_client_method() est la méthode "any version"
    // moderne (OpenSSL >= 1.1.0). On force TLS 1.2 minimum via
    // SSL_CTX_set_min_proto_version() pour respecter TLS-D.
    //
    // Verify paths : SSL_CTX_set_default_verify_paths() + probing
    // runtime des emplacements connus de CA bundles. Le détail est
    // documenté dans init_openssl_ctx() ci-dessous. Cohérent avec
    // TLS-5 (CA système par défaut).
    //
    // Politique d'erreur : aucune exception ne traverse vers Lua
    // (invariant codebase). En cas d'échec d'init, on retourne nullptr
    // et on remplit un message d'erreur lisible.

    SSL_CTX *g_tls_ctx = nullptr;

    // Construit un message d'erreur lisible à partir de la pile
    // d'erreurs OpenSSL. Vide la pile après lecture.
    // Préfixe "tls: " toujours présent (cohérence avec "socket: ",
    // "http: ", "toml: " — convention codebase).
    std::string format_tls_error(const char *context)
    {
        std::string msg = "tls: ";
        if (context && *context)
        {
            msg += context;
            msg += ": ";
        }
        unsigned long e = ERR_get_error();
        if (e == 0)
        {
            msg += "(no openssl error in queue)";
            return msg;
        }
        // ERR_error_string_n écrit dans un buffer, format
        // "error:CODE:LIB:FUNC:REASON". Lisible mais verbeux.
        // ERR_reason_error_string donne juste le motif, plus court.
        const char *reason = ERR_reason_error_string(e);
        if (reason)
        {
            msg += reason;
        }
        else
        {
            char buf[256];
            ERR_error_string_n(e, buf, sizeof(buf));
            msg += buf;
        }
        // Vider la pile : OpenSSL accumule les erreurs par thread, on
        // ne veut pas qu'un appel ultérieur ramasse de vieilles erreurs.
        ERR_clear_error();
        return msg;
    }

    // Spécifique aux erreurs de vérification de certificat : OpenSSL
    // donne un code via SSL_get_verify_result(), traduit en string par
    // X509_verify_cert_error_string() (toujours non-null). Plus précis
    // que ERR_get_error() pour ce cas (handshake fail vs cert invalide
    // sont des choses différentes côté utilisateur).
    std::string format_verify_error(long verify_result)
    {
        std::string msg = "tls: certificate verify failed: ";
        const char *reason = X509_verify_cert_error_string(verify_result);
        msg += reason ? reason : "(unknown verify error)";
        return msg;
    }

    // Initialise le SSL_CTX global (lazy, idempotent). Renvoie true
    // si OK, false avec err rempli sinon.
    //
    // Configuration appliquée :
    //   - TLS_client_method() (any version, négocie vers la plus haute
    //     supportée mutuellement)
    //   - TLS 1.2 minimum (TLS-D)
    //   - SSL_VERIFY_PEER + verify_cb par défaut (rejet sur cert invalide
    //     côté OpenSSL ; le hostname check est posé par SSL session, pas
    //     ici, parce qu'il dépend du host passé à connect_tls)
    //   - Verify paths système (TLS-5)
    //   - SSL_MODE_AUTO_RETRY pour que SSL_read/SSL_write gèrent eux-
    //     mêmes les renégociations transparentes sans retourner
    //     SSL_ERROR_WANT_READ/WRITE en pleine opération applicative
    //
    // NB : aucune exception, aucun goto. Politique RAII manuelle sur
    // SSL_CTX (libéré seulement si erreur de config en cours d'init).
    // CORRECTIF (post-revue Gemini) : init thread-safe.
    // Avant les workers, l'init était lazy ("if (g_tls_ctx) return")
    // mais ce pattern est cassé en multi-thread : deux workers qui
    // appellent connect_tls() exactement en même temps peuvent
    // tomber dans la branche d'allocation tous les deux, leaker
    // un SSL_CTX, et provoquer une race sur la configuration.
    //
    // std::call_once garantit que la fermeture passée est exécutée
    // exactement une fois, peu importe le nombre de threads
    // concurrents. Les autres threads bloquent jusqu'à la fin de
    // l'init, puis voient le résultat.
    std::once_flag g_tls_init_flag;
    bool g_tls_init_success = false;
    std::string g_tls_init_err;

    bool init_openssl_ctx(std::string &err)
    {
        std::call_once(g_tls_init_flag, []()
                       {
            // Premier appel idempotent depuis OpenSSL 1.1.0.
            OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS |
                                 OPENSSL_INIT_LOAD_CRYPTO_STRINGS,
                             nullptr);

            SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
            if (ctx == nullptr)
            {
                g_tls_init_err = format_tls_error("SSL_CTX_new failed");
                g_tls_init_success = false;
                return;
            }

            // TLS 1.2 minimum (TLS-D). TLS 1.3 sera négocié
            // automatiquement si dispo des deux côtés.
            if (SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) != 1)
            {
                g_tls_init_err = format_tls_error(
                    "set_min_proto_version(TLS1_2) failed");
                SSL_CTX_free(ctx);
                g_tls_init_success = false;
                return;
            }

            // ====== Verify paths : CA bundle system =================
            // Le bundle CA n'a pas un emplacement standard unique sur
            // Linux/BSD ; chaque distro choisit son chemin. Comme
            // notre OpenSSL est vendored et statiquement linké, on ne
            // peut pas se reposer sur la config système du paquet
            // openssl de la distro.
            //
            // Stratégie en deux passes :
            //   1) SSL_CTX_set_default_verify_paths() : utilise les
            //      chemins compile-time d'OpenSSL (configurés via
            //      --openssldir=/etc/ssl dans build_local.sh) ET les
            //      variables d'env SSL_CERT_FILE / SSL_CERT_DIR si
            //      définies. Couvre Arch/Debian/Ubuntu/Alpine.
            //   2) Probing d'une liste de chemins connus pour les
            //      autres distros (Fedora/RHEL, OpenSUSE, *BSD).
            //      On charge via SSL_CTX_load_verify_locations() qui
            //      est additif (peut être appelé plusieurs fois).
            //
            // Politique : aucune des deux passes n'est obligatoire.
            // Si rien n'est chargé, on continue quand même — le user
            // peut toujours passer ca_cert explicitement, ou faire
            // verify=false. Un fail dur ici casserait des usages
            // légitimes (TLS sans verify, ou serveur interne avec
            // ca_cert fourni).
            //
            // Passe 1 : chemins compile-time + env vars
            if (SSL_CTX_set_default_verify_paths(ctx) != 1)
            {
                // Pas fatal. On vide la pile d'erreur pour que les
                // prochains appels OpenSSL ne ramassent pas cette
                // erreur résiduelle.
                ERR_clear_error();
            }

            // Passe 2 : probing des emplacements connus.
            // Le premier qui marche s'arrête (les CA system sont
            // typiquement le même contenu partout, pas besoin de
            // charger plusieurs sources).
            struct CABundleCandidate
            {
                const char *file;
                const char *dir;
            };
            static const CABundleCandidate candidates[] = {
                // Debian / Ubuntu / Arch / Alpine / Gentoo
                {"/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/certs"},
                // Fedora / RHEL / CentOS / Rocky / Alma
                {"/etc/pki/tls/certs/ca-bundle.crt", "/etc/pki/tls/certs"},
                // OpenSUSE
                {"/etc/ssl/ca-bundle.pem", nullptr},
                {"/var/lib/ca-certificates/ca-bundle.pem", nullptr},
                // FreeBSD (security/ca_root_nss)
                {"/usr/local/etc/ssl/cert.pem", "/usr/local/etc/ssl/certs"},
                // NetBSD
                {"/etc/openssl/certs/ca-certificates.crt",
                 "/etc/openssl/certs"},
            };

            for (const auto &c : candidates)
            {
                const char *use_file = nullptr;
                const char *use_dir = nullptr;
                if (c.file && ::access(c.file, R_OK) == 0)
                {
                    use_file = c.file;
                }
                if (c.dir)
                {
                    struct stat st;
                    if (::stat(c.dir, &st) == 0 && S_ISDIR(st.st_mode))
                    {
                        use_dir = c.dir;
                    }
                }
                if (use_file == nullptr && use_dir == nullptr)
                {
                    continue;
                }
                if (SSL_CTX_load_verify_locations(ctx, use_file, use_dir)
                    == 1)
                {
                    break; // CA chargé, stop le probing
                }
                // Échec sur ce chemin (rare : fichier illisible,
                // format inconnu) : vider l'erreur et essayer le
                // suivant.
                ERR_clear_error();
            }

            // Vérification activée par défaut (TLS-C : verify=true).
            // verify_cb = nullptr : comportement OpenSSL par défaut
            // (rejette si verify_result != X509_V_OK).
            SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nullptr);

            // AUTO_RETRY : SSL_read/SSL_write gèrent les
            // renégociations transparentes sans renvoyer WANT_READ/
            // WANT_WRITE à l'appli.
            SSL_CTX_set_mode(ctx, SSL_MODE_AUTO_RETRY);

            g_tls_ctx = ctx;
            g_tls_init_success = true; });

        if (!g_tls_init_success)
        {
            err = g_tls_init_err;
            return false;
        }
        return true;
    }

    // Structure de configuration TLS (mappe les opts Lua TLS-3).
    struct TlsOptions
    {
        bool verify = true;      // TLS-C : verify ON par défaut
        std::string ca_cert;     // chemin fichier PEM (optionnel)
        std::string ca_path;     // chemin dossier (optionnel)
        std::string hostname;    // override (vide = utiliser host)
        std::string min_version; // "1.2" (défaut) ou "1.3"
        int timeout_ms = 0;      // 0 = bloquant infini
    };

    // Lit les opts depuis une table Lua à l'index donné (ou nil/absent).
    // Renvoie true en succès, false avec err rempli sur type invalide.
    // Politique stricte : types attendus (boolean/string/number), refuse
    // sinon. luaL_error non utilisé ici car on est dans une chaîne de
    // (val, err) — on remonte l'erreur au caller qui décide.
    bool parse_tls_options(lua_State *L, int idx, TlsOptions &opts,
                           std::string &err)
    {
        if (lua_isnoneornil(L, idx))
        {
            return true; // tout default
        }
        if (!lua_istable(L, idx))
        {
            err = "tls: opts must be a table";
            return false;
        }

        // opts.verify (boolean strict, pas de coercion truthy)
        lua_getfield(L, idx, "verify");
        if (!lua_isnil(L, -1))
        {
            if (lua_type(L, -1) != LUA_TBOOLEAN)
            {
                err = "tls: opts.verify must be a boolean";
                lua_pop(L, 1);
                return false;
            }
            opts.verify = lua_toboolean(L, -1);
        }
        lua_pop(L, 1);

        // opts.ca_cert (string)
        lua_getfield(L, idx, "ca_cert");
        if (!lua_isnil(L, -1))
        {
            if (lua_type(L, -1) != LUA_TSTRING)
            {
                err = "tls: opts.ca_cert must be a string";
                lua_pop(L, 1);
                return false;
            }
            opts.ca_cert = lua_tostring(L, -1);
        }
        lua_pop(L, 1);

        // opts.ca_path (string)
        lua_getfield(L, idx, "ca_path");
        if (!lua_isnil(L, -1))
        {
            if (lua_type(L, -1) != LUA_TSTRING)
            {
                err = "tls: opts.ca_path must be a string";
                lua_pop(L, 1);
                return false;
            }
            opts.ca_path = lua_tostring(L, -1);
        }
        lua_pop(L, 1);

        // opts.hostname (string)
        lua_getfield(L, idx, "hostname");
        if (!lua_isnil(L, -1))
        {
            if (lua_type(L, -1) != LUA_TSTRING)
            {
                err = "tls: opts.hostname must be a string";
                lua_pop(L, 1);
                return false;
            }
            opts.hostname = lua_tostring(L, -1);
        }
        lua_pop(L, 1);

        // opts.min_version (string "1.2" ou "1.3")
        lua_getfield(L, idx, "min_version");
        if (!lua_isnil(L, -1))
        {
            if (lua_type(L, -1) != LUA_TSTRING)
            {
                err = "tls: opts.min_version must be a string";
                lua_pop(L, 1);
                return false;
            }
            const char *v = lua_tostring(L, -1);
            if (std::strcmp(v, "1.2") != 0 && std::strcmp(v, "1.3") != 0)
            {
                err = "tls: opts.min_version must be '1.2' or '1.3'";
                lua_pop(L, 1);
                return false;
            }
            opts.min_version = v;
        }
        lua_pop(L, 1);

        // opts.timeout (number en secondes, même convention que partout)
        lua_getfield(L, idx, "timeout");
        if (!lua_isnil(L, -1))
        {
            if (lua_type(L, -1) != LUA_TNUMBER)
            {
                err = "tls: opts.timeout must be a number";
                lua_pop(L, 1);
                return false;
            }
            lua_Number t = lua_tonumber(L, -1);
            if (std::isnan(t) || !std::isfinite(t))
            {
                err = "tls: opts.timeout must be finite (not NaN or inf)";
                lua_pop(L, 1);
                return false;
            }
            if (t < 0.0)
            {
                err = "tls: opts.timeout must be >= 0";
                lua_pop(L, 1);
                return false;
            }
            if (t > 0.0)
            {
                double ms = t * 1000.0;
                if (ms > static_cast<double>(INT_MAX))
                {
                    err = "tls: opts.timeout too large";
                    lua_pop(L, 1);
                    return false;
                }
                opts.timeout_ms = (ms < 1.0) ? 1 : static_cast<int>(ms);
            }
        }
        lua_pop(L, 1);

        return true;
    }

    // Applique les options à un SSL* avant le handshake.
    // host_default sert pour le hostname check si opts.hostname est vide
    // (ex : "irc.libera.chat" pour connect_tls). Pour starttls() sur un
    // socket déjà connecté par IP, l'utilisateur DOIT passer
    // opts.hostname (le check serait sinon basé sur "127.0.0.1" ou
    // l'adresse IP, donc échouerait pour un vrai cert).
    //
    // ATTENTION : les options ca_cert / ca_path modifient le SSL_CTX
    // GLOBAL en v1 (pas par-connexion). C'est une limite acceptée :
    // pour des cas multi-CA strictement isolés, attendre une v2 qui
    // créerait un CTX par-connexion. Pour 99% des cas (bot IRC, SMTP,
    // etc.), les CA système suffisent et ca_cert n'est même pas utilisé.
    bool apply_tls_options(SSL *ssl, const TlsOptions &opts,
                           const char *host_default, std::string &err)
    {
        // Verify mode + hostname check (TLS-C + TLS-4)
        if (opts.verify)
        {
            SSL_set_verify(ssl, SSL_VERIFY_PEER, nullptr);
            const char *hn = !opts.hostname.empty()
                                 ? opts.hostname.c_str()
                                 : host_default;
            if (hn && *hn)
            {
                // SSL_set1_host : check chaîne ET hostname (CN/SAN).
                // OpenSSL >= 1.0.2. Renvoie 1 en succès.
                if (SSL_set1_host(ssl, hn) != 1)
                {
                    err = format_tls_error("SSL_set1_host failed");
                    return false;
                }
                // SNI : même hostname envoyé au serveur. Peut échouer
                // si hn est une IP littérale ; dans ce cas on ignore
                // (pas de SNI pour IP, c'est conforme RFC 6066).
                SSL_set_tlsext_host_name(ssl, hn);
                ERR_clear_error();
            }
        }
        else
        {
            SSL_set_verify(ssl, SSL_VERIFY_NONE, nullptr);
        }

        // CA cert / CA path : load via SSL_CTX_load_verify_locations
        // (cf. note sur le CTX global ci-dessus).
        if (!opts.ca_cert.empty() || !opts.ca_path.empty())
        {
            const char *cf = opts.ca_cert.empty()
                                 ? nullptr
                                 : opts.ca_cert.c_str();
            const char *cp = opts.ca_path.empty()
                                 ? nullptr
                                 : opts.ca_path.c_str();
            if (SSL_CTX_load_verify_locations(g_tls_ctx, cf, cp) != 1)
            {
                err = format_tls_error("load_verify_locations failed");
                return false;
            }
        }

        // min_version : "1.2" déjà posé sur le CTX (init_openssl_ctx).
        // "1.3" surcharge par-connexion.
        if (opts.min_version == "1.3")
        {
            if (SSL_set_min_proto_version(ssl, TLS1_3_VERSION) != 1)
            {
                err = format_tls_error("set_min_proto_version(TLS1_3) failed");
                return false;
            }
        }

        return true;
    }

    // Pilote SSL_connect() avec poll + deadline globale. Boucle sur
    // SSL_ERROR_WANT_READ / WANT_WRITE en utilisant wait_ready_deadline.
    // Si le handshake échoue à cause d'une vérif cert, le message
    // d'erreur est explicite via format_verify_error().
    //
    // Précondition : le fd doit être en mode non-bloquant (sinon
    // SSL_connect bloquerait dans le noyau sans qu'on puisse respecter
    // la deadline). L'appelant GARDE le fd en non-bloquant après
    // succès — c'est ce qui permet aux SSL_read/SSL_write ultérieurs
    // de respecter à leur tour la deadline globale via la boucle
    // WANT_READ/WANT_WRITE de tls_send_some / tls_recv_some.
    // En cas d'échec handshake, l'appelant remet bloquant avant de
    // fermer le fd (cohérence d'état avant cleanup).
    bool tls_handshake(SSL *ssl, int fd, int timeout_ms, std::string &err)
    {
        Deadline deadline = make_deadline(timeout_ms);
        for (;;)
        {
            ERR_clear_error();
            int rc = SSL_connect(ssl);
            if (rc == 1)
            {
                return true; // handshake OK
            }
            int e = SSL_get_error(ssl, rc);
            if (e == SSL_ERROR_WANT_READ)
            {
                int wr = wait_ready_deadline(fd, POLLIN, deadline);
                if (wr == WAIT_INTERRUPTED)
                {
                    // Phase B signal : on propage l'info via err.
                    // L'appelant (do_tls_handshake -> ...) verra
                    // err == "interrupted" et retournera (nil, err)
                    // à Lua. Le callback Lua sera invoqué soit par
                    // ce push depuis le caller (s'il fait dispatch),
                    // soit au prochain debug hook count tick.
                    err = "interrupted";
                    return false;
                }
                if (wr == 0)
                {
                    err = "timeout";
                    return false;
                }
                if (wr < 0)
                {
                    err = "tls: handshake poll failed";
                    return false;
                }
                continue;
            }
            if (e == SSL_ERROR_WANT_WRITE)
            {
                int wr = wait_ready_deadline(fd, POLLOUT, deadline);
                if (wr == WAIT_INTERRUPTED)
                {
                    err = "interrupted";
                    return false;
                }
                if (wr == 0)
                {
                    err = "timeout";
                    return false;
                }
                if (wr < 0)
                {
                    err = "tls: handshake poll failed";
                    return false;
                }
                continue;
            }
            // Erreur : si c'est une verif cert, message explicite ;
            // sinon, pile ERR générique.
            long vr = SSL_get_verify_result(ssl);
            if (vr != X509_V_OK)
            {
                err = format_verify_error(vr);
                return false;
            }
            err = format_tls_error("SSL_connect failed");
            return false;
        }
    }

    // Fermeture propre d'une session TLS (sous-étape 1 : helper prêt,
    // sera utilisé par sock_close en sous-étape 3).
    //
    // SSL_shutdown peut nécessiter deux passes (RFC 5246 §7.2.1) :
    //   - 1er appel envoie close_notify côté nous.
    //   - 2ème appel attend close_notify côté peer.
    // En pratique, peu de peers respectent strictement le double-pass
    // et beaucoup ferment juste la connexion. On fait UN appel
    // SSL_shutdown best-effort, on ignore les erreurs (le FD sous-
    // jacent sera fermé tout de suite après par ::close()).
    //
    // ERR_clear_error() est appelé en sortie pour ne pas polluer la
    // pile d'erreurs si SSL_shutdown a échoué proprement (peer brutal).
    void tls_close(SSL *ssl)
    {
        if (ssl == nullptr)
        {
            return;
        }
        // Best-effort : on tente une fois, on ne boucle pas. Si le
        // peer ne répond pas dans le délai noyau, tant pis : on libère.
        // Le FD est fermé juste après par l'appelant.
        SSL_shutdown(ssl);
        SSL_free(ssl);
        ERR_clear_error();
    }

    // -----------------------------------------------------------------
    // Helpers IO TLS (sous-étape 1.3)
    // -----------------------------------------------------------------
    //
    // SSL_read / SSL_write ont une convention d'erreur différente de
    // POSIX recv/send : sur retour <= 0, il faut appeler SSL_get_error
    // pour savoir si c'est WANT_READ/WANT_WRITE (rebloquant attendu,
    // équivalent EAGAIN), ZERO_RETURN (EOF propre, équivalent
    // recv()==0), ou erreur vraie.
    //
    // tls_send_some et tls_recv_some encapsulent UN appel SSL_write
    // / SSL_read avec la traduction des codes d'erreur en codes
    // standards utilisés par les sock_* (POSIX-like) :
    //   > 0  = nombre d'octets transférés
    //   0    = EOF (peer a fermé proprement, SSL_ERROR_ZERO_RETURN)
    //   -1   = WANT_READ — appelant doit poll(POLLIN) + retry
    //   -2   = WANT_WRITE — appelant doit poll(POLLOUT) + retry
    //   -3   = erreur fatale (err rempli)
    //
    // Pas de boucle ici : la boucle (avec deadline) est dans l'appelant
    // (sock_send/sock_recv/...) pour cohérence avec le pattern TCP qui
    // boucle déjà sur poll + retry.

    // Codes retour des helpers TLS (au-dessus de toute valeur ssize_t
    // positive valide).
    constexpr int TLS_IO_EOF = 0;
    constexpr int TLS_IO_WANT_READ = -1;
    constexpr int TLS_IO_WANT_WRITE = -2;
    constexpr int TLS_IO_FATAL = -3;

    // Effectue UN appel SSL_write. Convention de retour ci-dessus.
    // ERR_clear_error() AVANT l'appel : SSL_get_error consulte la pile
    // et on doit donc partir propre pour avoir un diagnostic juste.
    int tls_send_some(SSL *ssl, const char *data, size_t len,
                      std::string &err)
    {
        if (len == 0)
        {
            return 0; // rien à envoyer
        }
        ERR_clear_error();
        int n = SSL_write(ssl, data, static_cast<int>(len));
        if (n > 0)
        {
            return n;
        }
        int e = SSL_get_error(ssl, n);
        switch (e)
        {
        case SSL_ERROR_WANT_READ:
            return TLS_IO_WANT_READ;
        case SSL_ERROR_WANT_WRITE:
            return TLS_IO_WANT_WRITE;
        case SSL_ERROR_ZERO_RETURN:
            // close_notify reçu pendant write ; on remonte comme EOF
            // pour cohérence avec sock_send qui doit alors retourner
            // (nil, "closed").
            return TLS_IO_EOF;
        case SSL_ERROR_SYSCALL:
            // Erreur transport (peer brutal, EPIPE-like). errno utile
            // si non-zéro, sinon "closed" sur SSL_ERROR_SYSCALL est
            // une fermeture sans close_notify (cas courant).
            if (errno == 0)
            {
                return TLS_IO_EOF;
            }
            err = "tls: SSL_write syscall: ";
            err += std::strerror(errno);
            return TLS_IO_FATAL;
        default:
            err = format_tls_error("SSL_write failed");
            return TLS_IO_FATAL;
        }
    }

    // Effectue UN appel SSL_read. Convention de retour identique à
    // tls_send_some.
    int tls_recv_some(SSL *ssl, char *buf, size_t cap, std::string &err)
    {
        if (cap == 0)
        {
            return 0;
        }
        ERR_clear_error();
        int n = SSL_read(ssl, buf, static_cast<int>(cap));
        if (n > 0)
        {
            return n;
        }
        int e = SSL_get_error(ssl, n);
        switch (e)
        {
        case SSL_ERROR_WANT_READ:
            return TLS_IO_WANT_READ;
        case SSL_ERROR_WANT_WRITE:
            return TLS_IO_WANT_WRITE;
        case SSL_ERROR_ZERO_RETURN:
            return TLS_IO_EOF;
        case SSL_ERROR_SYSCALL:
            if (errno == 0)
            {
                return TLS_IO_EOF;
            }
            err = "tls: SSL_read syscall: ";
            err += std::strerror(errno);
            return TLS_IO_FATAL;
        default:
            err = format_tls_error("SSL_read failed");
            return TLS_IO_FATAL;
        }
    }

    // =================================================================
    // Fin TLS infrastructure (sous-étape 1)
    // =================================================================

    // Résout host/port via getaddrinfo. Renvoie un addrinfo* qui doit
    // être libéré avec freeaddrinfo, ou nullptr + remplit `err`.
    // `passive` = true pour bind/listen (utilise AI_PASSIVE + host
    // optionnel), false pour connect.
    struct addrinfo *resolve(const char *host, const char *port,
                             bool passive, std::string &err)
    {
        struct addrinfo hints;
        std::memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;     // IPv4 ou IPv6
        hints.ai_socktype = SOCK_STREAM; // TCP
        if (passive)
        {
            hints.ai_flags = AI_PASSIVE;
        }
        struct addrinfo *res = nullptr;
        const char *h = (host && *host) ? host : nullptr;
        int rc = ::getaddrinfo(h, port, &hints, &res);
        if (rc != 0)
        {
            err = "socket: getaddrinfo: ";
            err += ::gai_strerror(rc);
            return nullptr;
        }
        return res;
    }

    // -----------------------------------------------------------------
    // Méthodes du userdata socket
    // -----------------------------------------------------------------

    int sock_send(lua_State *L)
    {
        Sock *s = check_sock(L, 1);
        size_t len = 0;
        const char *data = luaL_checklstring(L, 2, &len);
        if (s->fd < 0)
        {
            return push_fail(L, "socket: send: socket is closed");
        }
        if (s->listening)
        {
            return push_fail(L,
                             "socket: send: cannot send on a listening socket");
        }

        // Boucle d'écriture : send() peut écrire partiellement, on
        // continue jusqu'à tout envoyer ou timeout. MSG_NOSIGNAL :
        // pas de SIGPIPE sur peer fermé (on reçoit EPIPE).
        //
        // CORRECTIF (post-revue ChatGPT) : si un timeout est actif,
        // on force MSG_DONTWAIT pour que send() lui-même ne bloque
        // PAS dans le noyau quand le peer lit lentement. Sans ça,
        // poll() nous disait "prêt pour au moins 1 octet" mais
        // send() pouvait quand même bloquer pour écrire un gros
        // buffer entier. EAGAIN/EWOULDBLOCK -> on reboucle sur
        // poll() avec le timeout restant. Si pas de timeout
        // (s->timeout_ms == 0), comportement bloquant pur conservé,
        // pas de MSG_DONTWAIT (sinon send() retournerait
        // immédiatement EAGAIN au lieu de bloquer comme attendu).
        //
        // DEADLINE GLOBALE (post-revue 2) : on calcule la deadline
        // UNE FOIS au début ; chaque tour de boucle utilise le temps
        // restant. timeout = durée max de l'APPEL complet (cohérent
        // avec http set_max_timeout, sémantique unifiée Babet).
        //
        // TLS (Chantier 7, sous-étape 1.3) : si s->ssl est non-null,
        // le socket est en mode TLS. Le FD est en O_NONBLOCK depuis
        // connect_tls/starttls (corrigé post-revue) : SSL_write ne
        // peut PAS bloquer dans le noyau au-delà de la deadline. Si
        // le buffer noyau est plein, SSL_write retourne WANT_WRITE ;
        // si une renégociation TLS interne demande des bytes du peer,
        // SSL_write retourne WANT_READ. tls_send_some traduit ces
        // cas en codes TLS_IO_WANT_* qu'on gère ci-dessous avec
        // wait_ready_deadline + retry. Garantie : deadline globale
        // respectée comme pour TCP brut.
        size_t total = 0;
        const bool is_tls = (s->ssl != nullptr);
        const bool use_nonblock = (!is_tls) && (s->timeout_ms > 0);
        const int send_flags = MSG_NOSIGNAL |
                               (use_nonblock ? MSG_DONTWAIT : 0);
        Deadline deadline = make_deadline(s->timeout_ms);
        std::string tls_err;
        while (total < len)
        {
            // Direction du poll : POLLOUT par défaut. En TLS, un
            // SSL_write peut demander POLLIN (renégociation), géré
            // dans la branche TLS via le code retour WANT_READ.
            short poll_events = POLLOUT;
            int r = wait_ready_deadline(s->fd, poll_events, deadline);
            if (r == WAIT_INTERRUPTED)
            {
                signal_dispatch_pending(L);
                return push_fail(L, "interrupted");
            }
            if (r < 0)
            {
                return push_errno_fail(L, "send");
            }
            if (r == 0)
            {
                return push_fail(L, "timeout");
            }

            if (is_tls)
            {
                int rc = tls_send_some(s->ssl, data + total,
                                       len - total, tls_err);
                if (rc > 0)
                {
                    total += static_cast<size_t>(rc);
                    continue;
                }
                if (rc == TLS_IO_EOF)
                {
                    return push_fail(L, "closed");
                }
                if (rc == TLS_IO_WANT_READ)
                {
                    int wr = wait_ready_deadline(s->fd, POLLIN, deadline);
                    if (wr == WAIT_INTERRUPTED)
                    {
                        signal_dispatch_pending(L);
                        return push_fail(L, "interrupted");
                    }
                    if (wr == 0)
                        return push_fail(L, "timeout");
                    if (wr < 0)
                        return push_errno_fail(L, "send");
                    continue;
                }
                if (rc == TLS_IO_WANT_WRITE)
                {
                    continue; // déjà attendu POLLOUT, reboucle
                }
                return push_fail(L, tls_err); // FATAL
            }

            // Branche TCP brut (inchangée).
            ssize_t n = ::send(s->fd, data + total, len - total,
                               send_flags);
            if (n < 0)
            {
                if (errno == EINTR)
                {
                    continue;
                }
                if (errno == EAGAIN || errno == EWOULDBLOCK)
                {
                    // Le buffer noyau s'est rempli juste après poll
                    // (race normale). On reboucle, poll() bloquera
                    // jusqu'à ce que de la place se libère, dans la
                    // limite du temps restant sur la deadline.
                    continue;
                }
                if (errno == EPIPE || errno == ECONNRESET)
                {
                    return push_fail(L, "closed");
                }
                return push_errno_fail(L, "send");
            }
            total += static_cast<size_t>(n);
        }
        lua_pushinteger(L, static_cast<lua_Integer>(total));
        return 1;
    }

    // Plafond raisonnable sur recv(n) pour éviter qu'une faute de
    // frappe (un *1024 accidentel) ne provoque une allocation OOM.
    // 16 MB est largement au-dessus du buffer noyau par défaut sous
    // Linux (~128 KB-2 MB selon tuning), donc aucun cas légitime
    // n'est restreint. Au-delà -> (nil, err) (décision post-revue).
    constexpr lua_Integer MAX_RECV_SIZE = 16 * 1024 * 1024;

    // recv(n) "au plus n octets" (sémantique read()). EOF -> (nil,
    // "closed"). Timeout -> (nil, "timeout").
    int sock_recv(lua_State *L)
    {
        Sock *s = check_sock(L, 1);
        lua_Integer n = luaL_checkinteger(L, 2);
        if (n <= 0)
        {
            return push_fail(L, "socket: recv: count must be > 0");
        }
        if (n > MAX_RECV_SIZE)
        {
            return push_fail(L,
                             "socket: recv: count exceeds 16 MB cap");
        }
        if (s->fd < 0)
        {
            return push_fail(L, "socket: recv: socket is closed");
        }
        if (s->listening)
        {
            return push_fail(L,
                             "socket: recv: cannot recv on a listening socket");
        }

        // CORRECTIF (post-revue ChatGPT) : symétrie avec send(),
        // MSG_DONTWAIT quand un timeout est actif. Le cas est moins
        // fréquent côté recv (poll(POLLIN) garantit qu'il y a déjà
        // des données), mais une race est possible entre poll() et
        // recv() ; on la traite proprement par reboucle.
        //
        // DEADLINE GLOBALE (post-revue 2) : une seule deadline pour
        // tout l'appel, même si on reboucle sur EAGAIN/EINTR.
        //
        // TLS (sous-étape 1.3) : si s->ssl non-null, route via
        // SSL_read avec gestion WANT_READ/WANT_WRITE.
        const bool is_tls = (s->ssl != nullptr);
        const bool use_nonblock = (!is_tls) && (s->timeout_ms > 0);
        const int recv_flags = use_nonblock ? MSG_DONTWAIT : 0;
        Deadline deadline = make_deadline(s->timeout_ms);

        std::vector<char> buf(static_cast<size_t>(n));
        std::string tls_err;
        for (;;)
        {
            // CORRECTIF (post-bug IRC TLS) : voir explication détaillée
            // dans sock_recv_line. Si OpenSSL a déjà déchiffré des octets
            // dans son buffer interne, le FD socket est vide alors qu'il
            // y a des données à lire. Il faut sauter wait_ready_deadline
            // dans ce cas.
            const bool ssl_has_data =
                is_tls && (SSL_pending(s->ssl) > 0);

            if (!ssl_has_data)
            {
                int r = wait_ready_deadline(s->fd, POLLIN, deadline);
                if (r == WAIT_INTERRUPTED)
                {
                    signal_dispatch_pending(L);
                    return push_fail(L, "interrupted");
                }
                if (r < 0)
                {
                    return push_errno_fail(L, "recv");
                }
                if (r == 0)
                {
                    return push_fail(L, "timeout");
                }
            }

            if (is_tls)
            {
                int rc = tls_recv_some(s->ssl, buf.data(), buf.size(),
                                       tls_err);
                if (rc > 0)
                {
                    lua_pushlstring(L, buf.data(),
                                    static_cast<size_t>(rc));
                    return 1;
                }
                if (rc == TLS_IO_EOF)
                {
                    return push_fail(L, "closed");
                }
                if (rc == TLS_IO_WANT_READ)
                {
                    continue; // déjà attendu POLLIN, reboucle
                }
                if (rc == TLS_IO_WANT_WRITE)
                {
                    int wr = wait_ready_deadline(s->fd, POLLOUT, deadline);
                    if (wr == WAIT_INTERRUPTED)
                    {
                        signal_dispatch_pending(L);
                        return push_fail(L, "interrupted");
                    }
                    if (wr == 0)
                        return push_fail(L, "timeout");
                    if (wr < 0)
                        return push_errno_fail(L, "recv");
                    continue;
                }
                return push_fail(L, tls_err); // FATAL
            }

            // Branche TCP brut (inchangée).
            ssize_t got = ::recv(s->fd, buf.data(), buf.size(),
                                 recv_flags);
            if (got >= 0)
            {
                if (got == 0)
                {
                    return push_fail(L, "closed");
                }
                lua_pushlstring(L, buf.data(),
                                static_cast<size_t>(got));
                return 1;
            }
            if (errno == EINTR)
            {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK)
            {
                continue;
            }
            return push_errno_fail(L, "recv");
        }
    }

    // recv_line() : lit jusqu'à '\n' inclus dans le flux ; renvoie la
    // ligne SANS le '\n' final (et sans un éventuel '\r' juste avant,
    // pour gérer CRLF transparent côté script).
    //
    // EOF en plein milieu : (nil, "closed", partial). 3 valeurs
    // assumées ici (cf. SOCK-5) -- ne pas perdre les octets déjà lus.
    int sock_recv_line(lua_State *L)
    {
        Sock *s = check_sock(L, 1);
        if (s->fd < 0)
        {
            return push_fail(L, "socket: recv_line: socket is closed");
        }
        if (s->listening)
        {
            return push_fail(L,
                             "socket: recv_line: cannot recv on a listening socket");
        }

        // DEADLINE GLOBALE : la lecture ligne-par-ligne peut faire
        // beaucoup d'appels recv(1 byte). La deadline couvre TOUT
        // l'appel recv_line, pas chaque octet.
        //
        // TLS (sous-étape 1.3) : route via tls_recv_some quand s->ssl
        // est non-null. NB : SSL_read par-octet est inefficace (chaque
        // appel peut déchiffrer un nouveau record TLS interne), mais
        // OpenSSL bufferise en interne -- le surcoût reste raisonnable
        // pour des protocoles texte légers (IRC, SMTP).
        const bool is_tls = (s->ssl != nullptr);
        Deadline deadline = make_deadline(s->timeout_ms);

        // CORRECTIF (post-bug bot IRC) : reprendre les octets déjà
        // lus lors d'un timeout précédent. Si recv_line_pending est
        // vide (cas normal), acc démarre vide ; sinon on reprend
        // où on s'était arrêté. Le move + clear garantit qu'on ne
        // double-traite jamais les mêmes octets.
        std::string acc = std::move(s->recv_line_pending);
        s->recv_line_pending.clear();

        std::string tls_err;
        char c;
        for (;;)
        {
            // CORRECTIF (post-bug IRC TLS) : en TLS, OpenSSL lit un
            // record TLS entier depuis le socket d'un coup. Un record
            // peut contenir plusieurs lignes IRC. Les octets bruts
            // sont consommés du socket par OpenSSL et stockés dans
            // son buffer interne déchiffré. À ce moment-là, le FD
            // socket est VIDE — poll(POLLIN) renvoie 0 — alors qu'il
            // y a plein de données à lire via SSL_read.
            //
            // Sans cette vérification, recv_line() retournait
            // (nil, "timeout") en boucle pendant que les lignes
            // IRC dormaient dans le buffer OpenSSL. Symptôme typique :
            // un bot IRC se fait kicker pour ping timeout côté serveur
            // (~240 s), puis au moment où le serveur ferme la
            // connexion, plusieurs lignes en attente sortent d'un
            // coup au même timestamp.
            //
            // SSL_pending() retourne le nombre d'octets DÉJÀ déchiffrés
            // disponibles immédiatement. Si > 0, on saute l'attente
            // sur le FD et on lit directement.
            const bool ssl_has_data =
                is_tls && (SSL_pending(s->ssl) > 0);

            if (!ssl_has_data)
            {
                int r = wait_ready_deadline(s->fd, POLLIN, deadline);
                if (r == WAIT_INTERRUPTED)
                {
                    // Phase B signal : un signal géré est arrivé
                    // pendant l'attente. On conserve les octets
                    // déjà lus pour ne pas les perdre (même logique
                    // que timeout), on dispatche le callback Lua
                    // utilisateur, puis on remonte "interrupted".
                    s->recv_line_pending = std::move(acc);
                    signal_dispatch_pending(L);
                    return push_fail(L, "interrupted");
                }
                if (r < 0)
                {
                    // Erreur fatale : on conserve quand même les octets
                    // au cas où l'utilisateur ferait quelque chose
                    // d'intelligent ensuite. close() les libère via __gc.
                    s->recv_line_pending = std::move(acc);
                    return push_errno_fail(L, "recv_line");
                }
                if (r == 0)
                {
                    // CORRECTIF (1.3.2) : conserver les octets déjà
                    // lus pour le prochain recv_line. Sinon, scénario
                    // typique IRC avec set_timeout(1) : la ligne
                    // ":server NOTICE ..." commence à arriver, le ':'
                    // est lu dans acc, puis le réseau tarde quelques
                    // ms et le timeout se déclenche. SANS ce buffer,
                    // le ':' est jeté et l'appel suivant récupère
                    // "server NOTICE ..." sans son ':'.
                    s->recv_line_pending = std::move(acc);
                    return push_fail(L, "timeout");
                }
            }
            // Si ssl_has_data, on saute wait_ready_deadline et on lit
            // directement le buffer interne d'OpenSSL via SSL_read.

            ssize_t got = 0;
            if (is_tls)
            {
                int rc = tls_recv_some(s->ssl, &c, 1, tls_err);
                if (rc == TLS_IO_WANT_READ)
                {
                    continue;
                }
                if (rc == TLS_IO_WANT_WRITE)
                {
                    int wr = wait_ready_deadline(s->fd, POLLOUT, deadline);
                    if (wr == WAIT_INTERRUPTED)
                    {
                        s->recv_line_pending = std::move(acc);
                        signal_dispatch_pending(L);
                        return push_fail(L, "interrupted");
                    }
                    if (wr == 0)
                    {
                        // Idem : conserver acc.
                        s->recv_line_pending = std::move(acc);
                        return push_fail(L, "timeout");
                    }
                    if (wr < 0)
                    {
                        s->recv_line_pending = std::move(acc);
                        return push_errno_fail(L, "recv_line");
                    }
                    continue;
                }
                if (rc == TLS_IO_FATAL)
                {
                    // Erreur TLS fatale : on garde quand même.
                    s->recv_line_pending = std::move(acc);
                    return push_fail(L, tls_err);
                }
                got = (rc == TLS_IO_EOF) ? 0 : rc;
            }
            else
            {
                got = ::recv(s->fd, &c, 1, 0);
                if (got < 0)
                {
                    if (errno == EINTR)
                    {
                        continue;
                    }
                    s->recv_line_pending = std::move(acc);
                    return push_errno_fail(L, "recv_line");
                }
            }

            if (got == 0)
            {
                // EOF en plein milieu : 3 valeurs (nil, "closed", partial)
                // Pas de conservation du buffer ici : le contrat est
                // déjà documenté et le user récupère partial en main.
                lua_pushnil(L);
                lua_pushstring(L, "closed");
                lua_pushlstring(L, acc.data(), acc.size());
                return 3;
            }
            if (c == '\n')
            {
                // CRLF transparent : retire un \r final si présent.
                if (!acc.empty() && acc.back() == '\r')
                {
                    acc.pop_back();
                }
                lua_pushlstring(L, acc.data(), acc.size());
                return 1;
            }
            // Garde contre DoS : sans limite, un peer malveillant ou
            // un serveur buggué qui envoie un flux infini sans '\n'
            // ferait grossir `acc` jusqu'à OOM (cf. retour audit
            // sécurité). 8 MiB est large pour du texte (RFC IRC :
            // 512 octets max ; HTTP : pas de limite hard mais
            // typique < 8 KB), et donne une marge confortable pour
            // les usages applicatifs légitimes. Si un cas concret
            // demande plus, on ajoutera une option recv_line(max)
            // sous SemVer.
            //
            // On vide pending pour qu'un futur appel ne retombe pas
            // sur la même donnée empoisonnée — le contrat est que
            // "line too long" jette aussi les octets accumulés.
            constexpr size_t MAX_LINE_BYTES = 8 * 1024 * 1024;
            if (acc.size() >= MAX_LINE_BYTES)
            {
                s->recv_line_pending.clear();
                return push_fail(L, "line too long");
            }
            acc.push_back(c);
        }
    }

    // recv_all() : lit jusqu'à EOF du peer, accumule tout. Renvoie
    // (data, nil) -- même chaîne vide est un succès (peer ferme sans
    // rien envoyer). Timeout sur un read intermédiaire -> (nil,
    // "timeout"). Si on veut un comportement "lire ce qui est dispo
    // maintenant", utiliser recv(n) avec timeout court.
    int sock_recv_all(lua_State *L)
    {
        Sock *s = check_sock(L, 1);
        if (s->fd < 0)
        {
            return push_fail(L, "socket: recv_all: socket is closed");
        }
        if (s->listening)
        {
            return push_fail(L,
                             "socket: recv_all: cannot recv on a listening socket");
        }

        // DEADLINE GLOBALE : on lit jusqu'à EOF, donc potentiellement
        // beaucoup de chunks. La deadline couvre TOUT l'appel.
        //
        // TLS (sous-étape 1.3) : tls_recv_some par chunks 4 KB. EOF
        // est SSL_ERROR_ZERO_RETURN, signe que le serveur a envoyé
        // close_notify — c'est le succès attendu pour recv_all.
        const bool is_tls = (s->ssl != nullptr);
        Deadline deadline = make_deadline(s->timeout_ms);

        std::string acc;
        std::string tls_err;
        char buf[4096];
        for (;;)
        {
            // CORRECTIF (post-bug IRC TLS) : voir explication détaillée
            // dans sock_recv_line. Si OpenSSL a déjà déchiffré des octets
            // dans son buffer interne, le FD socket est vide alors qu'il
            // y a des données à lire.
            const bool ssl_has_data =
                is_tls && (SSL_pending(s->ssl) > 0);

            if (!ssl_has_data)
            {
                int r = wait_ready_deadline(s->fd, POLLIN, deadline);
                if (r == WAIT_INTERRUPTED)
                {
                    signal_dispatch_pending(L);
                    return push_fail(L, "interrupted");
                }
                if (r < 0)
                {
                    return push_errno_fail(L, "recv_all");
                }
                if (r == 0)
                {
                    return push_fail(L, "timeout");
                }
            }

            ssize_t got = 0;
            if (is_tls)
            {
                int rc = tls_recv_some(s->ssl, buf, sizeof(buf), tls_err);
                if (rc == TLS_IO_WANT_READ)
                {
                    continue;
                }
                if (rc == TLS_IO_WANT_WRITE)
                {
                    int wr = wait_ready_deadline(s->fd, POLLOUT, deadline);
                    if (wr == WAIT_INTERRUPTED)
                    {
                        signal_dispatch_pending(L);
                        return push_fail(L, "interrupted");
                    }
                    if (wr == 0)
                        return push_fail(L, "timeout");
                    if (wr < 0)
                        return push_errno_fail(L, "recv_all");
                    continue;
                }
                if (rc == TLS_IO_FATAL)
                {
                    return push_fail(L, tls_err);
                }
                got = (rc == TLS_IO_EOF) ? 0 : rc;
            }
            else
            {
                got = ::recv(s->fd, buf, sizeof(buf), 0);
                if (got < 0)
                {
                    if (errno == EINTR)
                    {
                        continue;
                    }
                    return push_errno_fail(L, "recv_all");
                }
            }

            if (got == 0)
            {
                // EOF normal sur recv_all : c'est le SUCCÈS attendu.
                lua_pushlstring(L, acc.data(), acc.size());
                return 1;
            }
            acc.append(buf, static_cast<size_t>(got));
        }
    }

    // accept() : accepte une connexion entrante sur un socket
    // d'écoute. Renvoie un userdata socket connecté.
    int sock_accept(lua_State *L)
    {
        Sock *s = check_sock(L, 1);
        if (s->fd < 0)
        {
            return push_fail(L, "socket: accept: socket is closed");
        }
        if (!s->listening)
        {
            return push_fail(L,
                             "socket: accept: socket is not listening");
        }

        // DEADLINE GLOBALE : accept() bloque jusqu'à arrivée d'un
        // client. Si EINTR au milieu, on reboucle avec le temps
        // restant, jamais infini.
        Deadline deadline = make_deadline(s->timeout_ms);

        int r = wait_ready_deadline(s->fd, POLLIN, deadline);
        if (r == WAIT_INTERRUPTED)
        {
            signal_dispatch_pending(L);
            return push_fail(L, "interrupted");
        }
        if (r < 0)
        {
            return push_errno_fail(L, "accept");
        }
        if (r == 0)
        {
            return push_fail(L, "timeout");
        }

        int client_fd;
        for (;;)
        {
            // accept4 + SOCK_CLOEXEC : atomique, pas de fenêtre où
            // le FD pourrait fuiter vers un fork+exec concurrent.
            // Si accept4 n'est pas dispo (système très ancien), un
            // fallback ::accept + ensure_cloexec serait nécessaire ;
            // sur Linux moderne et FreeBSD, accept4 est garanti.
            client_fd = ::accept4(s->fd, nullptr, nullptr,
                                  SOCK_CLOEXEC);
            if (client_fd >= 0)
            {
                ensure_cloexec(client_fd); // ceinture + bretelles
                break;
            }
            if (errno == EINTR)
            {
                // Refaire un wait_ready : on a perdu du temps, on
                // doit re-vérifier que la deadline n'est pas dépassée
                // ET attendre à nouveau qu'un client se présente
                // (le précédent connect() peut ne plus être là).
                int r2 = wait_ready_deadline(s->fd, POLLIN, deadline);
                if (r2 == WAIT_INTERRUPTED)
                {
                    signal_dispatch_pending(L);
                    return push_fail(L, "interrupted");
                }
                if (r2 < 0)
                {
                    return push_errno_fail(L, "accept");
                }
                if (r2 == 0)
                {
                    return push_fail(L, "timeout");
                }
                continue;
            }
            return push_errno_fail(L, "accept");
        }
        push_new_sock(L, client_fd, false);
        return 1;
    }

    int sock_close(lua_State *L)
    {
        Sock *s = check_sock(L, 1);
        // TLS d'abord (close_notify best-effort), puis FD sous-jacent.
        // tls_close gère le cas nullptr et nettoie aussi la pile ERR.
        if (s->ssl != nullptr)
        {
            tls_close(s->ssl);
            s->ssl = nullptr;
        }
        if (s->fd >= 0)
        {
            ::close(s->fd);
            s->fd = -1;
        }
        return push_ok(L);
    }

    int sock_set_timeout(lua_State *L)
    {
        Sock *s = check_sock(L, 1);
        lua_Number t = luaL_checknumber(L, 2);
        // CORRECTIF (post-revue ChatGPT) : rejeter NaN et inf avant
        // tout cast vers int (sinon comportement indéfini). std::isnan
        // détecte NaN, std::isfinite refuse +inf et -inf (et accepte
        // 0 et toutes les valeurs finies).
        if (std::isnan(t) || !std::isfinite(t))
        {
            return push_fail(L,
                             "socket: set_timeout: value must be finite "
                             "(not NaN or inf)");
        }
        if (t < 0.0)
        {
            return push_fail(L,
                             "socket: set_timeout: value must be >= 0 (0 disables)");
        }
        // t = 0 -> timeout_ms = 0 -> bloquant infini (cf. make_deadline).
        // sinon : conversion secondes -> millisecondes, plancher 1 ms
        // pour éviter qu'un timeout positif arrondi à 0 ne désactive
        // silencieusement le timeout (même piège qu'avec set_max_timeout
        // côté http). Plafond INT_MAX ms (~24 jours) pour éviter le
        // débordement du cast en int.
        if (t == 0.0)
        {
            s->timeout_ms = 0;
        }
        else
        {
            double ms = t * 1000.0;
            if (ms > static_cast<double>(INT_MAX))
            {
                return push_fail(L,
                                 "socket: set_timeout: value too large");
            }
            s->timeout_ms = (ms < 1.0) ? 1 : static_cast<int>(ms);
        }
        return push_ok(L);
    }

    // peer() / sockname() : renvoie une table { host, port }.
    int push_addr_table(lua_State *L, const struct sockaddr *sa,
                        socklen_t salen)
    {
        char host[NI_MAXHOST];
        char port[NI_MAXSERV];
        int rc = ::getnameinfo(sa, salen, host, sizeof(host),
                               port, sizeof(port),
                               NI_NUMERICHOST | NI_NUMERICSERV);
        if (rc != 0)
        {
            std::string msg = "socket: getnameinfo: ";
            msg += ::gai_strerror(rc);
            return push_fail(L, msg);
        }
        lua_newtable(L);
        lua_pushstring(L, host);
        lua_setfield(L, -2, "host");
        lua_pushinteger(L, static_cast<lua_Integer>(std::atoi(port)));
        lua_setfield(L, -2, "port");
        return 1;
    }

    int sock_peer(lua_State *L)
    {
        Sock *s = check_sock(L, 1);
        if (s->fd < 0)
        {
            return push_fail(L, "socket: peer: socket is closed");
        }
        struct sockaddr_storage ss;
        socklen_t slen = sizeof(ss);
        if (::getpeername(s->fd,
                          reinterpret_cast<struct sockaddr *>(&ss),
                          &slen) != 0)
        {
            return push_errno_fail(L, "peer");
        }
        return push_addr_table(L,
                               reinterpret_cast<struct sockaddr *>(&ss), slen);
    }

    int sock_sockname(lua_State *L)
    {
        Sock *s = check_sock(L, 1);
        if (s->fd < 0)
        {
            return push_fail(L, "socket: sockname: socket is closed");
        }
        struct sockaddr_storage ss;
        socklen_t slen = sizeof(ss);
        if (::getsockname(s->fd,
                          reinterpret_cast<struct sockaddr *>(&ss),
                          &slen) != 0)
        {
            return push_errno_fail(L, "sockname");
        }
        return push_addr_table(L,
                               reinterpret_cast<struct sockaddr *>(&ss), slen);
    }

    // __gc : filet de sécurité. Si l'utilisateur a oublié :close(),
    // on ferme à la collecte de l'userdata. Pas de fuite de FD ni de SSL.
    // CORRECTIF (placement new) : on appelle aussi explicitement le
    // destructeur du Sock, car push_new_sock utilise placement new
    // pour initialiser le std::string recv_line_pending.
    int sock_gc(lua_State *L)
    {
        Sock *s = static_cast<Sock *>(
            luaL_testudata(L, 1, SOCK_META));
        if (s)
        {
            if (s->ssl != nullptr)
            {
                tls_close(s->ssl);
                s->ssl = nullptr;
            }
            if (s->fd >= 0)
            {
                ::close(s->fd);
                s->fd = -1;
            }
            s->~Sock(); // libère recv_line_pending
        }
        return 0;
    }

    // __tostring : utile pour debug et inspection.
    int sock_tostring(lua_State *L)
    {
        Sock *s = check_sock(L, 1);
        char buf[64];
        if (s->fd < 0)
        {
            std::snprintf(buf, sizeof(buf), "socket (closed)");
        }
        else
        {
            std::snprintf(buf, sizeof(buf),
                          "socket (%s, fd=%d)",
                          s->listening ? "listening" : "stream", s->fd);
        }
        lua_pushstring(L, buf);
        return 1;
    }

} // namespace

namespace
{
    // Helper interne factorisé (sous-étape 1.2) : effectue un TCP
    // connect avec deadline GLOBALE. Renvoie le FD connecté ou -1.
    // En cas d'erreur :
    //   - `timed_out` mis à true si la deadline a expiré
    //   - `err == "interrupted"` si un signal géré est arrivé (le
    //     caller dispatche le callback puis renvoie (nil, err))
    //   - sinon `err` contient un message lisible
    //
    // CORRECTIF (audit v21, option A validée) : chemin UNIFIÉ.
    //
    // 1. La deadline est créée UNE FOIS, avant la boucle d'addrinfo.
    //    L'ancienne version la recréait à CHAQUE tentative :
    //    connect(host, port, 5) sur un host multi-A/AAAA pouvait
    //    durer N × 5 s au total (ex : IPv6 trou noir qui échoue par
    //    SO_ERROR à 4,9 s → la deadline repartait à zéro pour
    //    l'IPv4). timeout = 5 signifie désormais 5 s pour l'appel
    //    COMPLET, toutes adresses confondues — cohérent avec
    //    send/recv, qui créent leur deadline une fois.
    //
    // 2. Le connect passe TOUJOURS par O_NONBLOCK + poll, y compris
    //    sans timeout (deadline = NO_DEADLINE → poll infini).
    //    L'ancien chemin bloquant (timeout_ms == 0) faisait un
    //    connect() kernel : un EINTR de signal géré (handlers babet
    //    installés SANS SA_RESTART) était traité comme une erreur
    //    ordinaire — close, adresse suivante, et au final
    //    (nil, "socket: connect: Interrupted system call"), sans
    //    dispatch. Via wait_ready_deadline, l'interruption devient
    //    (nil, "interrupted") + dispatch du callback, identique à
    //    recv/send/accept. (poll(2) n'est jamais redémarré par
    //    SA_RESTART, donc l'interruption est fiable dans tous les
    //    cas.)
    //
    // Réutilisé par lua_socket_connect (TCP brut) et
    // lua_socket_connect_tls (avant le handshake TLS).
    int tcp_connect_blocking(const char *host, lua_Integer port,
                             int timeout_ms,
                             std::string &err, bool &timed_out)
    {
        timed_out = false;

        char port_str[16];
        std::snprintf(port_str, sizeof(port_str), "%lld",
                      static_cast<long long>(port));

        struct addrinfo *res = resolve(host, port_str, false, err);
        if (!res)
        {
            return -1;
        }

        // Deadline GLOBALE : une seule pour toutes les tentatives.
        // NO_DEADLINE (poll infini) si timeout_ms == 0.
        Deadline deadline = make_deadline(timeout_ms);

        // Essaie chaque addrinfo dans l'ordre (IPv4/IPv6 selon DNS).
        int fd = -1;
        int last_errno = 0;
        for (struct addrinfo *ai = res; ai != nullptr; ai = ai->ai_next)
        {
            // SOCK_CLOEXEC dans le type : atomique, jamais hérité par
            // un fork+exec concurrent (cf. ensure_cloexec).
            fd = ::socket(ai->ai_family,
                          ai->ai_socktype | SOCK_CLOEXEC,
                          ai->ai_protocol);
            if (fd < 0)
            {
                last_errno = errno;
                continue;
            }
            ensure_cloexec(fd); // belt + suspenders

            // Non-bloquant SYSTÉMATIQUE le temps du connect (remis
            // bloquant en cas de succès). Si fcntl échoue (quasi
            // impossible), on ne peut pas garantir le pattern : on
            // abandonne cette adresse plutôt que de risquer un
            // connect kernel bloquant non maîtrisé.
            int flags = ::fcntl(fd, F_GETFL, 0);
            if (flags < 0 ||
                ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0)
            {
                last_errno = errno;
                ::close(fd);
                fd = -1;
                continue;
            }

            int rc = ::connect(fd, ai->ai_addr, ai->ai_addrlen);
            if (rc == 0)
            {
                // Connecté direct (loopback typique) : remettre
                // bloquant. CORRECTIF (revue ChatGPT, ajusté) : si la
                // restauration échoue (quasi impossible), le socket
                // resterait silencieusement non-bloquant alors que ses
                // méthodes supposent le mode bloquant sans timeout —
                // on préfère abandonner cette adresse proprement.
                if (::fcntl(fd, F_SETFL, flags) < 0)
                {
                    last_errno = errno;
                    ::close(fd);
                    fd = -1;
                    continue;
                }
                break;
            }
            // CORRECTIF (revue ChatGPT, sémantique CORRIGÉE) : un
            // EINTR de connect() est traité comme EINPROGRESS, pas
            // comme une erreur. POSIX : « si connect() est interrompu
            // par un signal, la connexion est établie de façon
            // asynchrone » — la suite correcte est d'attendre POLLOUT
            // (où l'interruption par signal géré est déjà rendue
            // proprement en "interrupted" via wait_ready_deadline),
            // PAS de fermer le FD. Sur Linux un connect NON-BLOQUANT
            // ne rend pas EINTR ; ce traitement est une robustesse
            // portable. NB : la revue proposait de rendre
            // "interrupted" ici — c'était incorrect : la tentative
            // continue en arrière-plan, l'abandonner casserait des
            // connects légitimes.
            if (errno != EINPROGRESS && errno != EINTR)
            {
                // Échec immédiat (réseau inaccessible, refus
                // synchrone…) : adresse suivante — la deadline
                // globale continue de courir.
                last_errno = errno;
                ::close(fd);
                fd = -1;
                continue;
            }
            // En cours, attendre POLLOUT sous la deadline GLOBALE.
            int wr = wait_ready_deadline(fd, POLLOUT, deadline);
            if (wr == WAIT_INTERRUPTED)
            {
                // Phase B signal : on signale via err (le caller
                // distingue "interrupted" de "timed out"). On ne
                // tente PAS les autres addrinfo : si l'utilisateur
                // a demandé l'arrêt, on s'arrête.
                err = "interrupted";
                ::close(fd);
                fd = -1;
                break;
            }
            if (wr == 0)
            {
                // Deadline globale expirée : inutile d'essayer les
                // autres addrinfo, elles n'auraient plus aucun
                // budget.
                timed_out = true;
                ::close(fd);
                fd = -1;
                break;
            }
            if (wr < 0)
            {
                last_errno = errno;
                ::close(fd);
                fd = -1;
                continue;
            }
            // Récupérer le statut réel de connect via SO_ERROR
            int soerr = 0;
            socklen_t slen = sizeof(soerr);
            if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen) < 0 || soerr != 0)
            {
                last_errno = (soerr != 0) ? soerr : errno;
                ::close(fd);
                fd = -1;
                continue;
            }
            // Succès : remettre bloquant. Même garde que le connect
            // direct ci-dessus : une restauration échouée rendrait un
            // socket silencieusement non-bloquant.
            if (::fcntl(fd, F_SETFL, flags) < 0)
            {
                last_errno = errno;
                ::close(fd);
                fd = -1;
                continue;
            }
            break;
        }
        ::freeaddrinfo(res);

        if (fd < 0 && !timed_out && err.empty())
        {
            err = "socket: connect: ";
            err += std::strerror(last_errno);
        }
        return fd;
    }

    // Parse + valide timeout en secondes depuis la stack Lua à l'index
    // donné (pour les fonctions qui prennent un timeout positionnel).
    // Renvoie true en succès. En cas d'invalidité, remplit err et
    // renvoie false. Si l'argument est absent/nil, *out reste 0 (=
    // bloquant infini).
    bool parse_positional_timeout(lua_State *L, int idx, int *out,
                                  std::string &err,
                                  const char *prefix_for_err)
    {
        *out = 0;
        if (lua_isnoneornil(L, idx))
        {
            return true;
        }
        // CORRECTIF longjmp (post-revue Gemini) : luaL_checknumber
        // utiliserait longjmp() si l'argument n'est pas un nombre,
        // ce qui ne déroulerait PAS le std::string err alloué par
        // l'appelant (lua_socket_connect). On vérifie le type
        // manuellement et on remonte via la convention (false, err)
        // que la fonction signe déjà.
        if (lua_type(L, idx) != LUA_TNUMBER)
        {
            err = prefix_for_err;
            err += ": timeout must be a number";
            return false;
        }
        lua_Number t = lua_tonumber(L, idx);
        if (std::isnan(t) || !std::isfinite(t))
        {
            err = prefix_for_err;
            err += ": timeout must be finite (not NaN or inf)";
            return false;
        }
        if (t < 0.0)
        {
            err = prefix_for_err;
            err += ": timeout must be >= 0";
            return false;
        }
        if (t > 0.0)
        {
            double ms = t * 1000.0;
            if (ms > static_cast<double>(INT_MAX))
            {
                err = prefix_for_err;
                err += ": timeout too large";
                return false;
            }
            *out = (ms < 1.0) ? 1 : static_cast<int>(ms);
        }
        return true;
    }
} // namespace

// -----------------------------------------------------------------------
// Fonctions publiques de babet.socket
// -----------------------------------------------------------------------

// babet.socket.connect(host, port [, timeout]) -> socket | (nil, err)
//
// timeout en SECONDES (float), s'applique à la phase de connexion
// uniquement ici ; pour les opérations suivantes, l'utilisateur peut
// appeler s:set_timeout(s) sur le socket retourné.
int lua_socket_connect(lua_State *L)
{
    const char *host = luaL_checkstring(L, 1);
    lua_Integer port = luaL_checkinteger(L, 2);
    if (port < 0 || port > 65535)
    {
        return push_fail(L,
                         "socket: connect: port must be in [0, 65535]");
    }

    int timeout_ms = 0;
    std::string err;
    if (!parse_positional_timeout(L, 3, &timeout_ms, err,
                                  "socket: connect"))
    {
        return push_fail(L, err);
    }

    bool timed_out = false;
    int fd = tcp_connect_blocking(host, port, timeout_ms, err, timed_out);
    if (fd < 0)
    {
        if (timed_out)
        {
            return push_fail(L, "timeout");
        }
        if (err == "interrupted")
        {
            // Phase B signal : dispatcher le callback Lua ici
            // (tcp_connect_blocking n'a pas accès à L).
            signal_dispatch_pending(L);
        }
        return push_fail(L, err);
    }
    push_new_sock(L, fd, false);
    return 1;
}

// babet.socket.connect_tls(host, port [, opts]) -> socket | (nil, err)
//
// Variante TLS de connect. opts table (toutes optionnelles) :
//   timeout      : secondes (float), bloquant infini si absent ou 0
//   verify       : boolean, défaut true (vérification stricte chaîne+hostname)
//   ca_cert      : string, chemin vers un fichier PEM (CA spécifique)
//   ca_path      : string, chemin vers un dossier de CAs
//   hostname     : string, override du hostname check + SNI (défaut = host)
//   min_version  : string, "1.2" (défaut) ou "1.3"
//
// Comportement :
//   1. TCP connect (réutilise tcp_connect_blocking).
//   2. Création SSL* sur le fd, application des options.
//   3. SSL_connect() avec poll + deadline globale.
//   4. Si verify ON, échec cert -> message lisible via SSL_get_verify_result.
//
// Le socket retourné est un Sock complet (méthodes send/recv/etc.
// fonctionneront en TLS après la sous-étape 1.3).
int lua_socket_connect_tls(lua_State *L)
{
    const char *host = luaL_checkstring(L, 1);
    lua_Integer port = luaL_checkinteger(L, 2);
    if (port < 0 || port > 65535)
    {
        return push_fail(L,
                         "socket: connect_tls: port must be in [0, 65535]");
    }

    std::string err;
    TlsOptions opts;
    if (!parse_tls_options(L, 3, opts, err))
    {
        return push_fail(L, err);
    }

    // Init OpenSSL CTX en lazy au premier appel.
    if (!init_openssl_ctx(err))
    {
        return push_fail(L, err);
    }

    // Phase 1 : TCP connect (réutilise le helper).
    bool timed_out = false;
    int fd = tcp_connect_blocking(host, port, opts.timeout_ms,
                                  err, timed_out);
    if (fd < 0)
    {
        if (timed_out)
        {
            return push_fail(L, "timeout");
        }
        if (err == "interrupted")
        {
            // Phase B signal : voir sock_connect.
            signal_dispatch_pending(L);
        }
        return push_fail(L, err);
    }

    // Phase 2 : créer SSL et l'attacher au fd.
    SSL *ssl = SSL_new(g_tls_ctx);
    if (ssl == nullptr)
    {
        ::close(fd);
        return push_fail(L, format_tls_error("SSL_new failed"));
    }
    if (SSL_set_fd(ssl, fd) != 1)
    {
        SSL_free(ssl);
        ::close(fd);
        return push_fail(L, format_tls_error("SSL_set_fd failed"));
    }

    // Phase 3 : appliquer les options (verify, hostname, CA, version).
    if (!apply_tls_options(ssl, opts, host, err))
    {
        SSL_free(ssl);
        ::close(fd);
        return push_fail(L, err);
    }

    // Phase 4 : passer en non-bloquant pour le handshake, et GARDER
    // le FD en non-bloquant après le succès. C'est crucial pour que
    // les opérations TLS suivantes (SSL_read/SSL_write via les
    // méthodes send/recv) respectent réellement la deadline globale :
    // sans ça, poll() pouvait dire "prêt" puis SSL_read/SSL_write
    // bloquait dans le noyau au-delà du timeout. Avec O_NONBLOCK
    // permanent + la boucle WANT_READ/WANT_WRITE dans tls_send_some/
    // tls_recv_some, la deadline est garantie.
    //
    // Pattern standard côté curl/nginx/etc. : une fois en TLS, on
    // pilote tout via SSL_get_error et poll, le FD ne sert plus
    // jamais directement à l'utilisateur.
    //
    // En cas d'ÉCHEC handshake, on remet bloquant avant de fermer
    // (cohérence : le FD reste bloquant si jamais quelqu'un le voyait
    // dans un état intermédiaire avant ::close).
    // CORRECTIF (revue ChatGPT post-audit v21) : si fcntl échoue
    // (quasi impossible), le handshake tournerait sur un FD BLOQUANT
    // et la deadline ne serait plus garantie — on échoue franchement
    // plutôt que de dégrader silencieusement le contrat.
    int flags = ::fcntl(fd, F_GETFL, 0);
    if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0)
    {
        int e = errno;
        SSL_free(ssl);
        ::close(fd);
        return push_fail(L, std::string("socket: connect_tls: fcntl: ") +
                                std::strerror(e));
    }
    bool hs_ok = tls_handshake(ssl, fd, opts.timeout_ms, err);
    if (!hs_ok)
    {
        if (flags >= 0)
        {
            ::fcntl(fd, F_SETFL, flags); // remettre bloquant avant close
        }
        SSL_free(ssl);
        ::close(fd);
        if (err == "interrupted")
        {
            signal_dispatch_pending(L);
        }
        return push_fail(L, err);
    }
    // Succès : NE PAS remettre bloquant. Le FD reste O_NONBLOCK pour
    // toute la vie du socket TLS (cf. note ci-dessus).

    // Succès : créer userdata Sock avec ssl attaché.
    Sock *s = push_new_sock(L, fd, false);
    s->ssl = ssl;
    return 1;
}

// Méthode s:starttls([opts]) -> (true, nil) | (nil, err)
//
// Pose une couche TLS sur un socket TCP existant connecté. Cas
// d'usage : SMTP STARTTLS, IMAP STARTTLS, IRC sur port plaintext avec
// extension CAP STARTTLS, etc.
//
// Préconditions :
//   - s->fd != -1 (socket ouvert)
//   - s->listening == false (pas un socket d'écoute)
//   - s->ssl == nullptr (pas déjà en TLS)
//
// Options identiques à connect_tls. ATTENTION sur opts.hostname :
// comme starttls() n'a pas reçu de `host` (le socket vient d'un
// connect par IP ou hostname antérieur), il faut le passer explicitement
// quand verify=true.
//
// Politique stricte (TLS-C "verify par défaut") : refus dur si
// verify=true et opts.hostname vide, avec message guidé. Pas de
// chemin silencieux "chaîne sans hostname check" — c'est une
// demi-mesure de sécurité qu'on ne propose pas. Si l'utilisateur
// veut explicitement zapper la vérif (test, peer auto-signé), il
// passe verify=false.
int sock_starttls(lua_State *L)
{
    Sock *s = check_sock(L, 1);
    if (s->fd < 0)
    {
        return push_fail(L, "socket: starttls: socket is closed");
    }
    if (s->listening)
    {
        return push_fail(L,
                         "socket: starttls: cannot start TLS on a listening socket");
    }
    if (s->ssl != nullptr)
    {
        return push_fail(L,
                         "socket: starttls: TLS already active on this socket");
    }

    std::string err;
    TlsOptions opts;
    if (!parse_tls_options(L, 2, opts, err))
    {
        return push_fail(L, err);
    }

    // CORRECTIF (post-revue ChatGPT) : "verify strict par défaut"
    // (TLS-C) signifie chaîne + hostname. starttls n'a pas de host
    // par défaut comme connect_tls (qui utilise son argument host).
    // Donc si verify=true et hostname vide, le hostname check serait
    // SAUTÉ silencieusement — c'est une demi-mesure de sécurité qui
    // contredit "strict par défaut". On REFUSE explicitement, avec un
    // message qui guide vers les deux choix corrects : passer hostname,
    // ou opt-out explicite via verify=false.
    if (opts.verify && opts.hostname.empty())
    {
        return push_fail(L,
                         "tls: starttls with verify=true requires opts.hostname; "
                         "pass hostname or set verify=false");
    }

    if (!init_openssl_ctx(err))
    {
        return push_fail(L, err);
    }

    SSL *ssl = SSL_new(g_tls_ctx);
    if (ssl == nullptr)
    {
        return push_fail(L, format_tls_error("SSL_new failed"));
    }
    if (SSL_set_fd(ssl, s->fd) != 1)
    {
        SSL_free(ssl);
        return push_fail(L, format_tls_error("SSL_set_fd failed"));
    }

    // host_default = nullptr ici : starttls n'a pas reçu de host. Si
    // opts.hostname est vide, on est en mode verify=false (vérifié
    // au-dessus), donc le hostname check ne s'applique pas. Sinon
    // opts.hostname est passé à apply_tls_options qui posera
    // SSL_set1_host + SNI dessus.
    if (!apply_tls_options(ssl, opts, nullptr, err))
    {
        SSL_free(ssl);
        return push_fail(L, err);
    }

    // CORRECTIF (post-revue ChatGPT, parallèle de connect_tls) :
    // garder le FD en O_NONBLOCK après le handshake pour que les
    // SSL_read/SSL_write ultérieurs respectent réellement la deadline
    // globale. cf. note détaillée dans connect_tls.
    // CORRECTIF (revue ChatGPT post-audit v21) : si fcntl échoue ici
    // (quasi impossible), on n'a RIEN modifié — le socket reste
    // bloquant et utilisable en clair, on échoue proprement sans le
    // toucher.
    int flags = ::fcntl(s->fd, F_GETFL, 0);
    if (flags < 0 || ::fcntl(s->fd, F_SETFL, flags | O_NONBLOCK) < 0)
    {
        int e = errno;
        SSL_free(ssl);
        return push_fail(L, std::string("socket: starttls: fcntl: ") +
                                std::strerror(e));
    }
    bool hs_ok = tls_handshake(ssl, s->fd, s->timeout_ms, err);
    if (!hs_ok)
    {
        // CORRECTIF (revue ChatGPT post-audit v21) : le contrat après
        // un échec de starttls est « socket rendu tel quel, bloquant,
        // toujours ouvert ». Si la remise en bloquant échoue (quasi
        // impossible), ce contrat n'est plus garantissable : le
        // script continuerait avec un socket silencieusement
        // NON-BLOQUANT (recv rendrait EAGAIN). Dans ce cas on ferme
        // le socket et on le dit dans l'erreur — un état sûr et
        // explicite vaut mieux qu'un état plausible et faux.
        // Dispatch AVANT d'éventuellement suffixer err : le test
        // d'égalité stricte doit voir "interrupted" nu.
        if (err == "interrupted")
        {
            signal_dispatch_pending(L);
        }
        if (::fcntl(s->fd, F_SETFL, flags) < 0)
        {
            ::close(s->fd);
            s->fd = -1;
            err += " (socket closed: could not restore blocking mode)";
        }
        SSL_free(ssl);
        return push_fail(L, err);
    }
    // Succès : NE PAS remettre bloquant. FD reste O_NONBLOCK pour
    // toute la vie du socket TLS.

    // Succès : attacher le ssl au Sock existant (transformation
    // en place). À partir de maintenant, send/recv/... iront via
    // SSL_read/SSL_write (sous-étape 1.3).
    s->ssl = ssl;
    return push_ok(L);
}

// babet.socket.listen(host, port [, backlog]) -> socket | (nil, err)
//
// Fait socket + setsockopt(SO_REUSEADDR) + bind + listen en une
// opération (API haute, décision SOCK-2). host peut être "" pour
// "toutes les interfaces" (AI_PASSIVE prend le relais).
int lua_socket_listen(lua_State *L)
{
    const char *host = luaL_checkstring(L, 1);
    lua_Integer port = luaL_checkinteger(L, 2);
    if (port < 0 || port > 65535)
    {
        return push_fail(L,
                         "socket: listen: port must be in [0, 65535]");
    }
    int backlog = 16;
    if (!lua_isnoneornil(L, 3))
    {
        lua_Integer b = luaL_checkinteger(L, 3);
        if (b <= 0)
        {
            return push_fail(L,
                             "socket: listen: backlog must be > 0");
        }
        backlog = static_cast<int>(b);
    }

    char port_str[16];
    std::snprintf(port_str, sizeof(port_str), "%lld",
                  static_cast<long long>(port));

    std::string err;
    struct addrinfo *res = resolve(host, port_str, true, err);
    if (!res)
    {
        return push_fail(L, err);
    }

    int fd = -1;
    int last_errno = 0;
    for (struct addrinfo *ai = res; ai != nullptr; ai = ai->ai_next)
    {
        // SOCK_CLOEXEC : voir note dans lua_socket_connect. C'est
        // CRITIQUE pour un socket d'écoute : sans ça, un Ctrl+C sur
        // le parent laisserait le port bloqué si un sous-processus
        // de babet.exec est encore vivant et a hérité du FD.
        fd = ::socket(ai->ai_family,
                      ai->ai_socktype | SOCK_CLOEXEC,
                      ai->ai_protocol);
        if (fd < 0)
        {
            last_errno = errno;
            continue;
        }
        ensure_cloexec(fd); // belt + suspenders
        // SO_REUSEADDR : activé en interne, non exposé. Doit être posé
        // AVANT bind() pour avoir effet.
        if (!enable_reuseaddr(fd))
        {
            last_errno = errno;
            ::close(fd);
            fd = -1;
            continue;
        }
        if (::bind(fd, ai->ai_addr, ai->ai_addrlen) != 0)
        {
            last_errno = errno;
            ::close(fd);
            fd = -1;
            continue;
        }
        if (::listen(fd, backlog) != 0)
        {
            last_errno = errno;
            ::close(fd);
            fd = -1;
            continue;
        }
        break;
    }
    ::freeaddrinfo(res);

    if (fd < 0)
    {
        std::string msg = "socket: listen: ";
        msg += std::strerror(last_errno);
        return push_fail(L, msg);
    }
    push_new_sock(L, fd, true);
    return 1;
}

void register_socket(lua_State *L)
{
    // 1. Pose la métatable LuapilotSocket dans le registry si pas
    //    déjà fait. luaL_newmetatable laisse la mt au sommet.
    if (luaL_newmetatable(L, SOCK_META))
    {
        // Méthodes via __index = même table
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");

        // __gc : filet anti-fuite (décision SOCK-3)
        lua_pushcfunction(L, sock_gc);
        lua_setfield(L, -2, "__gc");

        lua_pushcfunction(L, sock_tostring);
        lua_setfield(L, -2, "__tostring");

        lua_pushcfunction(L, sock_send);
        lua_setfield(L, -2, "send");
        lua_pushcfunction(L, sock_recv);
        lua_setfield(L, -2, "recv");
        lua_pushcfunction(L, sock_recv_line);
        lua_setfield(L, -2, "recv_line");
        lua_pushcfunction(L, sock_recv_all);
        lua_setfield(L, -2, "recv_all");
        lua_pushcfunction(L, sock_accept);
        lua_setfield(L, -2, "accept");
        lua_pushcfunction(L, sock_close);
        lua_setfield(L, -2, "close");
        lua_pushcfunction(L, sock_set_timeout);
        lua_setfield(L, -2, "set_timeout");
        lua_pushcfunction(L, sock_peer);
        lua_setfield(L, -2, "peer");
        lua_pushcfunction(L, sock_sockname);
        lua_setfield(L, -2, "sockname");
        // TLS (Chantier 7) : starttls élève un socket TCP en TLS sur place.
        lua_pushcfunction(L, sock_starttls);
        lua_setfield(L, -2, "starttls");
    }
    lua_pop(L, 1); // dépile la métatable, la table babet redevient au sommet

    // 2. Crée et attache la sous-table babet.socket.
    //    Précondition : table babet au sommet (-1).
    lua_newtable(L);

    lua_pushcfunction(L, lua_socket_connect);
    lua_setfield(L, -2, "connect");
    lua_pushcfunction(L, lua_socket_listen);
    lua_setfield(L, -2, "listen");
    // TLS (Chantier 7) : connect_tls = variante TLS de connect.
    // Cohérent avec TLS-1 (pas de sous-module séparé).
    lua_pushcfunction(L, lua_socket_connect_tls);
    lua_setfield(L, -2, "connect_tls");

    lua_setfield(L, -2, "socket");
}
