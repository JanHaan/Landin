GRAMMAR := ../tree-sitter
PARSER := parser/landin.so
SOURCES := $(GRAMMAR)/src/parser.c $(GRAMMAR)/src/scanner.c
UNAME := $(shell uname -s)

ifeq ($(UNAME),Darwin)
  SHARED := -dynamiclib
else
  SHARED := -shared
endif

.PHONY: all clean
all: $(PARSER)

$(PARSER): $(SOURCES)
	cc -O2 -fPIC $(SHARED) -I$(GRAMMAR)/src -o $@ $(SOURCES)

clean:
	rm -f $(PARSER)
