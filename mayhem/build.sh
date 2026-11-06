#!/usr/bin/env bash
#
# mayhem/build.sh — build ripwire's in-tree libFuzzer targets (test/fuzz/, enabled by upstream's own
# RIPWIRE_FUZZ=ON CMake switch) plus the doctest suite that mayhem/test.sh runs.
#
# Runs inside the commit image as `mayhem` in /mayhem. Everything is vendored in third_party/deps, so the
# whole build is offline and re-runnable.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

GRAMMARS="cpp python go rust typescript tsx swift objc javascript bash java ruby json toml yaml csharp c php dart elixir lua kotlin gdscript clojure"
READERS="$(sed -n '/set(RIPWIRE_FUZZ_READERS/,/)/p' CMakeLists.txt | tr -d '()' | sed 's/setRIPWIRE_FUZZ_READERS//' | tr -s ' \n' ' ')"

# A compiler path that differs between runs (ccache prefill masquerade vs plain) makes CMake wipe the cache and
# drop the -D options mid-configure; always configure from a fresh cache (ninja still reuses unchanged objects).
rm -f build-tests/CMakeCache.txt build-fuzz/CMakeCache.txt

# 1) The test suite, with the project's NORMAL flags, in its own build tree (gitignored: build*/).
cmake -S . -B build-tests -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DRIPWIRE_TESTS=ON
cmake --build build-tests -j"$MAYHEM_JOBS" --target \
    ripwire_test_csr ripwire_test_pagerank ripwire_test_radix ripwire_test_strkern ripwire_test_oswin32logic

# 2) Leak detection off at build time (ASan stays on): one TU linked into every fuzz and standalone binary.
mkdir -p build-fuzz
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-fuzz/lsan_off.o

# 3) The fuzz targets, through upstream's RIPWIRE_FUZZ switch. It carries its own sanitizer set
#    (address, undefined, integer, float checks; all halting) on every grammar, tree-sitter core and reader
#    object; our $SANITIZER_FLAGS/$DEBUG_FLAGS (DWARF 3) ride along in CMAKE_*_FLAGS and the lsan hook in the link.
sed 's|rw::notes::readNotes( writeScratch( ".ripwire_notes", in ) )|[\&]{ rw::notes::NotesReadStats st; return rw::notes::readNotes( writeScratch( ".ripwire_notes", in ), st ); }()|' \
    test/fuzz/readers/readers_domain.cpp > build-fuzz/readers_domain.cpp
cmake -S . -B build-fuzz -G Ninja \
    -DCMAKE_PROJECT_INCLUDE="$SRC/mayhem/fuzz_overlay.cmake" -DMAYHEM_READERS_DOMAIN="$SRC/build-fuzz/readers_domain.cpp" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$SRC/build-fuzz/lsan_off.o" \
    -DRIPWIRE_FUZZ=ON
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target ripwire_fuzzers ripwire_reader_fuzzers

# 4) A standalone (run-once, no libFuzzer runtime) reproducer per target, linked from the same objects.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-fuzz/standalone_main.o
INC="-Ithird_party/deps/tree_sitter/lib/include"
for g in $GRAMMARS; do
    lang="$(sed -n "s/^add_ripwire_fuzzer( *$g  *\([A-Za-z_]*\) .*/\1/p" CMakeLists.txt)"
    [ -n "$lang" ] || lang="$(sed -n "s/^  add_ripwire_fuzzer( *$g  *\([A-Za-z_]*\) .*/\1/p" CMakeLists.txt)"
    [ -n "$lang" ] || { echo "no add_ripwire_fuzzer line for $g" >&2; exit 1; }
    objs="$(find build-fuzz/CMakeFiles/ripwire_fuzz_grammar_$g.dir -name '*.o' | sort)"
    # shellcheck disable=SC2086
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++20 $INC -DRIPWIRE_FUZZ_LANGUAGE="$lang" \
        test/fuzz/fuzz_ingest.cpp build-fuzz/standalone_main.o $objs build-fuzz/libripwire_tree_sitter_fuzz.a \
        build-fuzz/lsan_off.o -o "build-fuzz/ripwire_fuzz_$g-standalone"
done
for r in $READERS; do
    # shellcheck disable=SC2086
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++20 -DRIPWIRE_FUZZ_READER="$r" \
        test/fuzz/readers/fuzz_reader.cpp build-fuzz/standalone_main.o \
        build-fuzz/libripwire_fuzz_readers.a build-fuzz/libripwire_fuzz_reader_grammars.a \
        build-fuzz/libripwire_tree_sitter_fuzz.a -lpthread build-fuzz/lsan_off.o \
        -o "build-fuzz/ripwire_fuzz_reader_$r-standalone"
done
