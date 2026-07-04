#include "workers.hpp"
#include "lua_utils.hpp"
#include "../project_core/bundled_modules.hpp"
#include "../project_core/embedded_searcher.hpp"

#include <pthread.h>
#include <signal.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <unordered_set>
#include <utility>

#include <nlohmann/json.hpp>

// Forward déclaration de register_babet, défini dans main.cpp.
// Pas d'extern "C" : fonction C++ standard, le linker la résout par
// mangling C++ comme partout dans le codebase.
void register_babet(lua_State *L);

namespace
{

    using nlohmann::json;

    // Forward declarations (définitions plus bas dans le namespace).
    int64_t parse_timeout_arg(lua_State *L, int idx);

    // =====================================================================
    // MessageQueue — primitive de queue thread-safe bornée (Chantier 9-1)
    // =====================================================================
    //
    // Queue FIFO bornée pour transporter des messages sérialisés (strings
    // JSON) entre threads. Utilise pthread directement pour cohérence avec
    // le reste du module workers.
    //
    // Sémantique :
    //   - capacité bornée fixée à la construction
    //   - push() bloque si pleine (sauf timeout_ms == 0)
    //   - pop() bloque si vide (sauf timeout_ms == 0)
    //   - close() : pose le drapeau "closed" et débloque tous les attendants
    //     - push() sur queue closed -> (false, "closed")
    //     - pop() sur queue closed et vide -> (false, "closed")
    //     - pop() sur queue closed mais non vide -> (true, msg)
    //       (on draine les messages restants avant de signaler "closed")
    //
    // Conventions de timeout (côté C++ : int64_t millisecondes) :
    //   - timeout_ms < 0  -> blocage indéfini
    //   - timeout_ms == 0 -> non-bloquant (retour immédiat)
    //   - timeout_ms > 0  -> blocage avec deadline absolue calculée à l'entrée
    //
    // Conventions de retour : std::pair<bool, const char *>
    //   - (true,  "")        succès (le message est dans out_msg pour pop)
    //   - (false, "full")    push avec timeout_ms == 0 et queue pleine
    //                        (échec IMMÉDIAT du non-bloquant)
    //   - (false, "empty")   pop avec timeout_ms == 0 et queue vide
    //                        (échec IMMÉDIAT du non-bloquant)
    //   - (false, "timeout") timeout_ms > 0 expiré sans succès
    //                        (échec APRÈS ATTENTE)
    //   - (false, "closed")  queue fermée (push toujours, pop si vide)
    //
    // La distinction "full"/"empty" (non-bloquant immédiat) vs "timeout"
    // (attente effective expirée) est utile à l'utilisateur : elle
    // signale s'il vient de tomber sur une queue déjà saturée/vide ou
    // si la condition d'arrêt s'est imposée pendant qu'il patientait.
    struct MessageQueue
    {
        std::deque<std::string> q;
        size_t capacity;
        bool closed;
        pthread_mutex_t mu;
        pthread_cond_t not_full;
        pthread_cond_t not_empty;
        bool initialized;

        MessageQueue() : capacity(0), closed(false), initialized(false) {}

        // Initialisation explicite (pas dans le ctor pour pouvoir gérer
        // l'échec d'allocation des primitives pthread sans exception).
        // Retourne true si OK, false sinon.
        bool init(size_t cap)
        {
            capacity = cap;
            closed = false;
            // CORRECTIF (audit v21) : condvars basées sur CLOCK_MONOTONIC.
            // Par défaut, pthread_cond_timedwait interprète la deadline
            // en CLOCK_REALTIME : un saut d'horloge murale (step NTP,
            // date manuelle, resume) faussait les timeouts de push/pop —
            // réveil prématuré si l'horloge saute en avant, attente
            // prolongée (jusqu'à l'amplitude du saut) si elle recule.
            // Aligné sur la doctrine steady-clock de socket.cpp.
            // compute_deadline lit désormais CLOCK_MONOTONIC : condvar
            // et deadline DOIVENT utiliser la même horloge.
            pthread_condattr_t cattr;
            if (pthread_condattr_init(&cattr) != 0)
                return false;
            if (pthread_condattr_setclock(&cattr, CLOCK_MONOTONIC) != 0)
            {
                pthread_condattr_destroy(&cattr);
                return false;
            }
            if (pthread_mutex_init(&mu, nullptr) != 0)
            {
                pthread_condattr_destroy(&cattr);
                return false;
            }
            if (pthread_cond_init(&not_full, &cattr) != 0)
            {
                pthread_condattr_destroy(&cattr);
                pthread_mutex_destroy(&mu);
                return false;
            }
            if (pthread_cond_init(&not_empty, &cattr) != 0)
            {
                pthread_condattr_destroy(&cattr);
                pthread_cond_destroy(&not_full);
                pthread_mutex_destroy(&mu);
                return false;
            }
            // L'attr est copiée dans les condvars à l'init : elle peut
            // (et doit) être détruite tout de suite.
            pthread_condattr_destroy(&cattr);
            initialized = true;
            return true;
        }

        // Destruction explicite (à appeler une seule fois). Safe si init()
        // n'a jamais réussi : ne fait rien dans ce cas.
        void destroy()
        {
            if (!initialized)
                return;
            pthread_cond_destroy(&not_empty);
            pthread_cond_destroy(&not_full);
            pthread_mutex_destroy(&mu);
            initialized = false;
        }

        // Helper : calcule un timespec absolu à partir de "maintenant + ms".
        // CORRECTIF (audit v21) : CLOCK_MONOTONIC, en cohérence avec les
        // condvars créées via pthread_condattr_setclock(CLOCK_MONOTONIC)
        // dans init(). Les deux DOIVENT utiliser la même horloge, sinon
        // la deadline est interprétée dans le mauvais référentiel.
        static void compute_deadline(int64_t timeout_ms, struct timespec &ts)
        {
            clock_gettime(CLOCK_MONOTONIC, &ts);
            ts.tv_sec += timeout_ms / 1000;
            ts.tv_nsec += (timeout_ms % 1000) * 1000000LL;
            if (ts.tv_nsec >= 1000000000LL)
            {
                ts.tv_sec += 1;
                ts.tv_nsec -= 1000000000LL;
            }
        }

