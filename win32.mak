
DMD=\cbx\mars\dmd
DOC=\cbx\mars\doc

TARGETS=dman.exe findtags.exe

TAGS=	expression.tag \
	statement.tag

targets : $(TARGETS)

expression.tag : findtags.exe $(DOC)\expression.html
	+findtags $(DOC)\expression.html >expression.tag

statement.tag : findtags.exe $(DOC)\statement.html
	+findtags $(DOC)\statement.html >statement.tag

findtags.exe : findtags.d
	$(DMD) findtags.d

dman.exe : dman.d $(TAGS)
	$(DMD) dman.d -J.

clean :
	del $(TARGETS) $(TAGS)
