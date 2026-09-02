#ifndef BABET_GUI_HPP
#define BABET_GUI_HPP

struct lua_State;

namespace babet_gui
{

// Enregistre la sous-table optionnelle babet.gui. Aucune bibliothèque GUI
// système n'est chargée pendant cet enregistrement.
void register_gui(lua_State *L);

// État logique du backend GUI. Ce helper ne fait aucun appel GTK et permet à
// ncurses de refuser une seconde boucle interactive concurrente.
bool session_active() noexcept;

// Nettoyage top-level idempotent, réservé au thread principal. GTK 4 ne fournit
// pas de shutdown global symétrique à gtk_init_check(); on libère donc seulement
// l'ownership logique Babet. Le DSO GTK chargé reste résident jusqu'à la fin du
// processus afin de ne jamais invalider des adresses de fonctions résolues.
void cleanup_on_main_thread(lua_State *L) noexcept;

} // namespace babet_gui

#endif // BABET_GUI_HPP
