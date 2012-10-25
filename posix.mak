DMD?=dmd

TARGETS=catdoc ddemangle detab rdmd tolf

all: $(TARGETS)

catdoc:
	$(DMD) -O catdoc.d -ofcatdoc

ddemangle:
	$(DMD) -O ddemangle.d -ofddemangle

detab:
	$(DMD) -O detab.d -ofdetab

rdmd:
	$(DMD) -O rdmd.d -ofrdmd

tolf:
	$(DMD) -O tolf.d -oftolf

clean:
	\rm -f $(TARGETS) *.o
