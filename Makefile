NIM := nim
SRC := src/main.nim
OUT := buxc
BUILD_DIR := build

.PHONY: all build test clean

all: build

build:
	$(NIM) c -o:$(OUT) -d:release $(SRC)

dev:
	$(NIM) c -o:$(OUT) $(SRC)

test: build
	@echo "Running lexer tests..."
	$(NIM) c -r tests/lexer_test.nim
	@echo "Running integration tests..."
	./$(OUT) new _test_tmp_pkg
	./$(OUT) --version

clean:
	rm -f $(OUT)
	rm -rf $(BUILD_DIR)
	rm -rf nimcache
