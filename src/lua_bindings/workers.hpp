#ifndef WORKERS_HPP
#define WORKERS_HPP

#include <lua.hpp>
#include <string>

/**
 * @brief Chantier 8 — Workers (concurrence à mémoire isolée).
 *
 * Modèle famille B : chaque worker est une pthread avec son propre
 * lua_State neuf, communiquant avec le parent par sérialisation JSON
 * interne. Pas de mémoire partagée, pas de race condition possible
 * au niveau Lua.
 *
 * API publique exposée sur babet.workers :
 *   - spawn(code [, args] [, opts])
 *       Lance un worker exécutant la string Lua `code` dans un
 *       lua_State neuf. `args` est une table sérialisable (scalaires
 *       + tables sans cycle) accessible côté worker via worker.args.
 *       Retourne le userdata worker, ou (nil, err) en cas d'échec
 *       de spawn (sérialisation impossible, échec pthread_create).
 *
 * Méthodes sur userdata worker (convention pcall-style — exception
 * délibérée à la convention (val, err) du reste de Babet, parce
 * qu'un worker peut légitimement retourner nil comme valeur métier) :
 *
 *   - w:join() -> (ok, value)
 *       Attend la fin du worker (bloquant). Retourne (true, result)
 *       en succès ou (false, err_string) si le worker a levé une
 *       erreur Lua.
 *
 *   - w:poll() -> (state, value)
 *       Vérifie l'état sans bloquer. state vaut :
 *         "running" : worker pas terminé, value = nil
 *         "done"    : terminé OK, value = résultat (peut être nil)
 *         "error"   : terminé en erreur, value = message
 *
 * Lifecycle : auto-cleanup du lua_State et de la thread quand join()
 * ou poll()=="done"/"error" est appelé, ou via __gc en filet de
 * sécurité si l'utilisateur oublie.
 *
 * Hors v1 (envisageable en SemVer additif) : spawn(function) via
 * string.dump, w:kill() pour interrompre, pool de workers persistants,
 * channels Go-like, format de sérialisation binaire plus rapide.
 */
void register_workers(lua_State *L);

/**
 * @brief Fournit au module workers le contexte de chargement de
 * modules utilisateur, pour que require("mymod") fonctionne aussi
 * dans les workers (comme dans le parent).
 *
 * À appeler depuis main.cpp UNE fois, après avoir déterminé le mode
 * d'exécution (dossier vs embarqué) et avant tout spawn.
 *
 * En mode dossier : projectDir est le chemin du dossier qui contient
 * main.lua (les workers ajouteront ?.lua et ?/init.lua à leur
 * package.path).
 *
 * En mode embarqué : exePath est le chemin du binaire Babet
 * (les workers enregistreront l'embedded searcher avec ce path).
 *
 * Si l'un des deux est utilisé, l'autre peut être vide. Si les deux
 * sont vides, les workers fonctionneront mais require() utilisateur
 * échouera (seuls stdlib + babet.* + modules bundlés via
 * package.preload restent disponibles).
 */
void set_workers_init_context(const std::string &projectDir,
                              const std::string &exePath,
                              bool embedded);

#include <functional>

/*
 * État processus partagé (option A validée — revues croisées triées).
 *
 * setenv(3) et le répertoire courant sont PROCESS-WIDE : une mutation
 * pendant qu'un worker lit l'environnement (getenv, exec, résolution
 * DNS) est une course de données (setenv peut realloc `environ`), et
 * un chdir change le CWD de tous les threads. Règle unique, simple et
 * sans course : mutations autorisées AVANT le premier workers.spawn,
 * interdites ensuite — définitivement, même après join, même si le
 * spawn a ensuite échoué.
 *
 * with_process_env_lock(fn) : exécute fn() sous le verrou d'état
 * processus SI aucun worker n'a jamais été lancé, et rend true.
 * Rend false (sans exécuter fn) si un worker a déjà été lancé.
 * spawn marque le drapeau sous le MÊME verrou, avant toute création
 * effective : aucun worker ne peut naître pendant une mutation.
 * IMPORTANT : fn ne doit faire AUCUNE opération Lua (un longjmp sous
 * verrou laisserait le mutex tenu) — uniquement le syscall, résultats
 * capturés dans des locales.
 */
bool with_process_env_lock(const std::function<void()> &fn);

#endif // WORKERS_HPP
