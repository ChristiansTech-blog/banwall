# Makefile - nur für die Entwicklung. Auf dem Zielserver reicht
# ./install.sh, damit dort kein make nötig ist.

SHELL := /bin/bash
SCRIPTS := bin/banwall install.sh $(wildcard lib/banwall/*.sh) $(wildcard libexec/*)

.PHONY: help lint syntax test test-unit test-integration install uninstall

help:
	@echo "make lint              shellcheck über alle Skripte"
	@echo "make syntax            bash -n über alle Skripte"
	@echo "make test              Unit-Tests (bats, ohne root)"
	@echo "make test-integration  Container-Tests (braucht podman/docker)"
	@echo "make install           lokal installieren (root)"

lint:
	shellcheck --severity=style --external-sources $(SCRIPTS)

syntax:
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	@echo "Syntax in Ordnung."

test: test-unit

test-unit:
	bats tests/unit

test-integration:
	bash tests/integration/run.sh

install:
	./install.sh install

uninstall:
	./install.sh uninstall
