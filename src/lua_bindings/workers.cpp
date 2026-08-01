#include "workers.hpp"
#include "lua_utils.hpp"
#include "workers_serialization_budget.hpp"
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
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>

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

    void set_transfer_error(std::string &err,
                            std::string_view context,
                            std::string_view detail)
    {
        err.assign(context.data(), context.size());
        err += ": ";
        err.append(detail.data(), detail.size());
    }

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
    //   - (false, "cancelled") opération d'un worker annulé réveillée
    //   - (false, "out of memory" / "internal ...") erreur interne
    //                        interceptée sans laisser le mutex verrouillé
    //
    // La distinction "full"/"empty" (non-bloquant immédiat) vs "timeout"
    // (attente effective expirée) est utile à l'utilisateur : elle
    // signale s'il vient de tomber sur une queue déjà saturée/vide ou
    // si la condition d'arrêt s'est imposée pendant qu'il patientait.
    struct PthreadMutexGuard
    {
        pthread_mutex_t *mutex;
        bool locked;

        explicit PthreadMutexGuard(pthread_mutex_t *m) noexcept
            : mutex(m), locked(pthread_mutex_lock(m) == 0)
        {
        }

        ~PthreadMutexGuard()
        {
            if (locked)
            {
                pthread_mutex_unlock(mutex);
            }
        }

        PthreadMutexGuard(const PthreadMutexGuard &) = delete;
        PthreadMutexGuard &operator=(const PthreadMutexGuard &) = delete;
    };

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
        std::pair<bool, const char *> push(
            std::string msg, int64_t timeout_ms,
            const std::atomic<bool> *cancel_requested = nullptr)
        {
            PthreadMutexGuard lock(&mu);
            if (!lock.locked)
            {
                return {false, "internal mutex error"};
            }
            const auto cancelled = [&]() noexcept
            {
                return cancel_requested != nullptr &&
                       cancel_requested->load(std::memory_order_acquire);
            };
            if (cancelled())
            {
                return {false, "cancelled"};
            }
            if (closed)
            {
                return {false, "closed"};
            }

            // Cas non-bloquant : retour immédiat si pleine.
            if (timeout_ms == 0)
            {
                if (q.size() >= capacity)
                {
                    return {false, "full"};
                }
            }
            else if (timeout_ms < 0)
            {
                // Bloquant infini : attend tant que pleine ET non-closed.
                while (q.size() >= capacity && !closed && !cancelled())
                {
                    const int rc = pthread_cond_wait(&not_full, &mu);
                    if (rc != 0)
                    {
                        return {false, "internal condition error"};
                    }
                }
                if (cancelled())
                {
                    return {false, "cancelled"};
                }
                if (closed)
                {
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
                while (q.size() >= capacity && !closed && !cancelled())
                {
                    int rc = pthread_cond_timedwait(&not_full, &mu, &deadline);
                    if (rc == ETIMEDOUT)
                    {
                        if (cancelled())
                        {
                            return {false, "cancelled"};
                        }
                        if (q.size() >= capacity && !closed)
                        {
                            return {false, "timeout"};
                        }
                        break;
                    }
                    if (rc != 0)
                    {
                        return {false, "internal condition error"};
                    }
                }
                if (cancelled())
                {
                    return {false, "cancelled"};
                }
                if (closed)
                {
                    return {false, "closed"};
                }
            }

            // Insertion.
            try
            {
                q.push_back(std::move(msg));
            }
            catch (const std::bad_alloc &)
            {
                return {false, "out of memory"};
            }
            catch (...)
            {
                return {false, "internal queue error"};
            }
            pthread_cond_signal(&not_empty);
            return {true, ""};
        }

        // pop : extrait un message dans out_msg. Retourne (true, "") ou
        // (false, reason). out_msg n'est modifié que si succès.
        std::pair<bool, const char *> pop(
            std::string &out_msg, int64_t timeout_ms,
            const std::atomic<bool> *cancel_requested = nullptr)
        {
            PthreadMutexGuard lock(&mu);
            if (!lock.locked)
            {
                return {false, "internal mutex error"};
            }
            const auto cancelled = [&]() noexcept
            {
                return cancel_requested != nullptr &&
                       cancel_requested->load(std::memory_order_acquire);
            };
            if (cancelled())
            {
                return {false, "cancelled"};
            }

            // Cas non-bloquant.
            if (timeout_ms == 0)
            {
                if (q.empty())
                {
                    if (closed)
                    {
                        return {false, "closed"};
                    }
                    return {false, "empty"};
                }
            }
            else if (timeout_ms < 0)
            {
                // Bloquant infini : attend tant que vide ET non-closed.
                while (q.empty() && !closed && !cancelled())
                {
                    const int rc = pthread_cond_wait(&not_empty, &mu);
                    if (rc != 0)
                    {
                        return {false, "internal condition error"};
                    }
                }
                if (cancelled())
                {
                    return {false, "cancelled"};
                }
                if (q.empty() && closed)
                {
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
                while (q.empty() && !closed && !cancelled())
                {
                    int rc = pthread_cond_timedwait(&not_empty, &mu, &deadline);
                    if (rc == ETIMEDOUT)
                    {
                        if (cancelled())
                        {
                            return {false, "cancelled"};
                        }
                        if (q.empty())
                        {
                            if (closed)
                            {
                                return {false, "closed"};
                            }
                            return {false, "timeout"};
                        }
                        break;
                    }
                    if (rc != 0)
                    {
                        return {false, "internal condition error"};
                    }
                }
                if (cancelled())
                {
                    return {false, "cancelled"};
                }
                if (q.empty() && closed)
                {
                    return {false, "closed"};
                }
            }

            // Extraction.
            try
            {
                out_msg = std::move(q.front());
                q.pop_front();
            }
            catch (const std::bad_alloc &)
            {
                return {false, "out of memory"};
            }
            catch (...)
            {
                return {false, "internal queue error"};
            }
            pthread_cond_signal(&not_full);
            return {true, ""};
        }

        // Réveille les waiters sans modifier l'état de la queue. Utilisé
        // par job:cancel() pour que le worker concerné puisse observer son
        // drapeau d'annulation sans fermer le channel partagé.
        void notify_waiters()
        {
            if (!initialized)
                return;
            PthreadMutexGuard lock(&mu);
            if (!lock.locked)
                return;
            pthread_cond_broadcast(&not_full);
            pthread_cond_broadcast(&not_empty);
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
            PthreadMutexGuard lock(&mu);
            if (!lock.locked)
                return;
            closed = true;
            pthread_cond_broadcast(&not_full);
            pthread_cond_broadcast(&not_empty);
        }

        bool is_closed()
        {
            if (!initialized)
                return true;
            PthreadMutexGuard lock(&mu);
            if (!lock.locked)
                return true;
            return closed;
        }
    };

    // Objet C++ partagé par tous les handles Lua d'un même channel.
    // La queue n'est fermée automatiquement que lorsque la dernière
    // référence disparaît. Détruire un handle local ne ferme donc jamais
    // le channel pour les autres états Lua.
    struct SharedChannel
    {
        MessageQueue queue;

        ~SharedChannel()
        {
            queue.close();
            queue.destroy();
        }
    };

    struct ChannelHandle
    {
        std::shared_ptr<SharedChannel> shared;
    };

    struct NamedChannel
    {
        std::string name;
        std::shared_ptr<SharedChannel> shared;
    };

    // Signal de terminaison séparé des queues de messages. join(timeout)
    // attend cette condition sans consommer le résultat. Le statut atomique
    // reste la source de vérité ; le mutex évite les réveils perdus entre le
    // test du prédicat et pthread_cond_wait().
    struct CompletionSignal
    {
        pthread_mutex_t mu;
        pthread_cond_t changed;
        bool initialized;

        CompletionSignal() : initialized(false) {}

        bool init()
        {
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
            if (pthread_cond_init(&changed, &cattr) != 0)
            {
                pthread_condattr_destroy(&cattr);
                pthread_mutex_destroy(&mu);
                return false;
            }
            pthread_condattr_destroy(&cattr);
            initialized = true;
            return true;
        }

        void destroy()
        {
            if (!initialized)
                return;
            pthread_cond_destroy(&changed);
            pthread_mutex_destroy(&mu);
            initialized = false;
        }

        void publish(std::atomic<int> &status, int value) noexcept
        {
            if (!initialized)
            {
                status.store(value, std::memory_order_release);
                return;
            }

            if (pthread_mutex_lock(&mu) != 0)
            {
                // Repli : le statut reste visible. Le broadcast sans verrou
                // réduit le risque d'une attente bloquée si le mutex pthread
                // est dans un état anormal.
                status.store(value, std::memory_order_release);
                pthread_cond_broadcast(&changed);
                return;
            }
            status.store(value, std::memory_order_release);
            pthread_cond_broadcast(&changed);
            pthread_mutex_unlock(&mu);
        }

        enum class WaitResult
        {
            completed,
            timeout,
            internal_error,
        };

        WaitResult wait(std::atomic<int> &status, int64_t timeout_ms) noexcept
        {
            if (status.load(std::memory_order_acquire) != 0)
                return WaitResult::completed;
            if (timeout_ms == 0)
                return WaitResult::timeout;
            if (!initialized)
                return WaitResult::internal_error;

            if (pthread_mutex_lock(&mu) != 0)
                return WaitResult::internal_error;

            WaitResult result = WaitResult::completed;
            if (timeout_ms < 0)
            {
                while (status.load(std::memory_order_acquire) == 0)
                {
                    const int rc = pthread_cond_wait(&changed, &mu);
                    if (rc != 0)
                    {
                        result = WaitResult::internal_error;
                        break;
                    }
                }
            }
            else
            {
                struct timespec deadline;
                MessageQueue::compute_deadline(timeout_ms, deadline);
                while (status.load(std::memory_order_acquire) == 0)
                {
                    const int rc = pthread_cond_timedwait(
                        &changed, &mu, &deadline);
                    if (rc == ETIMEDOUT)
                    {
                        if (status.load(std::memory_order_acquire) == 0)
                            result = WaitResult::timeout;
                        break;
                    }
                    if (rc != 0)
                    {
                        result = WaitResult::internal_error;
                        break;
                    }
                }
            }

            pthread_mutex_unlock(&mu);
            return result;
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

        // Annulation coopérative demandée par le parent. Elle ferme
        // uniquement l'inbox afin de réveiller worker.recv(); l'outbox
        // reste utilisable pour un dernier message de diagnostic.
        std::atomic<bool> cancel_requested;

        // Condition de terminaison utilisée par join(timeout).
        CompletionSignal completion;

        // Sérialisé en sortie de la thread, lu par join()/poll().
        std::string result_json;
        std::string err_msg;

        // Repli sans allocation pour le catch englobant de la thread.
        // Si la construction de err_msg échoue elle-même (bad_alloc),
        // ce buffer fixe permet tout de même de publier une erreur au
        // parent sans laisser sortir d'exception de la pthread.
        char emergency_error[256];

        // Lecture seule pour la thread après spawn. Mémoire stable
        // pendant toute la durée de vie de la thread.
        std::string code;
        std::string args_json;

        // Channels explicitement transmis via opts.channels. La thread
        // enfant transforme chaque shared_ptr en userdata dans
        // worker.channels puis vide ce vecteur pour ne pas prolonger
        // artificiellement leur durée de vie au-delà des handles Lua.
        std::vector<NamedChannel> channels;

        // Un état Lua worker exécute une seule opération de channel à la
        // fois. Le parent conserve ici une référence faible vers le channel
        // actuellement attendu afin que cancel() puisse réveiller sa condvar
        // sans fermer la ressource partagée pour les autres participants.
        std::mutex channel_wait_mu;
        std::weak_ptr<SharedChannel> waiting_channel;

        // Chantier 9-2 : queues bidirectionnelles parent <-> worker.
        // inbox : parent push, worker pop (en 9-3).
        // outbox : worker push (en 9-3), parent pop.
        // Initialisées au spawn(), fermées au __gc avant pthread_join
        // pour que les recv() côté worker se débloquent proprement.
        MessageQueue inbox;
        MessageQueue outbox;
    };

    thread_local Worker *g_current_worker = nullptr;

    class CurrentWorkerScope
    {
    public:
        explicit CurrentWorkerScope(Worker *worker) noexcept
            : previous_(g_current_worker)
        {
            g_current_worker = worker;
        }

        ~CurrentWorkerScope()
        {
            g_current_worker = previous_;
        }

        CurrentWorkerScope(const CurrentWorkerScope &) = delete;
        CurrentWorkerScope &operator=(const CurrentWorkerScope &) = delete;

    private:
        Worker *previous_;
    };

    class ChannelWaitScope
    {
    public:
        ChannelWaitScope(Worker *worker,
                         const std::shared_ptr<SharedChannel> &channel)
            : worker_(worker)
        {
            if (worker_)
            {
                std::lock_guard<std::mutex> lock(worker_->channel_wait_mu);
                worker_->waiting_channel = channel;
            }
        }

        ~ChannelWaitScope()
        {
            if (worker_)
            {
                std::lock_guard<std::mutex> lock(worker_->channel_wait_mu);
                worker_->waiting_channel.reset();
            }
        }

        ChannelWaitScope(const ChannelWaitScope &) = delete;
        ChannelWaitScope &operator=(const ChannelWaitScope &) = delete;

    private:
        Worker *worker_;
    };

    void request_worker_cancellation(Worker *worker)
    {
        worker->cancel_requested.store(true, std::memory_order_release);
        worker->inbox.close();

        std::shared_ptr<SharedChannel> waiting;
        {
            std::lock_guard<std::mutex> lock(worker->channel_wait_mu);
            waiting = worker->waiting_channel.lock();
        }
        if (waiting)
        {
            waiting->queue.notify_waiters();
        }
    }

    constexpr const char *WORKER_META = "LuapilotWorker";
    constexpr const char *CHANNEL_META = "BabetWorkerChannel";

    constexpr int WORKER_RUNNING = 0;
    constexpr int WORKER_DONE = 1;
    constexpr int WORKER_ERROR = 2;

    void publish_worker_status(Worker *w, int status) noexcept
    {
        w->completion.publish(w->status, status);
    }

    const char *worker_error_text(const Worker *w) noexcept
    {
        return w->emergency_error[0] != '\0'
                   ? w->emergency_error
                   : w->err_msg.c_str();
    }

    // Filet de sécurité ultime : cette fonction ne doit jamais lever.
    // Elle ferme les queues, publie un message (avec repli sur buffer
    // fixe) puis passe le worker en WORKER_ERROR avec release.
    void publish_unhandled_worker_exception(Worker *w,
                                            const char *detail) noexcept
    {
        w->inbox.close();
        w->outbox.close();

        w->emergency_error[0] = '\0';
        try
        {
            w->err_msg = "workers: internal: unhandled C++ exception";
            if (detail && detail[0] != '\0')
            {
                w->err_msg += ": ";
                w->err_msg += detail;
            }
        }
        catch (...)
        {
            std::snprintf(w->emergency_error,
                          sizeof(w->emergency_error),
                          "workers: internal C++ exception: %.190s",
                          detail ? detail : "unknown");
        }

        publish_worker_status(w, WORKER_ERROR);
    }

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

    using babet::workers_detail::SerializationBudget;
    using babet::workers_detail::SerializationBudgetStatus;

    bool consume_serialization_node(
        SerializationBudget &budget,
        std::string &err,
        std::string_view context)
    {
        switch (babet::workers_detail::consume_node(budget))
        {
        case SerializationBudgetStatus::ok:
            return true;
        case SerializationBudgetStatus::node_limit:
            set_transfer_error(
                err, context,
                "value exceeds the serialization node budget");
            return false;
        case SerializationBudgetStatus::byte_limit:
            set_transfer_error(
                err, context,
                "value exceeds the serialization byte budget");
            return false;
        case SerializationBudgetStatus::string_too_large:
            break;
        }

        set_transfer_error(
            err, context,
            "internal serialization budget failure");
        return false;
    }

    bool consume_serialization_string(
        SerializationBudget &budget,
        std::size_t length,
        std::string &err,
        std::string_view context)
    {
        switch (babet::workers_detail::consume_string(budget, length))
        {
        case SerializationBudgetStatus::ok:
            return true;
        case SerializationBudgetStatus::byte_limit:
            set_transfer_error(
                err, context,
                "value exceeds the serialization byte budget");
            return false;
        case SerializationBudgetStatus::string_too_large:
            set_transfer_error(
                err, context,
                "string is too large to serialize");
            return false;
        case SerializationBudgetStatus::node_limit:
            break;
        }

        set_transfer_error(
            err, context,
            "internal serialization budget failure");
        return false;
    }

    Worker *check_worker(lua_State *L, int idx)
    {
        return static_cast<Worker *>(luaL_checkudata(L, idx, WORKER_META));
    }

    ChannelHandle *check_channel(lua_State *L, int idx)
    {
        return static_cast<ChannelHandle *>(
            luaL_checkudata(L, idx, CHANNEL_META));
    }

    void push_channel_handle(lua_State *L,
                             const std::shared_ptr<SharedChannel> &shared)
    {
        ChannelHandle *handle = static_cast<ChannelHandle *>(
            lua_newuserdata(L, sizeof(ChannelHandle)));
        new (handle) ChannelHandle{shared};
        luaL_getmetatable(L, CHANNEL_META);
        lua_setmetatable(L, -2);
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
                     std::unordered_set<const void *> &visited,
                     SerializationBudget &budget,
                     std::string_view context);

    // Vérifie directement qu'une string Lua est un UTF-8 canonique :
    // séquences tronquées, octets de continuation isolés, surlongueurs,
    // surrogates UTF-16 et points de code au-delà de U+10FFFF sont refusés.
    // L'octet NUL est également rejeté par le contrat de transport workers.
    //
    // CORRECTIF (post-revue ChatGPT) : on refuse explicitement '\0'.
    // Techniquement '\0' est UTF-8 valide (un seul octet < 0x80), mais
    // sémantiquement c'est du binaire ; et côté désérialisation, les
    // clés d'objet JSON qu'on pousse via lua_setfield seraient tronquées
    // au NUL. Pour cohérence "pas de strings binaires", refus dur.
    bool is_valid_utf8(const char *s, size_t len)
    {
        const auto continuation = [](unsigned char byte)
        {
            return byte >= 0x80U && byte <= 0xBFU;
        };

        size_t i = 0;
        while (i < len)
        {
            const unsigned char first =
                static_cast<unsigned char>(s[i]);
            if (first == 0U)
            {
                return false;
            }
            if (first <= 0x7FU)
            {
                ++i;
                continue;
            }
            if (first >= 0xC2U && first <= 0xDFU)
            {
                if (i + 1 >= len ||
                    !continuation(static_cast<unsigned char>(s[i + 1])))
                {
                    return false;
                }
                i += 2;
                continue;
            }
            if (first >= 0xE0U && first <= 0xEFU)
            {
                if (i + 2 >= len)
                {
                    return false;
                }
                const unsigned char second =
                    static_cast<unsigned char>(s[i + 1]);
                const unsigned char third =
                    static_cast<unsigned char>(s[i + 2]);
                if (!continuation(third) ||
                    (first == 0xE0U &&
                     (second < 0xA0U || second > 0xBFU)) ||
                    (first == 0xEDU &&
                     (second < 0x80U || second > 0x9FU)) ||
                    (first != 0xE0U && first != 0xEDU &&
                     !continuation(second)))
                {
                    return false;
                }
                i += 3;
                continue;
            }
            if (first >= 0xF0U && first <= 0xF4U)
            {
                if (i + 3 >= len)
                {
                    return false;
                }
                const unsigned char second =
                    static_cast<unsigned char>(s[i + 1]);
                const unsigned char third =
                    static_cast<unsigned char>(s[i + 2]);
                const unsigned char fourth =
                    static_cast<unsigned char>(s[i + 3]);
                if (!continuation(third) || !continuation(fourth) ||
                    (first == 0xF0U &&
                     (second < 0x90U || second > 0xBFU)) ||
                    (first == 0xF4U &&
                     (second < 0x80U || second > 0x8FU)) ||
                    (first != 0xF0U && first != 0xF4U &&
                     !continuation(second)))
                {
                    return false;
                }
                i += 4;
                continue;
            }
            return false;
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
                           std::unordered_set<const void *> &visited,
                           SerializationBudget &budget,
                           std::string_view context)
    {
        // Détection de cycle : si on revoit la même table, c'est circulaire.
        const void *table_id = lua_topointer(L, idx);
        if (table_id != nullptr)
        {
            if (visited.find(table_id) != visited.end())
            {
                set_transfer_error(
                    err, context,
                    "table contains a cycle (not serializable)");
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
                if (lua_is_strict_number(L, -2) &&
                    lua_is_strict_integer(L, -2))
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
                                 visited, budget, context))
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
            if (!lua_is_strict_string(L, -2))
            {
                set_transfer_error(
                    err, context,
                    "table key must be a string (non-array table)");
                lua_pop(L, 2);
                return false;
            }
            size_t klen = 0;
            const char *kp = lua_tolstring(L, -2, &klen);
            if (!is_valid_utf8(kp, klen))
            {
                set_transfer_error(
                    err, context,
                    "table key contains non-UTF-8 bytes or NUL");
                lua_pop(L, 2);
                return false;
            }
            if (!consume_serialization_string(
                    budget, klen, err, context))
            {
                lua_pop(L, 2);
                return false;
            }
            std::string key(kp, klen);
            json val;
            if (!lua_to_json(L, lua_gettop(L), val, err, depth + 1,
                             visited, budget, context))
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
                     std::unordered_set<const void *> &visited,
                     SerializationBudget &budget,
                     std::string_view context)
    {
        if (depth > MAX_SERIALIZATION_DEPTH)
        {
            set_transfer_error(err, context, "value too deeply nested");
            return false;
        }
        if (!consume_serialization_node(budget, err, context))
        {
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
            set_transfer_error(
                err, context,
                "lua stack overflow during serialization");
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
            if (lua_is_strict_integer(L, idx))
            {
                out = static_cast<int64_t>(lua_tointeger(L, idx));
                return true;
            }
            else
            {
                double d = lua_tonumber(L, idx);
                if (std::isnan(d) || std::isinf(d))
                {
                    set_transfer_error(
                        err, context,
                        "number is NaN or Inf (not representable in JSON)");
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
                set_transfer_error(
                    err, context,
                    "string contains non-UTF-8 bytes or NUL");
                return false;
            }
            if (!consume_serialization_string(
                    budget, len, err, context))
            {
                return false;
            }
            out = std::string(s, len);
            return true;
        }
        case LUA_TTABLE:
            return lua_table_to_json(
                L, idx, out, err, depth, visited, budget, context);
        case LUA_TFUNCTION:
            set_transfer_error(
                err, context,
                "cannot transfer a function");
            return false;
        case LUA_TUSERDATA:
            set_transfer_error(
                err, context,
                "cannot transfer a userdata");
            return false;
        case LUA_TTHREAD:
            set_transfer_error(
                err, context,
                "cannot transfer a coroutine");
            return false;
        default:
            set_transfer_error(
                err, context,
                "unsupported Lua type for transfer");
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
                     std::string &err, int depth,
                     SerializationBudget &budget,
                     std::string_view context)
    {
        if (depth > MAX_SERIALIZATION_DEPTH)
        {
            set_transfer_error(err, context, "value too deeply nested");
            return false;
        }
        if (!consume_serialization_node(budget, err, context))
        {
            return false;
        }
        // CORRECTIF (revue Gemini post-audit v21, vérifié) : même
        // garde côté désérialisation (createtable + valeur = ~2
        // slots par niveau ; 4 avec marge). Convention « pile propre
        // sur false » préservée : l'échec ici ne pousse rien.
        if (!lua_checkstack(L, 4))
        {
            set_transfer_error(
                err, context,
                "lua stack overflow during deserialization");
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
        if (j.is_number_integer())
        {
            lua_pushinteger(L,
                            static_cast<lua_Integer>(j.get<int64_t>()));
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
            if (!consume_serialization_string(
                    budget, s.size(), err, context))
            {
                return false;
            }
            lua_pushlstring(L, s.data(), s.size());
            return true;
        }
        if (j.is_array())
        {
            lua_createtable(L, static_cast<int>(j.size()), 0);
            lua_Integer idx = 1;
            for (const auto &elem : j)
            {
                if (!json_to_lua(
                        L, elem, err, depth + 1, budget, context))
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
                const std::string &key = it.key();
                if (!consume_serialization_string(
                        budget, key.size(), err, context))
                {
                    lua_pop(L, 1);
                    return false;
                }
                if (!json_to_lua(
                        L, it.value(), err, depth + 1,
                        budget, context))
                {
                    lua_pop(L, 1);
                    return false;
                }
                lua_setfield(L, -2, key.c_str());
            }
            return true;
        }
        set_transfer_error(
            err, context,
            "unsupported JSON type during deserialization");
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
    // Les erreurs Lua sont encapsulées en pcall. La fonction de thread
    // entière est en plus protégée par un catch C++ englobant et déclarée
    // noexcept : aucune exception C++ ne peut sortir vers pthread et
    // déclencher std::terminate(). Toute anomalie devient WORKER_ERROR.

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

        // Sérialiser la valeur (arg 1) -> JSON string. La construction
        // du DOM et dump() peuvent tous deux allouer : aucune exception
        // C++ ne doit traverser la lua_CFunction.
        std::string msg_str;
        try
        {
            json msg_j;
            std::string err;
            std::unordered_set<const void *> visited;
            SerializationBudget budget;
            if (!lua_to_json(
                    L, 1, msg_j, err, 0, visited, budget,
                    "worker.send"))
            {
                // Convention pcall-style côté worker : (false, err).
                lua_pushboolean(L, 0);
                lua_pushlstring(L, err.data(), err.size());
                return 2;
            }
            msg_str = msg_j.dump();
        }
        catch (const std::bad_alloc &)
        {
            lua_pushboolean(L, 0);
            lua_pushliteral(
                L, "worker.send: out of memory during serialization");
            return 2;
        }
        catch (const std::exception &)
        {
            lua_pushboolean(L, 0);
            lua_pushliteral(
                L, "worker.send: internal serialization failure");
            return 2;
        }
        catch (...)
        {
            lua_pushboolean(L, 0);
            lua_pushliteral(
                L, "worker.send: unknown serialization failure");
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

    int worker_side_cancelled(lua_State *L)
    {
        if (lua_gettop(L) != 0)
        {
            return luaL_error(L,
                              "worker.cancelled: expected no arguments");
        }
        Worker *w = static_cast<Worker *>(
            lua_touserdata(L, lua_upvalueindex(1)));
        lua_pushboolean(
            L, w->cancel_requested.load(std::memory_order_acquire));
        return 1;
    }

    int worker_side_recv(lua_State *L)
    {
        Worker *w = static_cast<Worker *>(
            lua_touserdata(L, lua_upvalueindex(1)));

        if (!lua_arity_between(L, 0, 1))
        {
            return luaL_error(
                L, "worker.recv: expected zero or one timeout argument");
        }

        // Parse timeout (peut lever via luaL_error).
        int64_t timeout_ms = parse_timeout_arg(L, 1);

        // Une annulation abandonne immédiatement les commandes encore
        // en file : le worker ne doit pas poursuivre un protocole que le
        // parent vient d'annuler.
        if (w->cancel_requested.load(std::memory_order_acquire))
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L, "cancelled");
            return 2;
        }

        // Pop depuis l'INBOX (parent -> worker).
        std::string msg_str;
        auto r = w->inbox.pop(msg_str, timeout_ms);
        if (!r.first ||
            w->cancel_requested.load(std::memory_order_acquire))
        {
            lua_pushboolean(L, 0);
            lua_pushstring(
                L, w->cancel_requested.load(std::memory_order_acquire)
                       ? "cancelled"
                       : r.second);
            return 2;
        }

        // Déserialiser le JSON -> valeur Lua.
        try
        {
            json j = json::parse(msg_str);
            std::string err;
            SerializationBudget budget;
            if (!json_to_lua(
                    L, j, err, 0, budget, "worker.recv"))
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

    void *worker_thread_run(Worker *w, lua_State *&L)
    {
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

        L = luaL_newstate();
        if (!L)
        {
            w->err_msg = "workers: failed to create lua_State for worker";
            // Fermer d'abord les ressources de communication, puis publier
            // l'état terminal en toute dernière opération. Ainsi status()
            // et join(timeout) n'observent jamais un worker « terminé »
            // alors que son nettoyage est encore en cours.
            w->inbox.close();
            w->outbox.close();
            publish_worker_status(w, WORKER_ERROR);
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
                SerializationBudget budget;
                if (!json_to_lua(
                        L, args_j, err, 0, budget,
                        "workers.spawn"))
                {
                    w->err_msg = err;
                    // Fermer et détruire l'état enfant avant de publier
                    // l'état terminal ; voir le même invariant ci-dessus.
                    w->inbox.close();
                    w->outbox.close();
                    lua_close(L);
                    publish_worker_status(w, WORKER_ERROR);
                    return nullptr;
                }
            }
            catch (const std::exception &e)
            {
                w->err_msg = std::string(
                                 "workers: internal: failed to parse args_json: ") +
                             e.what();
                // Fermer et détruire l'état enfant avant de publier
                // l'état terminal ; voir le même invariant ci-dessus.
                w->inbox.close();
                w->outbox.close();
                lua_close(L);
                publish_worker_status(w, WORKER_ERROR);
                return nullptr;
            }
        }
        lua_setfield(L, -2, "args"); // worker.args = ...

        // Channels partagés explicitement via opts.channels. Chaque état
        // Lua reçoit ses propres userdata, mais tous les handles pointent
        // vers la même SharedChannel. Le vecteur du job est vidé après la
        // publication dans l'état enfant afin que sa durée de vie dépende
        // uniquement des handles Lua encore accessibles.
        lua_createtable(
            L, 0, static_cast<int>(w->channels.size()));
        for (const NamedChannel &named : w->channels)
        {
            push_channel_handle(L, named.shared);
            lua_setfield(L, -2, named.name.c_str());
        }
        lua_setfield(L, -2, "channels");
        w->channels.clear();

        // Chantier 9-3 : worker.send / worker.recv exposés au lua_State
        // enfant via lightuserdata du Worker* en upvalue (W2-C1).
        lua_pushlightuserdata(L, w);
        lua_pushcclosure(L, worker_side_send, 1);
        lua_setfield(L, -2, "send");

        lua_pushlightuserdata(L, w);
        lua_pushcclosure(L, worker_side_recv, 1);
        lua_setfield(L, -2, "recv");

        lua_pushlightuserdata(L, w);
        lua_pushcclosure(L, worker_side_cancelled, 1);
        lua_setfield(L, -2, "cancelled");

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
            w->err_msg = "workers: failed to load code: ";
            w->err_msg += lua_value_to_display_string(L, -1);
            // Fermer et détruire l'état enfant avant de publier
            // l'état terminal ; voir le même invariant ci-dessus.
            w->inbox.close();
            w->outbox.close();
            lua_close(L);
            publish_worker_status(w, WORKER_ERROR);
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
            w->err_msg = "workers: worker raised error: ";
            w->err_msg += lua_value_to_display_string(L, -1);
            // Fermer et détruire l'état enfant avant de publier
            // l'état terminal ; voir le même invariant ci-dessus.
            w->inbox.close();
            w->outbox.close();
            lua_close(L);
            publish_worker_status(w, WORKER_ERROR);
            return nullptr;
        }

        // Sérialiser le résultat.
        json result_j;
        std::unordered_set<const void *> result_visited;
        SerializationBudget result_budget;
        if (!lua_to_json(
                L, -1, result_j, err, 0, result_visited,
                result_budget, "worker return"))
        {
            // L'utilisateur a retourné un truc non sérialisable.
            w->err_msg = std::string(
                             "workers: worker return value is not transferable: ") +
                         err;
            // Fermer et détruire l'état enfant avant de publier
            // l'état terminal ; voir le même invariant ci-dessus.
            w->inbox.close();
            w->outbox.close();
            lua_close(L);
            publish_worker_status(w, WORKER_ERROR);
            return nullptr;
        }
        // Toute exception C++ (UTF-8 JSON invalide, bad_alloc, etc.) est
        // volontairement laissée au catch ENGLOBANT de la pthread. Cela
        // garantit un chemin unique : fermeture du lua_State et des queues,
        // publication WORKER_ERROR, et aucune exception vers pthread.
        w->result_json = result_j.dump();

        // Chantier 9-3 : ferme les queues au succès.
        w->inbox.close();
        w->outbox.close();
        lua_close(L);
        publish_worker_status(w, WORKER_DONE);
        return nullptr;
    }

    void *worker_thread_main(void *arg) noexcept
    {
        Worker *w = static_cast<Worker *>(arg);
        CurrentWorkerScope current_worker_scope(w);
        lua_State *L = nullptr;

        try
        {
            return worker_thread_run(w, L);
        }
        catch (const std::bad_alloc &)
        {
            if (L)
            {
                lua_close(L);
            }
            publish_unhandled_worker_exception(w, "out of memory");
            return nullptr;
        }
        catch (const std::exception &e)
        {
            if (L)
            {
                lua_close(L);
            }
            publish_unhandled_worker_exception(w, e.what());
            return nullptr;
        }
        catch (...)
        {
            if (L)
            {
                lua_close(L);
            }
            publish_unhandled_worker_exception(w, "unknown exception");
            return nullptr;
        }
    }

    // ==================================================================
    // Fonctions exposées
    // ==================================================================

    int lua_workers_spawn(lua_State *L)
    {
        // Contrat strict : le code doit être une vraie chaîne Lua.
        // luaL_checklstring convertirait silencieusement un nombre en texte,
        // puis créerait un worker qui échouerait seulement au chargement du
        // chunk. Refuser immédiatement donne une erreur d'appel claire.
        if (!lua_arity_between(L, 1, 3) ||
            !lua_is_strict_string(L, 1))
        {
            return luaL_error(L,
                              "workers.spawn: code must be a string");
        }
        size_t code_len = 0;
        const char *code = lua_tolstring(L, 1, &code_len);

        // Vérification de type sur args et opts (les contenus sont
        // validés via la sérialisation).
        if (!lua_is_none_or_nil(L, 2) && !lua_istable(L, 2))
        {
            return luaL_error(L,
                              "workers.spawn: args must be a table");
        }
        if (!lua_is_none_or_nil(L, 3) && !lua_istable(L, 3))
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
            // Les fautes de frappe dans opts sont des erreurs de
            // programmation. Valider toutes les clés avant de marquer le
            // processus comme ayant lancé son premier worker.
            lua_pushnil(L);
            while (lua_next(L, 3) != 0)
            {
                if (!lua_is_strict_string(L, -2))
                {
                    return luaL_error(
                        L, "workers.spawn: option names must be strings");
                }
                size_t name_len = 0;
                const char *name = lua_tolstring(L, -2, &name_len);
                if (std::memchr(name, '\0', name_len) != nullptr)
                {
                    return luaL_error(
                        L, "workers.spawn: option names must not contain NUL");
                }
                const bool known_inbox =
                    name_len == std::strlen("inbox_capacity") &&
                    std::memcmp(name, "inbox_capacity", name_len) == 0;
                const bool known_outbox =
                    name_len == std::strlen("outbox_capacity") &&
                    std::memcmp(name, "outbox_capacity", name_len) == 0;
                const bool known_channels =
                    name_len == std::strlen("channels") &&
                    std::memcmp(name, "channels", name_len) == 0;
                if (!known_inbox && !known_outbox && !known_channels)
                {
                    return luaL_error(
                        L, "workers.spawn: unknown option '%s'", name);
                }
                lua_pop(L, 1);
            }

            lua_getfield(L, 3, "inbox_capacity");
            if (!lua_isnil(L, -1))
            {
                if (!lua_is_strict_integer(L, -1))
                {
                    return luaL_error(
                        L, "workers.spawn: opts.inbox_capacity must be an "
                           "integer between 1 and 1000000");
                }
                const lua_Integer n = lua_tointeger(L, -1);
                if (n <= 0 || n > 1000000)
                {
                    return luaL_error(
                        L, "workers.spawn: opts.inbox_capacity must be an "
                           "integer between 1 and 1000000 (got %lld)",
                        static_cast<long long>(n));
                }
                inbox_cap = static_cast<int>(n);
            }
            lua_pop(L, 1);

            lua_getfield(L, 3, "outbox_capacity");
            if (!lua_isnil(L, -1))
            {
                if (!lua_is_strict_integer(L, -1))
                {
                    return luaL_error(
                        L, "workers.spawn: opts.outbox_capacity must be an "
                           "integer between 1 and 1000000");
                }
                const lua_Integer n = lua_tointeger(L, -1);
                if (n <= 0 || n > 1000000)
                {
                    return luaL_error(
                        L, "workers.spawn: opts.outbox_capacity must be an "
                           "integer between 1 and 1000000 (got %lld)",
                        static_cast<long long>(n));
                }
                outbox_cap = static_cast<int>(n);
            }
            lua_pop(L, 1);

            lua_getfield(L, 3, "channels");
            if (!lua_isnil(L, -1))
            {
                if (!lua_istable(L, -1))
                {
                    return luaL_error(
                        L, "workers.spawn: opts.channels must be a table");
                }

                const int channels_idx = lua_absindex(L, -1);
                lua_pushnil(L);
                while (lua_next(L, channels_idx) != 0)
                {
                    if (!lua_is_strict_string(L, -2))
                    {
                        return luaL_error(
                            L,
                            "workers.spawn: channel names must be strings");
                    }
                    size_t channel_name_len = 0;
                    const char *channel_name =
                        lua_tolstring(L, -2, &channel_name_len);
                    if (channel_name_len == 0 ||
                        !is_valid_utf8(channel_name, channel_name_len))
                    {
                        return luaL_error(
                            L,
                            "workers.spawn: channel names must be non-empty UTF-8 strings without NUL");
                    }
                    ChannelHandle *handle = static_cast<ChannelHandle *>(
                        luaL_testudata(L, -1, CHANNEL_META));
                    if (!handle || !handle->shared)
                    {
                        return luaL_error(
                            L,
                            "workers.spawn: opts.channels values must be channels created by babet.workers.channel()");
                    }
                    lua_pop(L, 1);
                }
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
            try
            {
                json args_j;
                std::string err;
                std::unordered_set<const void *> args_visited;
                SerializationBudget budget;
                if (!lua_to_json(
                        L, 2, args_j, err, 0, args_visited,
                        budget, "workers: spawn"))
                {
                    return push_fail(L, err);
                }
                args_json_str = args_j.dump();
            }
            catch (const std::bad_alloc &)
            {
                return push_fail(
                    L,
                    "workers.spawn: out of memory during serialization");
            }
            catch (const std::exception &)
            {
                return push_fail(
                    L,
                    "workers.spawn: internal serialization failure");
            }
            catch (...)
            {
                return push_fail(
                    L,
                    "workers.spawn: unknown serialization failure");
            }
        }

        // Copier les références partagées des channels après toutes les
        // validations susceptibles de lever une erreur Lua. Une erreur
        // d'allocation reste un échec runtime propre (nil, err).
        std::vector<NamedChannel> named_channels;
        if (lua_istable(L, 3))
        {
            lua_getfield(L, 3, "channels");
            if (lua_istable(L, -1))
            {
                const int channels_idx = lua_absindex(L, -1);
                try
                {
                    lua_pushnil(L);
                    while (lua_next(L, channels_idx) != 0)
                    {
                        size_t channel_name_len = 0;
                        const char *channel_name =
                            lua_tolstring(L, -2, &channel_name_len);
                        ChannelHandle *handle =
                            static_cast<ChannelHandle *>(
                                luaL_testudata(L, -1, CHANNEL_META));
                        named_channels.push_back(NamedChannel{
                            std::string(channel_name, channel_name_len),
                            handle->shared,
                        });
                        lua_pop(L, 1);
                    }
                }
                catch (const std::bad_alloc &)
                {
                    lua_settop(L, 3);
                    return push_fail(
                        L, "workers.spawn: out of memory while copying channels");
                }
                catch (const std::exception &e)
                {
                    lua_settop(L, 3);
                    return push_fail(
                        L,
                        std::string("workers.spawn: failed to copy channels: ") +
                            e.what());
                }
            }
            lua_pop(L, 1);
        }

        // Créer le userdata Worker AVANT pthread_create : si pthread
        // échoue, on libère en utilisant le __gc normal (pas de leak).
        Worker *w = static_cast<Worker *>(
            lua_newuserdata(L, sizeof(Worker)));
        new (w) Worker();
        w->tid_valid = false;
        w->status.store(WORKER_RUNNING, std::memory_order_relaxed);
        w->joined.store(false, std::memory_order_relaxed);
        w->cancel_requested.store(false, std::memory_order_relaxed);
        w->emergency_error[0] = '\0';
        w->code.assign(code, code_len);
        w->args_json = std::move(args_json_str);
        w->channels = std::move(named_channels);
        luaL_getmetatable(L, WORKER_META);
        lua_setmetatable(L, -2);

        if (!w->completion.init())
        {
            lua_pop(L, 1);
            return push_fail(
                L, "workers: failed to initialize completion signal");
        }

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

    // Désérialise le résultat interne d'un worker et pousse la valeur Lua.
    // En cas d'échec, restaure exactement la pile et fournit un message
    // explicite dans errbuf. Cette situation indique une corruption ou un
    // bug interne : elle ne doit jamais être transformée en succès + nil.
    bool push_deserialized_worker_result(lua_State *L,
                                         const std::string &result_json,
                                         char *errbuf,
                                         size_t errbuf_size) noexcept
    {
        const int initial_top = lua_gettop(L);
        try
        {
            json r = json::parse(result_json);
            std::string conversion_error;
            SerializationBudget budget;
            if (!json_to_lua(
                    L, r, conversion_error, 0, budget,
                    "workers.join"))
            {
                lua_settop(L, initial_top);
                std::snprintf(
                    errbuf, errbuf_size,
                    "workers: internal: failed to deserialize result: %.380s",
                    conversion_error.c_str());
                return false;
            }
            return true;
        }
        catch (const std::exception &e)
        {
            lua_settop(L, initial_top);
            std::snprintf(
                errbuf, errbuf_size,
                "workers: internal: failed to parse serialized result: %.380s",
                e.what());
            return false;
        }
        catch (...)
        {
            lua_settop(L, initial_top);
            std::snprintf(
                errbuf, errbuf_size,
                "workers: internal: failed to deserialize result");
            return false;
        }
    }

    int worker_join(lua_State *L)
    {
        Worker *w = check_worker(L, 1);
        if (!lua_arity_between(L, 1, 2))
        {
            return luaL_error(
                L, "workers.join: expected self and an optional timeout");
        }

        // parse_timeout_arg peut effectuer un longjmp : l'appeler avant
        // toute construction C++ locale non triviale.
        const int64_t timeout_ms = parse_timeout_arg(L, 2);

        if (w->joined.load(std::memory_order_acquire))
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L,
                           "workers: join: result already consumed");
            return 2;
        }

        const CompletionSignal::WaitResult waited =
            w->completion.wait(w->status, timeout_ms);
        if (waited == CompletionSignal::WaitResult::timeout)
        {
            // Le timeout ne rejoint pas la pthread et ne consomme rien.
            lua_pushnil(L);
            lua_pushstring(L, "timeout");
            return 2;
        }
        if (waited == CompletionSignal::WaitResult::internal_error)
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L, "workers: join: internal wait error");
            return 2;
        }

        if (w->tid_valid)
        {
            pthread_join(w->tid, nullptr);
            w->tid_valid = false; // évite double join via __gc
        }

        w->joined.store(true, std::memory_order_release);

        const int st = w->status.load(std::memory_order_acquire);
        if (st == WORKER_DONE)
        {
            char decode_error[512] = {};
            if (push_deserialized_worker_result(
                    L, w->result_json, decode_error,
                    sizeof(decode_error)))
            {
                lua_pushboolean(L, 1);
                lua_insert(L, -2);
                return 2;
            }

            lua_pushboolean(L, 0);
            lua_pushstring(L, decode_error);
            return 2;
        }

        lua_pushboolean(L, 0);
        lua_pushstring(L, worker_error_text(w));
        return 2;
    }

    int worker_status(lua_State *L)
    {
        Worker *w = check_worker(L, 1);
        if (lua_gettop(L) != 1)
        {
            return luaL_error(L, "workers.status: expected only self");
        }

        const int st = w->status.load(std::memory_order_acquire);
        lua_pushstring(L, st == WORKER_RUNNING ? "running"
                          : st == WORKER_DONE  ? "done"
                                               : "error");
        return 1;
    }

    int worker_cancel(lua_State *L)
    {
        Worker *w = check_worker(L, 1);
        if (lua_gettop(L) != 1)
        {
            return luaL_error(L, "workers.cancel: expected only self");
        }

        // Idempotent. Poser le drapeau avant close() garantit qu'un
        // worker.recv() réveillé traduit la fermeture en "cancelled".
        request_worker_cancellation(w);

        lua_pushboolean(L, 1);
        lua_pushnil(L);
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
            char decode_error[512] = {};
            if (push_deserialized_worker_result(
                    L, w->result_json, decode_error,
                    sizeof(decode_error)))
            {
                lua_pushstring(L, "done");
                lua_insert(L, -2);
                return 2;
            }

            lua_pushstring(L, "error");
            lua_pushstring(L, decode_error);
            return 2;
        }

        // WORKER_ERROR
        lua_pushstring(L, "error");
        lua_pushstring(L, worker_error_text(w));
        return 2;
    }

    // Helper: parse un timeout en secondes (Lua) vers int64_t millisecondes
    // avec la sémantique convenue :
    //   - absent / nil          -> -1 (blocage indéfini)
    //   - 0 (entier ou float)   ->  0 (non-bloquant immédiat)
    //   - 0 < n <= 86400       -> ceil(n * 1000) ms (minimum 1 ms)
    //   - n < 0, n > 86400, NaN, Inf -> luaL_error (mauvais usage)
    //   - non-numérique         -> luaL_error
    //
    // Retourne directement la valeur ms (peut lever via luaL_error).
    int64_t parse_timeout_arg(lua_State *L, int idx)
    {
        if (lua_is_none_or_nil(L, idx))
        {
            return -1; // blocage indéfini
        }
        if (!lua_is_strict_number(L, idx))
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
        // Résolution milliseconde. Toute valeur strictement positive
        // attend au moins 1 ms : l'ancien floor transformait par exemple
        // 0,0005 s en mode non bloquant, contrairement au contrat.
        // Les durées supérieures à 24 h sont refusées plutôt que tronquées
        // silencieusement à 24 h.
        constexpr lua_Number MAX_TIMEOUT_SECONDS = 24.0 * 3600.0;
        if (n > MAX_TIMEOUT_SECONDS)
        {
            luaL_error(L,
                       "workers: timeout too large (max 86400 seconds)");
            return 0;
        }
        lua_Number ms = std::ceil(n * 1000.0);
        if (ms < 1.0)
        {
            ms = 1.0;
        }
        return static_cast<int64_t>(ms);
    }

    // =================================================================
    // Channels directs, bornés et partagés entre états Lua
    // =================================================================

    bool is_queue_flow_reason(const char *reason)
    {
        return std::strcmp(reason, "full") == 0 ||
               std::strcmp(reason, "empty") == 0 ||
               std::strcmp(reason, "timeout") == 0 ||
               std::strcmp(reason, "closed") == 0 ||
               std::strcmp(reason, "cancelled") == 0;
    }

    int lua_workers_channel(lua_State *L)
    {
        if (!lua_arity_between(L, 0, 1))
        {
            return luaL_error(
                L, "workers.channel: expected zero or one options table");
        }
        if (!lua_is_none_or_nil(L, 1) && !lua_istable(L, 1))
        {
            return luaL_error(
                L, "workers.channel: opts must be a table or nil");
        }

        int capacity = 64;
        if (lua_istable(L, 1))
        {
            lua_pushnil(L);
            while (lua_next(L, 1) != 0)
            {
                if (!lua_is_strict_string(L, -2))
                {
                    return luaL_error(
                        L, "workers.channel: option names must be strings");
                }
                size_t name_len = 0;
                const char *name = lua_tolstring(L, -2, &name_len);
                if (std::memchr(name, '\0', name_len) != nullptr)
                {
                    return luaL_error(
                        L,
                        "workers.channel: option names must not contain NUL");
                }
                const bool known_capacity =
                    name_len == std::strlen("capacity") &&
                    std::memcmp(name, "capacity", name_len) == 0;
                if (!known_capacity)
                {
                    return luaL_error(
                        L, "workers.channel: unknown option '%s'", name);
                }
                lua_pop(L, 1);
            }

            lua_getfield(L, 1, "capacity");
            if (!lua_isnil(L, -1))
            {
                if (!lua_is_strict_integer(L, -1))
                {
                    return luaL_error(
                        L,
                        "workers.channel: opts.capacity must be an integer between 1 and 1000000");
                }
                const lua_Integer n = lua_tointeger(L, -1);
                if (n <= 0 || n > 1000000)
                {
                    return luaL_error(
                        L,
                        "workers.channel: opts.capacity must be an integer between 1 and 1000000 (got %lld)",
                        static_cast<long long>(n));
                }
                capacity = static_cast<int>(n);
            }
            lua_pop(L, 1);
        }

        // Créer d'abord un userdata vide afin qu'aucune ressource C++ ne
        // soit détenue si lua_newuserdata déclenche une erreur mémoire Lua.
        ChannelHandle *handle = static_cast<ChannelHandle *>(
            lua_newuserdata(L, sizeof(ChannelHandle)));
        new (handle) ChannelHandle{};
        luaL_getmetatable(L, CHANNEL_META);
        lua_setmetatable(L, -2);

        try
        {
            handle->shared = std::make_shared<SharedChannel>();
        }
        catch (const std::bad_alloc &)
        {
            lua_pop(L, 1);
            return push_fail(L, "workers.channel: out of memory");
        }
        catch (const std::exception &e)
        {
            lua_pop(L, 1);
            return push_fail(
                L,
                std::string("workers.channel: failed to allocate channel: ") +
                    e.what());
        }

        if (!handle->shared->queue.init(static_cast<size_t>(capacity)))
        {
            handle->shared.reset();
            lua_pop(L, 1);
            return push_fail(
                L, "workers.channel: failed to initialize queue");
        }

        return 1;
    }

    int channel_send(lua_State *L)
    {
        ChannelHandle *handle = check_channel(L, 1);
        if (!lua_arity_between(L, 2, 3))
        {
            return luaL_error(
                L,
                "workers.channel.send: expected self, value, and optional timeout");
        }

        // Peut longjmp : doit précéder toute construction C++ locale.
        const int64_t timeout_ms = parse_timeout_arg(L, 3);
        if (!handle->shared)
        {
            return push_fail(
                L, "workers.channel.send: invalid channel handle");
        }

        try
        {
            json message;
            std::string error;
            std::unordered_set<const void *> visited;
            SerializationBudget budget;
            if (!lua_to_json(
                    L, 2, message, error, 0, visited,
                    budget, "workers.channel.send"))
            {
                return push_fail(L, error);
            }

            std::string serialized = message.dump();
            ChannelWaitScope wait_scope(g_current_worker, handle->shared);
            const std::atomic<bool> *cancel_requested =
                g_current_worker ? &g_current_worker->cancel_requested
                                 : nullptr;
            auto result = handle->shared->queue.push(
                std::move(serialized), timeout_ms, cancel_requested);
            if (result.first)
            {
                lua_pushboolean(L, 1);
                lua_pushnil(L);
                return 2;
            }
            if (is_queue_flow_reason(result.second))
            {
                lua_pushboolean(L, 0);
                lua_pushstring(L, result.second);
                return 2;
            }
            return push_fail(
                L,
                std::string("workers.channel.send: ") + result.second);
        }
        catch (const std::bad_alloc &)
        {
            return push_fail(
                L,
                "workers.channel.send: out of memory during serialization");
        }
        catch (const std::exception &)
        {
            return push_fail(
                L,
                "workers.channel.send: internal serialization failure");
        }
        catch (...)
        {
            return push_fail(
                L,
                "workers.channel.send: unknown serialization failure");
        }
    }

    int channel_recv(lua_State *L)
    {
        ChannelHandle *handle = check_channel(L, 1);
        if (!lua_arity_between(L, 1, 2))
        {
            return luaL_error(
                L,
                "workers.channel.recv: expected self and optional timeout");
        }

        const int64_t timeout_ms = parse_timeout_arg(L, 2);
        if (!handle->shared)
        {
            return push_fail(
                L, "workers.channel.recv: invalid channel handle");
        }

        std::string serialized;
        ChannelWaitScope wait_scope(g_current_worker, handle->shared);
        const std::atomic<bool> *cancel_requested =
            g_current_worker ? &g_current_worker->cancel_requested
                             : nullptr;
        auto result = handle->shared->queue.pop(
            serialized, timeout_ms, cancel_requested);
        if (!result.first)
        {
            if (is_queue_flow_reason(result.second))
            {
                lua_pushboolean(L, 0);
                lua_pushstring(L, result.second);
                return 2;
            }
            return push_fail(
                L,
                std::string("workers.channel.recv: ") + result.second);
        }

        try
        {
            json message = json::parse(serialized);
            std::string error;
            SerializationBudget budget;
            if (!json_to_lua(
                    L, message, error, 0, budget,
                    "workers.channel.recv"))
            {
                return push_fail(L, error);
            }
        }
        catch (const std::exception &e)
        {
            return push_fail(
                L,
                std::string("workers.channel.recv: failed to parse message: ") +
                    e.what());
        }

        lua_pushboolean(L, 1);
        lua_insert(L, -2);
        return 2;
    }

    int channel_close(lua_State *L)
    {
        ChannelHandle *handle = check_channel(L, 1);
        if (lua_gettop(L) != 1)
        {
            return luaL_error(
                L, "workers.channel.close: expected only self");
        }
        if (!handle->shared)
        {
            return push_fail(
                L, "workers.channel.close: invalid channel handle");
        }
        handle->shared->queue.close();
        lua_pushboolean(L, 1);
        lua_pushnil(L);
        return 2;
    }

    int channel_is_closed(lua_State *L)
    {
        ChannelHandle *handle = check_channel(L, 1);
        if (lua_gettop(L) != 1)
        {
            return luaL_error(
                L, "workers.channel.is_closed: expected only self");
        }
        lua_pushboolean(
            L,
            !handle->shared || handle->shared->queue.is_closed());
        return 1;
    }

    int channel_gc(lua_State *L)
    {
        ChannelHandle *handle = static_cast<ChannelHandle *>(
            luaL_testudata(L, 1, CHANNEL_META));
        if (handle)
        {
            // Retirer d'abord la métatable rend un appel manuel à __gc
            // idempotent : le finaliseur Lua ultérieur ne reconnaîtra plus
            // ce userdata comme un ChannelHandle construit.
            lua_pushnil(L);
            lua_setmetatable(L, 1);

            // Le userdata contient un vrai std::shared_ptr construit par
            // placement-new. reset() seul libérerait la ressource partagée,
            // mais ne terminerait pas correctement la durée de vie de
            // l'objet C++ avant que Lua recycle sa mémoire.
            handle->~ChannelHandle();
        }
        return 0;
    }

    int channel_tostring(lua_State *L)
    {
        ChannelHandle *handle = check_channel(L, 1);
        const bool closed =
            !handle->shared || handle->shared->queue.is_closed();
        char buffer[48];
        std::snprintf(
            buffer, sizeof(buffer), "WorkerChannel(%s)",
            closed ? "closed" : "open");
        lua_pushstring(L, buffer);
        return 1;
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

        if (w->cancel_requested.load(std::memory_order_acquire))
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L, "cancelled");
            return 2;
        }

        // Sérialiser la valeur (arg 2) -> JSON string.
        // Toute valeur Lua passe : nil, boolean, number, string,
        // table sérialisable. Refus si function/userdata/coroutine/cycle.
        // lua_to_json() construit aussi le DOM et doit rester dans le try.
        std::string msg_str;
        try
        {
            json msg_j;
            std::string err;
            std::unordered_set<const void *> visited;
            SerializationBudget budget;
            if (!lua_to_json(
                    L, 2, msg_j, err, 0, visited, budget,
                    "workers.send"))
            {
                return push_fail(L, err);
            }
            msg_str = msg_j.dump();
        }
        catch (const std::bad_alloc &)
        {
            return push_fail(
                L, "workers.send: out of memory during serialization");
        }
        catch (const std::exception &)
        {
            return push_fail(
                L, "workers.send: internal serialization failure");
        }
        catch (...)
        {
            return push_fail(
                L, "workers.send: unknown serialization failure");
        }

        // Push dans l'inbox.
        auto r = w->inbox.push(std::move(msg_str), timeout_ms);
        if (!r.first &&
            w->cancel_requested.load(std::memory_order_acquire))
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L, "cancelled");
            return 2;
        }
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
            SerializationBudget budget;
            if (!json_to_lua(
                    L, j, err, 0, budget, "workers.recv"))
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
        request_worker_cancellation(w);
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
        w->completion.destroy();

        // Appel explicite du destructeur (libère strings, vectors, mutex et atomics).
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
    luaL_newmetatable(L, CHANNEL_META);
    {
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, channel_gc);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, channel_tostring);
        lua_setfield(L, -2, "__tostring");
        lua_pushcfunction(L, channel_send);
        lua_setfield(L, -2, "send");
        lua_pushcfunction(L, channel_recv);
        lua_setfield(L, -2, "recv");
        lua_pushcfunction(L, channel_close);
        lua_setfield(L, -2, "close");
        lua_pushcfunction(L, channel_is_closed);
        lua_setfield(L, -2, "is_closed");
    }
    lua_pop(L, 1);

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
        lua_pushcfunction(L, worker_status);
        lua_setfield(L, -2, "status");
        lua_pushcfunction(L, worker_cancel);
        lua_setfield(L, -2, "cancel");
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
    lua_pushcfunction(L, lua_workers_channel);
    lua_setfield(L, -2, "channel");
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
