# Loaded with -DCMAKE_PROJECT_INCLUDE by mayhem/build.sh; edits the reader fuzz library after upstream's
# CMakeLists.txt has defined it, so no upstream file is modified. At upstream HEAD the library does not build:
#  * test/fuzz/readers/readers_domain.cpp calls rw::notes::readNotes( path ) but src/notes.h now also requires a
#    NotesReadStats argument; build.sh writes a patched copy (MAYHEM_READERS_DOMAIN) that is swapped in here;
#  * src/quality.h needs rw::kRipwireSourceIdentity, the generated definition the real binary links
#    (cmake/source_identity.cmake) but the reader library never did.
# Both edits are no-ops once upstream fixes them.
#
# It also relaxes ONE check on the vendored grammar objects: implicit-integer-sign-change (not part of
# -fsanitize=undefined; upstream's RIPWIRE_FUZZ adds Clang's `integer` group). Tree-sitter sets `lexer->lookahead`
# (int32_t) to -1 on an invalid UTF-8 byte, and the external scanners pass it to iswspace()/iswalpha() (wint_t): a
# defined conversion (WEOF), not UB. Without the flag lua halts on a lone 0xff byte (seeds alone do not reach it):
# third_party/deps/lua/src/scanner.c:44:19: implicit conversion from int32_t -1 to wint_t 4294967295. Upstream already
# turns the check off on the tree-sitter core and on swift's eat_whitespace. ASan and every other UBSan/integer check
# stay on and halting.
function(_mayhem_fix_reader_fuzz_library)
  if(NOT TARGET ripwire_fuzz_readers)
    return()
  endif()
  get_target_property(_srcs ripwire_fuzz_readers SOURCES)
  if(DEFINED MAYHEM_READERS_DOMAIN)
    list(TRANSFORM _srcs REPLACE "^test/fuzz/readers/readers_domain\\.cpp$" "${MAYHEM_READERS_DOMAIN}")
  endif()
  set(_ident "${CMAKE_BINARY_DIR}/generated/source_identity.cpp")
  if(TARGET ripwire_source_identity AND NOT "${_srcs}" MATCHES "source_identity\\.cpp")
    list(APPEND _srcs "${_ident}")
    set_source_files_properties("${_ident}" PROPERTIES GENERATED TRUE)
    add_dependencies(ripwire_fuzz_readers ripwire_source_identity)
  endif()
  set_property(TARGET ripwire_fuzz_readers PROPERTY SOURCES ${_srcs})
endfunction()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _mayhem_fix_reader_fuzz_library)

function(_mayhem_relax_grammar_sign_change)
  get_property(_all DIRECTORY "${CMAKE_SOURCE_DIR}" PROPERTY BUILDSYSTEM_TARGETS)
  foreach(_t IN LISTS _all)
    if(_t MATCHES "^ripwire_fuzz_grammar_")
      target_compile_options(${_t} PRIVATE -fno-sanitize=implicit-integer-sign-change)
    endif()
  endforeach()
endfunction()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _mayhem_relax_grammar_sign_change)
