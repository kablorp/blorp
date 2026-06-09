cmake_minimum_required(VERSION 3.20)

project(blorp LANGUAGES NONE)

# CMake is an IDE/CTest wrapper for this repository. The Makefile and Dune
# remain the source of truth for generated files, OCaml builds, signing, and
# test gates.
find_program(MAKE_EXECUTABLE NAMES gmake make REQUIRED)

set(BLORP_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(BLORP_BINARY "${BLORP_SOURCE_DIR}/blorp")

add_custom_target(blorp
        ALL
        COMMAND "${MAKE_EXECUTABLE}" all
        WORKING_DIRECTORY "${BLORP_SOURCE_DIR}"
        BYPRODUCTS "${BLORP_BINARY}"
        USES_TERMINAL
        VERBATIM
        COMMENT "Building blorp through the repository Makefile"
)

function(add_blorp_make_target target_name)
        add_custom_target("${target_name}"
                COMMAND "${MAKE_EXECUTABLE}" ${ARGN}
                WORKING_DIRECTORY "${BLORP_SOURCE_DIR}"
                USES_TERMINAL
                VERBATIM
        )
endfunction()

add_blorp_make_target(blorp-install install)
add_blorp_make_target(blorp-smoke smoke)
add_blorp_make_target(blorp-test test)
add_blorp_make_target(blorp-runtime-test runtime-test)
add_blorp_make_target(blorp-compiler-unit-test compiler-unit-test)
add_blorp_make_target(blorp-fmt-check fmt-check)
add_blorp_make_target(blorp-quality quality)
add_blorp_make_target(blorp-quality-full quality-full)
add_blorp_make_target(blorp-clean clean)

enable_testing()

function(add_blorp_test test_name)
        add_test(
                NAME "${test_name}"
                COMMAND "${BLORP_SOURCE_DIR}/scripts/test" ${ARGN}
                WORKING_DIRECTORY "${BLORP_SOURCE_DIR}"
        )
endfunction()

add_blorp_test(blorp.compiler-unit compiler-unit)
add_blorp_test(blorp.compiler compiler)
add_blorp_test(blorp.runtime runtime)
add_blorp_test(blorp.leak leak)
add_blorp_test(blorp.doctest doctest)
add_blorp_test(blorp.cli cli)

