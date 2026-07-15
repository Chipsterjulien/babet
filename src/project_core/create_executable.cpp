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
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace
{
class ScopedFd
{
  public:
    explicit ScopedFd(int fd = -1) noexcept : fd_(fd) {}

    ~ScopedFd()
    {
        if (fd_ >= 0)
        {
            ::close(fd_);
        }
    }

    ScopedFd(const ScopedFd &) = delete;
    ScopedFd &operator=(const ScopedFd &) = delete;

    int get() const noexcept { return fd_; }

  private:
    int fd_;
};
} // namespace

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
    const fs::file_status main_status = fs::status(mainLuaPath, mec);
    if (mec && mec != std::errc::no_such_file_or_directory &&
        mec != std::errc::not_a_directory)
    {
        std::cerr << "Error: cannot inspect main.lua in directory " << dir
                  << " - " << mec.message() << std::endl;
        return false;
    }
    if (!fs::is_regular_file(main_status))
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

    // Création atomique du temporaire via mkstemp : O_EXCL et permissions
    // 0600. Le nom n'est utilisé que le temps de créer l'inode. Il est ensuite
    // supprimé immédiatement de l'arborescence ; le fichier reste vivant grâce
    // au descripteur ouvert et sera détruit automatiquement à sa fermeture.
    //
    // createZipFromDirectory() et mergeFiles() attendent encore un chemin.
    // /proc/self/fd/<n> est un magic link Linux vers le descripteur déjà ouvert :
    // leurs réouvertures restent donc attachées au même inode anonyme. Il ne
    // subsiste plus de fenêtre permettant de remplacer le temporaire par un
    // symlink ou un autre fichier entre mkstemp, miniz et la fusion finale.
    std::string tmpl = (tempDir / "babet_XXXXXX").string();
    std::vector<char> tmplBuf(tmpl.begin(), tmpl.end());
    tmplBuf.push_back('\0');

    const int raw_temp_fd = ::mkstemp(tmplBuf.data());
    if (raw_temp_fd < 0)
    {
        std::cerr << "Error: cannot create temporary file - "
                  << std::strerror(errno) << std::endl;
        return false;
    }
    ScopedFd temp_zip_fd(raw_temp_fd);

    const int fd_flags = ::fcntl(temp_zip_fd.get(), F_GETFD);
    if (fd_flags < 0 ||
        ::fcntl(temp_zip_fd.get(), F_SETFD, fd_flags | FD_CLOEXEC) < 0)
    {
        const int saved_errno = errno;
        (void)::unlink(tmplBuf.data());
        std::cerr << "Error: cannot protect temporary file descriptor - "
                  << std::strerror(saved_errno) << std::endl;
        return false;
    }

    if (::unlink(tmplBuf.data()) != 0)
    {
        std::cerr << "Error: cannot unlink temporary file - "
                  << std::strerror(errno) << std::endl;
        return false;
    }

    const std::string zipFileName =
        "/proc/self/fd/" + std::to_string(temp_zip_fd.get());

    // CORRECTIF (revue ChatGPT post-v2.2.0, vérifié) : chemin absolu
    // de l'output transmis au zippage pour exclusion — un output de
    // build précédent situé DANS le dossier empaqueté était
    // réembarqué (voir zip_utils.cpp). weakly_canonical tolère une
    // feuille absente (premier build) ; en cas d'échec de résolution
    // (rarissime), exclude reste vide et on retombe sur l'ancien
    // comportement, jamais sur un crash.
    std::error_code xc;
    fs::path exclude_abs = fs::weakly_canonical(fs::absolute(output, xc), xc);

    if (!createZipFromDirectory(dir, zipFileName, exclude_abs.string()))
    {
        std::cerr << "Error: failed to create ZIP file." << std::endl;
        return false;
    }

    // getExecutablePath() et mergeFiles() peuvent tous deux lever une
    // exception (lecture de /proc/self/exe, erreurs d'I/O). On les
    // englobe dans un seul try et on attrape std::exception largement.
    // Le ZIP temporaire est anonyme et sera détruit par ScopedFd.
    try
    {
        std::string exe = getExecutablePath();
        // CORRECTIF (revue ChatGPT post-audit v21, vérifié) : refuser
        // une sortie ÉQUIVALENTE au binaire en cours d'exécution.
        // Même si mergeFiles publie maintenant par rename atomique, on
        // refuse toujours que output désigne le binaire en cours : remplacer
        // l'exécutable lancé serait une opération surprenante et risquée.
        // Si output désigne le même
        // inode (chemin direct, symlink ou hardlink),
        // `babet --create-exe proj /chemin/vers/babet` DÉTRUISAIT
        // babet lui-même (il ne restait souvent que le zip).
        // fs::equivalent résout liens symboliques et durs.
        std::error_code eq_ec;
        const bool output_exists = fs::exists(output, eq_ec);
        if (eq_ec)
        {
            throw std::system_error(
                eq_ec, "cannot inspect output path '" + output + "'");
        }
        if (output_exists)
        {
            const bool same_file = fs::equivalent(exe, output, eq_ec);
            if (eq_ec)
            {
                throw std::system_error(
                    eq_ec, "cannot compare output path '" + output + "'");
            }
            if (same_file)
            {
                std::cerr << "Error: output must not overwrite the running Babet executable."
                          << std::endl;
                return false;
            }
        }
        mergeFiles(exe, zipFileName, output);
    }
    catch (const std::exception &e)
    {
        std::cerr << "Error: failed to build executable - " << e.what() << std::endl;
        return false;
    }

    // mergeFiles écrit dans un temporaire du même dossier, pose le mode
    // 0755, fsync puis publie par rename atomique. Aucun chmod ne doit être
    // effectué après publication : son échec laisserait sinon un nouvel
    // output en place tout en annonçant que la construction a échoué.

    return true;
}
