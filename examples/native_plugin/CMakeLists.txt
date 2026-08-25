cmake_minimum_required(VERSION 3.16)
project(babet_native_plugin_examples LANGUAGES C CXX)

set(BABET_INCLUDE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../include" CACHE PATH
    "Directory containing babet/plugin.h")

add_library(babet_example_plugin_c SHARED echo_plugin.c)
target_include_directories(babet_example_plugin_c PRIVATE "${BABET_INCLUDE_DIR}")
set_target_properties(babet_example_plugin_c PROPERTIES
    PREFIX ""
    OUTPUT_NAME "babet-example-c"
)
target_compile_features(babet_example_plugin_c PRIVATE c_std_11)
target_compile_options(babet_example_plugin_c PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_library(babet_example_plugin_cpp SHARED decorate_plugin.cpp)
target_include_directories(babet_example_plugin_cpp PRIVATE "${BABET_INCLUDE_DIR}")
set_target_properties(babet_example_plugin_cpp PROPERTIES
    PREFIX ""
    OUTPUT_NAME "babet-example-cpp"
)
target_compile_features(babet_example_plugin_cpp PRIVATE cxx_std_23)
target_compile_options(babet_example_plugin_cpp PRIVATE -Wall -Wextra -Wpedantic -Werror)
