# SACDPlayer build/package helper.
#
#   make            build helper for this host (normal development build)
#   make test       run Perl unit tests and helper selftest
#   make dist       create dist/SACD/ with a portable helper binary
#   make install PLUGINS_DIR=/path/to/lms/Plugins
#
# `make dist` deliberately builds a static helper with the vendored libdstdec
# decoder, so the resulting folder can be copied to a server without FFmpeg
# development libraries.  libav is only probed as an optional future backend.

VERSION ?= $(shell cat VERSION 2>/dev/null | head -n 1)
RELEASE_BASE ?= https://git.fchscastle.com/BeyondandSharp/lms-plugin-sacd/releases/download
RELEASE_TAG_PREFIX ?= v
ARCH    := $(shell uname -m)
ifeq ($(ARCH),x86_64)
BINARCH := x86_64-linux
else ifeq ($(ARCH),aarch64)
BINARCH := aarch64-linux
else
BINARCH := $(ARCH)-linux
endif

BUILD_DIR  := build
DIST       := dist/SACD
HELPER_BIN := helper/src/sacd_dsd
NO_LIBAV   ?= 1
STATIC     ?= 1
ARCHS      ?= x86_64-linux aarch64-linux armhf-linux arm-linux i386-linux MSWin32-x64-multi-thread

# Cross compilers used by `make bins`.  The x86_64 build is native; the
# other targets come from Debian's cross toolchains.
CC_x86_64_linux  ?= cc
CC_aarch64_linux ?= aarch64-linux-gnu-gcc
CC_armhf_linux   ?= arm-linux-gnueabihf-gcc
CC_arm_linux     ?= arm-linux-gnueabi-gcc
CC_i386_linux    ?= i686-linux-gnu-gcc
CC_ms_win        ?= x86_64-w64-mingw32-gcc

.PHONY: all helper helper-dist test bins render-version sync-version bump repo dist dist-all bundle bundle-all install clean verify-dist verify-bins

all: helper

# VERSION is the single source of truth.  The tracked manifests are templates
# (install.xml.in / repo.xml.in); the real XML is rendered only for a build.
render-version:
	@printf '%s\n' "$(VERSION)" > VERSION
	@perl tools/sync-version.pl --version "$(VERSION)" --release-base "$(RELEASE_BASE)" --tag-prefix "$(RELEASE_TAG_PREFIX)" --output-dir "$(BUILD_DIR)"

sync-version: render-version

# Update VERSION and render build/ metadata in one step:
#   make bump VERSION=0.3.0
bump:
	@printf '%s\n' "$(VERSION)" > VERSION
	@$(MAKE) render-version VERSION="$(VERSION)"

repo: render-version
	@echo "Catalog: $(BUILD_DIR)/repo.xml"

helper:
	$(MAKE) -C helper/src VERSION="$(VERSION)"

test: helper
	prove -l -It/lib t
	$(MAKE) -C helper/src test

# Build the exact helper that goes into the release folder.  By default this
# is static and includes libdstdec.  This target always rebuilds so a previous
# development build can never leak into dist/.
# Build the host helper (used by `make test` and local installs).
helper-dist:
	$(MAKE) -C helper/src clean
	$(MAKE) -C helper/src VERSION="$(VERSION)" NO_LIBAV=$(NO_LIBAV) STATIC=$(STATIC)
	mkdir -p Bin/$(BINARCH)
	cp -p $(HELPER_BIN) Bin/$(BINARCH)/sacd_dsd
	chmod 755 Bin/$(BINARCH)/sacd_dsd

# Build all release architectures into Bin/<arch>/sacd_dsd.
bins:
	$(MAKE) -C helper/src clean
	$(MAKE) -C helper/src VERSION="$(VERSION)" NO_LIBAV=$(NO_LIBAV) STATIC=$(STATIC) CC=$(CC_x86_64_linux)
	mkdir -p Bin/x86_64-linux
	cp -p $(HELPER_BIN) Bin/x86_64-linux/sacd_dsd
	$(MAKE) -C helper/src clean
	$(MAKE) -C helper/src VERSION="$(VERSION)" NO_LIBAV=$(NO_LIBAV) STATIC=$(STATIC) CC=$(CC_aarch64_linux)
	mkdir -p Bin/aarch64-linux
	cp -p $(HELPER_BIN) Bin/aarch64-linux/sacd_dsd
	$(MAKE) -C helper/src clean
	$(MAKE) -C helper/src VERSION="$(VERSION)" NO_LIBAV=$(NO_LIBAV) STATIC=$(STATIC) CC=$(CC_armhf_linux)
	mkdir -p Bin/armhf-linux
	cp -p $(HELPER_BIN) Bin/armhf-linux/sacd_dsd
	$(MAKE) -C helper/src clean
	$(MAKE) -C helper/src VERSION="$(VERSION)" NO_LIBAV=$(NO_LIBAV) STATIC=$(STATIC) CC=$(CC_arm_linux)
	mkdir -p Bin/arm-linux
	cp -p $(HELPER_BIN) Bin/arm-linux/sacd_dsd
	$(MAKE) -C helper/src clean
	$(MAKE) -C helper/src VERSION="$(VERSION)" NO_LIBAV=$(NO_LIBAV) STATIC=$(STATIC) CC=$(CC_i386_linux)
	mkdir -p Bin/i386-linux
	cp -p $(HELPER_BIN) Bin/i386-linux/sacd_dsd
	$(MAKE) -C helper/src clean
	$(MAKE) -C helper/src VERSION="$(VERSION)" NO_LIBAV=$(NO_LIBAV) STATIC=$(STATIC) CC=$(CC_ms_win) EXE=.exe
	mkdir -p Bin/MSWin32-x64-multi-thread
	cp -p helper/src/sacd_dsd.exe Bin/MSWin32-x64-multi-thread/sacd_dsd.exe
	$(MAKE) -C helper/src clean
	chmod 755 Bin/*/sacd_dsd Bin/*/sacd_dsd.exe 2>/dev/null || true

