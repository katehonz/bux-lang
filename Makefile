NIM := nim
SRC := bootstrap/main.nim
OUT := buxc
BUILD_DIR := build
# Project-local nimcache so CI can cache compiles (default is ~/.cache/nim).
NIMFLAGS ?= --nimcache:nimcache

EXAMPLES := hello fibonacci factorial structs enums methods algebraic_enums generics generics_struct generic_infer generic_infer2 extend_generic pattern_matching strings strings2 map result_option try_operator ownership ownership_checked ownership_release drop_early_return lifetime_elision ctfe ctfe_crc async concurrency os_time process json iter trait_bounds channel sync jwt stdlib_ergonomics tuples func_ptr map_remove array_iter_extra string_extra multi_closure iter_hof closure_control match_let string_interp iter_generic generic_infer_hof struct_tuple_pat match_block nested_patterns match_guards pattern_shadow move_field move_field_partial move_field_remaining move_field_nested move_field_ptr move_cross_fn c_precedence macro_twice macro_repeat macro_nested macro_hygiene macro_unhygienic macro_stmt_pat macro_tt macro_tt_raw macro_type collections_extra generic_enum switch

# Platform smoke (macOS CI): full EXAMPLES still runs on Linux.
EXAMPLES_SMOKE := hello ownership ownership_release strings map move_field move_field_partial move_field_remaining move_field_nested move_field_ptr move_cross_fn c_precedence macro_twice macro_repeat macro_nested macro_hygiene macro_unhygienic macro_stmt_pat macro_tt macro_tt_raw ctfe_crc

.PHONY: all build dev debug test clean clean-all test-examples test-examples-smoke selfhost test-golden test-errors test-stdlib selfhost-loop lsp fmt-check docs bench test-apps test-dwarf test-selfhost-smoke test-unit test-linux-targets ensure-buxc

all: build

