# Platform enum in build.zig
PLATFORMS := allwinner rk3566
# Extra options for the production builds, e.g. ZIGFLAGS="-Dcommit=..."
ZIGFLAGS ?=

## help: print this help message
.PHONY: help
help:
	@echo 'Usage:'
	@sed -n 's/^##//p' ${MAKEFILE_LIST} | column -t -s ':' | sed -e 's/^/ /'

## build-all: build production executables for every platform into zig-out/<platform>/bin
.PHONY: build-all
build-all:
	@for platform in $(PLATFORMS); do \
		echo "zig build -Doptimize=ReleaseSmall -Dplatform=$$platform $(ZIGFLAGS) --prefix zig-out/$$platform"; \
		zig build -Doptimize=ReleaseSmall -Dplatform=$$platform $(ZIGFLAGS) --prefix zig-out/$$platform || exit 1; \
	done

## build: build the production executable for Allwinner readers
.PHONY: build
build:
	zig build -Doptimize=ReleaseSmall

## fmt-check: check zig code format
.PHONY: fmt-check
fmt-check:
	zig fmt --check src build.zig

## fmt-fix: fix zig code format
.PHONY: fmt-fix
fmt-fix:
	zig fmt src build.zig

## test: run the unit tests
.PHONY: test
test:
	zig build test --summary all
