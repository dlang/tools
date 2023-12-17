DMD_DIR = ../dmd
BUILD = release
DMD = $(DMD_DIR)/generated/$(OS)/$(BUILD)/$(MODEL)/dmd
INSTALL_DIR = ../install
DRUNTIME_PATH = ../dmd/druntime
PHOBOS_PATH = ../phobos
DUB=dub

WITH_DOC = no
DOC = ../dlang.org

# Load operating system $(OS) (e.g. linux, osx, ...) and $(MODEL) (e.g. 32, 64) detection Makefile from dmd
$(shell [ ! -d $(DMD_DIR) ] && git clone --depth=1 https://github.com/dlang/dmd $(DMD_DIR))
include $(DMD_DIR)/compiler/src/osmodel.mak

ifeq (windows,$(OS))
    DOTEXE:=.exe
else
    DOTEXE:=
endif

# Build folder for all binaries
GENERATED = generated
ROOT = $(GENERATED)/$(OS)/$(MODEL)

# default to warnings and deprecations as errors, override via e.g. make WARNINGS=-wi
WARNINGS = -w -de
# default flags, override by setting DFLAGS (e.g. make DFLAGS=-O)
DFLAGS = $(MODEL_FLAG) $(if $(findstring windows,$(OS)),,-fPIC) -preview=dip1000
DFLAGS += $(WARNINGS)

# Default DUB flags (DUB uses a different architecture format)
DUBFLAGS = --arch=$(subst 32,x86,$(subst 64,x86_64,$(MODEL)))

TOOLS = \
    $(ROOT)/catdoc$(DOTEXE) \
    $(ROOT)/checkwhitespace$(DOTEXE) \
    $(ROOT)/contributors$(DOTEXE) \
    $(ROOT)/ddemangle$(DOTEXE) \
    $(ROOT)/detab$(DOTEXE) \
    $(ROOT)/rdmd$(DOTEXE) \
    $(ROOT)/tolf$(DOTEXE) \
    $(ROOT)/updatecopyright$(DOTEXE)

CURL_TOOLS = \
    $(ROOT)/changed$(DOTEXE) \
    $(ROOT)/dget$(DOTEXE)

DOC_TOOLS = \
    $(ROOT)/dman$(DOTEXE)

TEST_TOOLS = \
    $(ROOT)/rdmd_test$(DOTEXE)

all: $(TOOLS) $(CURL_TOOLS) $(ROOT)/dustmite$(DOTEXE)

rdmd:      $(ROOT)/rdmd$(DOTEXE)
ddemangle: $(ROOT)/ddemangle$(DOTEXE)
catdoc:    $(ROOT)/catdoc$(DOTEXE)
detab:     $(ROOT)/detab$(DOTEXE)
tolf:      $(ROOT)/tolf$(DOTEXE)
dget:      $(ROOT)/dget$(DOTEXE)
changed:   $(ROOT)/changed$(DOTEXE)
dman:      $(ROOT)/dman$(DOTEXE)
dustmite:  $(ROOT)/dustmite$(DOTEXE)

$(ROOT)/dustmite$(DOTEXE): DustMite/dustmite.d DustMite/splitter.d DustMite/polyhash.d
	$(DMD) $(DFLAGS) -version=Dlang_Tools DustMite/dustmite.d DustMite/splitter.d DustMite/polyhash.d -of$(@)

$(TOOLS) $(DOC_TOOLS) $(CURL_TOOLS) $(TEST_TOOLS): $(ROOT)/%$(DOTEXE): %.d
	$(DMD) $(DFLAGS) -of$(@) $(<)

d-tags.json:
	@echo 'Build d-tags.json and copy it here, e.g. by running:'
	@echo "    make -C ../dlang.org -f posix.mak d-tags-latest.json && cp ../dlang.org/d-tags-latest.json d-tags.json"
	@echo 'or:'
	@echo "    make -C ../dlang.org -f posix.mak d-tags-prerelease.json && cp ../dlang.org/d-tags-prerelease.json d-tags.json"
	@exit 1

$(ROOT)/dman$(DOTEXE): d-tags.json
$(ROOT)/dman$(DOTEXE): override DFLAGS += -J.

install: $(TOOLS) $(CURL_TOOLS) $(ROOT)/dustmite$(DOTEXE)
	mkdir -p $(INSTALL_DIR)/bin
	cp $^ $(INSTALL_DIR)/bin

clean:
	rm -rf $(GENERATED)

$(ROOT)/tests_extractor$(DOTEXE): tests_extractor.d
	mkdir -p $(ROOT)
	DFLAGS="$(DFLAGS)" $(DUB) build \
		   --single $< --force --compiler=$(DMD) $(DUBFLAGS) \
		   && mv ./tests_extractor$(DOTEXE) $@

################################################################################
# Build & run tests
################################################################################

test_tests_extractor: $(ROOT)/tests_extractor$(DOTEXE)
	for file in ascii iteration ; do \
		$< -i "./test/tests_extractor/$${file}.d" | diff --strip-trailing-cr -p - "./test/tests_extractor/$${file}.d.ext"; \
	done
	$< -a betterc -i "./test/tests_extractor/attributes.d" | diff --strip-trailing-cr -p - "./test/tests_extractor/attributes.d.ext";
	$< --betterC -i "./test/tests_extractor/betterc.d" | diff --strip-trailing-cr -p - "./test/tests_extractor/betterc.d.ext";

RDMD_TEST_COMPILERS = $(DMD)
RDMD_TEST_EXECUTABLE = $(ROOT)/rdmd$(DOTEXE)
RDMD_TEST_DEFAULT_COMPILER = $(basename $(DMD))

VERBOSE_RDMD_TEST=0
ifeq ($(VERBOSE_RDMD_TEST), 1)
	override VERBOSE_RDMD_TEST_FLAGS:=-v
endif

test_rdmd: $(ROOT)/rdmd_test$(DOTEXE) $(RDMD_TEST_EXECUTABLE)
	$< $(RDMD_TEST_EXECUTABLE) $(MODEL_FLAG) \
	   --rdmd-default-compiler=$(RDMD_TEST_DEFAULT_COMPILER) \
	   --test-compilers=$(RDMD_TEST_COMPILERS) \
	   $(VERBOSE_RDMD_TEST_FLAGS)
	$(DMD) $(DFLAGS) -unittest -main -run rdmd.d

test: test_tests_extractor test_rdmd

ifeq ($(WITH_DOC),yes)
all install: $(DOC_TOOLS)
endif

.PHONY: all install clean

.DELETE_ON_ERROR: # GNU Make directive (delete output files on error)
