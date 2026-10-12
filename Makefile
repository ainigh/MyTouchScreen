# Wisp (GesturePointer) — everything needs only the Xcode command-line tools.
#   make build    compile (release)
#   make app      assemble + ad-hoc sign GesturePointer.app
#   make run      build the app and open it
#   make doctor   print permissions, cameras, displays, measured fps
#   make install  copy the app to /Applications
#   make test     run the GestureCore test suite
#   make check    static checks (no placeholders, imports, Info.plist)

APP := GesturePointer.app
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
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "Installed to /Applications/$(APP). Grant Camera and Accessibility to that copy."

test:
	swift test

check:
	tools/check.sh

# Replays a synthetic session (no camera needed) and prints what Wisp would do.
replay-demo: app
	swift run gesture-replay --synthetic demo /tmp/wisp-demo.json
	$(BIN) --replay /tmp/wisp-demo.json --dry-run

clean:
	rm -rf .build $(APP)
