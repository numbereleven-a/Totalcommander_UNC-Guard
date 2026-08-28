add_executable(path_normalizer_tests
    path_normalizer_tests.cpp
    ../src/path_normalizer.cpp
)

target_compile_features(path_normalizer_tests PRIVATE cxx_std_17)
target_compile_definitions(path_normalizer_tests PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

if(MSVC)
    target_compile_options(path_normalizer_tests PRIVATE /utf-8 /W4 /WX /permissive- /EHsc)
    set_property(TARGET path_normalizer_tests PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
else()
    target_compile_options(path_normalizer_tests PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_test(NAME path_normalizer_tests COMMAND path_normalizer_tests)
