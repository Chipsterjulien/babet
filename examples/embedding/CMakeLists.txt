cmake_minimum_required(VERSION 3.20)
project(babet_embedding_examples LANGUAGES C CXX)

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

set(EXAMPLE_TARGETS
    babet_embed_01_hello
    babet_embed_02_search_root
    babet_embed_03_values
    babet_embed_04_call
    babet_embed_05_errors
    babet_embed_06_lifecycle_threads
    babet_embed_07_host_functions)

set(EXAMPLE_SOURCES
    01_hello.c
    02_search_root.c
    03_values.c
    04_call.c
    05_errors.c
    06_lifecycle_threads.c
    07_host_functions.c)

list(LENGTH EXAMPLE_TARGETS TARGET_COUNT)
math(EXPR LAST_INDEX "${TARGET_COUNT} - 1")
foreach(INDEX RANGE ${LAST_INDEX})
    list(GET EXAMPLE_TARGETS ${INDEX} TARGET)
    list(GET EXAMPLE_SOURCES ${INDEX} SOURCE)
    add_executable(${TARGET} ${SOURCE})
    target_compile_features(${TARGET} PRIVATE c_std_99)
    target_compile_options(${TARGET} PRIVATE -Wall -Wextra -Werror)
    target_include_directories(${TARGET} PRIVATE "${BABET_INCLUDE_DIR}")
    target_link_libraries(${TARGET} PRIVATE "${BABET_LIBRARY}" dl pthread m)
    if(CMAKE_SIZEOF_VOID_P EQUAL 4)
        target_link_libraries(${TARGET} PRIVATE atomic)
    endif()
    set_property(TARGET ${TARGET} PROPERTY LINKER_LANGUAGE CXX)
endforeach()

enable_testing()
add_test(NAME embed_01_hello COMMAND babet_embed_01_hello)
add_test(NAME embed_02_search_root COMMAND babet_embed_02_search_root
         "${CMAKE_CURRENT_SOURCE_DIR}/modules")
add_test(NAME embed_03_values COMMAND babet_embed_03_values)
add_test(NAME embed_04_call COMMAND babet_embed_04_call)
add_test(NAME embed_05_errors COMMAND babet_embed_05_errors)
add_test(NAME embed_06_lifecycle_threads COMMAND babet_embed_06_lifecycle_threads)
add_test(NAME embed_07_host_functions COMMAND babet_embed_07_host_functions)
