# SACDPlayer build/package helper.
#
#   make            build helper for this host (normal development build)
#   make test       run Perl unit tests and helper selftest
#   make dist       create dist/SACDPlayer/ with a portable helper binary
#   make install PLUGINS_DIR=/path/to/lms/Plugins
#
# `make dist` deliberately builds a static helper with the vendored libdstdec
# decoder, so the resulting folder can be copied to a server without FFmpeg
# development libraries.  libav is only probed as an optional future backend.

VERSION ?= 0.2.7
ARCH    := $(shell uname -m)
ifeq ($(ARCH),x86_64)
BINARCH := x86_64-linux
else ifeq ($(ARCH),aarch64)
BINARCH := aarch64-linux
else
BINARCH := $(ARCH)-linux
endif

DIST       := dist/SACDPlayer
HELPER_BIN := helper/src/sacd_dsd
BIN_TARGET := Bin/$(BINARCH)/sacd_dsd
NO_LIBAV   ?= 1
STATIC     ?= 1

.PHONY: all helper helper-dist test dist bundle install clean verify-dist

all: helper

helper:
	$(MAKE) -C helper/src

test: helper
	prove -l -It/lib t
	$(MAKE) -C helper/src test

# Build the exact helper that goes into the release folder.  By default this
# is static and includes libdstdec.  This target always rebuilds so a previous
# development build can never leak into dist/.
helper-dist:
	$(MAKE) -C helper/src clean
	$(MAKE) -C helper/src NO_LIBAV=$(NO_LIBAV) STATIC=$(STATIC)
	mkdir -p Bin/$(BINARCH)
	cp -p $(HELPER_BIN) $(BIN_TARGET)
	chmod 755 $(BIN_TARGET)

dist: helper-dist
	rm -rf $(DIST)
	mkdir -p $(DIST)/Bin/$(BINARCH)
	cp -p install.xml strings.txt README.md LICENSE THIRD_PARTY_NOTICES.md $(DIST)/
	cp -Rp lib HTML $(DIST)/
	cp -p $(BIN_TARGET) $(DIST)/Bin/$(BINARCH)/sacd_dsd
	cp -p Bin/README.md $(DIST)/Bin/README.md
	find $(DIST) -type d -exec chmod 755 {} +
	find $(DIST) -type f -exec chmod 644 {} +
	chmod 755 $(DIST)/Bin/$(BINARCH)/sacd_dsd
	@echo
	@echo "Release folder: $(DIST)"
	@echo "Copy it to <LMS>/Plugins/SACDPlayer, then restart LMS."
	@echo "Helper:"; $(DIST)/Bin/$(BINARCH)/sacd_dsd --probe

bundle: dist
	tar -C dist -czf dist/SACDPlayer-$(VERSION)-$(BINARCH).tar.gz SACDPlayer
	@echo "Archive: dist/SACDPlayer-$(VERSION)-$(BINARCH).tar.gz"

verify-dist:
	@test -f $(DIST)/install.xml || (echo "missing dist; run make dist" >&2; exit 1)
	@test -x $(DIST)/Bin/$(BINARCH)/sacd_dsd || (echo "missing helper" >&2; exit 1)
	@$(DIST)/Bin/$(BINARCH)/sacd_dsd --probe
	@perl -I$(DIST)/lib -It/lib -c $(DIST)/lib/Plugins/SACDPlayer/TagReader.pm
	@echo "dist verified"

install: dist
	@test -n "$(PLUGINS_DIR)" || (echo "usage: make install PLUGINS_DIR=/path/to/lms/Plugins" >&2; exit 1)
	rm -rf "$(PLUGINS_DIR)/SACDPlayer"
	cp -a $(DIST) "$(PLUGINS_DIR)/SACDPlayer"
	@echo "Installed to $(PLUGINS_DIR)/SACDPlayer"

clean:
	$(MAKE) -C helper/src clean
	rm -rf dist
