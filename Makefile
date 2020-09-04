NIMC=nimble c

MAIN=ndown

SRC=src

DEBUGOUT=build
RELEASEOUT=release

DEBUGOPTS=--outdir:$(DEBUGOUT) --verbose
RELEASEOPTS=--outdir:$(RELEASEOUT) -d:release

.PHONY: run debug release clean

run:
	$(NIMC) $(DEBUGOPTS) -r $(SRC)/$(MAIN)

debug:
	$(NIMC) $(DEBUGOPTS) $(SRC)/$(MAIN)

release:
	$(NIMC) $(RELEASEOPTS) $(SRC)/$(MAIN)

clean:
	rm ./$(DEBUGOUT)/*
	rm ./$(RELEASEOUT)/*
