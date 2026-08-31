cmake_minimum_required(VERSION 3.20)
project(TCUNCGuard VERSION 0.2 LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "TCUNCGuard supports Windows only.")
endif()

include(CTest)
add_subdirectory(src)

if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
