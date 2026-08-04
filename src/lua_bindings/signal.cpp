// =====================================================================
#include "lua_utils.hpp"
// signal.cpp — implémentation des bindings signaux POSIX
// =====================================================================
// Voir signal.hpp pour le design global et les invariants de sécurité.

#include "signal.hpp"

extern "C"
{
#include "lua.h"
#include "lauxlib.h"
}

#include <signal.h>
#include <cstring>
#include <string.h>
#include <errno.h>
#include <pthread.h>

namespace
{

    // ============================================================
    // Restriction au thread principal
    // ============================================================
    //
    // Les handlers de signaux POSIX sont **process-wide**, jamais
    // thread-wide. Si un worker installe un handler via sigaction(),
    // celui-ci s'applique à tout le process — mais le callback Lua
    // qu'on stocke dans la registry est dans le state du worker.
    // Comme les workers ont pthread_sigmask(SIG_BLOCK) sur tous les
    // signaux supportés (cf. workers.cpp), le signal est délivré au
    // main thread, qui n'a pas le callback du worker. Résultat : le
    // callback ne se déclenche jamais. Bug latent silencieux.
    //
    // Solution : refuser handle/ignore/default depuis tout autre
    // thread que le principal. main.cpp doit appeler
    // register_main_thread() au tout début, avant le register_signal
    // ou le spawn de workers.

    pthread_t g_main_thread{};
    bool g_main_thread_set = false;

    bool is_main_thread()
    {
        // Avant l'appel à register_main_thread, on accepte par
        // défaut (cas du démarrage). Ce point est rendu sûr par
        // le fait que workers.cpp n'est utilisable qu'après le
        // register_signal (et donc après que main.cpp ait appelé
        // register_main_thread).
        if (!g_main_thread_set)
            return true;
        return pthread_equal(pthread_self(), g_main_thread) != 0;
    }

    int check_main_thread(lua_State *L, const char *fn_name)
    {
        if (!is_main_thread())
        {
            return luaL_error(L,
                              "signal.%s: signal handlers can only be configured "
                              "from the main thread, not from a worker",
                              fn_name);
        }
        return 0;
    }

    // ============================================================
    // Liste blanche des signaux supportés
    // ============================================================
    //
    // Toute extension future de cette liste doit s'accompagner d'une
    // mise à jour de la doc dans signal.hpp ET d'un audit de
    // workers.cpp (qui bloque ces signaux dans chaque worker).

    struct SignalMapping
    {
        const char *name;
        int signum;
    };

    const SignalMapping SUPPORTED_SIGNALS[] = {
        {"TERM", SIGTERM},
        {"INT", SIGINT},
        {"HUP", SIGHUP},
        {"USR1", SIGUSR1},
        {"USR2", SIGUSR2},
        {"PIPE", SIGPIPE},
    };
    const size_t NUM_SUPPORTED =
        sizeof(SUPPORTED_SIGNALS) / sizeof(SUPPORTED_SIGNALS[0]);

    int signum_from_name(const char *name)
    {
        for (size_t i = 0; i < NUM_SUPPORTED; ++i)
        {
            if (strcmp(SUPPORTED_SIGNALS[i].name, name) == 0)
            {
                return SUPPORTED_SIGNALS[i].signum;
            }
        }
        return -1;
    }

    // ============================================================
    // État global
    // ============================================================
    //
    // g_pending : drapeaux indexés par numéro de signal. NSIG est défini
    // par <signal.h> (typiquement 64 ou 65 sur Linux). volatile +
    // sig_atomic_t : garanties POSIX pour qu'un handler de signal puisse
    // écrire dans la variable sans race avec le thread principal qui la
    // lit.
    volatile sig_atomic_t g_pending[NSIG] = {0};

    // Clé privée dans le LUA_REGISTRYINDEX où on stocke la table des
    // callbacks indexée par numéro de signal : { [SIGTERM] = fn, ... }
    // L'adresse de la variable elle-même sert de clé unique (idiome
    // classique Lua C).
    char g_callbacks_key = 0;