        // push : insère un message. Retourne (true, "") ou (false, reason).
        std::pair<bool, const char *> push(std::string msg, int64_t timeout_ms)
        {
            pthread_mutex_lock(&mu);
            if (closed)
            {
                pthread_mutex_unlock(&mu);
                return {false, "closed"};
            }

            // Cas non-bloquant : retour immédiat si pleine.
            if (timeout_ms == 0)
            {
                if (q.size() >= capacity)
                {
                    pthread_mutex_unlock(&mu);
                    return {false, "full"};
                }
            }
            else if (timeout_ms < 0)
            {
                // Bloquant infini : attend tant que pleine ET non-closed.
                while (q.size() >= capacity && !closed)
                {
                    pthread_cond_wait(&not_full, &mu);
                }
                if (closed)
                {
                    pthread_mutex_unlock(&mu);
                    return {false, "closed"};
                }
            }
            else
            {
                // Bloquant avec deadline. ATTENTION : la reason est
                // "timeout" (pas "full") si la deadline a expiré, pour
                // distinguer un échec après attente d'un échec immédiat.
                struct timespec deadline;
                compute_deadline(timeout_ms, deadline);
                while (q.size() >= capacity && !closed)
                {
                    int rc = pthread_cond_timedwait(&not_full, &mu, &deadline);
                    if (rc == ETIMEDOUT)
                    {
                        if (q.size() >= capacity && !closed)
                        {
                            pthread_mutex_unlock(&mu);
                            return {false, "timeout"};
                        }
                        break;
                    }
                }
                if (closed)
                {
                    pthread_mutex_unlock(&mu);
                    return {false, "closed"};
                }
            }

            // Insertion.
            q.push_back(std::move(msg));
            pthread_cond_signal(&not_empty);
            pthread_mutex_unlock(&mu);
            return {true, ""};
        }

        // pop : extrait un message dans out_msg. Retourne (true, "") ou
        // (false, reason). out_msg n'est modifié que si succès.
        std::pair<bool, const char *> pop(std::string &out_msg, int64_t timeout_ms)
        {
            pthread_mutex_lock(&mu);

            // Cas non-bloquant.
            if (timeout_ms == 0)
            {
                if (q.empty())
                {
                    if (closed)
                    {
                        pthread_mutex_unlock(&mu);
                        return {false, "closed"};
                    }
                    pthread_mutex_unlock(&mu);
                    return {false, "empty"};
                }
            }
            else if (timeout_ms < 0)
            {
                // Bloquant infini : attend tant que vide ET non-closed.
                while (q.empty() && !closed)
                {
                    pthread_cond_wait(&not_empty, &mu);
                }
                if (q.empty() && closed)
                {
                    pthread_mutex_unlock(&mu);
                    return {false, "closed"};
                }
            }
            else
            {
                // Bloquant avec deadline. ATTENTION : la reason est
                // "timeout" (pas "empty") si la deadline a expiré, pour
                // distinguer un échec après attente d'un échec immédiat.
                struct timespec deadline;
                compute_deadline(timeout_ms, deadline);
                while (q.empty() && !closed)
                {
                    int rc = pthread_cond_timedwait(&not_empty, &mu, &deadline);
                    if (rc == ETIMEDOUT)
                    {
                        if (q.empty())
                        {
                            if (closed)
                            {
                                pthread_mutex_unlock(&mu);
                                return {false, "closed"};
                            }
                            pthread_mutex_unlock(&mu);
                            return {false, "timeout"};
                        }
                        break;
                    }
                }
                if (q.empty() && closed)
                {
                    pthread_mutex_unlock(&mu);
                    return {false, "closed"};
                }
            }

            // Extraction.
            out_msg = std::move(q.front());
            q.pop_front();
            pthread_cond_signal(&not_full);
            pthread_mutex_unlock(&mu);
            return {true, ""};
        }

        // close : ferme la queue. Débloque tous les attendants. Idempotent.
        void close()
        {
            // CORRECTIF (audit v21) : no-op si init() n'a jamais réussi.
            // worker_gc appelle close() inconditionnellement ; si
            // inbox.init() ou outbox.init() a échoué dans spawn (échec
            // de pthread_mutex_init/cond_init — quasi impossible sur
            // Linux, mais le chemin existe), on verrouillait ici un
            // mutex JAMAIS initialisé -> comportement indéfini.
            // destroy() avait déjà ce garde, close() non. Pas de course
            // possible sur ce chemin : l'échec d'init précède
            // pthread_create, donc aucune thread ne touche la queue —
            // seul le __gc du parent y passe.
            if (!initialized)
                return;
            pthread_mutex_lock(&mu);
            closed = true;
            pthread_cond_broadcast(&not_full);
            pthread_cond_broadcast(&not_empty);
            pthread_mutex_unlock(&mu);
        }
    };

    // État porté par l'userdata Lua. La thread worker écrit result_json
    // ou err_msg PUIS publie status atomiquement ; le parent lit status
    // atomiquement puis result_json / err_msg sous garantie de visibilité
    // via la release/acquire de l'atomic.
    struct Worker
    {
        pthread_t tid;
        bool tid_valid;

        // Statut atomique :
        //   0 = running
        //   1 = done (succès, result_json prêt)
        //   2 = error (échec, err_msg prêt)
        std::atomic<int> status;

        // True une fois que join() ou poll()=="done"/"error" a consommé
        // le résultat. Sert au __gc à savoir si la thread a déjà été
        // rejointe (pour ne pas joindre 2 fois).
        std::atomic<bool> joined;

        // Sérialisé en sortie de la thread, lu par join()/poll().
        std::string result_json;
        std::string err_msg;

        // Lecture seule pour la thread après spawn. Mémoire stable
        // pendant toute la durée de vie de la thread.
        std::string code;
        std::string args_json;

        // Chantier 9-2 : queues bidirectionnelles parent <-> worker.
        // inbox : parent push, worker pop (en 9-3).
        // outbox : worker push (en 9-3), parent pop.
        // Initialisées au spawn(), fermées au __gc avant pthread_join
        // pour que les recv() côté worker se débloquent proprement.
        MessageQueue inbox;
        MessageQueue outbox;
    };

    constexpr const char *WORKER_META = "LuapilotWorker";

    constexpr int WORKER_RUNNING = 0;
    constexpr int WORKER_DONE = 1;
    constexpr int WORKER_ERROR = 2;

    // Contexte d'init pour le require() utilisateur dans les workers.
    // Rempli par set_workers_init_context() depuis main.cpp avant tout
    // spawn, lu par worker_thread_main() pour configurer le lua_State
    // enfant exactement comme le parent.
    //
    // Si projectDir/exePath sont vides ou embedded == false sans
    // projectDir, le worker fonctionnera mais require() utilisateur
    // échouera (le code utilisateur ne peut tester ça que via spawn).
    struct WorkerInitContext
    {
        std::string projectDir; // mode dossier
        std::string exePath;    // mode embarqué
        bool embedded;
        bool initialized;
    };
    WorkerInitContext g_init_ctx = {"", "", false, false};

    // Profondeur max pour les arborescences LÉGITIMES (sans cycle).
    // Les cycles sont détectés séparément via un set des tables déjà
    // visitées (cf. visited dans lua_table_to_json) — refus immédiat
    // dès la 2ème rencontre, pas attendre 32 niveaux. La limite ci-
    // dessous protège uniquement contre les arborescences pathologiques
    // très profondes mais sans cycle réel. 32 est très défensif :
    // au-delà, on consomme trop de pile C++ via la récursion, ce qui
    // a déclenché des SIGSEGV sur Linux x86_64 avec pile par défaut
    // 8 MB déjà partiellement consommée par Lua + OpenSSL.
    // État processus partagé (option A validée) : voir workers.hpp.
    // Le verrou sérialise « marquer le premier spawn » avec les
    // mutations setenv/chdir de sys.cpp et chdir.cpp.
    std::mutex g_process_state_mu;
    bool g_worker_ever_spawned = false;

