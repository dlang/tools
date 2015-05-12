DMD = ../dmd/src/dmd
CC = gcc
INSTALL_DIR = ../install
DRUNTIME_PATH = ../druntime
PHOBOS_PATH = ../phobos

WITH_DOC = no
DOC = ../dlang.org

ifeq (,$(OS))
    uname_S:=$(shell uname -s)
    ifeq (Darwin,$(uname_S))
        OS=osx
    endif
    ifeq (Linux,$(uname_S))
        OS=linux
    endif
    ifeq (FreeBSD,$(uname_S))
        OS=freebsd
    endif
    ifeq (OpenBSD,$(uname_S))
        OS=openbsd
    endif
    ifeq (Solaris,$(uname_S))
        OS=solaris
    endif
    ifeq (SunOS,$(uname_S))
        OS=solaris
    endif
    ifeq (,$(OS))
        $(error Unrecognized or unsupported OS for uname: $(uname_S))
    endif
endif

ifeq (,$(MODEL))
    uname_M:=$(shell uname -m)
    ifeq (x86_64,$(uname_M))
        MODEL=64
    else
        ifeq (i686,$(uname_M))
            MODEL=32
        else
            $(error Cannot figure 32/64 model from uname -m: $(uname_M))
        endif
    endif
endif

MODEL_FLAG=-m$(MODEL)

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

# default include/link paths, override by setting DMD (e.g. make -f posix.mak DMD=dmd)
DMD += -I$(DRUNTIME_PATH)/import -I$(PHOBOS_PATH) -L-L$(PHOBOS_PATH)/generated/$(OS)/release/$(MODEL)

DFLAGS = -w

TOOLS = \
    $(ROOT)/rdmd \
    $(ROOT)/ddemangle \
    $(ROOT)/catdoc \
    $(ROOT)/detab \
    $(ROOT)/reindent \
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
	$(DMD) $(MODEL_FLAG) $(DFLAGS) DustMite/dustmite.d DustMite/splitter.d -of$(@)

#dreadful custom step because of libcurl dmd linking problem (Bugzilla 7044)
$(CURL_TOOLS): $(ROOT)/%: %.d
	$(DMD) $(MODEL_FLAG) $(DFLAGS) -c -of$(@).o $(<)
# grep for the linker invocation and append -lcurl
	LINKCMD=$$($(DMD) $(MODEL_FLAG) $(DFLAGS) -v -of$(@) $(@).o 2>/dev/null | grep $(@).o); \
	$${LINKCMD} -lcurl

$(TOOLS) $(DOC_TOOLS): $(ROOT)/%: %.d
	$(DMD) $(MODEL_FLAG) $(DFLAGS) -of$(@) $(<)

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

ifeq ($(WITH_DOC),yes)
all install: $(DOC_TOOLS)
endif

.PHONY: all install clean
