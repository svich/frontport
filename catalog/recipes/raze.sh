#!/bin/bash
# Frontport Recipe: Raze (ZDoom/Raze), the Build engine games on the GZDoom engine, from their released source.
# Contract: catalog/recipes/README.md. Invoked as `raze.sh fetch`, then `raze.sh build`.
#
# Upstream publishes a Mac app, but its Releases predate GitHub's asset digests, so Frontport can't verify them.
# This builds the same app from the tag: the Cocoa backend, against a static ZMusic and a static libvpx, which it
# needs for the cutscenes. ZMusic's FluidSynth wants GLib on every system but Windows, where ZMusic stubs the few
# calls it makes; upstream's app links a GLib in statically. This adds the same stubs on POSIX threads instead, so
# nothing outside the system comes in. It links a static OpenAL Soft: upstream's app loads OpenAL at run time and
# finds only macOS's, which lacks the extensions Raze needs, so it plays without sound. Inside an app, Raze already
# keeps raze.ini in ~/Library/Preferences, its saves and screenshots in ~/Library/Application Support/Raze, and
# searches the folders inside that for games, all of which the App Sandbox puts in the container, where Frontport
# Seeds the game. One patch, from upstream's master: when Vulkan fails, as it does without MoltenVK in the app, 1.11.0
# falls back to its GLES renderer, whose shaders macOS's OpenGL rejects, so the screen stays black.
set -euo pipefail

step=${1:?usage: raze.sh fetch|build}
src=$FRONTPORT_SRC
work=$(dirname "$src")                 # Builds/<port>: writable during build, kept between builds
deps=$src/deps
raze=$src/raze
prefix=$work/prefix                    # the static libraries, reused while their pins don't change
deployment_target=13.0
export MACOSX_DEPLOYMENT_TARGET=$deployment_target
export GIT_CEILING_DIRECTORIES=$work

fail() {
    echo "error: $*" >&2
    exit 1
}

case "$FRONTPORT_PORT" in
    raze-duke3d) ;;
    *) fail "Port $FRONTPORT_PORT names no game this Recipe builds (raze-duke3d)" ;;
esac

# Commits of the tags this Recipe was tested against, so a moved tag fails the fetch.
known_commit() {
    case "$1" in
        1.11.0) echo 19e5f308de065fb432beb9d11070ece12da3ea3c ;;
    esac
}

# name sha256 url: GitHub archives of the commits of ZMusic's 1.1.14 tag, which upstream's CI builds against,
# libvpx's v1.15.2 tag and OpenAL Soft's 1.25.2 tag, as dhewm3.sh pins.
dependencies="
openal-soft 6a3e5f80058ecf994a6885d7db5013629a259c659ab40a6f17db8963ceb211b2 https://github.com/kcat/openal-soft/archive/b2c48f7718ef3fcf67921a8b6534c4914e328970.tar.gz
zmusic 7e391bbae4a5fb2a267e624e96319468975e998326916b6b457eee8d53aed0c3 https://github.com/ZDoom/ZMusic/archive/89f3d65734470fb7ec0c1e69f73a0cfcc88ed557.tar.gz
libvpx 5f6519823db1cc67fba023dc5dcf33abcd3fbab65d7e3c6f1d8ff00917a8c1c6 https://github.com/webmproject/libvpx/archive/d168454ecd099805c675d4a98c66f4891373302a.tar.gz
"

