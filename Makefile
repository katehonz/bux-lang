NIM := nim
SRC := compiler/bootstrap/main.nim
OUT := buxc
BUILD_DIR := build

EXAMPLES := hello fibonacci factorial structs enums methods algebraic_enums generics generics_struct generic_infer generic_infer2 extend_generic pattern_matching strings strings2 map result_option try_operator ownership ctfe async concurrency os_time process json

.PHONY: all build dev test clean test-examples

all: build

build:
	$(NIM) c -o:$(OUT) -d:release $(SRC)

dev:
	$(NIM) c -o:$(OUT) $(SRC)

test: build test-examples
	@echo "Running lexer tests..."
	$(NIM) c -r compiler/tests/lexer_test.nim
	@echo "Running parser tests..."
	$(NIM) c -r compiler/tests/parser_test.nim
	@echo "Running sema tests..."
	$(NIM) c -r compiler/tests/sema_test.nim
	@echo "Running HIR tests..."
	$(NIM) c -r compiler/tests/hir_test.nim
	@echo "Running borrow checker tests..."
	$(NIM) c -r compiler/tests/borrow_test.nim
	@echo "Running integration tests..."
	rm -rf _test_tmp_pkg
	./$(OUT) new _test_tmp_pkg
	./$(OUT) --version

test-examples: build
	@for ex in $(EXAMPLES); do \
		echo "=== Testing example: $$ex ==="; \
		mkdir -p examples_pkg/$$ex/src; \
		cp examples/$$ex.bux examples_pkg/$$ex/src/Main.bux; \
		if [ ! -f examples_pkg/$$ex/bux.toml ]; then \
			echo '[Package]' > examples_pkg/$$ex/bux.toml; \
			echo 'Name    = "'$$ex'"' >> examples_pkg/$$ex/bux.toml; \
			echo 'Version = "0.1.0"' >> examples_pkg/$$ex/bux.toml; \
			echo 'Type    = "bin"' >> examples_pkg/$$ex/bux.toml; \
			echo '' >> examples_pkg/$$ex/bux.toml; \
			echo '[Build]' >> examples_pkg/$$ex/bux.toml; \
			echo 'Output = "Bin"' >> examples_pkg/$$ex/bux.toml; \
		fi; \
		(cd examples_pkg/$$ex && timeout 10 ../../$(OUT) run) || exit 1; \
	done
	@echo "All examples passed!"

clean:
	rm -f $(OUT)
	rm -rf $(BUILD_DIR)
	rm -rf nimcache
	rm -rf examples_pkg
	rm -rf _test_tmp_pkg

selfhost: build
	@echo "=== Phase 7.9: Building self-hosted compiler ==="
	@rm -rf _selfhost/src
	@mkdir -p _selfhost/src
	@cp compiler/selfhost/*.bux _selfhost/src/
	@mv _selfhost/src/main.bux _selfhost/src/Main.bux 2>/dev/null || true
	@cd _selfhost && ../$(OUT) build
	@echo "=== Self-hosted compiler built successfully ==="
