DMD_DIR = ../dmd
DMD = $(DMD_DIR)/generated/$(OS)/release/$(MODEL)/dmd
CC = gcc
INSTALL_DIR = ../install
DRUNTIME_PATH = ../druntime
PHOBOS_PATH = ../phobos
DUB=dub

RDMD_TEST_COMPILERS = $(abspath $(DMD))

WITH_DOC = no
DOC = ../dlang.org

# Load operating system $(OS) (e.g. linux, osx, ...) and $(MODEL) (e.g. 32, 64) detection Makefile from dmd
$(shell [ ! -d $(DMD_DIR) ] && git clone --depth=1 https://github.com/dlang/dmd $(DMD_DIR))
include $(DMD_DIR)/src/osmodel.mak

# Build folder for all binaries
ROOT_OF_THEM_ALL = generated
ROOT = $(ROOT_OF_THEM_ALL)/$(OS)/$(MODEL)

# Set DRUNTIME name and full path
ifeq (,$(findstring win,$(OS)))
	DRUNTIME = $(DRUNTIME_PATH)/lib/libdruntime-$(OS)$(MODEL).a
	DRUNTIMESO = $(DRUNTIME_PATH)/lib/libdruntime-$(OS)$(MODEL)so.a
else
	DRUNTIME = $(DRUNTIME_PATH)/lib/druntime.lib
endif

# Set PHOBOS name and full path
ifeq (,$(findstring win,$(OS)))
	PHOBOS = $(PHOBOS_PATH)/generated/$(OS)/release/$(MODEL)/libphobos2.a
	PHOBOSSO = $(PHOBOS_PATH)/generated/$(OS)/release/$(MODEL)/libphobos2.so
endif

# default to warnings and deprecations as errors, override via e.g. make -f posix.mak WARNINGS=-wi
WARNINGS = -w -de
# default include/link paths, override by setting DFLAGS (e.g. make -f posix.mak DFLAGS=-I/foo)
DFLAGS = -I$(DRUNTIME_PATH)/import -I$(PHOBOS_PATH) \
		 -L-L$(PHOBOS_PATH)/generated/$(OS)/release/$(MODEL) $(MODEL_FLAG) -fPIC
DFLAGS += $(WARNINGS)

# Default DUB flags (DUB uses a different architecture format)
DUBFLAGS = --arch=$(subst 32,x86,$(subst 64,x86_64,$(MODEL)))

TOOLS = \
    $(ROOT)/catdoc \
    $(ROOT)/checkwhitespace \
    $(ROOT)/contributors \
    $(ROOT)/ddemangle \
    $(ROOT)/detab \
    $(ROOT)/rdmd \
    $(ROOT)/tolf

CURL_TOOLS = \
    $(ROOT)/changed \
    $(ROOT)/dget

DOC_TOOLS = \
    $(ROOT)/dman

TEST_TOOLS = \
    $(ROOT)/rdmd_test

all: $(TOOLS) $(CURL_TOOLS) $(ROOT)/dustmite

rdmd:      $(ROOT)/rdmd
ddemangle: $(ROOT)/ddemangle
catdoc:    $(ROOT)/catdoc
detab:     $(ROOT)/detab
tolf:      $(ROOT)/tolf
dget:      $(ROOT)/dget
changed:   $(ROOT)/changed
dman:      $(ROOT)/dman
dustmite:  $(ROOT)/dustmite

$(ROOT)/dustmite: DustMite/dustmite.d DustMite/splitter.d
	$(DMD) $(DFLAGS) DustMite/dustmite.d DustMite/splitter.d -of$(@)

$(TOOLS) $(DOC_TOOLS) $(CURL_TOOLS) $(TEST_TOOLS): $(ROOT)/%: %.d
	$(DMD) $(DFLAGS) -of$(@) $(<)

d-tags.json:
	@echo 'Build d-tags.json and copy it here, e.g. by running:'
	@echo "    make -C ../dlang.org -f posix.mak d-tags-latest.json && cp ../dlang.org/d-tags-latest.json d-tags.json"
	@echo 'or:'
	@echo "    make -C ../dlang.org -f posix.mak d-tags-prerelease.json && cp ../dlang.org/d-tags-prerelease.json d-tags.json"
	@exit 1

$(ROOT)/dman: d-tags.json
$(ROOT)/dman: override DFLAGS += -J.

install: $(TOOLS) $(CURL_TOOLS) $(ROOT)/dustmite
	mkdir -p $(INSTALL_DIR)/bin
	cp $^ $(INSTALL_DIR)/bin

clean:
	rm -f $(ROOT)/dustmite $(TOOLS) $(CURL_TOOLS) $(DOC_TOOLS) $(TAGS) *.o $(ROOT)/*.o

$(ROOT)/tests_extractor: tests_extractor.d
	mkdir -p $(ROOT)
	DFLAGS="$(DFLAGS)" $(DUB) build \
		   --single $< --force --compiler=$(abspath $(DMD)) $(DUBFLAGS) \
		   && mv ./tests_extractor $@

################################################################################
# Build & run tests
################################################################################

test_tests_extractor: $(ROOT)/tests_extractor
	$< -i ./test/tests_extractor/ascii.d | diff - ./test/tests_extractor/ascii.d.ext
	$< -i ./test/tests_extractor/iteration.d | diff - ./test/tests_extractor/iteration.d.ext

test_rdmd: $(ROOT)/rdmd_test $(ROOT)/rdmd
	$< --compiler=$(abspath $(DMD)) -m$(MODEL) \
	   --test-compilers=$(RDMD_TEST_COMPILERS)
	$(DMD) $(DFLAGS) -unittest -main -run rdmd.d

test: test_tests_extractor test_rdmd

ifeq ($(WITH_DOC),yes)
all install: $(DOC_TOOLS)
endif

.PHONY: all install clean

.DELETE_ON_ERROR: # GNU Make directive (delete output files on error)
