#ifndef BABET_PROCESS_LAUNCH_INTERNAL_HPP
#define BABET_PROCESS_LAUNCH_INTERNAL_HPP

#include <string>
#include <utility>
#include <vector>

namespace babet_process::detail
{

struct PreparedCommand
{
    PreparedCommand() = default;
    ~PreparedCommand() = default;
    PreparedCommand(const PreparedCommand &) = delete;
    PreparedCommand &operator=(const PreparedCommand &) = delete;
    PreparedCommand(PreparedCommand &&) = delete;
    PreparedCommand &operator=(PreparedCommand &&) = delete;

    // argv/envp point into the owned string vectors below. Keeping this type
    // immovable turns accidental future relocation into a compile-time error.
    void reset() noexcept;

    std::vector<std::string> argv_strings;
    std::vector<char *> argv;
    std::vector<std::string> env_strings;
    std::vector<char *> envp;
    // Liste ordonnée entièrement construite dans le parent. Une commande
    // contenant '/' produit un seul candidat ; sinon chaque composante PATH
    // produit un chemin absolu interprété depuis le cwd effectif de l'enfant.
    std::vector<std::string> executable_paths;
};

// Prépare entièrement argv, l'environnement effectif et le chemin exécutable
// dans le parent. Pour une commande sans '/', la recherche utilise le PATH de
// l'environnement final transmis à l'enfant. Les entrées PATH relatives ou
// vides sont résolues par rapport au cwd effectif de l'enfant.
bool prepare_command(
    const std::string &command,
    const std::vector<std::string> &argv_strings,
    const std::string &cwd,
    bool has_cwd,
    const std::vector<std::pair<std::string, std::string>> &env_overrides,
    PreparedCommand &prepared,
    int &error_number);

// N'alloue rien : essaie les chemins préparés avec execve() et reproduit la
// priorité Linux ENOENT/ENOTDIR/EACCES. Retourne uniquement en cas d'échec.
int exec_prepared_command(const PreparedCommand &prepared) noexcept;

// Hooks de test internes, non documentés. Le marqueur O_EXCL garantit que le
// délai n'est injecté qu'une seule fois dans un processus de test.
void delay_before_fork_for_test() noexcept;

} // namespace babet_process::detail

#endif // BABET_PROCESS_LAUNCH_INTERNAL_HPP
