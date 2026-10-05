#ifndef _LARGEFILE64_SOURCE
#define _LARGEFILE64_SOURCE 1
#endif
#include "zip_utils.hpp"
#include "miniz.h"

#include <iostream>
#include <fstream>
#include <filesystem>
#include <system_error>
#include <stdexcept>
#include <cerrno>
#include <exception>
#include <array>
#include <algorithm>
#include <vector>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <memory>
#include <limits>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace
{
    struct ImageMarker { unsigned char bytes[64]; };

    constexpr std::uint64_t marker_integer(const ImageMarker &marker,
                                           std::size_t offset)
    {
        std::uint64_t value = 0;
        for (unsigned i = 0; i < 8; ++i)
            value |= std::uint64_t(marker.bytes[offset + i]) << (8 * i);
        return value;
    }

    constexpr void marker_integer(ImageMarker &marker, std::size_t offset,
                                  std::uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i)
            marker.bytes[offset + i] = static_cast<unsigned char>(value >> (8 * i));
    }

    constexpr std::uint64_t marker_checksum(const ImageMarker &marker)
    {
        std::uint64_t value = 14695981039346656037ull;
        for (std::size_t i = 0; i < 56; ++i)
            value = (value ^ marker.bytes[i]) * 1099511628211ull;
        return value;
    }

    constexpr ImageMarker initial_marker()
    {
        ImageMarker marker{};
        constexpr char magic[] = "BABET_IMAGE_15_f419b2a67e8c930d!";
        static_assert(sizeof(magic) == 33);
        for (std::size_t i = 0; i < 32; ++i) marker.bytes[i] = magic[i];
        marker_integer(marker, 32, 1); // version 1, bare-runtime flag 0
        marker_integer(marker, 56, marker_checksum(marker));
        return marker;
    }

    // Volatile forces reads from the patched, loaded bytes even with LTO.
    // The live reference in runningEmbeddedImageLayout keeps this section
    // reachable under --gc-sections; 'used' alone would not be sufficient.
    __attribute__((used, section(".babet_image")))
    const volatile ImageMarker image_marker = initial_marker();

    ImageMarker loaded_marker()
    {
        ImageMarker marker{};
        for (std::size_t i = 0; i < sizeof(marker.bytes); ++i)
            marker.bytes[i] = image_marker.bytes[i];
        return marker;
    }

    std::optional<EmbeddedImageLayout> decode_marker(const ImageMarker &marker)
    {
        const auto tag = marker_integer(marker, 32);
        if ((tag != 1 && tag != (1ull | (1ull << 32))) ||
            marker_integer(marker, 56) != marker_checksum(marker))
            return std::nullopt;
        EmbeddedImageLayout layout{tag != 1, marker_integer(marker, 40),
                                   marker_integer(marker, 48)};
        if (!layout.generated)
        {
            if (layout.archive_offset || layout.archive_size) return std::nullopt;
        }
        else if (layout.archive_offset < sizeof(ImageMarker) ||
                 layout.archive_size < 22 ||
                 layout.archive_size > std::uint64_t(std::numeric_limits<off64_t>::max()) ||
                 layout.archive_offset >
                     std::uint64_t(std::numeric_limits<off64_t>::max()) - layout.archive_size)
            return std::nullopt;
        return layout;
    }

    class UniqueFd
    {
    public:
        explicit UniqueFd(int fd = -1) : fd_(fd) {}
        ~UniqueFd()
        {
            if (fd_ >= 0)
            {
                ::close(fd_);
            }
        }

        UniqueFd(const UniqueFd &) = delete;
        UniqueFd &operator=(const UniqueFd &) = delete;

        int get() const { return fd_; }

        int release()
        {
            int fd = fd_;
            fd_ = -1;
            return fd;
        }

    private:
        int fd_;
    };

    class TempEntryGuard
    {
    public:
        TempEntryGuard(int directory_fd, const char *name) noexcept
            : directory_fd_(directory_fd), name_(name) {}

        ~TempEntryGuard()
        {
            if (active_)
            {
                (void)::unlinkat(directory_fd_, name_, 0);
            }
        }

        TempEntryGuard(const TempEntryGuard &) = delete;
        TempEntryGuard &operator=(const TempEntryGuard &) = delete;

        void release() noexcept { active_ = false; }

    private:
        int directory_fd_;
        const char *name_;
        bool active_ = true;
    };

    [[noreturn]] void throw_errno(const std::string &operation, int error)
    {
        throw std::system_error(error, std::generic_category(), operation);
    }

    void read_at(int fd, unsigned char *bytes, std::size_t count, off64_t offset)
    {
        while (count)
        {
            const ssize_t n = ::pread64(fd, bytes, count, offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) throw_errno("read executable image descriptor", n < 0 ? errno : EIO);
            bytes += n; count -= static_cast<std::size_t>(n); offset += n;
        }
    }

    void patch_generated_marker(int fd, off64_t prefix_size, off64_t total_size)
    {
        if (prefix_size < static_cast<off64_t>(sizeof(ImageMarker)) ||
            total_size < prefix_size || total_size - prefix_size < 22)
            throw std::runtime_error("invalid executable or archive size");
        const ImageMarker pattern = loaded_marker();
        std::array<unsigned char, 64 * 1024 + 31> buffer{};
        off64_t offset = 0, marker_offset = -1;
        std::size_t carry = 0;
        while (offset < prefix_size)
        {
            const auto count = static_cast<std::size_t>(
                std::min<off64_t>(64 * 1024, prefix_size - offset));
            read_at(fd, buffer.data() + carry, count, offset);
            const std::size_t available = carry + count;
            for (std::size_t i = 0; i + 32 <= available; ++i)
            {
                if (std::memcmp(buffer.data() + i, pattern.bytes, 32) != 0) continue;
                if (marker_offset >= 0)
                    throw std::runtime_error("ambiguous executable image descriptor");
                marker_offset = offset - static_cast<off64_t>(carry) + static_cast<off64_t>(i);
            }
            carry = std::min<std::size_t>(31, available);
            std::memmove(buffer.data(), buffer.data() + available - carry, carry);
            offset += static_cast<off64_t>(count);
        }
        if (marker_offset < 0 ||
            marker_offset > prefix_size - static_cast<off64_t>(sizeof(ImageMarker)))
            throw std::runtime_error("missing executable image descriptor; runtime may be compressed or rewritten (UPX?); rebuild and use an uncompressed runtime");
        ImageMarker marker{};
        read_at(fd, marker.bytes, sizeof(marker.bytes), marker_offset);
        const auto layout = decode_marker(marker);
        if (!layout || layout->generated)
            throw std::runtime_error("builder requires an unmodified bare runtime descriptor");
        marker_integer(marker, 32, 1ull | (1ull << 32));
        marker_integer(marker, 40, static_cast<std::uint64_t>(prefix_size));
        marker_integer(marker, 48, static_cast<std::uint64_t>(total_size - prefix_size));
        marker_integer(marker, 56, marker_checksum(marker));
        std::size_t written = 0;
        while (written < sizeof(marker.bytes))
        {
            const ssize_t n = ::pwrite64(fd, marker.bytes + written,
                sizeof(marker.bytes) - written, marker_offset + static_cast<off64_t>(written));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) throw_errno("write executable image descriptor", n < 0 ? errno : EIO);
            written += static_cast<std::size_t>(n);
        }
    }

    void set_cloexec(int fd, const std::string &path)
    {
        int flags = ::fcntl(fd, F_GETFD);
        if (flags < 0 || ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0)
        {
            throw_errno("set close-on-exec on " + path, errno);
        }
    }

    void copy_fd_contents(int input_fd, int output_fd,
                          const std::string &input_name,
                          const std::string &output_name)
    {
        std::array<char, 64 * 1024> buffer{};

        for (;;)
        {
            ssize_t read_count = ::read(input_fd, buffer.data(),
                                        buffer.size());
            if (read_count == 0)
            {
                return;
            }
            if (read_count < 0)
            {
                if (errno == EINTR)
                {
                    continue;
                }
                throw_errno("read " + input_name, errno);
            }

            ssize_t written = 0;
            while (written < read_count)
            {
                ssize_t write_count =
                    ::write(output_fd, buffer.data() + written,
                            static_cast<std::size_t>(read_count - written));
                if (write_count < 0)
                {
                    if (errno == EINTR)
                    {
                        continue;
                    }
                    throw_errno("write " + output_name, errno);
                }
                if (write_count == 0)
                {
                    throw std::system_error(
                        EIO, std::generic_category(),
                        "write " + output_name + ": zero-byte write");
                }
                written += write_count;
            }
        }
    }

    bool is_vcs_metadata_directory(const fs::directory_entry &entry)
    {
        const std::string name = entry.path().filename().string();
        if (name != ".git" && name != ".svn" && name != ".hg")
        {
            return false;
        }

        // recursive_directory_iterator does not follow directory symlinks by
        // default. is_directory() is used only to avoid excluding a regular
        // file coincidentally named .git/.svn/.hg. Errors are allowed to
        // throw and are handled by the outer scan catch: packaging must fail
        // explicitly rather than silently omit an unreadable subtree.
        return entry.is_directory();
    }

    bool is_embedded_lua_path(const std::string &path)
    {
        return path.size() >= 4 && path.compare(path.size() - 4, 4, ".lua") == 0;
    }

    bool check_embedded_lua_size(const std::string &path, mz_uint64 size)
    {
        if (is_embedded_lua_path(path) && size > MAX_EMBEDDED_FILE_SIZE)
        {
            std::cerr << "embedded file '" << path
                      << "' exceeds maximum embedded file size of 16 MiB"
                      << std::endl;
            return false;
        }
        return true;
    }

    bool validate_packaged_lua_sizes(const std::string &zipFileName)
    {
        mz_zip_archive reader = {};
        if (!mz_zip_reader_init_file(&reader, zipFileName.c_str(), 0))
        {
            std::cerr << "Error reopening completed ZIP for validation" << std::endl;
            return false;
        }
        struct ReaderGuard
        {
            mz_zip_archive *zip;
            ~ReaderGuard() { mz_zip_reader_end(zip); }
        } guard{&reader};

        for (mz_uint i = 0; i < mz_zip_reader_get_num_files(&reader); ++i)
        {
            mz_zip_archive_file_stat info{};
            const mz_uint length = mz_zip_reader_get_filename(&reader, i, nullptr, 0);
            if (length == 0 || !mz_zip_reader_file_stat(&reader, i, &info))
            {
                std::cerr << "Error inspecting completed ZIP" << std::endl;
                return false;
            }
            // m_filename in file_stat is bounded; get the complete name so
            // deeply nested paths cannot hide their .lua suffix.
            std::vector<char> name(length);
            if (mz_zip_reader_get_filename(&reader, i, name.data(), length) != length)
            {
                std::cerr << "Error reading completed ZIP filename" << std::endl;
                return false;
            }
            if (!check_embedded_lua_size(std::string(name.data()), info.m_uncomp_size))
                return false;
        }
        return true;
    }
} // namespace

