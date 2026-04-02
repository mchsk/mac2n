.PHONY: test test-unit test-e2e lint clean help

SHELL := /bin/bash

LIB_FILES  := $(wildcard lib/*.sh)
CMD_FILES  := $(wildcard cmd/*.sh)
MAIN_FILES := wizard.sh build.sh install.sh
ALL_BASH   := $(LIB_FILES) $(CMD_FILES) $(MAIN_FILES)

help:
	@echo "mac2n development targets:"
	@echo "  make test       — run unit tests"
	@echo "  make test-e2e   — run E2E tests (requires sudo)"
	@echo "  make lint       — shellcheck all scripts"
	@echo "  make clean      — remove build artifacts"

test: test-unit

test-unit:
	@bash tests/run_unit.sh

test-e2e:
	@sudo bash tests/e2e.sh

lint:
	@shellcheck -s bash -S warning -e SC2034 $(ALL_BASH) 2>/dev/null || \
		echo "shellcheck not installed — brew install shellcheck"

clean:
	@cd n2n-src 2>/dev/null && $(MAKE) clean 2>/dev/null || true
	@rm -rf n2n-src/build
