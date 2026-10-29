PREFIX ?= /usr/local
BIN    = dontallow
SRC    = Sources/dontallow/Core.swift Sources/dontallow/main.swift

$(BIN): $(SRC)
	swiftc -O -o $(BIN) $(SRC)
	codesign -s - -f -i com.pkgwarden.dontallow $(BIN)

test: Sources/dontallow/Core.swift Tests/main.swift
	mkdir -p build
	swiftc -o build/tests Sources/dontallow/Core.swift Tests/main.swift
	./build/tests

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(BIN)

clean:
	rm -rf $(BIN) build

.PHONY: test install clean
