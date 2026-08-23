APP = build/Build/Products/Debug/Switchboard.app
# Stable signing identity so TCC permissions (Accessibility/Automation)
# survive rebuilds. Unsigned builds are keyed by binary hash — every rebuild
# silently invalidates the grant while the System Settings toggle stays on.
SIGN_ID = A0378A314F0717226B0F81430272DB8199F79B1D

# Distribution (outside the Mac App Store) — signed with a Developer ID cert,
# notarized, so Gatekeeper accepts it on a machine that isn't this one.
RELEASE_APP = build-release/Build/Products/Release/Switchboard.app
RELEASE_ZIP = build-release/Switchboard.zip
DMG = build-release/Switchboard.dmg
DEV_ID = Developer ID Application: Matthew Milliken (MM267F63K8)
NOTARY_PROFILE = switchboard-notary

.PHONY: generate build run logs release notarize dmg

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

# Builds a Developer ID-signed, Hardened Runtime app ready for notarization.
# One-time setup before this works: store notarization credentials in the
# keychain (asks for an app-specific password, generated at
# https://appleid.apple.com under Sign-In and Security):
#   xcrun notarytool store-credentials $(NOTARY_PROFILE) \
#     --apple-id <your-apple-id> --team-id <your-team-id>
release: generate
	xcodebuild -project Switchboard.xcodeproj -scheme Switchboard \
	  -configuration Release -derivedDataPath build-release build
	codesign --force --options runtime --timestamp \
	  --entitlements Switchboard.entitlements \
	  --sign "$(DEV_ID)" $(RELEASE_APP)
	codesign --verify --deep --strict --verbose=2 $(RELEASE_APP)

# Submits the Release build to Apple, waits for approval, and staples the
# ticket to the app so Gatekeeper can verify it offline.
notarize: release
	ditto -c -k --keepParent $(RELEASE_APP) $(RELEASE_ZIP)
	xcrun notarytool submit $(RELEASE_ZIP) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(RELEASE_APP)
	spctl -a -vvv -t install $(RELEASE_APP)

# Packages the notarized app into a disk image for download.
dmg: notarize
	rm -f $(DMG)
	hdiutil create -volname Switchboard -srcfolder $(RELEASE_APP) -ov -format UDZO $(DMG)
	@echo "Ready: $(DMG)"
