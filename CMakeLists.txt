cmake_minimum_required(VERSION 3.22)
project(babet VERSION 2.15.0 LANGUAGES CXX C)

# Génère src/generated/version.hpp depuis src/version.hpp.in,
# en injectant les composants de version définis dans project().
# Ainsi CMakeLists.txt reste la seule source de vérité pour la version.
configure_file(
    ${CMAKE_SOURCE_DIR}/src/version.hpp.in
    ${CMAKE_BINARY_DIR}/generated/version.hpp
    @ONLY
)

# Permet aux fichiers source de #include "version.hpp".
include_directories(${CMAKE_BINARY_DIR}/generated)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 99)

# Validation mémoire/UB optionnelle pour les builds de pré-release.
# Désactivée par défaut afin de ne rien changer aux builds normaux ni
# aux binaires distribués. Compatible GCC et Clang.
option(BABET_ENABLE_SANITIZERS
       "Enable AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

# External libs provided by build_local.sh
if(NOT LUA_INCLUDE OR NOT LUA_LIB)
    message(FATAL_ERROR "Lua paths not set (LUA_INCLUDE, LUA_LIB)")
endif()

if(NOT OPENSSL_LIB OR NOT CRYPTO_LIB)
    message(FATAL_ERROR "OpenSSL paths not set (OPENSSL_LIB, CRYPTO_LIB)")
endif()

if(NOT MINIZ_SRC OR NOT MINIZ_INCLUDE)
    message(FATAL_ERROR "miniz paths not set (MINIZ_SRC, MINIZ_INCLUDE)")
endif()

# libarchive : bibliothèque C statique compilée localement et épinglée par
# build_local.sh. La 2.8.0 l'utilise pour créer, inspecter et extraire les TAR
# non compressés, gzip, xz, bzip2 et zstd. Toutes les bibliothèques de
# compression sont compilées localement et liées statiquement.
if(NOT LIBARCHIVE_LIB OR NOT LIBARCHIVE_INCLUDE)
    message(FATAL_ERROR
        "libarchive paths not set (LIBARCHIVE_LIB, LIBARCHIVE_INCLUDE)")
endif()

# zlib : dépendance statique épinglée utilisée par le filtre gzip de
# libarchive. Les en-têtes et la bibliothèque doivent provenir de la même
# installation locale : utiliser les headers système avec la libz.a épinglée
# produirait une incohérence de version détectée au démarrage.
# La bibliothèque doit être liée explicitement après libarchive, car cette
# dernière est elle-même statique.
if(NOT ZLIB_LIB OR NOT ZLIB_INCLUDE)
    message(FATAL_ERROR "zlib paths not set (ZLIB_LIB, ZLIB_INCLUDE)")
endif()

if(NOT EXISTS "${ZLIB_LIB}")
    message(FATAL_ERROR "zlib static library not found: ${ZLIB_LIB}")
endif()

if(NOT EXISTS "${ZLIB_INCLUDE}/zlib.h" OR
   NOT EXISTS "${ZLIB_INCLUDE}/zconf.h")
    message(FATAL_ERROR
        "zlib headers not found in ZLIB_INCLUDE: ${ZLIB_INCLUDE}")
endif()

# XZ Utils / liblzma : dépendance statique épinglée utilisée par le filtre xz
# de libarchive. Comme pour zlib, les en-têtes et la bibliothèque doivent
# provenir de la même installation locale.
if(NOT LZMA_LIB OR NOT LZMA_INCLUDE)
    message(FATAL_ERROR "liblzma paths not set (LZMA_LIB, LZMA_INCLUDE)")
endif()

if(NOT EXISTS "${LZMA_LIB}")
    message(FATAL_ERROR "liblzma static library not found: ${LZMA_LIB}")
endif()

if(NOT EXISTS "${LZMA_INCLUDE}/lzma.h" OR
   NOT EXISTS "${LZMA_INCLUDE}/lzma/version.h")
    message(FATAL_ERROR
        "liblzma headers not found in LZMA_INCLUDE: ${LZMA_INCLUDE}")
endif()

# bzip2 / libbz2 : dépendance statique épinglée utilisée par le filtre bzip2
# de libarchive. Le header public ne fournit pas de macro de version exploitable,
# donc build_local.sh transmet aussi la version attendue, vérifiée au démarrage
# contre BZ2_bzlibVersion().
if(NOT BZIP2_LIB OR NOT BZIP2_INCLUDE OR NOT BZIP2_VERSION)
    message(FATAL_ERROR
        "bzip2 paths/version not set (BZIP2_LIB, BZIP2_INCLUDE, BZIP2_VERSION)")
endif()

if(NOT EXISTS "${BZIP2_LIB}")
    message(FATAL_ERROR "libbz2 static library not found: ${BZIP2_LIB}")
endif()

if(NOT EXISTS "${BZIP2_INCLUDE}/bzlib.h")
    message(FATAL_ERROR
        "libbz2 header not found in BZIP2_INCLUDE: ${BZIP2_INCLUDE}")
endif()

# Zstandard / libzstd : dépendance statique épinglée utilisée par le filtre
# zstd de libarchive. Les en-têtes et la bibliothèque doivent provenir de la
# même installation locale ; la cohérence est vérifiée au démarrage via
# ZSTD_VERSION_STRING et ZSTD_versionString().
if(NOT ZSTD_LIB OR NOT ZSTD_INCLUDE)
    message(FATAL_ERROR "libzstd paths not set (ZSTD_LIB, ZSTD_INCLUDE)")
endif()

if(NOT EXISTS "${ZSTD_LIB}")
    message(FATAL_ERROR "libzstd static library not found: ${ZSTD_LIB}")
endif()

if(NOT EXISTS "${ZSTD_INCLUDE}/zstd.h" OR
   NOT EXISTS "${ZSTD_INCLUDE}/zstd_errors.h")
    message(FATAL_ERROR
        "libzstd headers not found in ZSTD_INCLUDE: ${ZSTD_INCLUDE}")
endif()


# RE2 + Abseil : moteur d'expressions régulières borné et sa dépendance
# transitive, tous deux compilés localement et statiquement par build_local.sh.
# Les chemins CMake sont imposés afin qu'aucune installation système ne puisse
# être sélectionnée silencieusement.
if(NOT ABSL_CMAKE_DIR OR NOT RE2_CMAKE_DIR OR NOT RE2_INCLUDE)
    message(FATAL_ERROR
        "RE2/Abseil paths not set (ABSL_CMAKE_DIR, RE2_CMAKE_DIR, RE2_INCLUDE)")
endif()

if(NOT EXISTS "${ABSL_CMAKE_DIR}/abslConfig.cmake")
    message(FATAL_ERROR
        "local Abseil CMake package not found: ${ABSL_CMAKE_DIR}")
endif()

if(NOT EXISTS "${RE2_CMAKE_DIR}/re2Config.cmake" OR
   NOT EXISTS "${RE2_INCLUDE}/re2/re2.h")
    message(FATAL_ERROR
        "local RE2 package/headers not found: ${RE2_CMAKE_DIR}, ${RE2_INCLUDE}")
endif()

set(absl_DIR "${ABSL_CMAKE_DIR}" CACHE PATH
    "Pinned local Abseil package" FORCE)
set(re2_DIR "${RE2_CMAKE_DIR}" CACHE PATH
    "Pinned local RE2 package" FORCE)

find_package(absl CONFIG REQUIRED NO_DEFAULT_PATH
    PATHS "${ABSL_CMAKE_DIR}")
find_package(re2 CONFIG REQUIRED NO_DEFAULT_PATH
    PATHS "${RE2_CMAKE_DIR}")

if(NOT TARGET absl::base OR NOT TARGET re2::re2)
    message(FATAL_ERROR "local Abseil/RE2 imported targets are incomplete")
endif()

# Vérifie aussi l'origine physique des bibliothèques importées. Les packages
# CMake peuvent propager de nombreuses cibles Abseil : contrôler une cible
# fondamentale et RE2 suffit à détecter un mélange avec /usr/lib.
function(babet_require_local_imported_target target expected_prefix)
    get_target_property(_location "${target}" IMPORTED_LOCATION_RELEASE)
    if(NOT _location)
        get_target_property(_location "${target}" IMPORTED_LOCATION_NOCONFIG)
    endif()
    if(NOT _location)
        get_target_property(_location "${target}" IMPORTED_LOCATION)
    endif()
    if(NOT _location)
        message(FATAL_ERROR
            "cannot determine imported location for ${target}")
    endif()
    cmake_path(IS_PREFIX expected_prefix "${_location}" NORMALIZE _is_local)
    if(NOT _is_local)
        message(FATAL_ERROR
            "${target} does not come from the pinned local install: ${_location}")
    endif()
endfunction()

get_filename_component(ABSL_INSTALL_PREFIX "${ABSL_CMAKE_DIR}/../../.." ABSOLUTE)
get_filename_component(RE2_INSTALL_PREFIX "${RE2_CMAKE_DIR}/../../.." ABSOLUTE)
babet_require_local_imported_target(absl::base "${ABSL_INSTALL_PREFIX}")
babet_require_local_imported_target(re2::re2 "${RE2_INSTALL_PREFIX}")

# nlohmann/json : header-only, fourni par build_local.sh.
if(NOT JSON_INCLUDE)
    message(FATAL_ERROR "JSON_INCLUDE not set (nlohmann/json header dir)")
endif()

# cpp-httplib : header-only, fourni par build_local.sh. TLS activé
# localement dans src/lua_bindings/http.cpp (CPPHTTPLIB_OPENSSL_SUPPORT),
# pas en define global ici : httplib.h n'est inclus que dans cette TU.
if(NOT HTTPLIB_INCLUDE)
    message(FATAL_ERROR "HTTPLIB_INCLUDE not set (cpp-httplib header dir)")
endif()

# toml++ : header-only, fourni par build_local.sh. C++17 minimum
# satisfait (projet en C++23). Pas de TLS, pas de threads.
if(NOT TOMLPP_INCLUDE)
    message(FATAL_ERROR "TOMLPP_INCLUDE not set (toml++ header dir)")
endif()

# SQLite : amalgamation officielle (sqlite3.c + sqlite3.h), single-file
# fourni par build_local.sh. Compilé en C (pas C++) et lié dans le
# binaire final. SQLITE_THREADSAFE=1 (défaut) → un mutex global suffit
# pour notre usage actuel : chaque babet.sqlite.open() crée son
# propre handle, et les threads (workers) ne se partagent pas leurs
# handles (recommandation SQLite : "Do not pass a database connection
# from one thread to another").
if(NOT SQLITE_SRC OR NOT SQLITE_INCLUDE)
    message(FATAL_ERROR "SQLite paths not set (SQLITE_SRC, SQLITE_INCLUDE)")
endif()

# Dossier des headers générés (embedded_inspect.hpp et co)
# Doit être créé et peuplé par build_local.sh AVANT le cmake.
if(NOT GENERATED_INCLUDE)
    message(FATAL_ERROR "GENERATED_INCLUDE not set (build/generated path)")
endif()

# Sources
file(GLOB_RECURSE PROJECT_SOURCES
    src/lua_bindings/*.cpp
    src/project_core/*.cpp
)
list(APPEND PROJECT_SOURCES
    src/main.cpp
    ${MINIZ_SRC}
    ${SQLITE_SRC}
)

add_executable(${PROJECT_NAME} ${PROJECT_SOURCES})

# Compile-time options for sqlite3.c.
# SQLITE_DQS=0           : refuse les "double-quoted strings as identifiers"
# (sécurité — évite des bugs SQL subtils).
# SQLITE_THREADSAFE=1    : verrouillage par mutex (défaut) — sûr pour
# notre usage workers.
# SQLITE_DEFAULT_MEMSTATUS=0 : désactive le tracking d'allocations
# (perf gain, on ne s'en sert pas).
# SQLITE_OMIT_DEPRECATED : exclut les API dépréciées.
# SQLITE_OMIT_LOAD_EXTENSION : pas de chargement de .so en runtime —
# on est un binaire statique et embarqué,
# aucun cas d'usage justifie ça pour Babet.
set_source_files_properties(${SQLITE_SRC} PROPERTIES
    COMPILE_FLAGS "-DSQLITE_DQS=0 \
                   -DSQLITE_THREADSAFE=1 \
                   -DSQLITE_DEFAULT_MEMSTATUS=0 \
                   -DSQLITE_OMIT_DEPRECATED \
                   -DSQLITE_OMIT_LOAD_EXTENSION"
)

# BEFORE garantit que les en-têtes zlib, liblzma, libbz2, libzstd et RE2
# proviennent des versions épinglées, même si d’autres versions sont installées
# dans /usr/include.
target_include_directories(${PROJECT_NAME} BEFORE PRIVATE
    ${ZLIB_INCLUDE}
    ${LZMA_INCLUDE}
    ${BZIP2_INCLUDE}
    ${ZSTD_INCLUDE}
    ${RE2_INCLUDE}
)

target_include_directories(${PROJECT_NAME} PRIVATE
    ${LUA_INCLUDE}
    ${MINIZ_INCLUDE}
    ${LIBARCHIVE_INCLUDE}
    ${JSON_INCLUDE}
    ${HTTPLIB_INCLUDE}
    ${SQLITE_INCLUDE}
    ${GENERATED_INCLUDE}
    ${PROJECT_SOURCE_DIR}/src
)

# toml++ est une dépendance externe header-only. GCC 16 signale dans sa
# release épinglée 3.4.0 les anciens opérateurs littéraux `operator"" _toml`
# et `operator"" _tpath` comme dépréciés en C++23. Le chemin SYSTEM produit
# un include `-isystem` : les diagnostics du code tiers sont masqués, tandis
# que les avertissements provenant du code Babet restent pleinement actifs.
target_include_directories(${PROJECT_NAME} SYSTEM PRIVATE
    ${TOMLPP_INCLUDE}
)

target_compile_definitions(${PROJECT_NAME} PRIVATE
    LIBARCHIVE_STATIC
    BABET_BZIP2_EXPECTED_VERSION="${BZIP2_VERSION}"
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    ${LUA_LIB}
    ${OPENSSL_LIB}
    ${CRYPTO_LIB}
    ${LIBARCHIVE_LIB}
    ${ZLIB_LIB}
    ${LZMA_LIB}
    ${BZIP2_LIB}
    ${ZSTD_LIB}
    re2::re2
    dl
    pthread
)

# libatomic : nécessaire sur les architectures 32-bit (ARMv6 / ARMv7 /
# i386) qui n'ont pas d'instructions atomiques 64-bit en hardware.
# OpenSSL 3.x utilise des __atomic_load_8 / __atomic_fetch_or_8 dans
# son crypto/threads_pthread.c, ce qui déclenche des appels à des
# builtins software fournis par libatomic. Sans cette lib au link,
# on a des erreurs comme :
# référence indéfinie vers « __atomic_is_lock_free »
# référence indéfinie vers « __atomic_load_8 »
#
# CMAKE_SIZEOF_VOID_P EQUAL 4 = plateforme 32-bit. On laisse le linker
# (GCC/ld) résoudre -latomic lui-même : il connaît les paths
# multi-arch Debian (/usr/lib/arm-linux-gnueabihf/, etc.) que
# find_library peut rater. Sur les systèmes Linux modernes, libatomic
# est fournie par gcc-runtime, donc présente partout où gcc est
# installé.
#
# Sur x86_64 et aarch64 (64-bit), le CPU fait l'atomique 64-bit
# nativement, pas besoin de cette lib.
if(CMAKE_SIZEOF_VOID_P EQUAL 4)
    target_link_libraries(${PROJECT_NAME} PRIVATE atomic)
    message(STATUS "32-bit platform detected, linking libatomic")
endif()

if(BABET_ENABLE_SANITIZERS)
    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
        target_compile_options(${PROJECT_NAME} PRIVATE
            -O1
            -g
            -fno-omit-frame-pointer
            -fno-sanitize-recover=all
            -fsanitize=address,undefined
        )
        target_link_options(${PROJECT_NAME} PRIVATE
            -fno-sanitize-recover=all
            -fsanitize=address,undefined
        )
        message(STATUS "Babet sanitizers enabled: ASan + UBSan")
    else()
        message(FATAL_ERROR
            "BABET_ENABLE_SANITIZERS requires GCC or Clang")
    endif()
else()
    # Les runtimes statiques sont conservés pour les builds normaux.
    # Ils sont volontairement désactivés avec les sanitizers, dont les
    # runtimes doivent rester disponibles dynamiquement pendant les tests.
    target_link_options(${PROJECT_NAME} PRIVATE
        -static-libgcc
        -static-libstdc++
    )
endif()
