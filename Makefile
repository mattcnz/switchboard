APP = build/Build/Products/Debug/Switchboard.app
# Stable signing identity so TCC permissions (Accessibility/Automation)
# survive rebuilds. Unsigned builds are keyed by binary hash — every rebuild
# silently invalidates the grant while the System Settings toggle stays on.
SIGN_ID = A0378A314F0717226B0F81430272DB8199F79B1D

.PHONY: generate build run logs

generate:
	xcodegen generate

build: generate
	xcodebuild -project Switchboard.xcodeproj -scheme Switchboard \
	  -configuration Debug -derivedDataPath build build
	codesign --force --sign $(SIGN_ID) $(APP)

run: build
	-pkill -x Switchboard
	sleep 0.5
	open $(APP)

logs:
	log stream --predicate 'subsystem == "com.mattmilliken.switchboard"' --level debug
