# coinbase-cli-deepseek-agent-instabox — 常用任务
# 全部目标都可重复执行，不依赖任何外部服务。

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

SCRIPTS := $(wildcard scripts/*.sh) install.sh
.PHONY: help check shellcheck syntax test lint doctor clean

help: ## 显示可用目标
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

syntax: ## 只做语法检查（bash -n / node --check）
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	@node --check telegram/bot.mjs
	@echo "syntax OK"

shellcheck: ## 静态检查（需要 shellcheck）
	@command -v shellcheck >/dev/null || { echo "未安装 shellcheck"; exit 1; }
	@shellcheck $(SCRIPTS)

test: ## 跑全部测试
	@bash tests/run.sh

check: syntax test ## 语法 + 测试（CI 跑这个）

doctor: ## 在本机诊断 Coinbase 环境
	@bash scripts/cb-doctor.sh

clean: ## 清理测试产物
	@rm -rf .test-tmp
