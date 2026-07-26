SHELL := /bin/bash

IOS_DIR := apps/ios
MACOS_DIR := apps/macos

.PHONY: help

help:
	@printf "随心记 monorepo\\n"
	@printf "\\n"
	@printf "  make ios-<target>   转发到 $(IOS_DIR)/Makefile，例如 make ios-install\\n"
	@printf "  make mac-<target>   转发到 $(MACOS_DIR)/Makefile，例如 make mac-release\\n"
	@printf "  make ios-help       列出 iOS 端全部 target\\n"
	@printf "  make mac-help       列出 macOS 端全部 target\\n"

ios-%:
	@$(MAKE) -C $(IOS_DIR) $*

mac-%:
	@$(MAKE) -C $(MACOS_DIR) $*
