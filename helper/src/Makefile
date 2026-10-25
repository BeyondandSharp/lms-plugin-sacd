CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11
CPPFLAGS ?=
LDLIBS  ?= -lm

BIN     := sacd_dsd
SRC     := sacd_dsd.c

HAVE_LIBAV := $(shell pkg-config --exists libavformat libavcodec libavutil 2>/dev/null && echo 1 || echo 0)

ifeq ($(HAVE_LIBAV),1)
# AV_SAMPLE_FMT_DSD is a new enum value, not a preprocessor macro.  Probe it
# with the actual compiler/headers instead of guessing a version number.  We
# only link libav when raw DSD output is actually available; otherwise the
# helper stays dependency-free and DST falls back to the LMS PCM path.
AV_CFLAGS := $(shell pkg-config --cflags libavformat libavcodec libavutil)
AV_LIBS   := $(shell pkg-config --libs libavformat libavcodec libavutil)
DSD_PROBE := $(shell printf '%s\n' \
    '#include <libavutil/samplefmt.h>' \
    'int main(void) { return AV_SAMPLE_FMT_DSD; }' \
    | $(CC) $(AV_CFLAGS) -x c - -o /tmp/sacd_dsd_probe $(AV_LIBS) >/dev/null 2>&1 \
    && echo 1 || echo 0)
ifeq ($(DSD_PROBE),1)
CPPFLAGS += -DHAVE_LIBAV -DHAVE_DSD_SAMPLE_FMT $(AV_CFLAGS)
LDLIBS   += $(AV_LIBS)
endif
endif

ARCH := $(shell uname -m)
ifeq ($(ARCH),x86_64)
BINARCH := x86_64-linux
else ifeq ($(ARCH),aarch64)
BINARCH := aarch64-linux
else
BINARCH := $(ARCH)-linux
endif

.PHONY: all clean install test
all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CPPFLAGS) $(CFLAGS) -D_FILE_OFFSET_BITS=64 -o $@ $< $(LDFLAGS) $(LDLIBS)

test: $(BIN)
	./$(BIN) --selftest
	./$(BIN) --probe

install: $(BIN)
	mkdir -p ../../Bin/$(BINARCH)
	cp $(BIN) ../../Bin/$(BINARCH)/$(BIN)
	chmod 755 ../../Bin/$(BINARCH)/$(BIN)

clean:
	rm -f $(BIN)
