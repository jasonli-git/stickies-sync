.PHONY: build test check doctor release clean

# swift-testing ships inside the Command Line Tools, but SwiftPM only wires it
# up automatically under a full Xcode: on a CLT-only Mac the framework, the
# macro plugin, and the interop dylib all have to be pointed at by hand, and
# XCTest is absent entirely. The flags below are added only when the CLT layout
# is what's active, so installing Xcode makes them disappear rather than
# conflict. Run tests through `make test`, not bare `swift test`.
DEVELOPER_DIR := $(shell xcode-select -p)
CLT_FRAMEWORKS := $(DEVELOPER_DIR)/Library/Developer/Frameworks
CLT_TESTING_PLUGIN := $(DEVELOPER_DIR)/usr/lib/swift/host/plugins/testing
CLT_TESTING_INTEROP := $(DEVELOPER_DIR)/Library/Developer/usr/lib

ifneq ($(wildcard $(CLT_FRAMEWORKS)/Testing.framework),)
TEST_FLAGS := --disable-xctest \
	-Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
	-Xswiftc -plugin-path -Xswiftc $(CLT_TESTING_PLUGIN) \
	-Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_TESTING_INTEROP)
endif

build:
	swift build

test:
	swift test $(TEST_FLAGS)

# The gate a milestone must pass.
check: build test

doctor: build
	swift run stickiesctl doctor

release:
	swift build -c release

clean:
	swift package clean