    // Indique si on a déjà installé le debug hook qui scanne g_pending.
    // Le mutex protège contre une double installation si plusieurs
    // threads appelaient handle() simultanément (improbable mais
    // possible si l'utilisateur en fait dans son worker — qui aura ses
    // signaux bloqués, mais le code lua_sethook reste appelé).
    bool g_hook_installed = false;
    pthread_mutex_t g_hook_mutex = PTHREAD_MUTEX_INITIALIZER;

    // ============================================================
    // Handler C (async-signal-safe — STRICT minimum)
    // ============================================================
    //
    // Aucune allocation, aucun appel non async-signal-safe, aucune
    // interaction avec la VM Lua. On se contente de marquer le flag.
    // Le callback Lua sera invoqué plus tard depuis le hook.
    extern "C" void babet_sig_handler(int sig)
    {
        if (sig >= 0 && sig < NSIG)
        {
            g_pending[sig] = 1;
        }
    }

    // ============================================================
    // Helpers Lua : manipulation de la table de callbacks
    // ============================================================

    // Pousse la table de callbacks sur la pile (la crée vide si elle
    // n'existe pas encore). Stack delta : +1.
    void push_callbacks_table(lua_State *L)
    {
        lua_pushlightuserdata(L, &g_callbacks_key);
        lua_gettable(L, LUA_REGISTRYINDEX);
        if (lua_isnil(L, -1))
        {
            lua_pop(L, 1);
            lua_newtable(L);
            lua_pushlightuserdata(L, &g_callbacks_key);
            lua_pushvalue(L, -2);
            lua_settable(L, LUA_REGISTRYINDEX);
        }
    }

    // Stocke un callback pour le signal donné. Le callback (function
    // ou nil) doit être au sommet de la pile à l'appel. Il est dépilé.
    // Stack delta : -1.
    void store_callback(lua_State *L, int signum)
    {
        // pile : [..., callback]
        push_callbacks_table(L);    // [..., callback, table]
        lua_pushinteger(L, signum); // [..., callback, table, signum]
        lua_pushvalue(L, -3);       // [..., callback, table, signum, callback]
        lua_settable(L, -3);        // table[signum] = callback, pile=[..., callback, table]
        lua_pop(L, 2);              // pop table + callback
    }

    // ============================================================
    // Debug hook : dispatch automatique
    // ============================================================

    // Appelé par Lua toutes les N instructions (cf. ensure_hook_installed).
    // Conserve la signature exacte attendue par lua_sethook.
    void hook_dispatch(lua_State *L, lua_Debug *)
    {
        signal_dispatch_pending(L);
    }

    void ensure_hook_installed(lua_State *L)
    {
        pthread_mutex_lock(&g_hook_mutex);
        if (!g_hook_installed)
        {
            // Hook "count" : déclenché toutes les ~10000 instructions
            // Lua. Trade-off réactivité / overhead :
            //   - 1000  : ~1 ms de latence max, overhead ~3-5%
            //   - 10000 : ~10 ms de latence max, overhead < 1%
            //   - 100000: ~100 ms de latence max, overhead négligeable
            // 10000 est un bon compromis pour du scripting d'admin.
            lua_sethook(L, hook_dispatch, LUA_MASKCOUNT, 10000);
            g_hook_installed = true;
        }
        pthread_mutex_unlock(&g_hook_mutex);
    }

    // ============================================================
    // API Lua
    // ============================================================

    // Helper : valide le 1er argument et renvoie le numéro de signal,
    // ou lance une erreur Lua si invalide.
    int check_signum(lua_State *L)
    {
        // Contrat public strict : un nom de signal est une chaîne Lua.
        // luaL_checklstring accepterait aussi un nombre en le convertissant
        // implicitement en texte ; cette coercition rendait les diagnostics
        // incohérents avec le reste de l'API et masquait les erreurs d'appel.
        if (!lua_is_strict_string(L, 1))
        {
            luaL_argerror(L, 1, "signal name must be a string");
        }
        size_t name_len = 0;
        const char *name = lua_tolstring(L, 1, &name_len);
        if (std::memchr(name, '\0', name_len) != nullptr)
        {
            luaL_argerror(L, 1,
                          "signal name must not contain NUL byte");
        }
        int signum = signum_from_name(name);
        if (signum < 0)
        {
            luaL_error(L,
                       "signal: unsupported signal '%s' (supported: "
                       "TERM, INT, HUP, USR1, USR2, PIPE)",
                       name);
        }
        return signum;
    }

