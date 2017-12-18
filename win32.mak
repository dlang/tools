# Where scp command copies to
SCPDIR=..\backup

##### Tools

# D compiler
DMD=dmd
# C++ compiler
CC=dmc
# Make program
MAKE=make
# Librarian
LIB=lib
# Delete file(s)
DEL=del
# Make directory
MD=mkdir
# Remove directory
RD=rmdir
# File copy
CP=cp
# De-tabify
DETAB=detab
# Convert line endings to Unix
TOLF=tolf
# Zip
ZIP=zip32
# Copy to another directory
SCP=$(CP)

DFLAGS=-O -release

ROOT_OF_THEM_ALL = generated
ROOT = $(ROOT_OF_THEM_ALL)\windows\32

TARGETS=	$(ROOT)\dman.exe \
	$(ROOT)\rdmd.exe \
	$(ROOT)\ddemangle.exe \
	$(ROOT)\changed.exe \
	$(ROOT)\dustmite.exe

MAKEFILES=win32.mak posix.mak

SRCS=dman.d rdmd.d ddemangle.d

targets : $(TARGETS)

dman:      $(ROOT)\dman.exe
rdmd:      $(ROOT)\rdmd.exe
ddemangle: $(ROOT)\ddemangle.exe
changed:   $(ROOT)\changed.exe
dustmite:  $(ROOT)\dustmite.exe

d-tags.json :
	@echo 'Build d-tags.json and copy it here, e.g. by running:'
	@echo "    make -C ../dlang.org -f win32.mak d-tags.json && copy ../dlang.org/d-tags-latest.json d-tags.json"
	@exit

$(ROOT)\dman.exe : dman.d d-tags.json
	$(DMD) $(DFLAGS) -of$@ dman.d -J.

$(ROOT)\rdmd.exe : rdmd.d
	$(DMD) $(DFLAGS) -of$@ rdmd.d advapi32.lib

$(ROOT)\ddemangle.exe : ddemangle.d
	$(DMD) $(DFLAGS) -of$@ ddemangle.d

$(ROOT)\dustmite.exe : DustMite/dustmite.d DustMite/splitter.d
	$(DMD) $(DFLAGS) -of$@ DustMite/dustmite.d DustMite/splitter.d

$(ROOT)\changed.exe : changed.d
	$(DMD) $(DFLAGS) -of$@ changed.d

clean :
	del $(TARGETS) $(TAGS)

detab:
	$(DETAB) $(SRCS)

tolf:
	$(TOLF) $(SRCS) $(MAKEFILES)

zip: detab tolf $(MAKEFILES)
	$(DEL) dman.zip
	$(ZIP) dman $(MAKEFILES) $(SRCS) $(TAGS)

scp: detab tolf $(MAKEFILES)
	$(SCP) $(SRCS) $(MAKEFILES) $(SCPDIR)
