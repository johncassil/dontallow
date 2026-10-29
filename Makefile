PREFIX ?= /usr/local
BIN    = dontallow

$(BIN): Sources/dontallow/main.swift
	swiftc -O -o $(BIN) Sources/dontallow/main.swift
	codesign -s - -f -i com.pkgwarden.dontallow $(BIN)

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(BIN)

clean:
	rm -f $(BIN)

.PHONY: install clean
