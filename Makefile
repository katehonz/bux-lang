NIM := nim
SRC := bootstrap/main.nim
OUT := buxc
BUILD_DIR := build

EXAMPLES := hello fibonacci factorial structs enums methods algebraic_enums generics generics_struct generic_infer generic_infer2 extend_generic pattern_matching strings strings2 map result_option try_operator ownership ownership_checked drop_early_return lifetime_elision ctfe async concurrency os_time process json iter trait_bounds channel sync jwt stdlib_ergonomics tuples func_ptr map_remove array_iter_extra string_extra multi_closure iter_hof closure_control match_let string_interp iter_generic generic_infer_hof struct_tuple_pat match_block nested_patterns match_guards pattern_shadow move_field

.PHONY: all build dev debug test clean clean-all test-examples selfhost test-golden test-errors test-stdlib selfhost-loop lsp fmt-check docs bench test-apps test-dwarf test-selfhost-smoke

all: build

build:
	$(NIM) c -o:$(OUT) -d:release --opt:size $(SRC)
	# strip $(OUT)

dev:
	$(NIM) c -o:buxc_debug -d:debug --stackTrace:on --lineTrace:on $(SRC)

debug: dev
	@echo "Debug binary: buxc_debug"

test: build fmt-check test-examples test-errors test-stdlib test-registry test-dwarf test-apps test-selfhost-smoke
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

GOLDEN_TESTS := hello fibonacci structs generics algebraic_enums enums methods strings modern_features

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

test-errors: build
	@echo "=== Error diagnostic golden tests ==="
	@chmod +x tests/error_golden/run.sh
	@tests/error_golden/run.sh ./$(OUT)

test-stdlib: build
	@echo "=== Stdlib golden tests ==="
	@chmod +x tests/stdlib_golden/run.sh
	@tests/stdlib_golden/run.sh ./$(OUT)

# Generate stdlib API docs from /// comments → docs/api/stdlib.md
docs: build
	@mkdir -p docs/api
	@./$(OUT) doc --out docs/api/stdlib.md lib/
	@echo "docs/api/stdlib.md updated"

# CI: full-tree format check (lib / examples / src / tests / apps) + dirty-path smoke.
fmt-check: build
	@echo "=== fmt --check (full tree) ==="
	@./$(OUT) fmt --check lib/
	@./$(OUT) fmt --check examples/
	@./$(OUT) fmt --check src/
	@./$(OUT) fmt --check tests/
	@./$(OUT) fmt --check apps/
	@echo "=== fmt --check dirty-path smoke ==="
	@mkdir -p /tmp/bux_fmt_smoke
	@printf 'func Main() -> int {\nreturn 0;\n}\n' > /tmp/bux_fmt_smoke/bad.bux
	@if ./$(OUT) fmt --check /tmp/bux_fmt_smoke/bad.bux >/dev/null 2>&1; then \
		echo "error: expected --check to fail on dirty file"; exit 1; \
	fi
	@echo "fmt --check passed (tree clean + dirty exits 1)"

# One-shot reformat of the same trees (run before committing style-only fixes)
.PHONY: fmt
fmt: build
	@./$(OUT) fmt lib/
	@./$(OUT) fmt examples/
	@./$(OUT) fmt src/
	@./$(OUT) fmt tests/
	@./$(OUT) fmt apps/
	@echo "Formatted lib/ examples/ src/ tests/ apps/"

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
	@echo "Comparing ELF binaries (stripped)..."
	@cp build/selfhost-loop-a/build/buxc2 /tmp/buxc2_a && strip -d /tmp/buxc2_a
	@cp build/selfhost-loop-b/build/buxc2 /tmp/buxc2_b && strip -d /tmp/buxc2_b
	@if diff /tmp/buxc2_a /tmp/buxc2_b > /dev/null 2>&1; then \
		echo "  ELF binary: IDENTICAL ✓"; \
		echo "=== Selfhost loop PASSED ==="; \
	else \
		echo "  ELF binary: DIFFERENT ✗"; \
		echo "=== Selfhost loop FAILED ==="; \
		exit 1; \
	fi

lsp: tools/bux-lsp
	@echo "LSP server ready at tools/bux-lsp"

tools/bux-lsp: tools/lsp_server.nim bootstrap/*.nim
	cd tools && $(NIM) c -d:release --opt:size --path:../bootstrap -o:bux-lsp lsp_server.nim

.PHONY: test-lsp
test-lsp: lsp
	@echo "=== LSP unit (locals / inference) ==="
	$(NIM) r --path:bootstrap tools/test_lsp_locals.nim
	@echo "=== LSP hover smoke ==="
	@chmod +x tools/smoke_lsp_hover.sh
	@tools/smoke_lsp_hover.sh
	@echo "=== LSP references / rename smoke ==="
	@chmod +x tools/smoke_lsp_rename.sh
	@tools/smoke_lsp_rename.sh
	@echo "=== LSP workspace/symbol smoke ==="
	@chmod +x tools/smoke_lsp_workspace.sh
	@tools/smoke_lsp_workspace.sh
	@echo "=== LSP deeper rename smoke ==="
	@chmod +x tools/smoke_lsp_rename_deep.sh
	@tools/smoke_lsp_rename_deep.sh
	@echo "=== LSP call hierarchy smoke ==="
	@chmod +x tools/smoke_lsp_call_hierarchy.sh
	@tools/smoke_lsp_call_hierarchy.sh

.PHONY: test-registry
test-registry: build
	@echo "=== Registry smoke (E.1 + HTTP) ==="
	@chmod +x tools/smoke_registry.sh
	@tools/smoke_registry.sh

# E.2 — build showcase apps + simpledb/jwt CLI smoke
.PHONY: test-apps
test-apps: build
	@echo "=== Apps smoke (E.2) ==="
	@chmod +x tools/smoke_apps.sh
	@tools/smoke_apps.sh

# E.5 — micro-benchmarks (Bux + C/Nim/Zig twins)
.PHONY: bench
bench: build
	@chmod +x tools/bench.sh
	@tools/bench.sh

# E.5 — Nexus HTTP throughput (wrk); optional via BENCH_NEXUS=1 make bench
.PHONY: bench-nexus
bench-nexus: build
	@chmod +x tools/bench_nexus.sh
	@tools/bench_nexus.sh

# E.4 — DWARF / #line debugger smoke
.PHONY: test-dwarf
test-dwarf: build
	@echo "=== DWARF / #line smoke (E.4) ==="
	@chmod +x tools/smoke_dwarf.sh
	@tools/smoke_dwarf.sh

# Selfhost (buxc2): move_field ownership + multi-file #line (session 41/42)
.PHONY: test-selfhost-smoke
test-selfhost-smoke: selfhost
	@echo "=== Selfhost smoke (move_field + multi-file #line) ==="
	@chmod +x tools/smoke_selfhost.sh
	@tools/smoke_selfhost.sh
