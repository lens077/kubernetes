.DEFAULT_GOAL := help
SHELL := /bin/bash

# Put modern Bash first so child scripts invoking `bash` use the same version.
BASH_BIN ?= $(if $(wildcard /opt/homebrew/bin/bash),/opt/homebrew/bin/bash,$(shell command -v bash))
export PATH := $(dir $(BASH_BIN)):$(PATH)
export TOOLS_VENV ?= $(CURDIR)/.venv-tools
export PYTHON ?= $(TOOLS_VENV)/bin/python
export K8S_CONFIG_ENV ?= $(CURDIR)/bootstrap/config.hosting.env
export ENV ?= pre
export ADMIN_TOKEN_SECRET ?= config-center/config-center-operator$(if $(filter pre,$(ENV)),,-$(ENV)):token
export SERVICES
STRATEGY ?= $(if $(filter dev,$(ENV)),remote-dev,pre)
COMPONENT ?= reloader
CONFIRM ?= no
DOCKER_DEPLOY_DIR ?= $(abspath ../docker-deploy)
PANGOLIN_SCRIPT = $(DOCKER_DEPLOY_DIR)/pangolin/reconcile-k8s-dev-resources.sh

.PHONY: help confirm bootstrap-tools contracts mapping-test cc-plan cc-apply cc-bootstrap-plan cc-bootstrap-apply cc-forward operator-issue rotate-plan rotate-apply component-install pangolin-check pangolin-apply pangolin-apply-infra pangolin-disable

help: ## 显示帮助（默认不修改系统或集群）
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\n参数: ENV=pre|dev STRATEGY=pre|gateway|remote-dev SERVICES="cart user"\n'
	@printf '      COMPONENT=reloader CONFIRM=yes PYTHON=/path/to/python\n'
	@printf '默认配置: bootstrap/config.hosting.env；目标集群仍由 KUBECONFIG 决定。\n'
	@printf '详见 tools/MAKE-COMMANDS.md；不要将密码或 token 放进 make 参数。\n'

confirm:
	@test "$(CONFIRM)" = yes || { echo '拒绝执行写操作；先预览并确认集群，再加 CONFIRM=yes。' >&2; exit 2; }

bootstrap-tools: ## 创建工具 Python 环境并安装 PyYAML/jsonschema
	@command -v uv >/dev/null || { echo '需要 uv: https://docs.astral.sh/uv/'; exit 2; }
	@uv venv "$(TOOLS_VENV)"
	@uv pip install --python "$(PYTHON)" pyyaml jsonschema
	@echo "工具环境已就绪: PYTHON=$(PYTHON)"

contracts: ## 只读检查组件契约与当前集群
	@"$(BASH_BIN)" tools/verify-contracts.sh

mapping-test: ## 离线检查映射路径与 control-tower Schema
	@"$(BASH_BIN)" tests/mapping_test.sh

cc-plan: ## 预览服务配置差异，不写入
	@"$(BASH_BIN)" tools/config-center-harvest.sh --strategy "$(STRATEGY)" --dry-run --require-schema

cc-apply: confirm ## 写服务配置；非 pre 环境不重启集群中的 pre 服务
	@"$(BASH_BIN)" tools/config-center-harvest.sh --strategy "$(STRATEGY)" --require-schema $(if $(filter pre,$(ENV)),,--no-restart)

cc-bootstrap-plan: ## 预览 config-center 自举 Secret（固定集群内 pre 策略）
	@ENV=pre "$(BASH_BIN)" tools/config-center-harvest.sh --consumer config-center --strategy pre --dry-run

cc-bootstrap-apply: confirm ## 写 config-center 自举 Secret并滚动该服务
	@ENV=pre "$(BASH_BIN)" tools/config-center-harvest.sh --consumer config-center --strategy pre

cc-forward: ## 前台转发 Config Center 到 127.0.0.1:30010，Ctrl-C 停止
	@kubectl -n config-center port-forward --address 127.0.0.1 svc/config-center 30010:30010

operator-issue: confirm ## 为 ENV 签 operator 并写 Secret，需要管理员凭据
	@ENVIRONMENT="$(ENV)" "$(BASH_BIN)" tools/config-center-operator-token.sh

rotate-plan: ## 预览 Dragonfly 轮换（仅 pre；不会生成可写入的新配置）
	@test "$(ENV)" = pre || { echo '轮换入口仅支持 ENV=pre' >&2; exit 2; }
	@"$(BASH_BIN)" tools/rotate-credential.sh dragonfly --dry-run

rotate-apply: confirm ## 执行 Dragonfly 轮换，会中断连接；需另行同步 dev 配置
	@test "$(ENV)" = pre || { echo '轮换入口仅支持 ENV=pre' >&2; exit 2; }
	@"$(BASH_BIN)" tools/rotate-credential.sh dragonfly

component-install: confirm ## 安装指定组件（COMPONENT=reloader），不执行整个裸机安装器
	@case "$(COMPONENT)" in ''|*[!a-z0-9-]*) echo '非法 COMPONENT' >&2; exit 2;; esac; \
	 test -f "components/$(COMPONENT)/install.sh"; \
	 "$(BASH_BIN)" "components/$(COMPONENT)/install.sh"

pangolin-check: ## 检查 VPS/云防火墙；当前脚本仍需要 Pangolin 登录文件
	@"$(BASH_BIN)" "$(PANGOLIN_SCRIPT)" --check-infra

pangolin-apply: confirm ## 创建/补齐并启用 remote-dev Pangolin 资源
	@"$(BASH_BIN)" "$(PANGOLIN_SCRIPT)"

pangolin-disable: confirm ## 禁用 remote-dev 两条资源（不关闭 VPS/云防火墙端口）
	@"$(BASH_BIN)" "$(PANGOLIN_SCRIPT)" --disable-remote-dev