# Rebuild only when bootstrap sources change (CI can set BUX_SKIP_BUILD=1
# after downloading a prebuilt buxc artifact).
$(OUT): $(wildcard bootstrap/*.nim)
	$(NIM) c $(NIMFLAGS) -o:$(OUT) -d:release --opt:size $(SRC)
	# strip $(OUT)

build: $(OUT)

# CI parallel jobs download buxc and set BUX_SKIP_BUILD=1 to avoid rebuild.
ensure-buxc:
ifeq ($(BUX_SKIP_BUILD),1)
	@test -x ./$(OUT) || (echo "error: ./$(OUT) missing (BUX_SKIP_BUILD=1)"; exit 1)
else
	@$(MAKE) $(OUT)
endif

dev:
	$(NIM) c $(NIMFLAGS) -o:buxc_debug -d:debug --stackTrace:on --lineTrace:on $(SRC)

debug: dev
	@echo "Debug binary: buxc_debug"

# Full local / sequential suite (same coverage as split CI jobs combined).
test: build fmt-check test-examples test-errors test-stdlib test-registry test-dwarf test-drop-move test-linux-targets test-apps test-selfhost-smoke test-unit

# Nim unit tests + tiny CLI smoke (needs Nim + buxc).
test-unit: ensure-buxc
	@echo "Running lexer tests..."
	$(NIM) c $(NIMFLAGS) -r tests/lexer_test.nim
	@echo "Running parser tests..."
	$(NIM) c $(NIMFLAGS) -r tests/parser_test.nim
	@echo "Running sema tests..."
	$(NIM) c $(NIMFLAGS) -r tests/sema_test.nim
	@echo "Running HIR tests..."
	$(NIM) c $(NIMFLAGS) -r tests/hir_test.nim
	@echo "Running borrow checker tests..."
	$(NIM) c $(NIMFLAGS) -r tests/borrow_test.nim
	@echo "Running integration tests..."
	rm -rf _test_tmp_pkg
	./$(OUT) new _test_tmp_pkg
	./$(OUT) --version

# Shared loop body for full + smoke example runners.
define run-examples
	@for ex in $(1); do \
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
		if command -v timeout >/dev/null 2>&1; then \
			(cd examples_pkg/$$ex && timeout 30 ../../$(OUT) run) || exit 1; \
		else \
			(cd examples_pkg/$$ex && ../../$(OUT) run) || exit 1; \
		fi; \
	done
endef

test-examples: ensure-buxc
	$(call run-examples,$(EXAMPLES))
	@echo "All examples passed!"

# Subset for macOS / quick platform smoke (Linux CI runs full EXAMPLES).
test-examples-smoke: ensure-buxc
	$(call run-examples,$(EXAMPLES_SMOKE))
	@echo "Smoke examples passed!"

clean:
	rm -f $(OUT) buxc_debug
	rm -rf $(BUILD_DIR)
	rm -rf nimcache
	rm -rf examples_pkg
	rm -rf _test_tmp_pkg
	rm -rf _test_cast _test_cast2 _test_cast3 _test_channel

clean-all: clean
	rm -rf build/selfhost build/selfhost-loop-a build/selfhost-loop-b build/selfhost-loop-c
	rm -rf tests/golden/*/build

selfhost: ensure-buxc
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

test-golden: ensure-buxc
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

test-errors: ensure-buxc
	@echo "=== Error diagnostic golden tests ==="
	@chmod +x tests/error_golden/run.sh
	@tests/error_golden/run.sh ./$(OUT)

test-stdlib: ensure-buxc
	@echo "=== Stdlib golden tests ==="
	@chmod +x tests/stdlib_golden/run.sh
	@tests/stdlib_golden/run.sh ./$(OUT)

# Generate stdlib API docs from /// comments → docs/api/stdlib.md
docs: ensure-buxc
	@mkdir -p docs/api
	@./$(OUT) doc --out docs/api/stdlib.md lib/
	@echo "docs/api/stdlib.md updated"

# CI: full-tree format check (lib / examples / src / tests / apps) + dirty-path smoke.
fmt-check: ensure-buxc
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
fmt: ensure-buxc
	@./$(OUT) fmt lib/
	@./$(OUT) fmt examples/
	@./$(OUT) fmt src/
	@./$(OUT) fmt tests/
	@./$(OUT) fmt apps/
	@echo "Formatted lib/ examples/ src/ tests/ apps/"

# Fixed-point: bootstrap buxc → buxc2 → buxc3 (path-normalized C + stripped ELF).
# Slow; not part of default `make test`. Optional CI: .github/workflows/selfhost-loop.yml
selfhost-loop: ensure-buxc
	@chmod +x tools/selfhost_loop.sh
	@tools/selfhost_loop.sh

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
	@echo "=== LSP method call hierarchy smoke ==="
	@chmod +x tools/smoke_lsp_method_hierarchy.sh
	@tools/smoke_lsp_method_hierarchy.sh
	@echo "=== LSP method/type/receiver rename smoke ==="
	@chmod +x tools/smoke_lsp_rename_method.sh
	@tools/smoke_lsp_rename_method.sh
	@echo "=== LSP interface dispatch hierarchy smoke ==="
	@chmod +x tools/smoke_lsp_iface_hierarchy.sh
	@tools/smoke_lsp_iface_hierarchy.sh
	@echo "==> LSP path rename smoke"
	@chmod +x tools/smoke_lsp_rename_path.sh
	@tools/smoke_lsp_rename_path.sh
	@echo "==> LSP implementation smoke"
	@chmod +x tools/smoke_lsp_implementation.sh
	@tools/smoke_lsp_implementation.sh
	@echo "==> LSP workspace import index smoke"
	@chmod +x tools/smoke_lsp_workspace_imports.sh
	@tools/smoke_lsp_workspace_imports.sh
	@echo "==> LSP type hierarchy smoke"
	@chmod +x tools/smoke_lsp_type_hierarchy.sh
	@tools/smoke_lsp_type_hierarchy.sh
	@echo "==> LSP type hierarchy workspace (closed multi-file)"
	@chmod +x tools/smoke_lsp_type_hierarchy_ws.sh
	@tools/smoke_lsp_type_hierarchy_ws.sh

.PHONY: test-registry
test-registry: ensure-buxc
	@echo "=== Registry smoke (E.1 + HTTP) ==="
	@chmod +x tools/smoke_registry.sh
	@tools/smoke_registry.sh

# E.2 — build showcase apps + simpledb/jwt CLI smoke
.PHONY: test-apps
test-apps: ensure-buxc
	@echo "=== Apps smoke (E.2) ==="
	@chmod +x tools/smoke_apps.sh
	@tools/smoke_apps.sh

# E.5 — micro-benchmarks (Bux + C/Nim/Zig twins)
.PHONY: bench
bench: ensure-buxc
	@chmod +x tools/bench.sh
	@tools/bench.sh

# E.5 — Nexus HTTP throughput (wrk); optional via BENCH_NEXUS=1 make bench
.PHONY: bench-nexus
bench-nexus: ensure-buxc
	@chmod +x tools/bench_nexus.sh
	@tools/bench_nexus.sh

# E.4 — DWARF / #line debugger smoke
.PHONY: test-dwarf
test-dwarf: ensure-buxc
	@echo "=== DWARF / #line smoke (E.4) ==="
	@chmod +x tools/smoke_dwarf.sh
	@tools/smoke_dwarf.sh

# Session 75/85 — Linux / cloud / embedded: minimal, static, aarch64+riscv64 cross, CTFE CRC
.PHONY: test-linux-targets
test-linux-targets: ensure-buxc
	@echo "=== Linux targets smoke (minimal / static / aarch64+riscv64 cross) ==="
	@chmod +x tools/smoke_linux_targets.sh
	@tools/smoke_linux_targets.sh

# Session 78 — Nexus HTTPS (self-signed) smoke
.PHONY: test-nexus-tls
test-nexus-tls: ensure-buxc
	@echo "=== Nexus TLS smoke ==="
	@chmod +x tools/smoke_nexus_tls.sh
	@tools/smoke_nexus_tls.sh

# Session 79 — musl static (SKIP if no musl-gcc/zig)
.PHONY: test-musl-static
test-musl-static: ensure-buxc
	@echo "=== musl static smoke ==="
	@chmod +x tools/smoke_musl_static.sh
	@tools/smoke_musl_static.sh

# Session 80 — selfhost install --locked + Nexus mTLS
.PHONY: test-selfhost-install test-nexus-mtls test-selfhost-registry
test-selfhost-install: ensure-buxc selfhost
	@echo "=== Selfhost install --locked ==="
	@chmod +x tools/smoke_selfhost_install.sh
	@tools/smoke_selfhost_install.sh

test-nexus-mtls: ensure-buxc
	@echo "=== Nexus mTLS smoke ==="
	@chmod +x tools/smoke_nexus_mtls.sh
	@tools/smoke_nexus_mtls.sh

# Session 81 — selfhost full registry (search / add / HTTP)
test-selfhost-registry: ensure-buxc selfhost
	@echo "=== Selfhost registry ==="
	@chmod +x tools/smoke_selfhost_registry.sh
	@tools/smoke_selfhost_registry.sh

# Drop / field-move goldens (whole + partial field move; early-return counts)
.PHONY: test-drop-move
test-drop-move: ensure-buxc
	@echo "=== Drop / field-move smoke ==="
	@chmod +x tools/smoke_drop_move.sh
	@tools/smoke_drop_move.sh

# Selfhost (buxc2): move_field ownership + multi-file #line (session 41/42)
# When BUX_SKIP_BUILD=1, reuse prebuilt buxc; still builds buxc2 via selfhost.
.PHONY: test-selfhost-smoke
test-selfhost-smoke: ensure-buxc selfhost
	@echo "=== Selfhost smoke (move_field + multi-file #line) ==="
	@chmod +x tools/smoke_selfhost.sh
	@tools/smoke_selfhost.sh
	@echo "=== Graft / quote hygiene smoke ==="
	@chmod +x tools/smoke_graft_hygiene.sh
	@tools/smoke_graft_hygiene.sh
