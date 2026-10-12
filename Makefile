# Wisp (GesturePointer) — everything needs only the Xcode command-line tools.
#   make build    compile (release)
#   make app      assemble + ad-hoc sign GesturePointer.app
#   make run      build the app and open it
#   make doctor   print permissions, cameras, displays, measured fps
#   make install  install into ~/Applications (same place install.sh uses) and open it
#   make test     run the GestureCore test suite
#   make check    static checks (unfinished markers, imports, Info.plist)
#   make replay-demo  run a synthetic click / drag / zoom / scroll session through the app (no camera)

APP := build/GesturePointer.app
BIN := $(APP)/Contents/MacOS/GesturePointer

.PHONY: build app run doctor install test check clean replay-demo

build:
	swift build -c release --product GesturePointer

app:
	scripts/make-app.sh

run: app
	open $(APP)

doctor: app
	$(BIN) --doctor

install: app
	pkill -x GesturePointer 2>/dev/null; sleep 1; true
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/GesturePointer.app
	ditto $(APP) $(HOME)/Applications/GesturePointer.app
	open $(HOME)/Applications/GesturePointer.app
	@echo "Installed to ~/Applications/GesturePointer.app. Grant Camera and Accessibility to that copy."

test:
	swift test

check:
	tools/check.sh

# Replays a synthetic session (no camera needed) and prints what Wisp would do.
replay-demo: app
	swift run gesture-replay --synthetic demo /tmp/wisp-demo.json
	$(BIN) --replay /tmp/wisp-demo.json --dry-run

clean:
	rm -rf .build build
