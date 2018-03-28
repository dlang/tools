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

GENERATED = generated
ROOT = $(GENERATED)\windows\32

TARGETS=	$(ROOT)\dman.exe \
	$(ROOT)\rdmd.exe \
	$(ROOT)\ddemangle.exe \
	$(ROOT)\changed.exe \
	$(ROOT)\dustmite.exe

MAKEFILES=win32.mak posix.mak

RDMD_SRC = rdmd/main.d \
           rdmd/args.d \
           rdmd/config.d \
           rdmd/eval.d \
           rdmd/filesystem.d \
           rdmd/verbose.d

SRCS=dman.d $(RDMD_SRC) ddemangle.d

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

$(ROOT)\rdmd.exe : $(RDMD_SRC)
	$(DMD) $(DFLAGS) -of$@ $(RDMD_SRC) advapi32.lib

$(ROOT)\ddemangle.exe : ddemangle.d
	$(DMD) $(DFLAGS) -of$@ ddemangle.d

$(ROOT)\dustmite.exe : DustMite/dustmite.d DustMite/splitter.d
	$(DMD) $(DFLAGS) -of$@ DustMite/dustmite.d DustMite/splitter.d

$(ROOT)\changed.exe : changed.d
	$(DMD) $(DFLAGS) -of$@ changed.d

clean :
	rmdir /s /q $(GENERATED)

detab:
	$(DETAB) $(SRCS)

tolf:
	$(TOLF) $(SRCS) $(MAKEFILES)

zip: detab tolf $(MAKEFILES)
	$(DEL) dman.zip
	$(ZIP) dman $(MAKEFILES) $(SRCS) $(TAGS)

scp: detab tolf $(MAKEFILES)
	$(SCP) $(SRCS) $(MAKEFILES) $(SCPDIR)


################################################################################
# Build and run tests
################################################################################

RDMD_TEST_COMPILERS = $(DMD)
RDMD_TEST_EXECUTABLE = $(ROOT)\rdmd.exe
RDMD_TEST_DEFAULT_COMPILER = $(DMD)

$(ROOT)\rdmd_test.exe : rdmd_test.d
	$(DMD) $(DFLAGS) -of$@ rdmd_test.d

test_rdmd : $(ROOT)\rdmd_test.exe $(RDMD_TEST_EXECUTABLE)
        $(ROOT)\rdmd_test.exe \
           $(RDMD_TEST_EXECUTABLE) -m$(MODEL) -v \
           --rdmd-default-compiler=$(RDMD_TEST_DEFAULT_COMPILER) \
           --test-compilers=$(RDMD_TEST_COMPILERS)

test : test_rdmd