bool createZipFromDirectory(const std::string &dir, const std::string &zipFileName,
                            const std::string &excludePath)
{
    mz_zip_archive zip = {};

    if (!mz_zip_writer_init_file(&zip, zipFileName.c_str(), 0))
    {
        std::cerr << "Error creating ZIP file: " << zipFileName << std::endl;
        return false;
    }

    bool exclude_exists = false;
    if (!excludePath.empty())
    {
        std::error_code exclude_ec;
        const fs::file_status exclude_status =
            fs::status(excludePath, exclude_ec);
        if (exclude_ec &&
            exclude_ec != std::errc::no_such_file_or_directory &&
            exclude_ec != std::errc::not_a_directory)
        {
            std::cerr << "Error inspecting excluded output '" << excludePath
                      << "': " << exclude_ec.message() << std::endl;
            mz_zip_writer_end(&zip);
            return false;
        }
        exclude_exists = !exclude_ec && fs::exists(exclude_status);
    }

    // CORRECTIF (audit v21) : try/catch autour de l'itération.
    //
    // recursive_directory_iterator (variante sans error_code) JETTE
    // filesystem_error sur une erreur d'OS — typiquement un
    // sous-dossier illisible (EACCES) rencontré pendant le parcours.
    // L'appelant (createExecutableWithDir) appelle cette fonction HORS
    // de son try/catch : avant ce correctif, l'exception remontait
    // jusqu'à main() sans être attrapée -> std::terminate (abort,
    // code 134) au lieu d'un message d'erreur propre + exit 1.
    //
    // Politique : on échoue FORT et PROPREMENT. Pas de
    // skip_permission_denied ici (contrairement à copyTree) : un
    // --create-exe qui embarquerait silencieusement un projet
    // incomplet produirait un binaire cassé de façon différée et
    // difficile à diagnostiquer. Mieux vaut refuser tout de suite
    // avec la cause.
    try
    {
        for (auto it = fs::recursive_directory_iterator(dir);
             it != fs::recursive_directory_iterator(); ++it)
        {
            const fs::directory_entry &entry = *it;

            // Metadata from supported version-control systems is never part
            // of the executable payload. The exclusion is recursive and
            // applies at any depth, not only at the project root.
            if (is_vcs_metadata_directory(entry))
            {
                it.disable_recursion_pending();
                continue;
            }

            if (!fs::is_regular_file(entry))
                continue;

            // CORRECTIF (revue ChatGPT post-v2.2.0, vérifié) : ne
            // jamais réembarquer l'output d'un --create-exe
            // PRÉCÉDENT. `--create-exe . app` lancé deux fois :
            // l'ancien `app` (binaire complet !) vivait dans le
            // dossier parcouru et finissait dans le ZIP du nouveau —
            // app(N+1) = Babet + projet + app(N), croissance à
            // chaque reconstruction. fs::equivalent compare les
            // inodes (symlinks résolus : un lien vers l'output est
            // exclu aussi). L'existence de l'output a été contrôlée une
            // seule fois avant le parcours ; au premier build il n'existe
            // pas encore et aucune comparaison n'est nécessaire. Toute
            // erreur réelle de comparaison fait échouer l'empaquetage.
            if (exclude_exists)
            {
                std::error_code eq_ec;
                const bool is_excluded =
                    fs::equivalent(entry.path(), excludePath, eq_ec);
                if (eq_ec)
                {
                    std::cerr << "Error comparing archive entry '"
                              << entry.path() << "' with excluded output '"
                              << excludePath << "': " << eq_ec.message()
                              << std::endl;
                    mz_zip_writer_end(&zip);
                    return false;
                }
                if (is_excluded)
                {
                    continue;
                }
            }

            // CORRECTIF (audit v21) : PURE lexical, surtout PAS
            // fs::relative — même bug (et même fix) que copyTree.cpp /
            // moveTree.cpp. fs::relative équivaut à
            // weakly_canonical(path).lexically_relative(
            // weakly_canonical(dir)) : il RÉSOUT les symlinks. Pour un
            // module du projet qui est un symlink vers un fichier hors
            // du dossier (ex : proj/mylib.lua -> ../shared/mylib.lua),
            // le nom d'entrée ZIP devenait le chemin de la CIBLE
            // relatif au projet ("../shared/mylib.lua") au lieu de la
            // position du lien ("mylib.lua") -> require("mylib")
            // échouait dans le binaire empaqueté.
            //
            // L'itérateur fournit toujours path = dir/... littéral,
            // donc lexically_relative donne la structure exacte vue
            // dans le projet, sans suivre aucun lien. Le CONTENU, lui,
            // est lu par mz_zip_writer_add_file qui ouvre le chemin et
            // suit donc le symlink : on embarque le bon contenu sous
            // le bon nom. Vérifié aussi avec un slash final sur `dir`
            // (forme produite par la complétion tab) : la
            // décomposition en composants de lexically_relative
            // l'absorbe correctement.
            //
            // Limite préexistante (inchangée) : les symlinks vers des
            // DOSSIERS ne sont pas suivis par
            // recursive_directory_iterator (comportement par défaut),
            // leur contenu n'est donc pas embarqué.
            std::string relativePath =
                entry.path().lexically_relative(dir).string();

            // Reject unusable scripts before doing compression work. Assets
            // with other suffixes retain their existing packaging contract.
            if (is_embedded_lua_path(relativePath) &&
                !check_embedded_lua_size(relativePath, entry.file_size()))
            {
                mz_zip_writer_end(&zip);
                return false;
            }

            if (!mz_zip_writer_add_file(&zip, relativePath.c_str(),
                                        entry.path().string().c_str(),
                                        nullptr, 0, MZ_BEST_COMPRESSION))
            {
                std::cerr << "Error adding to ZIP: " << entry.path() << std::endl;
                mz_zip_writer_end(&zip);
                return false;
            }
        }
    }
    catch (const std::exception &e)
    {
        std::cerr << "Error scanning directory '" << dir << "': "
                  << e.what() << std::endl;
        mz_zip_writer_end(&zip);
        return false;
    }

    if (!mz_zip_writer_finalize_archive(&zip))
    {
        std::cerr << "Error finalizing ZIP" << std::endl;
        mz_zip_writer_end(&zip);
        return false;
    }
    mz_zip_writer_end(&zip);
    try
    {
        // Check the bytes actually archived too: a source file may grow
        // between the initial file_size() and miniz opening it. Publication
        // is only allowed after the completed archive passes this check.
        return validate_packaged_lua_sizes(zipFileName);
    }
    catch (const std::exception &e)
    {
        std::cerr << "Error validating completed ZIP: " << e.what() << std::endl;
        return false;
    }
}

