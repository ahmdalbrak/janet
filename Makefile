# Copyright (c) 2019 Calvin Rose
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

################################
##### Set global variables #####
################################

PREFIX?=/usr/local

INCLUDEDIR=$(PREFIX)/include
BINDIR=$(PREFIX)/bin
JANET_BUILD?="\"$(shell git log --pretty=format:'%h' -n 1)\""
CLIBS=-lm
JANET_TARGET=build/janet
JANET_LIBRARY=build/libjanet.so
JANET_PATH?=$(PREFIX)/lib/janet
MANPATH?=$(PREFIX)/share/man/man1/
DEBUGGER=gdb

CFLAGS=-std=c99 -Wall -Wextra -Isrc/include -fpic -O2 -fvisibility=hidden \
	   -DJANET_BUILD=$(JANET_BUILD)

UNAME:=$(shell uname -s)
ifeq ($(UNAME), Darwin)
	# Add other macos/clang flags
	CLIBS:=$(CLIBS) -ldl
else ifeq ($(UNAME), OpenBSD)
	# pass ...
else
	CFLAGS:=$(CFLAGS) -rdynamic
	CLIBS:=$(CLIBS) -lrt -ldl
endif

$(shell mkdir -p build/core build/mainclient build/webclient build/boot)

# Source headers
JANET_HEADERS=$(sort $(wildcard src/include/*.h))
JANET_LOCAL_HEADERS=$(sort $(wildcard src/*/*.h))

