DMD_DIR = ../dmd
DMD = $(DMD_DIR)/generated/$(OS)/release/$(MODEL)/dmd
CC = gcc
INSTALL_DIR = ../install
DRUNTIME_PATH = ../druntime
PHOBOS_PATH = ../phobos
DUB=dub

WITH_DOC = no
DOC = ../dlang.org

$(shell [ ! -d $(DMD_DIR) ] && git clone --depth=1 https://github.com/dlang/dmd $(DMD_DIR))
include $(DMD_DIR)/src/osmodel.mak

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

# default include/link paths, override by setting DFLAGS (e.g. make -f posix.mak DFLAGS=-I/foo)
DFLAGS = -I$(DRUNTIME_PATH)/import -I$(PHOBOS_PATH) \
		 -L-L$(PHOBOS_PATH)/generated/$(OS)/release/$(MODEL) $(MODEL_FLAG)
DFLAGS += -w

TOOLS = \
    $(ROOT)/rdmd \
    $(ROOT)/ddemangle \
    $(ROOT)/catdoc \
    $(ROOT)/detab \
    $(ROOT)/tolf

CURL_TOOLS = \
    $(ROOT)/dget \
    $(ROOT)/changed

DOC_TOOLS = \
    $(ROOT)/dman

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

#dreadful custom step because of libcurl dmd linking problem (Bugzilla 7044)
$(CURL_TOOLS): $(ROOT)/%: %.d
	$(DMD) $(DFLAGS) -c -of$(@).o $(<)
# grep for the linker invocation and append -lcurl
	LINKCMD=$$($(DMD) $(DFLAGS) -v -of$(@) $(@).o 2>/dev/null | grep $(@).o); \
	$${LINKCMD} -lcurl

$(TOOLS) $(DOC_TOOLS): $(ROOT)/%: %.d
	$(DMD) $(DFLAGS) -of$(@) $(<)

ALL_OF_PHOBOS_DRUNTIME_AND_DLANG_ORG = # ???

$(DOC)/d.tag : $(ALL_OF_PHOBOS_DRUNTIME_AND_DLANG_ORG)
	${MAKE} --directory=${DOC} -f posix.mak d.tag

$(ROOT)/dman: $(DOC)/d.tag
$(ROOT)/dman: DFLAGS += -J$(DOC)

install: $(TOOLS) $(CURL_TOOLS) $(ROOT)/dustmite
	mkdir -p $(INSTALL_DIR)/bin
	cp $^ $(INSTALL_DIR)/bin

clean:
	rm -f $(ROOT)/dustmite $(TOOLS) $(CURL_TOOLS) $(DOC_TOOLS) $(TAGS) *.o $(ROOT)/*.o

$(ROOT)/tests_extractor: tests_extractor.d
	mkdir -p $(ROOT)
	$(DUB) build \
		   --single $< --force --compiler=$(abspath $(DMD)) && mv ./tests_extractor $@

test: $(ROOT)/tests_extractor
	$< -i ./test/tests_extractor/ascii.d | diff - ./test/tests_extractor/ascii.d.ext
	$< -i ./test/tests_extractor/iteration.d | diff - ./test/tests_extractor/iteration.d.ext

ifeq ($(WITH_DOC),yes)
all install: $(DOC_TOOLS)
endif

.PHONY: all install clean

.DELETE_ON_ERROR: # GNU Make directive (delete output files on error)
