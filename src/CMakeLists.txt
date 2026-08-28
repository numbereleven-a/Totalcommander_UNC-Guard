add_library(TCUNCGuard SHARED
    path_normalizer.cpp
    plugin.cpp
    plugin.def
)

target_compile_features(TCUNCGuard PRIVATE cxx_std_17)
target_compile_definitions(TCUNCGuard PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

if(MSVC)
    target_compile_options(TCUNCGuard PRIVATE /utf-8 /W4 /WX /permissive- /EHsc /guard:cf)
    target_link_options(TCUNCGuard PRIVATE /DYNAMICBASE /NXCOMPAT /GUARD:CF /DEBUG:NONE)
    set_property(TARGET TCUNCGuard PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
else()
    target_compile_options(TCUNCGuard PRIVATE -Wall -Wextra -Wpedantic)
endif()

target_link_libraries(TCUNCGuard PRIVATE user32)

set_target_properties(TCUNCGuard PROPERTIES
    OUTPUT_NAME "TCUNCGuard"
    PREFIX ""
    SUFFIX ".dll64"
)