# Replaces exactly the text given in a file, failing loudly when upstream changed it.
replace() {
    local file=$1 old=$2 new=$3
    grep -qF -- "$old" "$file" || fail "$file no longer contains: $old"
    OLD=$old NEW=$new perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

# Builds ZMusic's FluidSynth with GLib stubs on macOS too, as it does on Windows: posix_glibstubs.h and .c follow
# win32_glibstubs.h and .c, on POSIX threads.
patch_zmusic() {
    local fluidsynth=$deps/zmusic/thirdparty/fluidsynth/src
    replace "$fluidsynth/config.h" "#ifdef _WIN32
#define WITH_GLIB_STUBS" "#if defined(_WIN32) || defined(__APPLE__)
#define WITH_GLIB_STUBS"
    replace "$fluidsynth/CMakeLists.txt" "endif ( WIN32 )

set ( public_HEADERS" "elseif ( APPLE )
    set( fluidsynth_SOURCES
        \${fluidsynth_SOURCES}
        utils/posix_glibstubs.c
        utils/posix_glibstubs.h
    )
endif ( WIN32 )

set ( public_HEADERS"
    replace "$fluidsynth/CMakeLists.txt" "if (NOT WIN32)
   find_package(PkgConfig REQUIRED)" "if (NOT WIN32 AND NOT APPLE)
   find_package(PkgConfig REQUIRED)"
    replace "$fluidsynth/utils/fluid_sys.h" "#ifndef WIN32
#include <glib/gstdio.h>
#endif" "#if defined(WITH_GLIB_STUBS) && !defined(WIN32)
#include \"posix_glibstubs.h\"
#elif !defined(WIN32)
#include <glib/gstdio.h>
#endif"
    cat >"$fluidsynth/utils/posix_glibstubs.h" <<'STUBS'
/* Frontport: the GLib calls FluidSynth makes, on POSIX threads, after ZMusic's win32_glibstubs.h, so ZMusic needs no
 * GLib on macOS. Like those, it takes FluidSynth's pre-2.32 thread API. */
#ifndef _POSIX_GLIBSTUBS_H
#define _POSIX_GLIBSTUBS_H

#include <alloca.h>
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

/* As GLib 2.29: older than the new thread API of 2.32, new enough for GStatBuf (2.26). */
#define GLIB_CHECK_VERSION(x, y, z) ((x) < 2 || ((x) == 2 && (y) <= 29))
#define GLIB_MAJOR_VERSION 2
#define GLIB_MINOR_VERSION 29

typedef int BOOL;
#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif

typedef struct
{
    int code;
    const char *message;
} GError;
typedef void *gpointer;

#define g_new(s, c) FLUID_ARRAY(s, c)
#define g_free(p) FLUID_FREE(p)
#define g_strfreev FLUID_FREE
#define g_newa(_type, _len) (_type *)alloca(sizeof(_type) * (_len))
#define g_assert(a) assert(a)
#define G_LIKELY(expr) __builtin_expect(!!(expr), 1)
#define G_UNLIKELY(expr) __builtin_expect(!!(expr), 0)

#define g_vsnprintf(b, c, f, a) vsnprintf(b, c, f, a)
#define g_snprintf(b, c, f, ...) snprintf(b, c, f, __VA_ARGS__)

#define g_return_val_if_fail(expr, val) if (expr) {} else { return val; }
#define g_clear_error(err) do {} while (0)

#define G_FILE_TEST_EXISTS 1
#define G_FILE_TEST_IS_REGULAR 2

#define g_file_test fluid_g_file_test
#define g_shell_parse_argv fluid_g_shell_parse_argv
BOOL fluid_g_file_test(const char *path, int flags);
BOOL fluid_g_shell_parse_argv(const char *command_line, int *argcp, char ***argvp, void *dummy);

#define g_get_monotonic_time fluid_g_get_monotonic_time
double fluid_g_get_monotonic_time(void);

typedef struct stat GStatBuf;
#define g_stat stat

/* Byte ordering: every Mac is little endian */
#define G_BYTE_ORDER 1234
#define G_BIG_ENDIAN 4321
#define GINT32_FROM_LE(x) (x)
#define GINT16_FROM_LE(x) (x)

/* Thread support */
#define g_thread_supported() 1
#define g_thread_init(_) do {} while (0)
#define g_usleep(usecs) usleep(usecs)

typedef gpointer (*GThreadFunc)(void *data);
typedef struct
{
    GThreadFunc func;
    void *data;
    pthread_t handle;
    BOOL joinable;
} GThread;

#define g_thread_create fluid_g_thread_create
#define g_thread_join fluid_g_thread_join
/* Only compared, as the current thread's ID: pthread_t is a pointer on macOS, unique among running threads. */
#define g_thread_self() ((GThread *)pthread_self())
GThread *fluid_g_thread_create(GThreadFunc func, void *data, BOOL joinable, GError **error);
void fluid_g_thread_join(GThread *thread);

/* Regular mutex */
typedef pthread_mutex_t GStaticMutex;
#define G_STATIC_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER
#define g_static_mutex_init(_m) pthread_mutex_init(_m, NULL)
#define g_static_mutex_free(_m) pthread_mutex_destroy(_m)
#define g_static_mutex_lock(_m) pthread_mutex_lock(_m)
#define g_static_mutex_unlock(_m) pthread_mutex_unlock(_m)

/* Recursive lock capable mutex */
typedef pthread_mutex_t GStaticRecMutex;
#define g_static_rec_mutex_init(_m) fluid_g_rec_mutex_init(_m)
#define g_static_rec_mutex_free(_m) pthread_mutex_destroy(_m)
#define g_static_rec_mutex_lock(_m) pthread_mutex_lock(_m)
#define g_static_rec_mutex_unlock(_m) pthread_mutex_unlock(_m)
void fluid_g_rec_mutex_init(pthread_mutex_t *mutex);

/* Dynamically allocated mutex suitable for fluid_cond_t use */
typedef pthread_mutex_t GMutex;
#define g_mutex_free(m) do { if (m != NULL) { pthread_mutex_destroy(m); g_free(m); } } while (0)
#define g_mutex_lock(m) pthread_mutex_lock(m)
#define g_mutex_unlock(m) pthread_mutex_unlock(m)

static inline GMutex *g_mutex_new(void)
{
    GMutex *mutex = (GMutex *)malloc(sizeof(GMutex));
    if (mutex != NULL)
    {
        pthread_mutex_init(mutex, NULL);
    }
    return mutex;
}

/* Thread condition signaling */
typedef pthread_cond_t GCond;
#define g_cond_free(cond) do { if (cond != NULL) { pthread_cond_destroy(cond); g_free(cond); } } while (0)
#define g_cond_signal(cond) pthread_cond_signal(cond)
#define g_cond_broadcast(cond) pthread_cond_broadcast(cond)
#define g_cond_wait(cond, mutex) pthread_cond_wait(cond, mutex)

static inline GCond *g_cond_new(void)
{
    GCond *cond = (GCond *)malloc(sizeof(GCond));
    if (cond != NULL)
    {
        pthread_cond_init(cond, NULL);
    }
    return cond;
}

/* Thread private data */
typedef pthread_key_t GStaticPrivate;
#define g_static_private_init(_priv) pthread_key_create(_priv, NULL)
#define g_static_private_get(_priv) pthread_getspecific(*(_priv))
#define g_static_private_set(_priv, _data, _) pthread_setspecific(*(_priv), _data)
#define g_static_private_free(_priv) pthread_key_delete(*(_priv))

/* Atomic operations */
#define g_atomic_int_inc(_pi) __atomic_add_fetch(_pi, 1, __ATOMIC_SEQ_CST)
#define g_atomic_int_get(_pi) __atomic_load_n(_pi, __ATOMIC_SEQ_CST)
#define g_atomic_int_set(_pi, _val) __atomic_store_n(_pi, _val, __ATOMIC_SEQ_CST)
#define g_atomic_int_dec_and_test(_pi) (__atomic_sub_fetch(_pi, 1, __ATOMIC_SEQ_CST) == 0)
#define g_atomic_int_compare_and_exchange(_pi, _old, _new) \
    __sync_bool_compare_and_swap(_pi, _old, _new)
#define g_atomic_int_exchange_and_add(_pi, _add) __atomic_fetch_add(_pi, _add, __ATOMIC_SEQ_CST)
#define g_atomic_pointer_get(_pp) __atomic_load_n(_pp, __ATOMIC_SEQ_CST)
#define g_atomic_pointer_set(_pp, _val) __atomic_store_n(_pp, _val, __ATOMIC_SEQ_CST)
#define g_atomic_pointer_compare_and_exchange(_pp, _old, _new) \
    __sync_bool_compare_and_swap(_pp, _old, _new)

#endif
STUBS
    cat >"$fluidsynth/utils/posix_glibstubs.c" <<'STUBS'
/* Frontport: posix_glibstubs.h's functions, after ZMusic's win32_glibstubs.c. */
#include "fluidsynth_priv.h"
#include "fluid_sys.h"

#include <errno.h>
#include <string.h>
#include <time.h>

BOOL fluid_g_file_test(const char *path, int flags)
{
    struct stat info;
    if (path == NULL || stat(path, &info) != 0)
    {
        return FALSE;
    }
    if (flags & G_FILE_TEST_EXISTS)
    {
        return TRUE;
    }
    if (flags & G_FILE_TEST_IS_REGULAR)
    {
        return S_ISREG(info.st_mode);
    }
    return FALSE;
}

BOOL fluid_g_shell_parse_argv(const char *command_line, int *argcp, char ***argvp, void *dummy)
{
    /* Only FluidSynth's command shell parses command lines, and ZMusic never runs it. */
    return FALSE;
}

double fluid_g_get_monotonic_time(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000000.0 + now.tv_nsec / 1000.0; /* time in micros */
}

void fluid_g_rec_mutex_init(pthread_mutex_t *mutex)
{
    pthread_mutexattr_t attributes;
    pthread_mutexattr_init(&attributes);
    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(mutex, &attributes);
    pthread_mutexattr_destroy(&attributes);
}

static void *g_thread_wrapper(void *info_)
{
    GThread *info = (GThread *)info_;
    info->func(info->data);
    /* Free the "GThread" now if it was detached. Otherwise, it's freed in fluid_g_thread_join. */
    if (!info->joinable)
    {
        free(info);
    }
    return NULL;
}

GThread *fluid_g_thread_create(GThreadFunc func, void *data, BOOL joinable, GError **error)
{
    static GError error_container;
    int status;

    g_return_val_if_fail(func != NULL, NULL);
    GThread *info = (GThread *)malloc(sizeof(GThread));
    if (info == NULL)
    {
        return NULL;
    }
    info->func = func;
    info->data = data;
    info->joinable = joinable;

    status = pthread_create(&info->handle, NULL, g_thread_wrapper, info);
    if (error != NULL)
    {
        error_container.code = status;
        error_container.message = status != 0 ? strerror(status) : NULL;
        *error = &error_container;
    }
    if (status != 0)
    {
        free(info);
        return NULL;
    }
    if (!joinable)
    {
        pthread_detach(info->handle);
    }
    return info;
}

void fluid_g_thread_join(GThread *thread)
{
    if (thread != NULL && thread->joinable)
    {
        pthread_join(thread->handle, NULL);
        free(thread);
    }
}
STUBS
}

fetch() {
    echo "==> Cloning Raze $FRONTPORT_REF"
    git clone --quiet https://github.com/ZDoom/Raze.git "$raze"
    git -C "$raze" -c advice.detachedHead=false checkout --quiet "$FRONTPORT_REF"
    local expected actual
    expected=$(known_commit "$FRONTPORT_REF")
    actual=$(git -C "$raze" rev-parse HEAD)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        fail "$FRONTPORT_REF is $actual upstream, but this Recipe was tested with $expected"
    fi
    git -C "$raze" describe --tags >"$src/version" 2>/dev/null || echo "$actual" >"$src/version"

    mkdir -p "$deps"
    local name sha url file
    while read -r name sha url; do
        [ -n "$name" ] || continue
        echo "==> Downloading $name"
        file=$deps/$name.download
        curl -fsSL --retry 3 -o "$file" "$url"
        echo "$sha  $file" | shasum -a 256 -c --status - || fail "$name doesn't match its pinned sha256"
        mkdir -p "$deps/$name"
        tar -xf "$file" -C "$deps/$name" --strip-components=1
        rm "$file"
    done <<<"$dependencies"

    echo "==> Patching"
    patch_zmusic
    # Upstream's master: only the GLES backend asked for gets the GLES renderer; a failed Vulkan gets desktop OpenGL.
    replace "$raze/source/common/platform/posix/cocoa/i_video.mm" "			if(V_GetBackend() != 0)
				fb = new OpenGLESRenderer::OpenGLFrameBuffer(0, vid_fullscreen);" "			if(V_GetBackend() == 2)
				fb = new OpenGLESRenderer::OpenGLFrameBuffer(0, vid_fullscreen);"
}

build_libraries() {
    local stamp=$prefix/.frontport-libraries
    local wanted
    wanted=$( (echo "$dependencies $deployment_target"; cat "${BASH_SOURCE[0]}") | shasum -a 256 | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$wanted" ]; then
        echo "==> Reusing the libraries in $prefix"
        return
    fi
    rm -rf "$prefix" "$work"/*-build

    # The decoder only, with its NEON code; the assembler is clang's.
    echo "==> Building libvpx"
    mkdir -p "$work/libvpx-build"
    (cd "$work/libvpx-build" && "$deps/libvpx/configure" --prefix="$prefix" --target=arm64-darwin22-gcc \
        --enable-static --disable-shared --disable-vp8-encoder --disable-vp9-encoder --disable-examples --disable-tools --disable-docs \
        --disable-unit-tests --extra-cflags="-mmacosx-version-min=$deployment_target" \
        && make -j "$FRONTPORT_JOBS" && make install)

    # Static, with the synthesizers built in; libsndfile and mpg123, which it would load at run time for compressed
    # music, aren't in the app, as in upstream's.
    echo "==> Building ZMusic"
    cmake -S "$deps/zmusic" -B "$work/zmusic-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST -DBUILD_SHARED_LIBS=OFF
    cmake --build "$work/zmusic-build" -j "$FRONTPORT_JOBS"
    cmake --install "$work/zmusic-build"
    # Raze compiles the same library loader, FModule from GZDoom's common code, which a shared ZMusic keeps to
    # itself; the static one would define it twice. So ZMusic uses Raze's, which lacks only FModule_GetProgDir.
    cat >"$work/zmusic-build/progdir.cpp" <<'PROGDIR'
#include <string>
extern std::string module_progdir; // Raze's, in common/utility/i_module.cpp
const std::string& FModule_GetProgDir() { return module_progdir; }
PROGDIR
    clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=$deployment_target -c "$work/zmusic-build/progdir.cpp" \
        -o "$work/zmusic-build/progdir.o"
    local lib
    for lib in libzmusic.a libzmusiclite.a; do
        ar -d "$prefix/lib/$lib" i_module.cpp.o
        ar -r "$prefix/lib/$lib" "$work/zmusic-build/progdir.o"
    done

    # Only the library, playing through CoreAudio, as dhewm3.sh builds it.
    echo "==> Building OpenAL Soft"
    cmake -S "$deps/openal-soft" -B "$work/openal-soft-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST -DLIBTYPE=STATIC -DHAVE_WFUNCTION_EFFECTS=OFF \
        -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_INSTALL_CONFIG=OFF \
        -DALSOFT_INSTALL_HRTF_DATA=OFF -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF -DALSOFT_INSTALL_EXAMPLES=OFF \
        -DALSOFT_INSTALL_UTILS=OFF -DALSOFT_UPDATE_BUILD_VERSION=OFF \
        -DALSOFT_ENABLE_MODULES=OFF -DALSOFT_REQUIRE_COREAUDIO=ON -DALSOFT_BACKEND_PIPEWIRE=OFF \
        -DALSOFT_BACKEND_PULSEAUDIO=OFF -DALSOFT_BACKEND_JACK=OFF -DALSOFT_BACKEND_PORTAUDIO=OFF \
        -DALSOFT_BACKEND_WAVE=OFF
    cmake --build "$work/openal-soft-build" -j "$FRONTPORT_JOBS"
    cmake --install "$work/openal-soft-build"
    echo "$wanted" >"$stamp"
}

build() {
    build_libraries

    # Raze takes OPENAL_LIBRARY for files it depends on, so the frameworks OpenAL Soft needs go to the linker.
    local openal_frameworks="-framework AudioToolbox -framework AudioUnit -framework CoreAudio"
    openal_frameworks+=" -framework ApplicationServices -framework CoreFoundation"

    echo "==> Configuring Raze"
    rm -rf "$work/build"
    GIT_DESCRIBE=$(cat "$src/version") cmake -S "$raze" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_FRAMEWORK=LAST -DPK3_QUIET_ZIPDIR=ON \
        -DVPX_INCLUDE_DIR="$prefix/include" -DVPX_LIBRARIES="$prefix/lib/libvpx.a" -DDYN_OPENAL=OFF \
        -DOPENAL_INCLUDE_DIR="$prefix/include/AL" -DOPENAL_LIBRARY="$prefix/lib/libopenal.a" \
        -DCMAKE_EXE_LINKER_FLAGS="$openal_frameworks"

    echo "==> Building Raze"
    GIT_DESCRIBE=$(cat "$src/version") cmake --build "$work/build" -j "$FRONTPORT_JOBS"

    echo "==> Making Raze.app"
    local app=$FRONTPORT_OUT/Raze.app
    [ -d "$work/build/raze.app" ] || fail "the build made no app"
    cp -R "$work/build/raze.app" "$app"
    [ -f "$app/Contents/MacOS/raze.pk3" ] || fail "raze.pk3 isn't in the app"
    # Raze reads raze.pk3 and soundfonts/ beside its executable, but codesign takes a folder in Contents/MacOS for
    # code, and fails on soundfonts/. They go in Contents/Resources, with links where Raze looks.
    mkdir -p "$app/Contents/Resources"
    local data
    for data in raze.pk3 soundfonts; do
        mv "$app/Contents/MacOS/$data" "$app/Contents/Resources/"
        ln -s "../Resources/$data" "$app/Contents/MacOS/$data"
    done
    if otool -L "$app/Contents/MacOS/raze" | grep -qiE 'zmusic|vpx|openal|/opt/|/usr/local/'; then
        fail "raze links a library outside the system"
    fi
    plutil -replace CFBundleIdentifier -string "dev.frontport.port.$FRONTPORT_PORT" "$app/Contents/Info.plist"
}

case "$step" in
    fetch) fetch ;;
    build) build ;;
    *) fail "unknown step $step" ;;
esac
