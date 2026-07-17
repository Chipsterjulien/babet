#ifndef WORKERS_HPP
#define WORKERS_HPP

#include <lua.hpp>
#include <functional>
#include <string>

/**
 * @brief Workers à mémoire Lua isolée, queues privées et channels partagés.
 *
 * API parent :
 *
 *   job, err = babet.workers.spawn(code [, args] [, opts])
 *
 *   code : chaîne Lua stricte.
 *   args : table sérialisable ou nil, visible via worker.args.
 *   opts : inbox_capacity / outbox_capacity, entiers 1..1 000 000,
 *          défaut 64 messages par queue ; channels = table nom->channel.
 *          Toute option inconnue est refusée.
 *
 *   channel, err = babet.workers.channel({ capacity = 64 })
 *
 * Méthodes du channel :
 *
 *   channel:send(v, t?) -> (true, nil) | (false, reason) | (nil, err)
 *   channel:recv(t?)    -> (true, value) | (false, reason) | (nil, err)
 *   channel:close()     -> (true, nil)
 *   channel:is_closed() -> bool
 *
 * Méthodes du job :
 *
 *   job:join(t?)      -> (true, result) | (false, err) |
 *                        (nil, "timeout")
 *   job:status()      -> "running" | "done" | "error"
 *   job:cancel()      -> (true, nil) ; annulation coopérative
 *   job:poll()        -> ("running", nil) |
 *                        ("done", result) | ("error", err)
 *   job:send(v, t?)   -> (true, nil) | (false, reason) | (nil, err)
 *   job:recv(t?)      -> (true, value) | (false, reason)
 *   job:close()       -> (true, nil) ; ferme l'inbox uniquement
 *
 * API dans l'état enfant :
 *
 *   worker.args
 *   worker.channels.<name>
 *   worker.send(v, t?) -> (true, nil) | (false, reason_or_error)
 *   worker.recv(t?)    -> (true, value) | (false, reason)
 *   worker.cancelled() -> bool
 *
 * join(timeout?) attend sur une condition monotone. Un timeout renvoie
 * (nil, "timeout") sans joindre la pthread ni consommer le résultat. status()
 * ne consomme jamais. poll() reste compatible et consomme done/error ; il ne
 * faut donc pas faire poll terminé puis join. cancel() pose un drapeau, ferme
 * seulement l'inbox et réveille worker.recv(), qui renvoie "cancelled" ;
 * l'outbox reste drainable. Un send/recv de channel bloqué dans ce worker est
 * également réveillé avec "cancelled", sans fermer le channel global.
 * L'annulation est coopérative et ne peut pas interrompre un appel système
 * arbitraire. Le __gc demande l'annulation, ferme les deux queues puis joint
 * la pthread, et peut donc encore bloquer si
 * le worker ne termine pas.
 *
 * Les channels sont des queues bornées FIFO, thread-safe, multi-producteurs et
 * multi-consommateurs. close() interdit tout nouvel envoi, réveille les appels
 * bloqués et laisse recv() drainer les messages présents avant "closed". Les
 * handles Lua partagent un même objet C++ via shared_ptr ; le GC d'un handle ne
 * ferme pas le channel global. Un channel n'est jamais sérialisé dans args ou
 * comme message : il doit être transmis explicitement par opts.channels.
 *
 * Transport : nil, booléens, nombres finis, chaînes sans NUL acceptées par le
 * validateur UTF-8, listes denses non vides et objets à clés string. Tables
 * vides -> objets JSON. Fonctions, userdata, coroutines, cycles, tables
 * creuses/mixtes et profondeur > 32 sont refusés. Seule la première valeur de
 * retour traverse ; aucun traceback n'est ajouté automatiquement.
 *
 * Timeout des queues : nil/absent = infini, 0 = immédiat, valeur positive
 * <= 86400 s = attente bornée arrondie au milliseconde supérieur. Les raisons
 * normales sont full, empty, timeout, closed et cancelled.
 */
void register_workers(lua_State *L);

/**
 * @brief Fournit le contexte de chargement des modules utilisateur.
 *
 * À appeler une fois après résolution du mode dossier/embarqué et avant tout
 * spawn. En dossier, projectDir alimente package.path du worker. En embarqué,
 * exePath permet d'enregistrer le searcher ZIP. Si les deux sont vides, seuls
 * stdlib, babet.* et les modules bundle/preload restent disponibles.
 */
void set_workers_init_context(const std::string &projectDir,
                              const std::string &exePath,
                              bool embedded);

/**
 * @brief Exécute une mutation process-wide avant le premier spawn.
 *
 * setenv(3) et chdir(2) modifient un état partagé par tous les threads. Le
 * premier workers.spawn valide marque donc définitivement le processus :
 * toute mutation ultérieure est refusée, même après join et même si ce spawn
 * échoue plus tard pendant sérialisation, initialisation ou pthread_create.
 *
 * `fn` est exécutée sous le verrou uniquement si aucun spawn n'a encore marqué
 * l'état. Elle ne doit effectuer aucune opération Lua : un longjmp sous verrou
 * laisserait le mutex détenu.
 */
bool with_process_env_lock(const std::function<void()> &fn);

#endif // WORKERS_HPP
