ROOT = generated\windows\64

TARGETS=	$(ROOT)\dman.exe \
	$(ROOT)\rdmd.exe \
	$(ROOT)\ddemangle.exe \
	$(ROOT)\changed.exe \
	$(ROOT)\dustmite.exe

targets : $(TARGETS)

dman:      $(ROOT)\dman.exe
rdmd:      $(ROOT)\rdmd.exe
ddemangle: $(ROOT)\ddemangle.exe
changed:   $(ROOT)\changed.exe
dustmite:  $(ROOT)\dustmite.exe

d-tags.json :
	@echo 'Build d-tags.json and copy it here, e.g. by running:'
	@echo "    make -C ../dlang.org -f win64.mak d-tags.json && copy ../dlang.org/d-tags-latest.json d-tags.json"
	@exit

MAKE_WIN32=make -f win32.mak "ROOT=$(ROOT)" "MODEL=$(MODEL)"

$(ROOT)\dman.exe : dman.d d-tags.json
	$(MAKE_WIN32) $@

$(ROOT)\rdmd.exe : rdmd.d
	$(MAKE_WIN32) $@

$(ROOT)\ddemangle.exe : ddemangle.d
	$(MAKE_WIN32) $@

$(ROOT)\dustmite.exe : DustMite/dustmite.d DustMite/splitter.d DustMite/polyhash.d
	$(MAKE_WIN32) $@

$(ROOT)\changed.exe : changed.d
	$(MAKE_WIN32) $@

clean :
	$(MAKE_WIN32) $@

detab:
	$(MAKE_WIN32) $@

tolf:
	$(MAKE_WIN32) $@

zip: detab tolf $(MAKEFILES)
	$(MAKE_WIN32) $@

scp: detab tolf $(MAKEFILES)
	$(MAKE_WIN32) $@


################################################################################
# Build and run tests
################################################################################
$(ROOT)\rdmd_test.exe : rdmd_test.d
	$(MAKE_WIN32) $@

test_rdmd : $(ROOT)\rdmd_test.exe $(RDMD_TEST_EXECUTABLE)
	$(MAKE_WIN32) $@

test : test_rdmd