# Source files
JANET_CORE_SOURCES=$(sort $(wildcard src/core/*.c))
JANET_MAINCLIENT_SOURCES=$(sort $(wildcard src/mainclient/*.c))
JANET_WEBCLIENT_SOURCES=$(sort $(wildcard src/webclient/*.c))

all: $(JANET_TARGET) $(JANET_LIBRARY)

##################################################################
##### The bootstrap interpreter that compiles the core image #####
##################################################################

JANET_BOOT_SOURCES=$(sort $(wildcard src/boot/*.c))
JANET_BOOT_OBJECTS=$(patsubst src/%.c,build/%.boot.o,$(JANET_CORE_SOURCES) $(JANET_BOOT_SOURCES)) \
	build/core.gen.o \
	build/boot.gen.o

build/%.boot.o: src/%.c
	$(CC) $(CFLAGS) -DJANET_BOOTSTRAP -o $@ -c $<

build/janet_boot: $(JANET_BOOT_OBJECTS)
	$(CC) $(CFLAGS) -DJANET_BOOTSTRAP -o $@ $^ $(CLIBS)

# Now the reason we bootstrap in the first place
build/core_image.c: build/janet_boot
	JANET_PATH=$(JANET_PATH) build/janet_boot

##########################################################
##### The main interpreter program and shared object #####
##########################################################

JANET_CORE_OBJECTS=$(patsubst src/%.c,build/%.o,$(JANET_CORE_SOURCES)) build/core_image.o
JANET_MAINCLIENT_OBJECTS=$(patsubst src/%.c,build/%.o,$(JANET_MAINCLIENT_SOURCES)) build/init.gen.o

# Compile the core image generated by the bootstrap build
build/core_image.o: build/core_image.c $(JANET_HEADERS) $(JANET_LOCAL_HEADERS)
	$(CC) $(CFLAGS) -o $@ -c $<

build/%.o: src/%.c $(JANET_HEADERS) $(JANET_LOCAL_HEADERS)
	$(CC) $(CFLAGS) -o $@ -c $<

$(JANET_TARGET): $(JANET_CORE_OBJECTS) $(JANET_MAINCLIENT_OBJECTS)
	$(CC) $(CFLAGS) -o $@ $^ $(CLIBS)

$(JANET_LIBRARY): $(JANET_CORE_OBJECTS)
	$(CC) $(CFLAGS) -shared -o $@ $^ $(CLIBS)

######################
##### Emscripten #####
######################

EMCC=emcc
EMCFLAGS=-std=c99 -Wall -Wextra -Isrc/include -O2 \
		  -s EXTRA_EXPORTED_RUNTIME_METHODS='["cwrap"]' \
		  -s ALLOW_MEMORY_GROWTH=1 \
		  -s AGGRESSIVE_VARIABLE_ELIMINATION=1 \
		  -DJANET_BUILD=$(JANET_BUILD)
JANET_EMTARGET=build/janet.js
JANET_WEB_SOURCES=$(JANET_CORE_SOURCES) $(JANET_WEBCLIENT_SOURCES)
JANET_EMOBJECTS=$(patsubst src/%.c,build/%.bc,$(JANET_WEB_SOURCES)) \
				build/webinit.gen.bc build/core_image.bc

%.gen.bc: %.gen.c
	$(EMCC) $(EMCFLAGS) -o $@ -c $<

build/core_image.bc: build/core_image.c $(JANET_HEADERS) $(JANET_LOCAL_HEADERS)
	$(EMCC) $(EMCFLAGS) -o $@ -c $<

build/%.bc: src/%.c $(JANET_HEADERS) $(JANET_LOCAL_HEADERS)
	$(EMCC) $(EMCFLAGS) -o $@ -c $<

$(JANET_EMTARGET): $(JANET_EMOBJECTS)
	$(EMCC) $(EMCFLAGS) -shared -o $@ $^

emscripten: $(JANET_EMTARGET)

#############################
##### Generated C files #####
#############################

%.gen.o: %.gen.c
	$(CC) $(CFLAGS) -o $@ -c $<

build/xxd: tools/xxd.c
	$(CC) $< -o $@

build/core.gen.c: src/core/core.janet build/xxd
	build/xxd $< $@ janet_gen_core
build/init.gen.c: src/mainclient/init.janet build/xxd
	build/xxd $< $@ janet_gen_init
build/webinit.gen.c: src/webclient/webinit.janet build/xxd
	build/xxd $< $@ janet_gen_webinit
build/boot.gen.c: src/boot/boot.janet build/xxd
	build/xxd $< $@ janet_gen_boot

########################
##### Amalgamation #####
########################

amalg: build/janet.c build/janet.h build/core_image.c

build/janet.c: $(JANET_LOCAL_HEADERS) $(JANET_CORE_SOURCES) tools/amalg.janet $(JANET_TARGET)
	$(JANET_TARGET) tools/amalg.janet > $@

build/janet.h: src/include/janet.h
	cp $< $@

###################
##### Testing #####
###################

TEST_SCRIPTS=$(wildcard test/suite*.janet)

repl: $(JANET_TARGET)
	./$(JANET_TARGET)

debug: $(JANET_TARGET)
	$(DEBUGGER) ./$(JANET_TARGET)

VALGRIND_COMMAND=valgrind --leak-check=full

valgrind: $(JANET_TARGET)
	$(VALGRIND_COMMAND) ./$(JANET_TARGET)

test: $(JANET_TARGET) $(TEST_PROGRAMS)
	for f in test/*.janet; do ./$(JANET_TARGET) "$$f" || exit; done

valtest: $(JANET_TARGET) $(TEST_PROGRAMS)
	for f in test/*.janet; do $(VALGRIND_COMMAND) ./$(JANET_TARGET) "$$f" || exit; done

callgrind: $(JANET_TARGET)
	for f in test/*.janet; do valgrind --tool=callgrind ./$(JANET_TARGET) "$$f" || exit; done

########################
##### Distribution #####
########################

dist: build/janet-dist.tar.gz

build/janet-%.tar.gz: $(JANET_TARGET) src/include/janet.h \
	janet.1 LICENSE CONTRIBUTING.md $(JANET_LIBRARY) \
	build/doc.html README.md build/janet.c
	tar -czvf $@ $^

#########################
##### Documentation #####
#########################

docs: build/doc.html

build/doc.html: $(JANET_TARGET) tools/gendoc.janet
	$(JANET_TARGET) tools/gendoc.janet > build/doc.html

#################
##### Other #####
#################

STYLEOPTS=--style=attach --indent-switches --convert-tabs \
		  --align-pointer=name --pad-header --pad-oper --unpad-paren --indent-labels
format:
	astyle $(STYLEOPTS) */*.c
	astyle $(STYLEOPTS) */*/*.c
	astyle $(STYLEOPTS) */*/*.h

grammar: build/janet.tmLanguage
build/janet.tmLanguage: tools/tm_lang_gen.janet $(JANET_TARGET)
	$(JANET_TARGET) $< > $@

clean:
	-rm -rf build vgcore.* callgrind.*

install: $(JANET_TARGET)
	mkdir -p $(BINDIR)
	cp $(JANET_TARGET) $(BINDIR)/janet
	mkdir -p $(INCLUDEDIR)
	cp $(JANET_HEADERS) $(INCLUDEDIR)
	mkdir -p $(INCLUDEDIR)/janet
	mkdir -p $(JANET_PATH)
	ln -sf $(INCLUDEDIR)/janet.h $(INCLUDEDIR)/janet/janet.h
	ln -sf $(INCLUDEDIR)/janet.h $(JANET_PATH)/janet.h
	cp tools/cook.janet $(JANET_PATH)
	cp tools/highlight.janet $(JANET_PATH)
	cp tools/bars.janet $(JANET_PATH)
	mkdir -p $(MANPATH)
	cp janet.1 $(MANPATH)

test-install:
	cd test/install && rm -rf build && janet test

uninstall:
	-rm $(BINDIR)/../$(JANET_TARGET)
	-rm -rf $(INCLUDEDIR)

.PHONY: clean install repl debug valgrind test amalg \
	valtest emscripten dist uninstall docs grammar format