std::optional<EmbeddedImageLayout> runningEmbeddedImageLayout(std::string *error)
{
    if (error) error->clear();
    const auto layout = decode_marker(loaded_marker());
    if (!layout && error) *error = "invalid loaded executable image descriptor";
    return layout;
}

void mergeFiles(const std::string &exe, const std::string &zip,
                const std::string &output)
{
    // Les deux entrées sont ouvertes avant toute création temporaire. Une
    // erreur de lecture ne touche donc jamais l'ancien output.
    UniqueFd exe_fd(::open(exe.c_str(), O_RDONLY | O_CLOEXEC));
    if (exe_fd.get() < 0)
    {
        throw_errno("open " + exe, errno);
    }

    UniqueFd zip_fd(::open(zip.c_str(), O_RDONLY | O_CLOEXEC));
    if (zip_fd.get() < 0)
    {
        throw_errno("open " + zip, errno);
    }

    fs::path output_path(output);
    fs::path parent = output_path.parent_path();
    if (parent.empty())
    {
        parent = ".";
    }

    const std::string base_name = output_path.filename().string();
    if (base_name.empty() || base_name == "." || base_name == "..")
    {
        throw std::invalid_argument(
            "output path must name a regular directory entry");
    }

    // Épingler le parent une seule fois empêche un remplacement concurrent
    // d'un composant symlinké de rediriger la publication vers un autre
    // répertoire. O_PATH n'exige pas le droit de lecture du dossier : seuls
    // les droits de parcours et d'écriture nécessaires à mkstemp/renameat
    // restent applicables.
    UniqueFd parent_fd(
        ::open(parent.c_str(), O_PATH | O_DIRECTORY | O_CLOEXEC));
    if (parent_fd.get() < 0)
    {
        throw_errno("open output directory " + parent.string(), errno);
    }

    // Défense en profondeur pour le contrat « ne jamais écraser le binaire
    // Babet en cours ». Le contrôle historique effectué par l'appelant reste
    // utile pour un diagnostic précoce, mais celui-ci est réalisé sur le
    // parent désormais épinglé et ne peut donc pas être contourné en changeant
    // un symlink dans le chemin du dossier.
    struct stat executable_stat{};
    if (::fstat(exe_fd.get(), &executable_stat) != 0)
    {
        throw_errno("fstat " + exe, errno);
    }

    struct stat output_stat{};
    if (::fstatat(parent_fd.get(), base_name.c_str(), &output_stat, 0) == 0)
    {
        if (output_stat.st_dev == executable_stat.st_dev &&
            output_stat.st_ino == executable_stat.st_ino)
        {
            throw std::runtime_error(
                "output must not overwrite the running Babet executable");
        }
    }
    else if (errno != ENOENT)
    {
        throw_errno("inspect output " + output, errno);
    }

    // Le nom interne est volontairement court et indépendant du basename de
    // sortie. Une destination valide proche de NAME_MAX ne doit pas échouer
    // uniquement parce que le temporaire ajoutait un préfixe et un suffixe.
    // /proc/self/fd/<n> maintient mkstemp dans le parent déjà épinglé.
    const std::string parent_proc =
        "/proc/self/fd/" + std::to_string(parent_fd.get());
    std::string temp_template = parent_proc + "/.babet-output-XXXXXX";
    std::vector<char> temp_buffer(temp_template.begin(),
                                  temp_template.end());
    temp_buffer.push_back('\0');

    const int raw_temp_fd = ::mkstemp(temp_buffer.data());
    if (raw_temp_fd < 0)
    {
        throw_errno("create temporary output in " + parent.string(), errno);
    }

    UniqueFd temp_fd(raw_temp_fd);
    const char *temp_name = std::strrchr(temp_buffer.data(), '/');
    temp_name = temp_name ? temp_name + 1 : temp_buffer.data();
    TempEntryGuard temp_guard(parent_fd.get(), temp_name);
    const std::string temp_display(temp_name);
    set_cloexec(temp_fd.get(), temp_display);

    copy_fd_contents(exe_fd.get(), temp_fd.get(), exe, temp_display);
    const off64_t prefix_size = ::lseek64(temp_fd.get(), 0, SEEK_CUR);
    if (prefix_size < 0) throw_errno("measure executable image", errno);
    copy_fd_contents(zip_fd.get(), temp_fd.get(), zip, temp_display);
    const off64_t total_size = ::lseek64(temp_fd.get(), 0, SEEK_CUR);
    if (total_size < 0) throw_errno("measure packaged image", errno);
    patch_generated_marker(temp_fd.get(), prefix_size, total_size);

    // Le mode final est posé AVANT le rename, mais seulement après que le
    // contenu complet a été écrit. Un temporaire partiel reste ainsi privé
    // (0600, mode de mkstemp), et un échec de chmod laisse l'ancien output
    // intact.
    if (::fchmod(temp_fd.get(), 0755) != 0)
    {
        throw_errno("chmod " + temp_display, errno);
    }

    // Garantit que les écritures du fichier temporaire ont été remises au
    // noyau avant publication. Si fsync échoue, l'ancien output reste intact.
    if (::fsync(temp_fd.get()) != 0)
    {
        throw_errno("fsync " + temp_display, errno);
    }

    // Fermer avant rename simplifie aussi les diagnostics sur certains FS.
    const int fd_to_close = temp_fd.release();
    if (::close(fd_to_close) != 0)
    {
        throw_errno("close " + temp_display, errno);
    }

    if (::renameat(parent_fd.get(), temp_name,
                   parent_fd.get(), base_name.c_str()) != 0)
    {
        throw_errno("rename temporary output to " + output, errno);
    }

    temp_guard.release();
    std::cout << "Successfully created executable: " << output << std::endl;
}

