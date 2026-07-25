# Synesthia — one entry point for every build, asset, and release command.
#
# `make` (or `make help`) lists the targets. Each target is a thin wrapper
# around xcodebuild or a script in scripts/; the scripts remain runnable
# directly, and their own `--help`/header comments are the detailed reference.
#
# Overridable variables:
#   CONFIGURATION   Debug (default) | Direct | Release — see docs/distribution.md
#   DESTINATION     xcodebuild -destination for `make test`
#   ARGS            Extra flags forwarded to the script a target wraps

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT       := Synesthia.xcodeproj
SCHEME        := Synesthia
CONFIGURATION ?= Debug
DESTINATION   ?= platform=macOS
ARGS          ?=

# Where xcodebuild actually put Synesthia.app for $(CONFIGURATION). Resolved
# lazily (`=`, not `:=`) so targets that never need it don't pay the ~2 s.
BUILT_PRODUCTS_DIR = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-configuration $(CONFIGURATION) -showBuildSettings 2>/dev/null \
	| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}')

.PHONY: help build run test clean app-path \
        demo-track screenshots check-metadata \
        appstore appstore-upload direct direct-fast appcast \
        web-install web-dev web-build web-preview web-assets

help: ## List the available targets
	@printf '\033[1mSynesthia\033[0m — make targets\n\n'
	@awk 'BEGIN { FS = ":.*## " } \
	     /^# ==/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 8); next } \
	     /^[a-zA-Z0-9_-]+:.*## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' \
	     $(MAKEFILE_LIST)
	@printf '\nVariables: CONFIGURATION=%s  DESTINATION=%s  ARGS=…\n' \
	     '$(CONFIGURATION)' '$(DESTINATION)'

# ==== App

build: ## Build the app (CONFIGURATION=Debug by default)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) build

run: build ## Build and launch the app
	open "$(BUILT_PRODUCTS_DIR)/Synesthia.app"

test: ## Run the SynesthiaTests suite
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)'

clean: ## Clean the Xcode build and the release output in build/
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf build

app-path: ## Print the built app's path for the current CONFIGURATION
	@echo "$(BUILT_PRODUCTS_DIR)/Synesthia.app"

# ==== Assets

demo-track: ## Regenerate Synesthia/Resources/DemoLoop.m4a (deterministic)
	python3 scripts/make_demo_loop.py

screenshots: ## Capture every visualizer into web/src/assets/screenshots (see script header)
	./scripts/take-screenshots.sh $(ARGS)

# ==== Release  (docs/distribution.md)

appstore: ## Archive + validate the Mac App Store build (Release config)
	./scripts/build-appstore.sh $(ARGS)

appstore-upload: ## …and upload it to App Store Connect
	./scripts/build-appstore.sh --upload

direct: ## Archive, sign, notarize, staple and package the direct build (Direct config)
	./scripts/build-direct.sh $(ARGS)

direct-fast: ## Same, but skip notarization (local smoke test)
	./scripts/build-direct.sh --skip-notarize

appcast: ## Regenerate the signed Sparkle appcast from the DMGs in build/
	./scripts/make-appcast.sh $(ARGS)

check-metadata: ## Check docs/app-store-metadata.md against App Store field limits
	python3 scripts/check-metadata.py

# ==== Website  (web/)

web-install: ## Install the website's npm dependencies
	cd web && npm ci

web-dev: ## Run the Astro dev server
	cd web && npm run dev

web-build: ## Build the static site into web/dist
	cd web && npm run build

web-preview: ## Serve the built site locally
	cd web && npm run preview

web-assets: ## Regenerate icons/OG images in web/public from assets/
	cd web && npm run assets