dist: render-version helper-dist
	rm -rf $(DIST)
	mkdir -p $(DIST)
	cp -p $(BUILD_DIR)/install.xml strings.txt README.md README.zh-CN.md LICENSE THIRD_PARTY_NOTICES.md $(DIST)/
	cp -Rp lib HTML Bin $(DIST)/
	find $(DIST) -type d -exec chmod 755 {} +
	find $(DIST) -type f -exec chmod 644 {} +
	chmod 755 $(DIST)/Bin/*/sacd_dsd $(DIST)/Bin/*/sacd_dsd.exe 2>/dev/null || true
	@echo
	@echo "Release folder: $(DIST)"
	@echo "Copy it to <LMS>/Plugins/SACD, then restart LMS."
	@echo "Helper:"; $(DIST)/Bin/$(BINARCH)/sacd_dsd --probe

dist-all: bins render-version
	rm -rf $(DIST)
	mkdir -p $(DIST)
	cp -p $(BUILD_DIR)/install.xml strings.txt README.md README.zh-CN.md LICENSE THIRD_PARTY_NOTICES.md $(DIST)/
	cp -Rp lib HTML Bin $(DIST)/
	find $(DIST) -type d -exec chmod 755 {} +
	find $(DIST) -type f -exec chmod 644 {} +
	chmod 755 $(DIST)/Bin/*/sacd_dsd $(DIST)/Bin/*/sacd_dsd.exe 2>/dev/null || true

bundle: dist
	tar -C dist -czf dist/SACD-$(VERSION)-$(BINARCH).tar.gz SACD
	@echo "Archive: dist/SACD-$(VERSION)-$(BINARCH).tar.gz"

bundle-all: dist-all
	tar -C dist -czf dist/SACD-$(VERSION)-all.tar.gz SACD
	@echo "Archive: dist/SACD-$(VERSION)-all.tar.gz"

verify-dist:
	@test -f $(DIST)/install.xml || (echo "missing dist; run make dist" >&2; exit 1)
	@grep -q "<version>$(VERSION)</version>" $(DIST)/install.xml || (echo "install.xml version mismatch" >&2; exit 1)
	@for bin in $(DIST)/Bin/*/sacd_dsd $(DIST)/Bin/*/sacd_dsd.exe; do test -x "$$bin" 2>/dev/null || test -f "$$bin" || (echo "missing helper: $$bin" >&2; exit 1); done
	@$(DIST)/Bin/$(BINARCH)/sacd_dsd --probe
	@perl -I$(DIST)/lib -It/lib -c $(DIST)/lib/Plugins/SACDPlayer/TagReader.pm
	@echo "dist verified"

verify-bins:
	@file Bin/x86_64-linux/sacd_dsd Bin/aarch64-linux/sacd_dsd Bin/armhf-linux/sacd_dsd Bin/arm-linux/sacd_dsd Bin/i386-linux/sacd_dsd Bin/MSWin32-x64-multi-thread/sacd_dsd.exe
	@qemu-aarch64-static Bin/aarch64-linux/sacd_dsd --probe
	@qemu-arm-static Bin/armhf-linux/sacd_dsd --probe
	@qemu-arm-static Bin/arm-linux/sacd_dsd --probe
	@qemu-i386-static Bin/i386-linux/sacd_dsd --probe
	@WINEDEBUG=-all wine Bin/MSWin32-x64-multi-thread/sacd_dsd.exe --probe
	@echo "binaries verified"

install: dist
	@test -n "$(PLUGINS_DIR)" || (echo "usage: make install PLUGINS_DIR=/path/to/lms/Plugins" >&2; exit 1)
	rm -rf "$(PLUGINS_DIR)/SACDPlayer"
	cp -a $(DIST) "$(PLUGINS_DIR)/SACDPlayer"
	@echo "Installed to $(PLUGINS_DIR)/SACDPlayer"

clean:
	$(MAKE) -C helper/src clean
	rm -rf dist build