    // Helper : installe sigaction(signum, sa_handler, no SA_RESTART)
    // Retourne true en succès. Si erreur, pose (nil, err) sur la pile
    // et retourne false.
    bool apply_sigaction(lua_State *L, int signum, void (*handler)(int))
    {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sigemptyset(&sa.sa_mask);
        sa.sa_handler = handler;
        // PAS de SA_RESTART : on veut que les syscalls bloquants
        // (poll, nanosleep, etc.) retournent EINTR pour qu'on puisse
        // les interrompre proprement. C'est essentiel à la phase B.
        sa.sa_flags = 0;

        if (sigaction(signum, &sa, nullptr) != 0)
        {
            int e = errno;
            lua_pushnil(L);
            lua_pushfstring(L, "signal: sigaction failed: %s", strerror(e));
            return false;
        }
        return true;
    }

    // babet.signal.handle(name, fn_or_nil) -> true | (nil, err)
    int l_handle(lua_State *L)
    {
        check_main_thread(L, "handle");

        // Exiger explicitement le 2e argument. Sans ça,
        // handle("TERM") (un seul arg) serait équivalent à
        // handle("TERM", nil), donc désinstallerait silencieusement
        // le handler — typique foot-gun pour quelqu'un qui voulait
        // juste interroger l'état.
        if (!lua_arity_is(L, 2))
        {
            return luaL_error(L,
                              "signal.handle: missing handler argument; "
                              "use handle(name, fn) to install, "
                              "or handle(name, nil) to remove");
        }

        int signum = check_signum(L);

        int t = lua_type(L, 2);
        if (t != LUA_TFUNCTION && t != LUA_TNIL)
        {
            return luaL_error(L,
                              "signal: handler must be a function or nil, got %s",
                              lua_typename(L, t));
        }

        // Installer ou désinstaller le handler système.
        void (*handler)(int) =
            (t == LUA_TFUNCTION) ? babet_sig_handler : SIG_DFL;
        if (!apply_sigaction(L, signum, handler))
        {
            return 2; // (nil, err) déjà sur la pile
        }

        // Stocker (ou effacer) le callback dans la registry.
        // Dans les deux cas on pose au sommet de la pile la valeur
        // à enregistrer (fn ou nil), puis store_callback la dépile.
        if (t == LUA_TFUNCTION)
        {
            lua_pushvalue(L, 2);
        }
        else
        {
            lua_pushnil(L);
        }
        store_callback(L, signum);

        // Installer le hook si pas encore fait. Seulement utile quand
        // on enregistre un vrai callback : si on désinstalle tout, le
        // hook continue à tourner mais ne fait rien (coût négligeable).
        if (t == LUA_TFUNCTION)
        {
            ensure_hook_installed(L);
        }

        lua_pushboolean(L, 1);
        return 1;
    }

    // babet.signal.ignore(name) -> true | (nil, err)
    int l_ignore(lua_State *L)
    {
        check_main_thread(L, "ignore");
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L, "signal.ignore expects one argument");
        }

        int signum = check_signum(L);

        if (!apply_sigaction(L, signum, SIG_IGN))
        {
            return 2;
        }

        // Effacer un callback Lua éventuel : le signal sera ignoré
        // par le kernel, le callback ne sera jamais appelé.
        lua_pushnil(L);
        store_callback(L, signum);

        lua_pushboolean(L, 1);
        return 1;
    }

    // babet.signal.default(name) -> true | (nil, err)
    int l_default(lua_State *L)
    {
        check_main_thread(L, "default");
        if (!lua_arity_is(L, 1))
        {
            return luaL_error(L, "signal.default expects one argument");
        }

        int signum = check_signum(L);

        if (!apply_sigaction(L, signum, SIG_DFL))
        {
            return 2;
        }

        lua_pushnil(L);
        store_callback(L, signum);

        lua_pushboolean(L, 1);
        return 1;
    }

} // namespace anonyme

// ============================================================
// Fonctions exportées (déclarées dans signal.hpp)
// ============================================================