    constexpr int MAX_SERIALIZATION_DEPTH = 32;

    Worker *check_worker(lua_State *L, int idx)
    {
        return static_cast<Worker *>(luaL_checkudata(L, idx, WORKER_META));
    }

    // ==================================================================
    // Sérialisation Lua -> JSON
    // ==================================================================
    //
    // Conventions (alignées avec babet.json mais implémentation
    // indépendante — décision Option 2) :
    //   nil           -> null
    //   boolean       -> true/false
    //   integer       -> nombre JSON (mais perte de distinction au reload)
    //   float         -> nombre JSON (NaN/Inf -> refus dur)
    //   string        -> string JSON (UTF-8 requis, sinon refus)
    //   table séq 1..n -> array
    //   table clés str -> object
    //   table mixte / à trous -> refus dur (cohérent avec babet.json)
    //   function / userdata / thread -> refus dur
    //   cycle -> refus IMMÉDIAT via set des pointeurs de tables visitées
    //
    // La fonction renvoie true en succès, false avec err rempli.
    // La pile Lua reste exactement comme à l'entrée.
    //
    // `visited` est un set des pointeurs de tables actuellement en cours
    // de traversée. Une table est insérée à l'entrée de
    // lua_table_to_json et retirée à la sortie. Si une table dont le
    // pointeur est déjà dedans est rencontrée, c'est un cycle -> refus.

    bool lua_to_json(lua_State *L, int idx, json &out,
                     std::string &err, int depth,
                     std::unordered_set<const void *> &visited);

    // Vérifie qu'une string Lua est UTF-8 valide (au moins acceptable
    // pour nlohmann::json). On utilise la fonction utilitaire de
    // nlohmann elle-même via un cast après accept : on tente le dump
    // d'une string-only et on regarde si ça réussit. Implémentation
    // directe plus rapide pour les chaînes : on accepte tout ce qui
    // n'a pas d'octet NUL ET respecte les règles UTF-8 basiques.
    //
    // CORRECTIF (post-revue ChatGPT) : on refuse explicitement '\0'.
    // Techniquement '\0' est UTF-8 valide (un seul octet < 0x80), mais
    // sémantiquement c'est du binaire ; et côté désérialisation, les
    // clés d'objet JSON qu'on pousse via lua_setfield seraient tronquées
    // au NUL. Pour cohérence "pas de strings binaires", refus dur.
    bool is_valid_utf8(const char *s, size_t len)
    {
        size_t i = 0;
        while (i < len)
        {
            unsigned char c = static_cast<unsigned char>(s[i]);
            if (c == 0)
                return false;
            if (c < 0x80)
            {
                i += 1;
                continue;
            }
            size_t cont = 0;
            if ((c & 0xE0) == 0xC0)
                cont = 1;
            else if ((c & 0xF0) == 0xE0)
                cont = 2;
            else if ((c & 0xF8) == 0xF0)
                cont = 3;
            else
                return false;
            if (i + cont >= len)
                return false;
            for (size_t k = 1; k <= cont; ++k)
            {
                unsigned char cc = static_cast<unsigned char>(s[i + k]);
                if ((cc & 0xC0) != 0x80)
                    return false;
            }
            i += cont + 1;
        }
        return true;
    }

    // Sérialise une table Lua à l'index `idx` (absolu attendu).
    // Détermine array vs object selon les clés. Détecte les cycles via
    // `visited` : si la table est déjà en cours de traversée, refus
    // immédiat. Sinon on l'enregistre, on traverse, et on la retire en
    // fin de fonction (RAII garantirait ça mieux mais on a plusieurs
    // chemins de sortie ; on utilise un guard manuel discipliné).
    bool lua_table_to_json(lua_State *L, int idx, json &out,
                           std::string &err, int depth,
                           std::unordered_set<const void *> &visited)
    {
        // Détection de cycle : si on revoit la même table, c'est circulaire.
        const void *table_id = lua_topointer(L, idx);
        if (table_id != nullptr)
        {
            if (visited.find(table_id) != visited.end())
            {
                err = "workers: spawn: table contains a cycle "
                      "(not serializable)";
                return false;
            }
            visited.insert(table_id);
        }

        // Helper pour garantir le retrait de la table de visited sur
        // tous les chemins de sortie (success ET failure).
        struct VisitedGuard
        {
            std::unordered_set<const void *> &set;
            const void *key;
            bool inserted;
            ~VisitedGuard()
            {
                if (inserted && key != nullptr)
                    set.erase(key);
            }
        } guard{visited, table_id, table_id != nullptr};

        // Compter les clés et déterminer si c'est une séquence 1..n.
        lua_Integer n = luaL_len(L, idx);
        bool is_array = (n > 0);
        if (is_array)
        {
            // Vérifier qu'on a bien 1..n sans trou ni clé non-int.
            // Stratégie : itérer tout, et vérifier que toutes les clés
            // entières sont dans [1, n] et qu'il n'y a aucune clé non
            // entière. (lua's `#` n'est pas fiable pour les tables à
            // trous.)
            bool has_non_int_key = false;
            lua_Integer max_int_key = 0;
            lua_Integer int_count = 0;
            lua_pushnil(L);
            while (lua_next(L, idx) != 0)
            {
                if (lua_type(L, -2) == LUA_TNUMBER &&
                    lua_isinteger(L, -2))
                {
                    lua_Integer k = lua_tointeger(L, -2);
                    if (k < 1)
                    {
                        has_non_int_key = true;
                    }
                    else
                    {
                        if (k > max_int_key)
                            max_int_key = k;
                        ++int_count;
                    }
                }
                else
                {
                    has_non_int_key = true;
                }
                lua_pop(L, 1);
                if (has_non_int_key)
                {
                    lua_pop(L, 1);
                    break;
                }
            }
            if (has_non_int_key || int_count != max_int_key)
            {
                is_array = false;
            }
            else
            {
                n = max_int_key;
            }
        }

        if (is_array)
        {
            out = json::array();
            for (lua_Integer i = 1; i <= n; ++i)
            {
                lua_geti(L, idx, i);
                json elem;
                if (!lua_to_json(L, lua_gettop(L), elem, err, depth + 1,
                                 visited))
                {
                    lua_pop(L, 1);
                    return false;
                }
                out.push_back(std::move(elem));
                lua_pop(L, 1);
            }
            return true;
        }

        // Object : toutes les clés doivent être strings.
        out = json::object();
        lua_pushnil(L);
        while (lua_next(L, idx) != 0)
        {
            if (lua_type(L, -2) != LUA_TSTRING)
            {
                err = "workers: spawn: table key must be a string "
                      "(non-array table)";
                lua_pop(L, 2);
                return false;
            }
            size_t klen = 0;
            const char *kp = lua_tolstring(L, -2, &klen);
            if (!is_valid_utf8(kp, klen))
            {
                err = "workers: spawn: table key contains "
                      "non-UTF-8 bytes";
                lua_pop(L, 2);
                return false;
            }
            std::string key(kp, klen);
            json val;
            if (!lua_to_json(L, lua_gettop(L), val, err, depth + 1,
                             visited))
            {
                lua_pop(L, 2);
                return false;
            }
            out[key] = std::move(val);
            lua_pop(L, 1);
        }
        return true;
    }

