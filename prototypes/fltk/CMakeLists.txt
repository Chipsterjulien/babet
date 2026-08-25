cmake_minimum_required(VERSION 3.20)
project(babet_fltk_lot9_prototype LANGUAGES CXX)

if(NOT DEFINED BABET_SDK_DIR)
    message(FATAL_ERROR "Set BABET_SDK_DIR to the standalone Babet embedding SDK")
endif()

get_filename_component(BABET_SDK_DIR "${BABET_SDK_DIR}" ABSOLUTE)
set(BABET_INCLUDE_DIR "${BABET_SDK_DIR}/include")
set(BABET_LIBRARY "${BABET_SDK_DIR}/lib/libbabet.a")

if(NOT EXISTS "${BABET_INCLUDE_DIR}/babet/babet.h")
    message(FATAL_ERROR "Missing ${BABET_INCLUDE_DIR}/babet/babet.h")
endif()
if(NOT EXISTS "${BABET_LIBRARY}")
    message(FATAL_ERROR "Missing ${BABET_LIBRARY}")
endif()

# CONFIG mode is the FLTK 1.4 supported consumer path. This prototype is a
# separate project on purpose: the normal Babet CMake build never finds FLTK.
find_package(FLTK 1.4 CONFIG REQUIRED)

add_executable(babet_fltk_prototype WIN32 MACOSX_BUNDLE main.cpp)
target_compile_features(babet_fltk_prototype PRIVATE cxx_std_17)
target_compile_options(babet_fltk_prototype PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_include_directories(babet_fltk_prototype PRIVATE "${BABET_INCLUDE_DIR}")
target_link_libraries(babet_fltk_prototype PRIVATE
    "${BABET_LIBRARY}"
    fltk::fltk
    dl
    pthread
    m)
