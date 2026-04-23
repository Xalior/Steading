# Stable entry points for the Steading Xcode build + test. Each target
# is a thin wrapper over the invocation documented in CLAUDE.md's
# build-and-test cheatsheet.

.PHONY: build test generate clean

XCODEBUILD := xcodebuild
PROJECT    := Steading.xcodeproj
SCHEME     := Steading
CONFIG     := Debug
DEST       := platform=macOS,arch=arm64

build:
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) -arch arm64 ONLY_ACTIVE_ARCH=YES build

test:
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) -destination '$(DEST)' \
		-enableCodeCoverage NO test

generate:
	xcodegen generate

clean:
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) clean
