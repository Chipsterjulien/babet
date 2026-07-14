// =====================================================================
// time_clock.hpp — bindings Lua pour les horloges monotone et temps réel
// =====================================================================
//
// Expose deux fonctions à la racine de la table `babet` :
//
//   babet.monotonic() -> number
//     Renvoie un nombre de secondes (avec partie fractionnaire) depuis
//     un point arbitraire (typiquement le boot). Idéal pour mesurer
//     des durées : NE SAUTE JAMAIS en arrière, contrairement à
//     l'horloge système qui peut être ajustée par NTP, l'utilisateur,
//     ou un changement de fuseau.
//
//     Backend : clock_gettime(CLOCK_MONOTONIC).
//
//   babet.now() -> number
//     Renvoie le timestamp Unix (secondes depuis 1970-01-01 UTC) avec
//     partie fractionnaire (précision µs). Pour timestamps de logs,
//     fichiers, comparaisons absolues entre machines synchronisées.
//     Peut sauter (NTP), donc NE PAS l'utiliser pour mesurer des
//     durées — utiliser monotonic() pour ça.
//
//     Backend : clock_gettime(CLOCK_REALTIME).
//
// Pourquoi ces fonctions plutôt que os.time() / os.clock() de la stdlib
// Lua :
//   - os.time() renvoie un integer en secondes ENTIÈRES — pas de
//     précision sub-seconde, donc inutilisable pour les latences IRC
//     ou les timestamps de logs précis.
//   - os.clock() mesure du temps CPU process, pas du temps réel —
//     donne 0 si le process attend (sleep, recv).
//   - Ni l'une ni l'autre ne distingue temps monotone / temps réel.

#ifndef TIME_CLOCK_HPP
#define TIME_CLOCK_HPP

struct lua_State;

// Conventions de retour :
//   number          en succès (une seule valeur Lua)
//   (nil, string)   si clock_gettime échoue — cas théorique sur Linux
//                   moderne, mais prévu par l'implémentation.
//
// Les deux fonctions exigent une arité nulle, y compris via leurs alias
// babet.time.monotonic et babet.time.now.
int lua_monotonic(lua_State *L);
int lua_now(lua_State *L);

#endif // TIME_CLOCK_HPP
