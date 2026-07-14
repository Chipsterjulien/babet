cmake_minimum_required(VERSION 3.16)
project(babet VERSION 2.4.0 LANGUAGES CXX C)

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

target_include_directories(${PROJECT_NAME} PRIVATE
    ${LUA_INCLUDE}
    ${MINIZ_INCLUDE}
    ${JSON_INCLUDE}
    ${HTTPLIB_INCLUDE}
    ${TOMLPP_INCLUDE}
    ${SQLITE_INCLUDE}
    ${GENERATED_INCLUDE}
    ${PROJECT_SOURCE_DIR}/src
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    ${LUA_LIB}
    ${OPENSSL_LIB}
    ${CRYPTO_LIB}
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