void signal_dispatch_pending(lua_State *L)
{
    // CORRECTIF (audit v21) : réservé au main thread. Cette fonction
    // (et signal_any_handled_pending ci-dessous) est appelée depuis
    // les boucles d'attente de socket/sleep/inotify — y compris dans
    // les threads workers, qui enregistrent tout babet. Scénario de
    // vol de flag : un signal géré arrive (flag posé, signal livré au
    // main thread) ; un worker dont le poll() prend un EINTR (autre
    // signal, non bloqué par le masque des workers) voyait le flag,
    // le CONSOMMAIT ici, puis cherchait le callback dans SA registry
    // (vide : handle() est interdit hors main thread) -> le callback
    // du main thread était perdu et le worker recevait un
    // "interrupted" parasite. Fenêtre très étroite (les signaux gérés
    // sont bloqués dans les workers), mais l'invariant doit être
    // garanti : les flags g_pending n'appartiennent qu'au main
    // thread. No-op partout ailleurs.
    if (!is_main_thread())
    {
        return;
    }
    for (size_t i = 0; i < NUM_SUPPORTED; ++i)
    {
        int signum = SUPPORTED_SIGNALS[i].signum;
        if (g_pending[signum])
        {
            // Reset AVANT d'invoquer le callback : si un nouveau
            // signal du même type arrive pendant l'exécution du
            // callback (peu probable mais possible), le flag sera
            // reposé et traité au tour de dispatch suivant.
            g_pending[signum] = 0;

            // Récupérer le callback dans la registry.
            push_callbacks_table(L);    // [callbacks]
            lua_pushinteger(L, signum); // [callbacks, signum]
            lua_gettable(L, -2);        // [callbacks, callback]
            lua_remove(L, -2);          // [callback]

            if (lua_isfunction(L, -1))
            {
                // pcall pour ne pas propager une erreur du callback.
                // Les handlers POSIX n'ont pas de mécanisme d'erreur
                // propre : faire échouer le programme parce que le
                // callback a un bug est pire que d'avaler l'erreur
                // silencieusement. Le user qui veut savoir doit
                // entourer son code de pcall lui-même.
                if (lua_pcall(L, 0, 0, 0) != 0)
                {
                    lua_pop(L, 1); // pop le message d'erreur
                }
            }
            else
            {
                // Callback effacé entre le set du flag et le dispatch
                // (race rare mais possible si user fait handle(nil)
                // pile-poil au mauvais moment). On l'ignore.
                lua_pop(L, 1);
            }
        }
    }
}

bool signal_any_handled_pending()
{
    // CORRECTIF (audit v21) : même garde que signal_dispatch_pending
    // (cf. commentaire ci-dessus). Un worker ne doit ni voir ni
    // consommer les flags du main thread : après un EINTR étranger,
    // ses attentes (sleep/socket/inotify) reprennent simplement,
    // sans "interrupted" parasite.
    if (!is_main_thread())
    {
        return false;
    }
    for (size_t i = 0; i < NUM_SUPPORTED; ++i)
    {
        if (g_pending[SUPPORTED_SIGNALS[i].signum])
        {
            return true;
        }
    }
    return false;
}

// ============================================================
// Fonctions exportées (déclarées dans signal.hpp)
// ============================================================

// À appeler une fois au tout début du main(), avant tout autre
// register_* et avant le spawn de workers. Capture le pthread_t
// du thread courant pour permettre à is_main_thread() de
// fonctionner ensuite.
void register_main_thread()
{
    g_main_thread = pthread_self();
    g_main_thread_set = true;
}

void register_signal(lua_State *L)
{
    // Les trois fonctions publiques ne conservent aucun propriétaire C++
    // non trivial autour d'une API Lua susceptible d'allouer. Elles peuvent
    // donc rester enregistrées directement : leurs erreurs de programmation
    // suivent le longjmp Lua normal sans contourner de nettoyage RAII.
    // Précondition : la table babet est au sommet.
    lua_newtable(L);

    lua_pushcfunction(L, l_handle);
    lua_setfield(L, -2, "handle");

    lua_pushcfunction(L, l_ignore);
    lua_setfield(L, -2, "ignore");

    lua_pushcfunction(L, l_default);
    lua_setfield(L, -2, "default");

    lua_setfield(L, -2, "signal");
}
