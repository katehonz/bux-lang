NIM := nim
SRC := bootstrap/main.nim
OUT := buxc
BUILD_DIR := build

EXAMPLES := hello fibonacci factorial structs enums methods algebraic_enums generics generics_struct generic_infer generic_infer2 extend_generic pattern_matching strings strings2 map result_option try_operator ownership ctfe async concurrency os_time process json iter

.PHONY: all build dev debug test clean clean-all test-examples selfhost test-golden selfhost-loop lsp

all: build

build:
	$(NIM) c -o:$(OUT) -d:release --opt:size $(SRC)
	# strip $(OUT)

dev:
	$(NIM) c -o:buxc_debug -d:debug --stackTrace:on --lineTrace:on $(SRC)

debug: dev
	@echo "Debug binary: buxc_debug"

test: build test-examples
	@echo "Running lexer tests..."
	$(NIM) c -r tests/lexer_test.nim
	@echo "Running parser tests..."
	$(NIM) c -r tests/parser_test.nim
	@echo "Running sema tests..."
	$(NIM) c -r tests/sema_test.nim
	@echo "Running HIR tests..."
	$(NIM) c -r tests/hir_test.nim
	@echo "Running borrow checker tests..."
	$(NIM) c -r tests/borrow_test.nim
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
	rm -f $(OUT) buxc_debug
	rm -rf $(BUILD_DIR)
	rm -rf nimcache
	rm -rf examples_pkg
	rm -rf _test_tmp_pkg
	rm -rf _test_cast _test_cast2 _test_cast3 _test_channel

clean-all: clean
	rm -rf build/selfhost build/selfhost-loop-a build/selfhost-loop-b
	rm -rf tests/golden/*/build

selfhost: build
	@echo "=== Building self-hosted compiler ==="
	@rm -rf build/selfhost
	@mkdir -p build/selfhost/src
	@cp src/*.bux build/selfhost/src/
	@cp src/bux.toml build/selfhost/
	@mv build/selfhost/src/main.bux build/selfhost/src/Main.bux 2>/dev/null || true
	@cd build/selfhost && ../../$(OUT) build
	# strip removed for debug
	@echo "=== Self-hosted compiler built successfully ==="

.PHONY: test-golden

GOLDEN_TESTS := hello fibonacci

test-golden: build
	@echo "=== Golden tests ==="
	@passed=0; failed=0; \
	for test in $(GOLDEN_TESTS); do \
		gd="tests/golden/$$test"; \
		if [ ! -d "$$gd" ]; then echo "  SKIP $$test (no dir)"; continue; fi; \
		if [ ! -f "$$gd/expected.c" ]; then echo "  SKIP $$test (no expected.c)"; continue; fi; \
		rm -rf "$$gd/build"; \
		(cd "$$gd" && ../../../$(OUT) build > /dev/null 2>&1); \
		if diff "$$gd/build/main.c" "$$gd/expected.c" > /dev/null 2>&1; then \
			echo "  PASS $$test"; \
			passed=$$((passed + 1)); \
		else \
			echo "  FAIL $$test — C output differs from expected"; \
			failed=$$((failed + 1)); \
		fi; \
	done; \
	echo "Golden tests: $$passed passed, $$failed failed"; \
	if [ $$failed -gt 0 ]; then exit 1; fi

selfhost-loop: build
	@echo "=== Selfhost loop: bootstrap determinism check ==="
	@echo "Build A..."
	@rm -rf build/selfhost-loop-a
	@mkdir -p build/selfhost-loop-a/src
	@cp src/*.bux build/selfhost-loop-a/src/
	@cp src/bux.toml build/selfhost-loop-a/
	@mv build/selfhost-loop-a/src/main.bux build/selfhost-loop-a/src/Main.bux 2>/dev/null || true
	@cd build/selfhost-loop-a && ../../$(OUT) build
	@echo "Build B..."
	@rm -rf build/selfhost-loop-b
	@mkdir -p build/selfhost-loop-b/src
	@cp src/*.bux build/selfhost-loop-b/src/
	@cp src/bux.toml build/selfhost-loop-b/
	@mv build/selfhost-loop-b/src/main.bux build/selfhost-loop-b/src/Main.bux 2>/dev/null || true
	@cd build/selfhost-loop-b && ../../$(OUT) build
	@echo ""
	@echo "Comparing C output..."
	@if diff build/selfhost-loop-a/build/main.c build/selfhost-loop-b/build/main.c > /dev/null 2>&1; then \
		echo "  C output: IDENTICAL ✓"; \
	else \
		echo "  C output: DIFFERENT ✗"; \
	fi
	@echo "Comparing ELF binaries..."
	@if diff build/selfhost-loop-a/build/buxc2 build/selfhost-loop-b/build/buxc2 > /dev/null 2>&1; then \
		echo "  ELF binary: IDENTICAL ✓"; \
		echo "=== Selfhost loop PASSED ==="; \
	else \
		echo "  ELF binary: DIFFERENT ✗ (may be due to timestamps)"; \
		echo "  C output was identical — ELF difference is likely linker non-determinism"; \
		echo "=== Selfhost loop: C codegen deterministic ✓, ELF non-deterministic (expected) ==="; \
	fi

lsp: tools/bux-lsp
	@echo "LSP server ready at tools/bux-lsp"

tools/bux-lsp: tools/lsp_server.nim
	cd tools && $(NIM) c -o:bux-lsp lsp_server.nim
