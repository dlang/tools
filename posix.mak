DMD ?= dmd
CC ?= gcc
PREFIX ?= /usr/local/bin

WITH_DOC ?= no
DOC ?= ../d-programming-language.org/web

MODEL:=
ifneq (,$(MODEL))
    MODEL_FLAG:=-m$(MODEL)
endif

TOOLS = \
    rdmd \
    ddemangle \
    catdoc \
    detab \
    tolf

CURL_TOOLS = \
    dget \
    changed

DOC_TOOLS = \
    findtags \
    dman

TAGS:= \
	expression.tag \
	statement.tag

PHOBOS_TAGS:= \
	std_algorithm.tag \
	std_array.tag \
	std_file.tag \
	std_format.tag \
	std_math.tag \
	std_parallelism.tag \
	std_path.tag \
	std_random.tag \
	std_range.tag \
	std_regex.tag \
	std_stdio.tag \
	std_string.tag \
	std_traits.tag \
	std_typetuple.tag

all: $(TOOLS) $(CURL_TOOLS)

#dreadful custom step because of libcurl dmd linking problem
$(CURL_TOOLS): %: %.d
	$(DMD) -c $(<)
	($(DMD) -v $(@).o  2>1 | grep gcc | cut -f2- -d' ' ; echo -lcurl  ) | xargs $(CC)

$(TOOLS) $(DOC_TOOLS): %: %.d
	$(DMD) $(MODEL_FLAG) $(DFLAGS) $(<)

$(TAGS): %.tag: $(DOC)/%.html findtags
	./findtags $< > $@

$(PHOBOS_TAGS): %.tag: $(DOC)/phobos/%.html findtags
	./findtags $< > $@

dman: $(TAGS) $(PHOBOS_TAGS)
dman: DFLAGS += -J.

install: $(TOOLS) $(CURL_TOOLS)
	install -d $(DESTDIR)$(PREFIX)
	install -t $(DESTDIR)$(PREFIX) $(^)

clean:
	rm -f $(TOOLS) $(DOC_TOOLS) $(TAGS) *.o

ifeq ($(WITH_DOC),yes)
all install: $(DOC_TOOLS)
endif

.PHONY: all install clean