std::optional<std::vector<char>> readEmbeddedFile(
    const std::string &exePath,
    const std::string &archivePath,
    std::string *error,
    const EmbeddedImageLayout *layout)
{
    if (error != nullptr)
    {
        error->clear();
    }

    // Keep the stream available after a failed miniz initialization: miniz
    // can report "central directory not found" even when a read failed.
    // Linux/glibc's 'e' mode makes this descriptor close-on-exec atomically.
    struct FileCloser
    {
        void operator()(FILE *stream) const noexcept { std::fclose(stream); }
    };
    // Match miniz's large-file stdio API on 32-bit Linux too.
    std::unique_ptr<FILE, FileCloser> input(::fopen64(exePath.c_str(), "rbe"));
    if (!input)
    {
        const int open_error = errno;
        if (error != nullptr)
            *error = "cannot open executable image '" + exePath + "': " +
                     std::strerror(open_error);
        return std::nullopt;
    }

    auto image_error = [&](const char *detail)
    {
        if (error) *error = "cannot inspect executable image '" + exePath + "': " + detail;
    };
    if (::fseeko64(input.get(), 0, SEEK_END) != 0)
    {
        image_error("cannot seek executable image");
        return std::nullopt;
    }
    const off64_t image_size = ::ftello64(input.get());
    if (image_size < 0)
    {
        image_error("cannot measure executable image");
        return std::nullopt;
    }
    if (layout && layout->generated &&
        (layout->archive_offset > static_cast<std::uint64_t>(image_size) ||
         static_cast<std::uint64_t>(image_size) - layout->archive_offset != layout->archive_size))
    {
        image_error("generated application size mismatch (truncated or appended data)");
        return std::nullopt;
    }
    std::array<unsigned char, 22> trailer{};
    if (image_size >= static_cast<off64_t>(trailer.size()))
    {
        if (::fseeko64(input.get(), image_size - static_cast<off64_t>(trailer.size()), SEEK_SET) != 0 ||
            std::fread(trailer.data(), 1, trailer.size(), input.get()) != trailer.size() ||
            std::ferror(input.get()) || std::feof(input.get()))
        {
            image_error("read failure or truncated image");
            return std::nullopt;
        }
    }
    // The loaded descriptor, not coincidental PK bytes in ELF data, identifies
    // a bare runtime. Still check image access/I/O before processing arguments.
    if (layout && !layout->generated) return std::nullopt;
    if (image_size < static_cast<off64_t>(trailer.size()) ||
        std::memcmp(trailer.data(), "PK\005\006", 4) != 0 || trailer[20] || trailer[21])
    {
        if (layout && layout->generated) image_error("missing or invalid generated ZIP trailer");
        return std::nullopt;
    }
    const off64_t archive_start = layout ? static_cast<off64_t>(layout->archive_offset) : 0;
    if (::fseeko64(input.get(), archive_start, SEEK_SET) != 0)
    {
        image_error("cannot seek embedded archive");
        return std::nullopt;
    }
    mz_zip_archive zip = {};
    if (!mz_zip_reader_init_cfile(&zip, input.get(), layout ? layout->archive_size : 0, 0))
    {
        const mz_zip_error reason = mz_zip_get_last_error(&zip);
        const bool read_failed = std::ferror(input.get()) || std::feof(input.get());
        if (error != nullptr)
            *error = "cannot inspect executable image '" + exePath + "': " +
                     (read_failed ? "read failure or truncated image"
                                  : mz_zip_get_error_string(reason));
        return std::nullopt;
    }
    // Error-message construction can itself throw under memory pressure.
    // Keep the archive and its file descriptor owned until every return or
    // C++ exception has left this function, including the allocation catch.
    struct ReaderGuard
    {
        mz_zip_archive *zip;
        ~ReaderGuard() { mz_zip_reader_end(zip); }
    } guard{&zip};

    int idx = mz_zip_reader_locate_file(&zip, archivePath.c_str(), nullptr, 0);
    if (idx < 0)
    {
        return std::nullopt;
    }

    mz_zip_archive_file_stat stat;
    if (!mz_zip_reader_file_stat(&zip, idx, &stat))
    {
        if (error != nullptr)
        {
            *error = "cannot inspect embedded file '" + archivePath + "'";
        }
        return std::nullopt;
    }

    if (stat.m_uncomp_size > MAX_EMBEDDED_FILE_SIZE)
    {
        if (error != nullptr)
        {
            *error = "embedded file '" + archivePath +
                     "' exceeds maximum embedded file size of 16 MiB";
        }
        return std::nullopt;
    }

    std::vector<char> data;
    try
    {
        data.resize(static_cast<std::size_t>(stat.m_uncomp_size));
    }
    catch (const std::exception &e)
    {
        if (error != nullptr)
        {
            *error = "cannot allocate memory for embedded file '" +
                     archivePath + "': " + e.what();
        }
        return std::nullopt;
    }

    if (!mz_zip_reader_extract_to_mem(&zip, idx, data.data(), data.size(), 0))
    {
        if (error != nullptr)
        {
            *error = "cannot extract embedded file '" + archivePath + "'";
        }
        return std::nullopt;
    }

    return data;
}
