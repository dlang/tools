DMD ?= dmd
PREFIX ?= /usr/local/bin

WITH_DOC ?= no
DOC ?= ../d-programming-language.org/web

MODEL ?= 32
ifneq (,$(MODEL))
    MODEL_FLAG ?= -m$(MODEL)
endif

TOOLS = \
    rdmd \
    ddemangle \
    dget \
    catdoc \
    detab \
    tolf

DOC_TOOLS = \
    findtags \
    dman

TAGS = \
    expression.tag \
    statement.tag

all: $(TOOLS)

$(TOOLS) $(DOC_TOOLS): %: %.d
	$(DMD) $(MODEL_FLAG) $(DFLAGS) $(<)

$(TAGS): %.tag: $(DOC)/%.html findtags
	./findtags $(filter %.html,$(^)) > $(@)

dman: $(TAGS)
dman: DFLAGS += -J.

install: $(TOOLS)
	install -d $(DESTDIR)$(PREFIX)
	install -t $(DESTDIR)$(PREFIX) $(^)

clean:
	rm -f $(TOOLS) $(DOC_TOOLS) $(TAGS) *.o

ifeq ($(WITH_DOC),yes)
all install: $(DOC_TOOLS)
endif

.PHONY: all install clean