    bool lua_to_json(lua_State *L, int idx, json &out,
                     std::string &err, int depth,
                     std::unordered_set<const void *> &visited)
    {
        if (depth > MAX_SERIALIZATION_DEPTH)
        {
            err = "workers: spawn: value too deeply nested";
            return false;
        }
        // CORRECTIF (revue Gemini post-audit v21, vérifié) : réserver
        // la pile avant de pousser — même garde que json.cpp (~2-3
        // slots simultanés par niveau ici : lua_geti, ou lua_next
        // clé+valeur ; 4 avec marge). Sans lui, MAX_SERIALIZATION_
        // DEPTH = 32 niveaux x ~2 slots dépassait les ~20 garantis ->
        // UB. Convention préservée : false = rien poussé, err posé.
        if (!lua_checkstack(L, 4))
        {
            err = "workers: spawn: lua stack overflow during serialization";
            return false;
        }
        idx = lua_absindex(L, idx);
        int t = lua_type(L, idx);
        switch (t)
        {
        case LUA_TNIL:
            out = nullptr;
            return true;
        case LUA_TBOOLEAN:
            out = static_cast<bool>(lua_toboolean(L, idx));
            return true;
        case LUA_TNUMBER:
            if (lua_isinteger(L, idx))
            {
                out = static_cast<int64_t>(lua_tointeger(L, idx));
                return true;
            }
            else
            {
                double d = lua_tonumber(L, idx);
                if (std::isnan(d) || std::isinf(d))
                {
                    err = "workers: spawn: number is NaN or Inf "
                          "(not representable in JSON)";
                    return false;
                }
                out = d;
                return true;
            }
        case LUA_TSTRING:
        {
            size_t len = 0;
            const char *s = lua_tolstring(L, idx, &len);
            if (!is_valid_utf8(s, len))
            {
                err = "workers: spawn: string contains non-UTF-8 "
                      "bytes (not transferable to worker)";
                return false;
            }
            out = std::string(s, len);
            return true;
        }
        case LUA_TTABLE:
            return lua_table_to_json(L, idx, out, err, depth, visited);
        case LUA_TFUNCTION:
            err = "workers: spawn: cannot transfer a function "
                  "(use spawn(string_code) only)";
            return false;
        case LUA_TUSERDATA:
            err = "workers: spawn: cannot transfer a userdata "
                  "(e.g. socket, file handle) to a worker";
            return false;
        case LUA_TTHREAD:
            err = "workers: spawn: cannot transfer a coroutine "
                  "to a worker";
            return false;
        default:
            err = "workers: spawn: unsupported Lua type for transfer";
            return false;
        }
    }

    // ==================================================================
    // Désérialisation JSON -> Lua
    // ==================================================================
    //
    // Empile la valeur sur la pile Lua. Renvoie true en succès, false
    // avec err rempli en cas de structure invalide (ne devrait pas
    // arriver en pratique car le JSON vient de notre propre serialize,
    // mais on garde un filet).

    bool json_to_lua(lua_State *L, const json &j,
                     std::string &err, int depth)
    {
        if (depth > MAX_SERIALIZATION_DEPTH)
        {
            err = "workers: result too deeply nested";
            return false;
        }
        // CORRECTIF (revue Gemini post-audit v21, vérifié) : même
        // garde côté désérialisation (createtable + valeur = ~2
        // slots par niveau ; 4 avec marge). Convention « pile propre
        // sur false » préservée : l'échec ici ne pousse rien.
        if (!lua_checkstack(L, 4))
        {
            err = "workers: lua stack overflow during deserialization";
            return false;
        }
        if (j.is_null())
        {
            lua_pushnil(L);
            return true;
        }
        if (j.is_boolean())
        {
            lua_pushboolean(L, j.get<bool>() ? 1 : 0);
            return true;
        }
        if (j.is_number_integer())
        {
            lua_pushinteger(L,
                            static_cast<lua_Integer>(j.get<int64_t>()));
            return true;
        }
        if (j.is_number_unsigned())
        {
            uint64_t v = j.get<uint64_t>();
            if (v <= static_cast<uint64_t>(LUA_MAXINTEGER))
            {
                lua_pushinteger(L, static_cast<lua_Integer>(v));
            }
            else
            {
                lua_pushnumber(L, static_cast<lua_Number>(v));
            }
            return true;
        }
        if (j.is_number_float())
        {
            lua_pushnumber(L, j.get<double>());
            return true;
        }
        if (j.is_string())
        {
            const std::string &s = j.get_ref<const std::string &>();
            lua_pushlstring(L, s.data(), s.size());
            return true;
        }
        if (j.is_array())
        {
            lua_createtable(L, static_cast<int>(j.size()), 0);
            lua_Integer idx = 1;
            for (const auto &elem : j)
            {
                if (!json_to_lua(L, elem, err, depth + 1))
                {
                    lua_pop(L, 1);
                    return false;
                }
                lua_seti(L, -2, idx++);
            }
            return true;
        }
        if (j.is_object())
        {
            lua_createtable(L, 0, static_cast<int>(j.size()));
            for (auto it = j.begin(); it != j.end(); ++it)
            {
                if (!json_to_lua(L, it.value(), err, depth + 1))
                {
                    lua_pop(L, 1);
                    return false;
                }
                lua_setfield(L, -2, it.key().c_str());
            }
            return true;
        }
        err = "workers: unsupported JSON type in result";
        return false;
    }

    // ==================================================================
    // Thread worker
    // ==================================================================
    //
    // Tourne dans une pthread. Crée son propre lua_State neuf, ouvre la
    // stdlib + babet.* via register_babet, désérialise args dans
    // le global "worker.args" puis "worker.args" via le namespace
    // "worker", charge code, exécute en pcall, sérialise le résultat.
    //
    // Tout est encapsulé en pcall : aucune erreur Lua ne tue le process.
    // En cas de crash C++ dans le code de l'utilisateur (très rare avec
    // pcall en place), c'est la thread qui meurt et on remontera "error"
    // avec un message générique.

    // ============================================================
    // Chantier 9-3 : worker.send / worker.recv côté worker
    // ============================================================
    //
    // Symétriques de w:send / w:recv côté parent :
    //   - worker.send(v) push dans OUTBOX (worker -> parent)
    //   - worker.recv()  pop  depuis INBOX (parent -> worker)
    //
    // Conventions de retour CÔTÉ WORKER (pcall-style, symétrique avec
    // w:recv() / w:join() côté parent) :
    //   - worker.send(v) -> (true, nil) | (false, reason)
    //   - worker.recv()  -> (true, value) | (false, reason)
    //
    // La différence avec w:send côté parent : sur erreur de sérialisation,
    // worker.send rend (false, err) — pas (nil, err) — pour rester
    // cohérent avec la convention pcall-style du côté worker.
    //
    // Worker* est passé via upvalue C (décision W2-C1) :
    //   - lua_pushlightuserdata(L, w)
    //   - lua_pushcclosure(L, worker_side_*, 1)
    // La fonction le récupère avec lua_touserdata(L, lua_upvalueindex(1)).

