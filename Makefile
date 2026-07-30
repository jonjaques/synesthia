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
#   BUMP            patch (default) | minor | major | an explicit version, for `make bump`

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT       := Synesthia.xcodeproj
# Two app targets, two schemes. `Synesthia` is the Mac App Store build and links
# nothing; `Synesthia Direct` links Sparkle and is what ships from the website.
# See docs/distribution.md.
SCHEME        := Synesthia
DIRECT_SCHEME := Synesthia Direct
CONFIGURATION ?= Debug
DESTINATION   ?= platform=macOS
ARGS          ?=
BUMP          ?= patch

# Where xcodebuild actually put Synesthia.app for $(CONFIGURATION). Resolved
# lazily (`=`, not `:=`) so targets that never need it don't pay the ~2 s.
BUILT_PRODUCTS_DIR = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-configuration $(CONFIGURATION) -showBuildSettings 2>/dev/null \
	| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2; exit}')

# swift-format ships inside the Xcode toolchain (`swift format`, no install
# step), configured by .swift-format at the repo root. Everything Swift we own
# — the app, the tests, and the standalone screenshot helper.
SWIFT_FORMAT  := swift format
SWIFT_SOURCES := Synesthia SynesthiaTests scripts/shotkit.swift

# CI runners have no signing identity and no provisioning profile, so automatic
# signing fails before a single file compiles. Ad-hoc signing (`-`) still
# satisfies the sandbox, which is all `make test` needs. GitHub Actions (and
# most other CI) exports CI=true; locally this is empty and nothing changes.
ifdef CI
SIGNING := CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
endif

.PHONY: help build bump build-direct run test clean app-path \
        install healthcheck lint format \
        demo-track screenshots check-metadata \
        appstore appstore-upload direct direct-fast bump \
        sparkle-keys appcast publish-release publish-dry-run

help: ## List the available targets
	@printf '\033[1mSynesthia\033[0m — make targets\n\n'
	@awk 'BEGIN { FS = ":.*## " } \
	     /^# ==/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 8); next } \
	     /^[a-zA-Z0-9_-]+:.*## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' \
	     $(MAKEFILE_LIST)
	@printf '\nVariables: CONFIGURATION=%s  DESTINATION=%s  ARGS=…\n' \
	     '$(CONFIGURATION)' '$(DESTINATION)'

# ==== App

build: ## Build the App Store app (CONFIGURATION=Debug by default)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) $(SIGNING) build

build-direct: ## Build the Sparkle-enabled direct app (same product name — see docs)
	xcodebuild -project $(PROJECT) -scheme "$(DIRECT_SCHEME)" -configuration $(CONFIGURATION) $(SIGNING) build

run: build ## Build and launch the app
	open "$(BUILT_PRODUCTS_DIR)/Synesthia.app"

test: ## Run the SynesthiaTests suite
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' $(SIGNING)

clean: ## Clean the Xcode build and the release output in build/
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf build

app-path: ## Print the built app's path for the current CONFIGURATION
	@echo "$(BUILT_PRODUCTS_DIR)/Synesthia.app"

# ==== Checks

install: ## Install npm dependencies: root formatting tools
	npm install

# The PR quality gate: what .github/workflows/healthcheck.yml runs on the
# macOS side, as `make install && make healthcheck`. Order matters — the cheap
# check fails first. `web/` is its own project and is gated separately.
healthcheck: lint test build-direct ## Everything a PR has to pass: lint, tests, both builds

lint: ## Check formatting without writing: Prettier, then swift-format --strict
	npm run format:check && $(SWIFT_FORMAT) lint --configuration .swift-format \
		--recursive --parallel --strict $(SWIFT_SOURCES)

format: ## Reformat in place: Prettier, then swift-format (.swift-format)
	npm run format && $(SWIFT_FORMAT) --configuration .swift-format \
		--recursive --parallel --in-place $(SWIFT_SOURCES)

# ==== Assets

demo-track: ## Regenerate Synesthia/Resources/DemoLoop.m4a (deterministic)
	python3 scripts/make_demo_loop.py

screenshots: ## Capture every visualizer into web/src/assets/screenshots/<run>, incl. App Store sizes
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

bump: ## Bump the version everywhere: BUMP=patch|minor|major|<version> (default patch)
	./scripts/bump-version.sh $(BUMP) $(ARGS)

sparkle-keys: ## One-time: create the Sparkle EdDSA signing key and print the public half
	./scripts/sparkle-keys.sh $(ARGS)

appcast: ## Regenerate the signed Sparkle appcast into build/releases (does not publish)
	./scripts/make-appcast.sh $(ARGS)

publish-release: ## Upload the DMGs, appcast and latest.json to the R2 bucket
	./scripts/publish-release.sh $(ARGS)

publish-dry-run: ## …show what publish-release would upload, without uploading
	./scripts/publish-release.sh --dry-run

check-metadata: ## Check docs/app-store-metadata.md against App Store field limits
	python3 scripts/check-metadata.py
