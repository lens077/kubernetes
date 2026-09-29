.DEFAULT_GOAL := check
SHELL := /bin/bash
export ANSIBLE_CONFIG := $(CURDIR)/ansible.cfg
ANSIBLE_PLAYBOOK ?= $(CURDIR)/.venv/bin/ansible-playbook
PYTHON ?= python3
# Pinned alongside roles/host_otel/defaults/main.yml; guarded by tests.
OTELCOL_IMAGE := otel/opentelemetry-collector-contrib@sha256:c5918f78992ee73b0d6f0e599423ac5ec52dd5d9726733114d6eca53d5a32ed5
OTELCOL_BIN := build/bin/otelcol-contrib-0.158.0/otelcol-contrib

.PHONY: bootstrap generate check binary deploy
bootstrap:
	$(PYTHON) -m venv .venv
	.venv/bin/python -m pip install -r requirements.txt
generate:
	$(PYTHON) ../../components/vmalert/build-host-recording.py
check:
	$(PYTHON) ../../components/vmalert/build-host-recording.py --check
	$(ANSIBLE_PLAYBOOK) -i inventory.generated.json playbook.yml --syntax-check
binary: $(OTELCOL_BIN)
$(OTELCOL_BIN):
	@set -eu; mkdir -p $(dir $@); \
	 docker pull -q --platform linux/amd64 $(OTELCOL_IMAGE); \
	 cid=$$(docker create --platform linux/amd64 $(OTELCOL_IMAGE)); \
	 trap 'docker rm "$$cid" >/dev/null' EXIT; \
	 docker cp "$$cid:/otelcol-contrib" "$@"
deploy: check binary
	$(ANSIBLE_PLAYBOOK) -i inventory.generated.json playbook.yml $(if $(H),-l $(H))