    int worker_side_send(lua_State *L)
    {
        Worker *w = static_cast<Worker *>(
            lua_touserdata(L, lua_upvalueindex(1)));

        // CORRECTIF Gemini : parse_timeout_arg peut faire un longjmp via
        // luaL_error si l'utilisateur passe un timeout invalide. Or
        // longjmp ne déroule PAS les destructeurs C++. Donc on parse
        // le timeout AVANT toute allocation C++ (json, std::string, set).
        int64_t timeout_ms = parse_timeout_arg(L, 2);

        // Sérialiser la valeur (arg 1) -> JSON string.
        json msg_j;
        std::string err;
        std::unordered_set<const void *> visited;
        if (!lua_to_json(L, 1, msg_j, err, 0, visited))
        {
            // Convention pcall-style côté worker : (false, err).
            lua_pushboolean(L, 0);
            lua_pushstring(L, err.c_str());
            return 2;
        }
        std::string msg_str;
        try
        {
            msg_str = msg_j.dump();
        }
        catch (const std::exception &e)
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L,
                           (std::string("workers: failed to serialize message: ") + e.what()).c_str());
            return 2;
        }

        // Push dans l'OUTBOX (worker -> parent).
        auto r = w->outbox.push(std::move(msg_str), timeout_ms);
        if (r.first)
        {
            lua_pushboolean(L, 1);
            lua_pushnil(L);
            return 2;
        }
        lua_pushboolean(L, 0);
        lua_pushstring(L, r.second);
        return 2;
    }

    int worker_side_recv(lua_State *L)
    {
        Worker *w = static_cast<Worker *>(
            lua_touserdata(L, lua_upvalueindex(1)));

        // Parse timeout (peut lever via luaL_error).
        int64_t timeout_ms = parse_timeout_arg(L, 1);

        // Pop depuis l'INBOX (parent -> worker).
        std::string msg_str;
        auto r = w->inbox.pop(msg_str, timeout_ms);
        if (!r.first)
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L, r.second);
            return 2;
        }

        // Déserialiser le JSON -> valeur Lua.
        try
        {
            json j = json::parse(msg_str);
            std::string err;
            if (!json_to_lua(L, j, err, 0))
            {
                lua_pushboolean(L, 0);
                lua_pushstring(L, err.c_str());
                return 2;
            }
        }
        catch (const std::exception &e)
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L, e.what());
            return 2;
        }

        // pile : ..., value
        // On veut renvoyer (true, value).
        lua_pushboolean(L, 1);
        lua_insert(L, -2);
        return 2;
    }

    void *worker_thread_main(void *arg)
    {
        Worker *w = static_cast<Worker *>(arg);

        // ==========================================================
        // Bloquer les signaux gérables par babet.signal dans ce
        // worker. Sans cela, le kernel pourrait délivrer un SIGTERM
        // (ou autre) à ce thread plutôt qu'au thread principal, et le
        // callback Lua serait invoqué dans un mauvais lua_State —
        // ou pire, dans aucun.
        //
        // Cette liste DOIT rester synchronisée avec SUPPORTED_SIGNALS
        // dans signal.cpp. Les signaux non listés ici garderont leur
        // comportement par défaut dans le worker (typiquement : tuer
        // le process, ce qui est OK puisqu'on ne prétend pas les
        // gérer en v1).
        sigset_t mask;
        sigemptyset(&mask);
        sigaddset(&mask, SIGTERM);
        sigaddset(&mask, SIGINT);
        sigaddset(&mask, SIGHUP);
        sigaddset(&mask, SIGUSR1);
        sigaddset(&mask, SIGUSR2);
        sigaddset(&mask, SIGPIPE);
        pthread_sigmask(SIG_BLOCK, &mask, nullptr);
        // ==========================================================

        lua_State *L = luaL_newstate();
        if (!L)
        {
            w->err_msg = "workers: failed to create lua_State for worker";
            w->status.store(WORKER_ERROR, std::memory_order_release);
            // Chantier 9-3 : ferme les queues même sur échec précoce,
            // pour que les recv/send bloquants côté parent ne restent
            // pas en attente indéfinie.
            w->inbox.close();
            w->outbox.close();
            return nullptr;
        }
        luaL_openlibs(L);

        // Charger babet.* + modules bundlés (inspect, argparse, logging).
        // L'ORDRE COMPTE : register_bundled_modules pose package.preload
        // pour les modules bundlés, et doit être appelé AVANT toute
        // exécution de require() — donc avant register_babet ne
        // l'utilise et avant le code utilisateur.
        register_bundled_modules(L);
        register_babet(L);

        // CORRECTIF (post-revue ChatGPT) : appliquer la même config de
        // require() que le parent, pour que require("mymod") trouve les
        // modules utilisateur depuis un worker. Sans ça, seuls les
        // modules bundlés (via package.preload) marchaient.
        if (g_init_ctx.initialized)
        {
            if (g_init_ctx.embedded && !g_init_ctx.exePath.empty())
            {
                // Mode embarqué : pose un searcher qui lit depuis le ZIP
                // appendu au binaire. Même fonction publique que le
                // parent utilise.
                register_embedded_searcher(L, g_init_ctx.exePath.c_str());
            }
            else if (!g_init_ctx.projectDir.empty())
            {
                // Mode dossier : préfixe ?.lua et ?/init.lua à
                // package.path. Pure manipulation de pile Lua, pas
                // d'évaluation de string utilisateur (sûr si projectDir
                // contient des caractères spéciaux).
                const std::string &d = g_init_ctx.projectDir;
                lua_getglobal(L, "package"); // pile: package
                lua_getfield(L, -1, "path"); // pile: package, oldpath
                const char *oldpath = lua_tostring(L, -1);
                std::string newpath = d + "/?.lua;" + d + "/?/init.lua;" + (oldpath ? oldpath : "");
                lua_pop(L, 1);                      // pile: package
                lua_pushstring(L, newpath.c_str()); // pile: package, newpath
                lua_setfield(L, -2, "path");        // pile: package
                lua_pop(L, 1);                      // pile: <vide>
            }
        }

        // Préparer worker.args via le namespace "worker" (décision W-7).
        // worker = { args = <args_json désérialisé> }
        lua_newtable(L); // worker = {}
        std::string err;
        if (w->args_json.empty() || w->args_json == "null")
        {
            lua_pushnil(L);
        }
        else
        {
            try
            {
                json args_j = json::parse(w->args_json);
                if (!json_to_lua(L, args_j, err, 0))
                {
                    w->err_msg = err;
                    w->status.store(WORKER_ERROR,
                                    std::memory_order_release);
                    // Chantier 9-3 : ferme les queues pour que les recv/send
                    // futurs côté parent voient 'closed' au lieu d'attendre.
                    w->inbox.close();
                    w->outbox.close();
                    lua_close(L);
                    return nullptr;
                }
            }
            catch (const std::exception &e)
            {
                w->err_msg = std::string(
                                 "workers: internal: failed to parse args_json: ") +
                             e.what();
                w->status.store(WORKER_ERROR,
                                std::memory_order_release);
                // Chantier 9-3 : ferme les queues pour que les recv/send
                // futurs côté parent voient 'closed' au lieu d'attendre.
                w->inbox.close();
                w->outbox.close();
                lua_close(L);
                return nullptr;
            }
        }
        lua_setfield(L, -2, "args"); // worker.args = ...

        // Chantier 9-3 : worker.send / worker.recv exposés au lua_State
        // enfant via lightuserdata du Worker* en upvalue (W2-C1).
        lua_pushlightuserdata(L, w);
        lua_pushcclosure(L, worker_side_send, 1);
        lua_setfield(L, -2, "send");

        lua_pushlightuserdata(L, w);
        lua_pushcclosure(L, worker_side_recv, 1);
        lua_setfield(L, -2, "recv");

        lua_setglobal(L, "worker"); // _G.worker = ...

        // arg = nil dans le worker (décision W-7).
        lua_pushnil(L);
        lua_setglobal(L, "arg");

        // Charger et exécuter le code de l'utilisateur en pcall.
        // CORRECTIF (post-revue ChatGPT) : luaL_loadbuffer avec size
        // explicite plutôt que luaL_loadstring (qui ferait un strlen et
        // tronquerait au premier NUL). Et chunkname "worker" plutôt que
        // toute la source : messages d'erreur Lua plus lisibles si le
        // code est long.
        int rc = luaL_loadbuffer(L, w->code.data(), w->code.size(),
                                 "worker");
        if (rc != LUA_OK)
        {
            const char *m = lua_tostring(L, -1);
            w->err_msg = m ? std::string(m)
                           : "workers: failed to load code (no message)";
            w->status.store(WORKER_ERROR, std::memory_order_release);
            // Chantier 9-3 : ferme les queues pour que les recv/send
            // futurs côté parent voient 'closed' au lieu d'attendre.
            w->inbox.close();
            w->outbox.close();
            lua_close(L);
            return nullptr;
        }
        // Exécution du code en pcall, 1 seul résultat récupéré.
        // DÉCISION DOCUMENTÉE (post-revue ChatGPT) : si le worker fait
        // `return a, b, c`, seul `a` traverse à :join() / :poll().
        // Les valeurs supplémentaires sont silencieusement écartées.
        // Pour rendre plusieurs valeurs, l'utilisateur doit les wrapper :
        //   return { a, b, c }   -- côté worker
        //   local ok, t = w:join()  -- t = { a, b, c } côté parent
        // C'est la convention la plus simple, cohérente avec le modèle
        // "un worker calcule UNE chose et la rend".
        rc = lua_pcall(L, 0, 1, 0);
        if (rc != LUA_OK)
        {
            const char *m = lua_tostring(L, -1);
            w->err_msg = m ? std::string(m)
                           : "workers: worker raised error (no message)";
            w->status.store(WORKER_ERROR, std::memory_order_release);
            // Chantier 9-3 : ferme les queues pour que les recv/send
            // futurs côté parent voient 'closed' au lieu d'attendre.
            w->inbox.close();
            w->outbox.close();
            lua_close(L);
            return nullptr;
        }

        // Sérialiser le résultat.
        json result_j;
        std::unordered_set<const void *> result_visited;
        if (!lua_to_json(L, -1, result_j, err, 0, result_visited))
        {
            // L'utilisateur a retourné un truc non sérialisable.
            w->err_msg = std::string(
                             "workers: worker return value is not transferable: ") +
                         err;
            w->status.store(WORKER_ERROR, std::memory_order_release);
            // Chantier 9-3 : ferme les queues pour que les recv/send
            // futurs côté parent voient 'closed' au lieu d'attendre.
            w->inbox.close();
            w->outbox.close();
            lua_close(L);
            return nullptr;
        }
        try
        {
            w->result_json = result_j.dump();
        }
        catch (const std::exception &e)
        {
            w->err_msg = std::string(
                             "workers: internal: result_json dump failed: ") +
                         e.what();
            w->status.store(WORKER_ERROR, std::memory_order_release);
            // Chantier 9-3 : ferme les queues pour que les recv/send
            // futurs côté parent voient 'closed' au lieu d'attendre.
            w->inbox.close();
            w->outbox.close();
            lua_close(L);
            return nullptr;
        }

        // Chantier 9-3 : ferme les queues au succès.
        w->inbox.close();
        w->outbox.close();
        lua_close(L);
        w->status.store(WORKER_DONE, std::memory_order_release);
        return nullptr;
    }

    // ==================================================================
    // Fonctions exposées
    // ==================================================================

    int lua_workers_spawn(lua_State *L)
    {
        size_t code_len = 0;
        const char *code = luaL_checklstring(L, 1, &code_len);

        // Vérification de type sur args et opts (les contenus sont
        // validés via la sérialisation).
        if (!lua_isnoneornil(L, 2) && !lua_istable(L, 2))
        {
            return luaL_error(L,
                              "workers.spawn: args must be a table");
        }
        if (!lua_isnoneornil(L, 3) && !lua_istable(L, 3))
        {
            return luaL_error(L,
                              "workers.spawn: opts must be a table");
        }

        // Chantier 9-2 : parsing des capacités des queues.
        // Défaut : 64 messages chacune. Valeurs valides : entiers > 0.
        // Toute autre valeur (zéro, négatif, non-numérique) : luaL_error
        // (faute de programmeur, pas runtime).
        int inbox_cap = 64;
        int outbox_cap = 64;
        if (lua_istable(L, 3))
        {
            lua_getfield(L, 3, "inbox_capacity");
            if (!lua_isnil(L, -1))
            {
                if (!lua_isnumber(L, -1))
                {
                    return luaL_error(L,
                                      "workers.spawn: opts.inbox_capacity must be a number");
                }
                lua_Number n = lua_tonumber(L, -1);
                if (n != std::floor(n) || n <= 0 || n > 1000000)
                {
                    return luaL_error(L,
                                      "workers.spawn: opts.inbox_capacity must be a "
                                      "positive integer (got %g)",
                                      (double)n);
                }
                inbox_cap = (int)n;
            }
            lua_pop(L, 1);

            lua_getfield(L, 3, "outbox_capacity");
            if (!lua_isnil(L, -1))
            {
                if (!lua_isnumber(L, -1))
                {
                    return luaL_error(L,
                                      "workers.spawn: opts.outbox_capacity must be a number");
                }
                lua_Number n = lua_tonumber(L, -1);
                if (n != std::floor(n) || n <= 0 || n > 1000000)
                {
                    return luaL_error(L,
                                      "workers.spawn: opts.outbox_capacity must be a "
                                      "positive integer (got %g)",
                                      (double)n);
                }
                outbox_cap = (int)n;
            }
            lua_pop(L, 1);
        }

        // État processus (option A validée) : marquer « un worker a
        // été lancé » AVANT toute création effective, sous le MÊME
        // verrou que les mutations d'environnement/cwd — aucun worker
        // ne peut naître pendant un setenv/chdir, et réciproquement.
        // Placé après la validation des arguments (un spawn mal typé
        // lève sans déclencher la restriction) mais avant tout le
        // reste ; définitif même si ce spawn échoue ensuite (règle
        // simple, sans course).
        {
            std::lock_guard<std::mutex> lk(g_process_state_mu);
            g_worker_ever_spawned = true;
        }

        // Sérialiser args -> JSON.
        std::string args_json_str = "null";
        if (lua_istable(L, 2))
        {
            json args_j;
            std::string err;
            std::unordered_set<const void *> args_visited;
            if (!lua_to_json(L, 2, args_j, err, 0, args_visited))
            {
                return push_fail(L, err);
            }
            try
            {
                args_json_str = args_j.dump();
            }
            catch (const std::exception &e)
            {
                return push_fail(L,
                                 std::string("workers: failed to dump args: ") + e.what());
            }
        }

        // Créer le userdata Worker AVANT pthread_create : si pthread
        // échoue, on libère en utilisant le __gc normal (pas de leak).
        Worker *w = static_cast<Worker *>(
            lua_newuserdata(L, sizeof(Worker)));
        new (w) Worker();
        w->tid_valid = false;
        w->status.store(WORKER_RUNNING, std::memory_order_relaxed);
        w->joined.store(false, std::memory_order_relaxed);
        w->code.assign(code, code_len);
        w->args_json = std::move(args_json_str);
        luaL_getmetatable(L, WORKER_META);
        lua_setmetatable(L, -2);

        // Chantier 9-2 : init des queues. Si l'init échoue (allocation
        // pthread), on remonte une erreur runtime. Le __gc libérera la
        // queue éventuellement à demi initialisée (init() retournant
        // false laisse initialized=false, donc destroy() ne touchera
        // pas aux primitives non créées).
        if (!w->inbox.init((size_t)inbox_cap))
        {
            lua_pop(L, 1);
            return push_fail(L,
                             "workers: failed to initialize inbox queue");
        }
        if (!w->outbox.init((size_t)outbox_cap))
        {
            lua_pop(L, 1);
            return push_fail(L,
                             "workers: failed to initialize outbox queue");
        }

        int rc = pthread_create(&w->tid, nullptr, worker_thread_main, w);
        if (rc != 0)
        {
            // userdata sera __gc'd par Lua (rien à joindre puisque
            // tid_valid reste false).
            lua_pop(L, 1);
            return push_fail(L,
                             std::string("workers: pthread_create failed: ") + std::strerror(rc));
        }
        w->tid_valid = true;

        return 1; // userdata Worker au sommet
    }

    int worker_join(lua_State *L)
    {
        Worker *w = check_worker(L, 1);

        if (w->joined.load(std::memory_order_acquire))
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L,
                           "workers: join: result already consumed");
            return 2;
        }

        if (w->tid_valid)
        {
            pthread_join(w->tid, nullptr);
            w->tid_valid = false; // évite double join via __gc
        }

        w->joined.store(true, std::memory_order_release);

        int st = w->status.load(std::memory_order_acquire);
        if (st == WORKER_DONE)
        {
            lua_pushboolean(L, 1);
            // Désérialiser le résultat. json_to_lua laisse la pile
            // propre en cas d'échec (nettoyage interne). On rend
            // (true, nil) si la désérialisation échoue : politique
            // "on a annoncé success, on ne recule pas" — un échec
            // ici serait un bug de notre sérialisation, pas de
            // l'utilisateur.
            try
            {
                json r = json::parse(w->result_json);
                std::string err;
                if (!json_to_lua(L, r, err, 0))
                {
                    lua_pushnil(L);
                }
            }
            catch (...)
            {
                lua_pushnil(L);
            }
            return 2;
        }
        // WORKER_ERROR (ou running anormal — ne devrait pas se produire
        // après pthread_join).
        lua_pushboolean(L, 0);
        lua_pushstring(L, w->err_msg.c_str());
        return 2;
    }

    int worker_poll(lua_State *L)
    {
        Worker *w = check_worker(L, 1);

        if (w->joined.load(std::memory_order_acquire))
        {
            // Politique : si déjà consommé, on rend "error" pour signaler
            // qu'on ne peut plus poll. Cohérent avec join() qui rend
            // (false, "already consumed").
            lua_pushstring(L, "error");
            lua_pushstring(L,
                           "workers: poll: result already consumed");
            return 2;
        }

        int st = w->status.load(std::memory_order_acquire);
        if (st == WORKER_RUNNING)
        {
            lua_pushstring(L, "running");
            lua_pushnil(L);
            return 2;
        }

        // st == WORKER_DONE ou WORKER_ERROR : rejoindre la thread
        // (rapide, elle a déjà fini) et marquer consommé.
        if (w->tid_valid)
        {
            pthread_join(w->tid, nullptr);
            w->tid_valid = false;
        }
        w->joined.store(true, std::memory_order_release);

        if (st == WORKER_DONE)
        {
            lua_pushstring(L, "done");
            try
            {
                json r = json::parse(w->result_json);
                std::string err;
                if (!json_to_lua(L, r, err, 0))
                {
                    lua_pushnil(L);
                }
            }
            catch (...)
            {
                lua_pushnil(L);
            }
            return 2;
        }

        // WORKER_ERROR
        lua_pushstring(L, "error");
        lua_pushstring(L, w->err_msg.c_str());
        return 2;
    }

    // Helper: parse un timeout en secondes (Lua) vers int64_t millisecondes
    // avec la sémantique convenue :
    //   - absent / nil          -> -1 (blocage indéfini)
    //   - 0 (entier ou float)   ->  0 (non-bloquant immédiat)
    //   - n > 0                 -> floor(n * 1000) ms
    //   - n < 0, NaN, Inf       -> luaL_error (mauvais usage)
    //   - non-numérique         -> luaL_error
    //
    // Retourne directement la valeur ms (peut lever via luaL_error).
    int64_t parse_timeout_arg(lua_State *L, int idx)
    {
        if (lua_isnoneornil(L, idx))
        {
            return -1; // blocage indéfini
        }
        if (!lua_isnumber(L, idx))
        {
            luaL_error(L,
                       "workers: timeout must be a number (seconds) or nil");
            return 0; // unreachable
        }
        lua_Number n = lua_tonumber(L, idx);
        if (std::isnan(n) || std::isinf(n))
        {
            luaL_error(L,
                       "workers: timeout must be a finite number");
            return 0;
        }
        if (n < 0)
        {
            luaL_error(L,
                       "workers: timeout must be >= 0 (got %g)", (double)n);
            return 0;
        }
        if (n == 0)
        {
            return 0;
        }
        // floor(n * 1000) avec garde anti-débordement à 24h.
        lua_Number ms = std::floor(n * 1000.0);
        if (ms > 24.0 * 3600.0 * 1000.0)
        {
            ms = 24.0 * 3600.0 * 1000.0;
        }
        return (int64_t)ms;
    }

    // =================================================================
    // Chantier 9-2 : send / recv / close côté parent
    // =================================================================
    //
    // w:send(value [, timeout]) -> (true, nil) | (false, reason)
    // w:recv([timeout])         -> (true, value) | (false, reason)
    // w:close()                 -> (true, nil)
    //
    // Conventions de retour :
    //   reason ∈ {"full"|"empty", "timeout", "closed"}
    //   - "full"/"empty" : timeout == 0 et queue saturée/vide immédiatement
    //   - "timeout"      : timeout > 0 expiré sans succès
    //   - "closed"       : queue fermée (worker mort, w:close(), ou GC)
    //
    // Note : en étape 9-2 le worker fork-join classique ignore les
    // queues. Côté parent, send réussit tant que l'inbox a de la place
    // (jusqu'à inbox_capacity), et recv depuis l'outbox renvoie toujours
    // "empty"/"timeout"/"closed" car le worker ne push rien. L'usage
    // réel arrivera en 9-3 quand le worker exposera worker.send/recv.

    int worker_send(lua_State *L)
    {
        Worker *w = check_worker(L, 1);

        // CORRECTIF Gemini : parse_timeout_arg peut faire un longjmp via
        // luaL_error si l'utilisateur passe un timeout invalide. Or
        // longjmp ne déroule PAS les destructeurs C++. Donc on parse
        // le timeout AVANT toute allocation C++ (json, std::string, set).
        int64_t timeout_ms = parse_timeout_arg(L, 3);

        // Sérialiser la valeur (arg 2) -> JSON string.
        // Toute valeur Lua passe : nil, boolean, number, string,
        // table sérialisable. Refus si function/userdata/coroutine/cycle.
        json msg_j;
        std::string err;
        std::unordered_set<const void *> visited;
        if (!lua_to_json(L, 2, msg_j, err, 0, visited))
        {
            return push_fail(L, err);
        }
        std::string msg_str;
        try
        {
            msg_str = msg_j.dump();
        }
        catch (const std::exception &e)
        {
            return push_fail(L,
                             std::string("workers: failed to serialize message: ") + e.what());
        }

        // Push dans l'inbox.
        auto r = w->inbox.push(std::move(msg_str), timeout_ms);
        if (r.first)
        {
            lua_pushboolean(L, 1);
            lua_pushnil(L);
            return 2;
        }
        lua_pushboolean(L, 0);
        lua_pushstring(L, r.second);
        return 2;
    }

    int worker_recv(lua_State *L)
    {
        Worker *w = check_worker(L, 1);

        // Parse timeout (peut lever).
        int64_t timeout_ms = parse_timeout_arg(L, 2);

        // Pop depuis l'outbox.
        std::string msg_str;
        auto r = w->outbox.pop(msg_str, timeout_ms);
        if (!r.first)
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L, r.second);
            return 2;
        }

        // Déserialiser le JSON -> valeur Lua.
        try
        {
            json j = json::parse(msg_str);
            std::string err;
            if (!json_to_lua(L, j, err, 0))
            {
                // Cas extrêmement rare : message qui a été sérialisé mais
                // ne se deserialise pas. Remontée propre.
                lua_pushboolean(L, 0);
                lua_pushstring(L, err.c_str());
                return 2;
            }
        }
        catch (const std::exception &e)
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L, e.what());
            return 2;
        }

        // pile actuelle : ..., value_désérialisée
        // On veut renvoyer (true, value).
        lua_pushboolean(L, 1);
        lua_insert(L, -2); // permute : ..., true, value
        return 2;
    }

    int worker_close(lua_State *L)
    {
        Worker *w = check_worker(L, 1);
        // Idempotent : appeler plusieurs fois est OK (MessageQueue::close
        // est lui-même idempotent).
        // Sémantique : ferme l'INBOX du worker. Tout send ultérieur
        // depuis le parent rendra (false, "closed"). Côté worker (9-3),
        // worker.recv() rendra (false, "closed").
        // L'outbox reste ouverte : le parent peut continuer à drainer
        // les messages restants jusqu'à ce que le worker ferme à son
        // tour ou que __gc passe.
        w->inbox.close();
        lua_pushboolean(L, 1);
        lua_pushnil(L);
        return 2;
    }

    int worker_gc(lua_State *L)
    {
        Worker *w = static_cast<Worker *>(
            luaL_testudata(L, 1, WORKER_META));
        if (!w)
            return 0;

        // Filet de sécurité : si l'utilisateur n'a jamais join/poll,
        // on attend la thread ici. Bloque potentiellement le GC, mais
        // c'est la bonne chose à faire (pas de leak, pas de fd ouvert
        // sur le lua_State enfant).
        //
        // Chantier 9-2 : on close les queues AVANT le join, pour que
        // d'éventuels recv() côté worker (en 9-3+) se débloquent
        // proprement avec "closed". En 9-2 le worker ignore les queues
        // donc le close est neutre, mais la séquence est en place.
        w->inbox.close();
        w->outbox.close();

        if (w->tid_valid)
        {
            pthread_join(w->tid, nullptr);
            w->tid_valid = false;
        }

        // Libération des primitives pthread des queues (init/destroy
        // symétriques). Safe si init() n'avait pas réussi.
        w->inbox.destroy();
        w->outbox.destroy();

        // Appel explicite du destructeur (libère std::string + atomic).
        w->~Worker();
        return 0;
    }

    int worker_tostring(lua_State *L)
    {
        Worker *w = check_worker(L, 1);
        char buf[80];
        int st = w->status.load(std::memory_order_acquire);
        const char *sname = (st == WORKER_RUNNING) ? "running"
                            : (st == WORKER_DONE)  ? "done"
                                                   : "error";
        std::snprintf(buf, sizeof(buf), "Worker(%s)", sname);
        lua_pushstring(L, buf);
        return 1;
    }

} // namespace

