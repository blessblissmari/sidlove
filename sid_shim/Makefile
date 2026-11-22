# sidlove_sid Makefile - builds the C shim around libsidplayfp for each target.
#
# The shim is the ONLY thing you must compile yourself. libsidplayfp itself
# you obtain prebuilt (see README.md "Ship list"). This Makefile assumes the
# sidplayfp headers and library are on the include/link path - set SIDINC and
# SIDLIB if they are not.
#
# Targets:
#   make linux    -> sidlove_sid.so        (x86_64-linux-gnu)
#   make windows  -> sidlove_sid.dll       (x86_64-w64-mingw32, cross)
#   make macos    -> sidlove_sid.dylib     (arm64 + x86_64 universal)
#   make android  -> sidlove_sid.so        (arm64-v8a + armeabi-v7a)
#   make clean
#
# For Windows/Android cross-compilation you need the mingw-w64 and NDK
# toolchains installed; see README.md for the exact packages.

CXX      ?= g++
CXXFLAGS ?= -O2 -fno-strict-aliasing -fvisibility=hidden
CXXFLAGS += -Wall -Wno-unused-parameter -std=c++14

SRC      := sidlove_sid.cpp
OUT      := sidlove_sid

# Default: sidplayfp headers + lib are in /usr (apt: libsidplayfp-dev)
SIDINC   ?= /usr/include
SIDLIB   ?= /usr/lib

# --- Linux x86_64 ---
linux: $(OUT).so
$(OUT).so: $(SRC) sidlove_sid.h
	$(CXX) $(CXXFLAGS) -shared -fPIC -I$(SIDINC) $(SRC) \
	    -o $@ -L$(SIDLIB) -lsidplayfp -lstdc++

# --- Windows x86_64 (cross via mingw-w64) ---
windows: $(OUT).dll
$(OUT).dll: $(SRC) sidlove_sid.h
	x86_64-w64-mingw32-g++-posix $(CXXFLAGS) -shared -I$(SIDINC) $(SRC) \
	    -o $@ -L$(SIDLIB) -lsidplayfp -lstdc++ -static-libgcc -static-libstdc++
	x86_64-w64-mingw32-strip $@

# --- macOS (universal arm64+x86_64) ---
macos: $(OUT).dylib
$(OUT).dylib: $(SRC) sidlove_sid.h
	clang++ $(CXXFLAGS) -arch arm64 -arch x86_64 -shared -fPIC \
	    -I$(SIDINC) $(SRC) -o $@ -L$(SIDLIB) -lsidplayfp -lstdc++

# --- Android arm64-v8a (via NDK clang) ---
# Point NDKROOT at your android-ndk-rNN, API e.g. 21.
NDKROOT  ?= $(ANDROID_NDK_HOME)
API      ?= 21
android: arm64-v8a armeabi-v7a
arm64-v8a: $(OUT).arm64.so
$(OUT).arm64.so: $(SRC) sidlove_sid.h
	$(NDKROOT)/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android$(API)-clang++ \
	    $(CXXFLAGS) -shared -fPIC -I$(SIDINC) $(SRC) \
	    -o $@ -L$(SIDLIB) -lsidplayfp -lc++_static
armeabi-v7a: $(OUT).v7a.so
$(OUT).v7a.so: $(SRC) sidlove_sid.h
	$(NDKROOT)/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi$(API)-clang++ \
	    $(CXXFLAGS) -shared -fPIC -I$(SIDINC) $(SRC) \
	    -o $@ -L$(SIDLIB) -lsidplayfp -lc++_static

clean:
	rm -f $(OUT).so $(OUT).dll $(OUT).dylib $(OUT).arm64.so $(OUT).v7a.so

.PHONY: linux windows macos android arm64-v8a armeabi-v7a clean
