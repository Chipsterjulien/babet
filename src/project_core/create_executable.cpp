#include "create_executable.hpp"
#include "zip_utils.hpp"
#include "executable_path.hpp"
#include <iostream>
#include <filesystem>
#include <system_error>
#include <exception>
#include <vector>
#include <cstdlib> // mkstemp
#include <cstring> // strerror
#include <cerrno>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace
{
    // Garde RAII : supprime le fichier temporaire sur TOUS les chemins
    // de sortie (succès, exception, return d'erreur précoce). Évite la
    // classe de bug "oubli d'unlink sur un chemin d'erreur" — un échec
    // de createZipFromDirectory laissait sinon traîner le fichier que
    // mkstemp vient de créer. Non-copiable (même discipline que les
    // autres RAII du projet, ex. EVP_MD_CTX_RAII).
    //
    // Un échec du unlink n'invalide pas un binaire correctement produit
    // (cohérent avec le comportement historique : warning, pas d'échec).
    class TempFileGuard
    {
    public:
        explicit TempFileGuard(std::string path) : path_(std::move(path)) {}

        ~TempFileGuard()
        {
            std::error_code ec;
            fs::remove(path_, ec);
            if (ec)
            {
                std::cerr << "Warning: failed to remove temporary file '"
                          << path_ << "' - " << ec.message() << std::endl;
            }
        }

        TempFileGuard(const TempFileGuard &) = delete;
        TempFileGuard &operator=(const TempFileGuard &) = delete;

    private:
        std::string path_;
    };
}

bool createExecutableWithDir(const std::string &dir, const std::string &output)
{
    fs::path mainLuaPath = fs::path(dir) / "main.lua";

    // CORRECTIF (revue ChatGPT post-audit v21) : fichier RÉGULIER
    // exigé. Un DOSSIER nommé main.lua passait fs::exists ; le ZIP ne
    // prend que les fichiers réguliers, donc --create-exe produisait
    // en silence un binaire SANS main.lua embarqué — échec différé et
    // déroutant au premier lancement. is_regular_file suit les
    // symlinks : un lien vers un vrai main.lua reste accepté.
    std::error_code mec;
    if (!fs::is_regular_file(mainLuaPath, mec))
    {
        std::cerr << "Error: main.lua not found (or not a regular file) in the directory "
                  << dir << std::endl;
        return false;
    }

    std::error_code ec;
    fs::path tempDir = fs::temp_directory_path(ec);
    if (ec)
    {
        std::cerr << "Error: cannot locate temp directory - " << ec.message() << std::endl;
        return false;
    }

    // Création ATOMIQUE du temporaire via mkstemp : nom imprévisible +
    // O_EXCL + permissions 0600. Ferme le trou du nom prévisible
    // ("babet_<pid>.zip"), qui sur une machine partagée permettait à
    // un attaquant de pré-créer le fichier / d'y poser un symlink.
    //
    // fs::temp_directory_path() respecte déjà $TMPDIR puis /tmp : on
    // garde cette base, mkstemp ne consulte pas TMPDIR de lui-même.
    //
    // Pas d'extension .zip : mkstemp exige un template finissant par
    // XXXXXX (sinon il faudrait mkstemps, moins portable). Le fichier
    // n'est qu'un intermédiaire concaténé dans le binaire final, son
    // nom n'a aucun impact fonctionnel.
    //
    // TOCTOU résiduelle assumée : createZipFromDirectory/mergeFiles
    // réouvrent par CHEMIN, il reste donc une micro-fenêtre entre
    // mkstemp et la réouverture. Bénigne : fichier créé par nous, 0600,
    // nom aléatoire (ni pré-créable via O_EXCL, ni devinable). La
    // fermer totalement imposerait que zip_utils accepte un fd
    // (refonte séparée, hors périmètre de ce durcissement).
    std::string tmpl = (tempDir / "babet_XXXXXX").string();
    std::vector<char> tmplBuf(tmpl.begin(), tmpl.end());
    tmplBuf.push_back('\0');

    int fd = ::mkstemp(tmplBuf.data());
    if (fd < 0)
    {
        std::cerr << "Error: cannot create temporary file - "
                  << std::strerror(errno) << std::endl;
        return false;
    }
    // createZipFromDirectory rouvrira le fichier par son chemin : on n'a
    // pas besoin du fd, on le ferme (le fichier reste sur disque).
    ::close(fd);

    std::string zipFileName(tmplBuf.data());

    // À partir d'ici le fichier existe : le garde en assure la
    // suppression quel que soit le chemin de sortie.
    TempFileGuard tempZipGuard(zipFileName);

    if (!createZipFromDirectory(dir, zipFileName))
    {
        std::cerr << "Error: failed to create ZIP file." << std::endl;
        return false;
    }

    // getExecutablePath() et mergeFiles() peuvent tous deux lever une
    // exception (lecture de /proc/self/exe, erreurs d'I/O). On les
    // englobe dans un seul try et on attrape std::exception largement.
    // Le nettoyage du temporaire est assuré par tempZipGuard, pas besoin
    // de fs::remove explicite ici.
    try
    {
        std::string exe = getExecutablePath();
        // CORRECTIF (revue post-audit v21, vérifié) : refuser
        // une sortie ÉQUIVALENTE au binaire en cours d'exécution.
        // mergeFiles ouvre la sortie en ofstream (troncature) pendant
        // qu'il LIT le binaire courant : si output désigne le même
        // inode (chemin direct, symlink ou hardlink),
        // `babet --create-exe proj /chemin/vers/babet` DÉTRUISAIT
        // babet lui-même (il ne restait souvent que le zip).
        // fs::equivalent résout liens symboliques et durs.
        std::error_code eq_ec;
        if (fs::exists(output, eq_ec) && fs::equivalent(exe, output, eq_ec))
        {
            std::cerr << "Error: output must not overwrite the running Babet executable."
                      << std::endl;
            return false;
        }
        mergeFiles(exe, zipFileName, output);
    }
    catch (const std::exception &e)
    {
        std::cerr << "Error: failed to build executable - " << e.what() << std::endl;
        return false;
    }

    if (chmod(output.c_str(), 0755) != 0)
    {
        std::cerr << "Error: failed to make the file executable " << output << std::endl;
        return false;
    }

    return true;
}