// Voir le contrat détaillé dans workers.hpp. fn ne doit faire aucune
// opération Lua (longjmp sous verrou interdit).
bool with_process_env_lock(const std::function<void()> &fn)
{
    std::lock_guard<std::mutex> lk(g_process_state_mu);
    if (g_worker_ever_spawned)
    {
        return false;
    }
    fn();
    return true;
}

void register_workers(lua_State *L)
{
    luaL_newmetatable(L, WORKER_META);
    {
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, worker_gc);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, worker_tostring);
        lua_setfield(L, -2, "__tostring");
        lua_pushcfunction(L, worker_join);
        lua_setfield(L, -2, "join");
        lua_pushcfunction(L, worker_poll);
        lua_setfield(L, -2, "poll");
        // Chantier 9-2 : send / recv / close
        lua_pushcfunction(L, worker_send);
        lua_setfield(L, -2, "send");
        lua_pushcfunction(L, worker_recv);
        lua_setfield(L, -2, "recv");
        lua_pushcfunction(L, worker_close);
        lua_setfield(L, -2, "close");
    }
    lua_pop(L, 1);

    lua_newtable(L);
    lua_pushcfunction(L, lua_workers_spawn);
    lua_setfield(L, -2, "spawn");
    lua_setfield(L, -2, "workers");
}

void set_workers_init_context(const std::string &projectDir,
                              const std::string &exePath,
                              bool embedded)
{
    g_init_ctx.projectDir = projectDir;
    g_init_ctx.exePath = exePath;
    g_init_ctx.embedded = embedded;
    g_init_ctx.initialized = true;
}
