# TokenMaxx Makefile
# Ruby-only task runner with colorized output

# ============== Colors & Symbols ==============
GREEN := \033[92m
EMERALD := \033[38;2;16;185;129m
CYAN := \033[96m
YELLOW := \033[93m
MAGENTA := \033[95m
RED := \033[91m
GRAY := \033[90m
BOLD := \033[1m
RESET := \033[0m

CHECK := ✓
CROSS := ✗
ARROW := ▸
PROGRESS := →

# ============== Project Metadata ==============
VERSION := $(shell sed -n 's/^MARKETING_VERSION=//p' version.env)
BUILD_NUMBER := $(shell sed -n 's/^BUILD_NUMBER=//p' version.env)

PREFIX ?= $(HOME)/.local
APP_NAME := tokenmaxx
APP_DIR := $(PREFIX)/share/$(APP_NAME)
BIN_DIR := $(PREFIX)/bin
CONFIG ?= $(HOME)/.config/tokenmaxx/config.json
SOLVERFORGE_PATH ?= $(HOME)/.local/share/solverforge

RUBY_SOURCES := bin/tokenmaxx bin/release-notes $(shell rg --files lib test -g '*.rb')

INSTALL_FILES := \
	AGENTS.md \
	CHANGELOG.md \
	LICENSE \
	README.md \
	WIREFRAME.md \
	bin/tokenmaxx \
	tokenmaxx-mascot.png \
	tokenmaxx.png \
	version.env \
	docs/DEVELOPMENT.md \
	docs/RELEASING.md \
	docs/architecture.md \
	docs/cli.md \
	docs/configuration.md \
	docs/tokenmaxx.png \
	docs/icon.png \
	docs/index.html \
	docs/installation.md \
	docs/providers.md \
	docs/runtime-contracts.md \
	docs/site.css \
	docs/status.md \
	docs/ui.md \
	frontend/quickshell/shell.qml \
	lib/tokenmaxx.rb \
	lib/tokenmaxx/cli.rb \
	lib/tokenmaxx/core/config.rb \
	lib/tokenmaxx/core/format.rb \
	lib/tokenmaxx/core/http.rb \
	lib/tokenmaxx/core/metric.rb \
	lib/tokenmaxx/core/peak.rb \
	lib/tokenmaxx/core/process.rb \
	lib/tokenmaxx/core/types.rb \
	lib/tokenmaxx/providers/claude.rb \
	lib/tokenmaxx/providers/codex.rb \
	lib/tokenmaxx/providers/gemini.rb \
	lib/tokenmaxx/providers/index.rb \
	lib/tokenmaxx/providers/ollama.rb \
	lib/tokenmaxx/providers/opencode.rb \
	lib/tokenmaxx/providers/zai.rb \
	lib/tokenmaxx/runtime/daemon.rb \
	lib/tokenmaxx/runtime/hermes_usage.rb \
	lib/tokenmaxx/runtime/history.rb \
	lib/tokenmaxx/runtime/local_usage.rb \
	lib/tokenmaxx/runtime/notifications.rb \
	lib/tokenmaxx/runtime/omarchy.rb \
	lib/tokenmaxx/runtime/presenter.rb \
	lib/tokenmaxx/runtime/quickshell.rb \
	lib/tokenmaxx/runtime/server.rb \
	lib/tokenmaxx/runtime/state.rb \
	lib/tokenmaxx/runtime/status.rb \
	lib/tokenmaxx/runtime/status/claude.rb \
	lib/tokenmaxx/runtime/status/openai.rb \
	lib/tokenmaxx/runtime/status/opencode.rb \
	lib/tokenmaxx/runtime/storage.rb \
	lib/tokenmaxx/runtime/swaybar.rb \
	lib/tokenmaxx/runtime/usage.rb \
	lib/tokenmaxx/runtime/waybar.rb

# ============== Phony Targets ==============
.PHONY: banner help install uninstall configure-user install-solverforge-linux-integration \
        check check-live lint syntax test smoke waybar-render panel daemon quickshell-load \
        version bump-patch bump-minor bump-major bump-dry

# ============== Default Target ==============
.DEFAULT_GOAL := help

# ============== Banner ==============
banner:
	@printf "$(EMERALD)$(BOLD)"
	@printf " _____     _              __  __                  \n"
	@printf "|_   _|__ | | _____ _ __ |  \134/  | __ ___  ____  __\n"
	@printf "  | |/ _ \134| |/ / _ \134 '_ \134| |\134/| |/ _\140 \134 \134/ /\134 \134/ /\n"
	@printf "  | | (_) |   <  __/ | | | |  | | (_| |>  <  >  < \n"
	@printf "  |_|\134___/|_|\134_\134___|_| |_|_|  |_|\134__,_/_/\134_\134/_/\134_\134\n"
	@printf "$(RESET)"
	@printf "  $(GRAY)v$(VERSION)$(RESET) $(EMERALD)TokenMaxx Build System$(RESET)\n\n"

# ============== Install Targets ==============

install: banner
	@printf "$(CYAN)$(BOLD)╔══════════════════════════════════════╗$(RESET)\n"
	@printf "$(CYAN)$(BOLD)║         Installing TokenMaxx          ║$(RESET)\n"
	@printf "$(CYAN)$(BOLD)╚══════════════════════════════════════╝$(RESET)\n\n"
	@printf "$(ARROW) $(BOLD)Staging release files...$(RESET)\n"
	@rm -rf "$(APP_DIR).tmp"
	@mkdir -p "$(APP_DIR).tmp" "$(BIN_DIR)"
	@for path in $(INSTALL_FILES); do \
		mkdir -p "$(APP_DIR).tmp/$$(dirname "$$path")"; \
		cp -p "$$path" "$(APP_DIR).tmp/$$path"; \
	done
	@chmod 0755 "$(APP_DIR).tmp/bin/tokenmaxx"
	@printf "$(ARROW) $(BOLD)Activating install...$(RESET)\n"
	@rm -rf "$(APP_DIR).previous"
	@if [[ -e "$(APP_DIR)" || -L "$(APP_DIR)" ]]; then mv "$(APP_DIR)" "$(APP_DIR).previous"; fi
	@mv "$(APP_DIR).tmp" "$(APP_DIR)"
	@ln -sfn "$(APP_DIR)/bin/tokenmaxx" "$(BIN_DIR)/tokenmaxx"
	@rm -rf "$(APP_DIR).previous"
	@printf "$(GREEN)$(CHECK) Installed tokenmaxx v$(VERSION) to $(APP_DIR)$(RESET)\n"
	@printf "$(GREEN)$(CHECK) Linked $(BIN_DIR)/tokenmaxx$(RESET)\n\n"

uninstall:
	@printf "$(ARROW) Removing TokenMaxx install...\n"
	@if [[ -L "$(BIN_DIR)/tokenmaxx" && "$$(readlink -f "$(BIN_DIR)/tokenmaxx")" == "$(APP_DIR)/bin/tokenmaxx" ]]; then \
		rm -f "$(BIN_DIR)/tokenmaxx"; \
	fi
	@rm -rf "$(APP_DIR)"
	@printf "$(GREEN)$(CHECK) TokenMaxx uninstalled$(RESET)\n"

configure-user:
	@printf "$(ARROW) Pointing user config at the installed QuickShell shell...\n"
	@if [[ ! -x "$(BIN_DIR)/tokenmaxx" ]]; then \
		printf "$(RED)$(CROSS) Run make install before make configure-user.$(RESET)\n" >&2; \
		exit 1; \
	fi
	@if [[ ! -f "$(CONFIG)" ]]; then "$(BIN_DIR)/tokenmaxx" config init --config "$(CONFIG)" >/dev/null; fi
	@ruby -rjson -rfileutils -e 'path, shell = ARGV; path = File.expand_path(path); data = JSON.parse(File.read(path)); data["runtime"] ||= {}; data["runtime"]["quickShellShell"] = File.expand_path(shell); FileUtils.mkdir_p(File.dirname(path)); tmp = path + ".tmp." + Process.pid.to_s; File.write(tmp, JSON.pretty_generate(data) + "\n"); File.chmod(0o600, tmp); File.rename(tmp, path); File.chmod(0o600, path)' "$(CONFIG)" "$(APP_DIR)/frontend/quickshell/shell.qml"
	@printf "$(GREEN)$(CHECK) User config updated: $(CONFIG)$(RESET)\n"

install-solverforge-linux-integration:
	@printf "$(ARROW) Installing SolverForge Waybar wrapper...\n"
	@mkdir -p "$(SOLVERFORGE_PATH)/bin"
	@install -m 0755 packaging/solverforge-linux/solverforge-waybar-tokenmaxx "$(SOLVERFORGE_PATH)/bin/solverforge-waybar-tokenmaxx"
	@if [[ -f "$(SOLVERFORGE_PATH)/default/waybar/config" ]]; then \
		rg -q '"custom/tokenmaxx"' "$(SOLVERFORGE_PATH)/default/waybar/config"; \
	fi
	@printf "$(GREEN)$(CHECK) Wrapper installed to $(SOLVERFORGE_PATH)/bin/solverforge-waybar-tokenmaxx$(RESET)\n"

# ============== Validation Targets ==============

check: banner
	@printf "$(CYAN)$(BOLD)╔══════════════════════════════════════╗$(RESET)\n"
	@printf "$(CYAN)$(BOLD)║            Release Check             ║$(RESET)\n"
	@printf "$(CYAN)$(BOLD)╚══════════════════════════════════════╝$(RESET)\n\n"
	@printf "$(ARROW) $(BOLD)Running bin/release-check...$(RESET)\n"
	@bin/release-check && \
		printf "\n$(GREEN)$(BOLD)$(CHECK) Release check passed$(RESET)\n\n" || \
		(printf "\n$(RED)$(CROSS) Release check failed$(RESET)\n\n" && exit 1)

check-live: banner
	@printf "$(CYAN)$(BOLD)╔══════════════════════════════════════╗$(RESET)\n"
	@printf "$(CYAN)$(BOLD)║         Live Release Check           ║$(RESET)\n"
	@printf "$(CYAN)$(BOLD)╚══════════════════════════════════════╝$(RESET)\n\n"
	@printf "$(ARROW) $(BOLD)Running bin/release-check --with-live...$(RESET)\n"
	@bin/release-check --with-live && \
		printf "\n$(GREEN)$(BOLD)$(CHECK) Live release check passed$(RESET)\n\n" || \
		(printf "\n$(RED)$(CROSS) Live release check failed$(RESET)\n\n" && exit 1)

lint:
	@printf "$(PROGRESS) Running pre-commit hooks...\n"
	@python3 -m pre_commit run --all-files && \
		printf "$(GREEN)$(CHECK) Lint passed$(RESET)\n" || \
		(printf "$(RED)$(CROSS) Lint failed$(RESET)\n" && exit 1)

syntax:
	@printf "$(PROGRESS) Checking Bash syntax...\n"
	@bash -n bin/release-check && \
		printf "$(GREEN)$(CHECK) Bash syntax valid$(RESET)\n" || \
		(printf "$(RED)$(CROSS) Bash syntax errors found$(RESET)\n" && exit 1)
	@printf "$(PROGRESS) Checking Ruby syntax per file...\n"
	@for path in $(RUBY_SOURCES); do ruby -wc "$$path" || exit $$?; done && \
		printf "$(GREEN)$(CHECK) Ruby syntax valid ($(words $(RUBY_SOURCES)) files)$(RESET)\n" || \
		(printf "$(RED)$(CROSS) Ruby syntax errors found$(RESET)\n" && exit 1)

test: banner
	@printf "$(CYAN)$(BOLD)╔══════════════════════════════════════╗$(RESET)\n"
	@printf "$(CYAN)$(BOLD)║          Ruby Test Suite             ║$(RESET)\n"
	@printf "$(CYAN)$(BOLD)╚══════════════════════════════════════╝$(RESET)\n\n"
	@printf "$(ARROW) $(BOLD)Running all tests...$(RESET)\n"
	@ruby -Itest test/run.rb && \
		printf "\n$(GREEN)$(CHECK) All tests passed$(RESET)\n\n" || \
		(printf "\n$(RED)$(CROSS) Tests failed$(RESET)\n\n" && exit 1)

smoke: banner
	@printf "$(CYAN)$(BOLD)╔══════════════════════════════════════╗$(RESET)\n"
	@printf "$(CYAN)$(BOLD)║           CLI Smoke Checks           ║$(RESET)\n"
	@printf "$(CYAN)$(BOLD)╚══════════════════════════════════════╝$(RESET)\n\n"
	@printf "$(ARROW) $(BOLD)Exercising CLI commands in a sandboxed HOME...$(RESET)\n"
	@tmp_root="$$(mktemp -d -t tokenmaxx-smoke-XXXXXX)"; \
	trap 'rm -rf "$$tmp_root"' EXIT; \
	tmp_config="$$tmp_root/config.json"; \
	HOME="$$tmp_root" bin/tokenmaxx config init --config "$$tmp_config" >/dev/null; \
	HOME="$$tmp_root" bin/tokenmaxx config validate --config "$$tmp_config"; \
	HOME="$$tmp_root" bin/tokenmaxx config dump --config "$$tmp_config" --format json >/dev/null; \
	HOME="$$tmp_root" bin/tokenmaxx waybar render --config "$$tmp_config" >/dev/null; \
	HOME="$$tmp_root" bin/tokenmaxx ui status --config "$$tmp_config" --format json --pretty >/dev/null; \
	HOME="$$tmp_root" bin/tokenmaxx history --config "$$tmp_config" --format json >/dev/null; \
	HOME="$$tmp_root" bin/tokenmaxx cost --cached --config "$$tmp_config" --format json >/dev/null; \
	HOME="$$tmp_root" bin/tokenmaxx status --cached --config "$$tmp_config" --format json >/dev/null; \
	HOME="$$tmp_root" bin/tokenmaxx cache clear all --config "$$tmp_config" --format json >/dev/null; \
	printf "$(GREEN)$(CHECK) CLI smoke passed$(RESET)\n\n"

# ============== Runtime Targets ==============

daemon:
	@printf "$(ARROW) Starting the TokenMaxx daemon (Ctrl+C to stop)...\n"
	@bin/tokenmaxx daemon

panel:
	@printf "$(ARROW) Opening the QuickShell panel...\n"
	@bin/tokenmaxx panel

waybar-render:
	@printf "$(PROGRESS) Rendering Waybar JSON from cached state...\n"
	@bin/tokenmaxx waybar render

quickshell-load:
	@printf "$(ARROW) Loading the source-tree QuickShell panel...\n"
	@env QT_QPA_PLATFORM=wayland TOKENMAXX_BIN="$(PWD)/bin/tokenmaxx" TOKENMAXX_CONFIG="$(CONFIG)" TOKENMAXX_STATE_DIR="$(HOME)/.local/state/tokenmaxx" quickshell --path "$(PWD)/frontend/quickshell/shell.qml"

# ============== Version Management ==============

version:
	@printf "$(CYAN)Current version:$(RESET) $(YELLOW)$(BOLD)v$(VERSION)$(RESET) $(GRAY)(build $(BUILD_NUMBER))$(RESET)\n"

bump-patch: banner
	@printf "$(ARROW) Bumping patch version...\n"
	@csemver --release-as patch && \
		printf "$(GREEN)$(CHECK) Version bumped$(RESET)\n" || \
		(printf "$(RED)$(CROSS) Version bump failed$(RESET)\n" && exit 1)

bump-minor: banner
	@printf "$(ARROW) Bumping minor version...\n"
	@csemver --release-as minor && \
		printf "$(GREEN)$(CHECK) Version bumped$(RESET)\n" || \
		(printf "$(RED)$(CROSS) Version bump failed$(RESET)\n" && exit 1)

bump-major: banner
	@printf "$(ARROW) Bumping major version...\n"
	@csemver --release-as major && \
		printf "$(GREEN)$(CHECK) Version bumped$(RESET)\n" || \
		(printf "$(RED)$(CROSS) Version bump failed$(RESET)\n" && exit 1)

bump-dry:
	@csemver --dry-run

# ============== Help ==============

help: banner
	@/bin/echo -e "$(CYAN)$(BOLD)Install & Setup:$(RESET)"
	@/bin/echo -e "  $(GREEN)make install$(RESET)                               - Install TokenMaxx into ~/.local"
	@/bin/echo -e "  $(GREEN)make configure-user$(RESET)                        - Point user config at the installed shell"
	@/bin/echo -e "  $(GREEN)make install-solverforge-linux-integration$(RESET) - Install the SolverForge Waybar wrapper"
	@/bin/echo -e "  $(GREEN)make uninstall$(RESET)                             - Remove the installed app and link"
	@/bin/echo -e ""
	@/bin/echo -e "$(CYAN)$(BOLD)Validation & Tests:$(RESET)"
	@/bin/echo -e "  $(GREEN)make syntax$(RESET)      - Bash plus per-file Ruby syntax checks"
	@/bin/echo -e "  $(GREEN)make test$(RESET)        - Run the Ruby test suite"
	@/bin/echo -e "  $(GREEN)make smoke$(RESET)       - CLI smoke checks in a sandboxed HOME"
	@/bin/echo -e "  $(GREEN)make lint$(RESET)        - Run pre-commit hooks"
	@/bin/echo -e "  $(GREEN)make check$(RESET)       - $(YELLOW)$(BOLD)Full release gate via bin/release-check$(RESET)"
	@/bin/echo -e "  $(GREEN)make check-live$(RESET)  - $(RED)$(BOLD)Release gate plus live provider checks$(RESET)"
	@/bin/echo -e ""
	@/bin/echo -e "$(CYAN)$(BOLD)Runtime & UI:$(RESET)"
	@/bin/echo -e "  $(GREEN)make daemon$(RESET)          - Run the fetch daemon"
	@/bin/echo -e "  $(GREEN)make panel$(RESET)           - Open the QuickShell panel"
	@/bin/echo -e "  $(GREEN)make waybar-render$(RESET)   - Render Waybar JSON from cached state"
	@/bin/echo -e "  $(GREEN)make quickshell-load$(RESET) - Load the source-tree panel"
	@/bin/echo -e ""
	@/bin/echo -e "$(CYAN)$(BOLD)Version Management:$(RESET)"
	@/bin/echo -e "  $(GREEN)make version$(RESET)      - Show the current version"
	@/bin/echo -e "  $(GREEN)make bump-patch$(RESET)   - Bump patch version (1.2.$(YELLOW)x$(RESET))"
	@/bin/echo -e "  $(GREEN)make bump-minor$(RESET)   - Bump minor version (1.$(YELLOW)x$(RESET).0)"
	@/bin/echo -e "  $(GREEN)make bump-major$(RESET)   - Bump major version ($(YELLOW)x$(RESET).0.0)"
	@/bin/echo -e "  $(GREEN)make bump-dry$(RESET)     - Preview the next release"
	@/bin/echo -e ""
	@/bin/echo -e "$(GRAY)Runtime stack: Ruby + QuickShell + Waybar$(RESET)"
	@/bin/echo -e "$(GRAY)Current version: v$(VERSION) (build $(BUILD_NUMBER))$(RESET)"
	@/bin/echo -e ""
