APP := CmdTab.app
VERSION := 0.01
DIST := dist
UNIVERSAL := .build/universal/CmdTab
BIN ?= .build/release/CmdTab
SIGN_ID := CmdTab Local Signing
SIGNING_DIR := $(HOME)/Library/Application Support/CmdTab/signing
KEYCHAIN := $(HOME)/Library/Keychains/login.keychain-db

.PHONY: build run app-bundle install universal dist clean reset-permissions sign-setup sign-status

build:
	swift build -c release

run:
	swift run

app-bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/
	@if security find-certificate -c "$(SIGN_ID)" >/dev/null 2>&1; then \
		codesign --force --sign "$(SIGN_ID)" --identifier com.faucher.cmdtab $(APP); \
		echo "signed with: $(SIGN_ID)"; \
	else \
		echo "warning: '$(SIGN_ID)' identity missing, falling back to ad-hoc."; \
		echo "         Ad-hoc signatures change on every build, so macOS drops the"; \
		echo "         Accessibility grant each time. Run 'make sign-setup' once to fix."; \
		codesign --force --sign - --identifier com.faucher.cmdtab $(APP); \
	fi

install: app-bundle
	@pkill -f "Applications/$(APP)/Contents/MacOS/CmdTab" 2>/dev/null || true
	@sleep 0.3
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/$(APP)
	cp -R $(APP) $(HOME)/Applications/
	@echo "Installed to $(HOME)/Applications/$(APP)"
	@echo "Then: open $(HOME)/Applications/$(APP)"

# Release build: arm64 + x86_64 in one binary, so the download runs on Apple
# Silicon and Intel. Slower than `build` because it compiles twice.
universal:
	swift build -c release --arch arm64 --scratch-path .build/arm64
	swift build -c release --arch x86_64 --scratch-path .build/x86_64
	mkdir -p .build/universal
	lipo -create .build/arm64/release/CmdTab .build/x86_64/release/CmdTab -output $(UNIVERSAL)
	@lipo -info $(UNIVERSAL)

# Distributable zip for a GitHub release.
dist: universal
	@$(MAKE) --no-print-directory app-bundle BIN=$(UNIVERSAL)
	@mkdir -p $(DIST)
	ditto -c -k --sequesterRsrc --keepParent $(APP) $(DIST)/CmdTab-$(VERSION).zip
	@echo
	@shasum -a 256 $(DIST)/CmdTab-$(VERSION).zip

# Creates a self-signed code-signing identity once. Because the identity (not the
# binary hash) is what macOS remembers, the Accessibility grant survives rebuilds.
sign-setup:
	@mkdir -p "$(SIGNING_DIR)"
	@cd "$(SIGNING_DIR)" && { \
		if [ ! -f cert.pem ]; then \
			openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
				-keyout key.pem -out cert.pem \
				-subj "/CN=$(SIGN_ID)" \
				-addext "extendedKeyUsage=codeSigning" \
				-addext "basicConstraints=critical,CA:false" \
				-addext "keyUsage=critical,digitalSignature" 2>/dev/null && echo "generated key + cert"; \
		fi; \
	}
	@if security find-certificate -c "$(SIGN_ID)" >/dev/null 2>&1; then \
		echo "'$(SIGN_ID)' is already in the keychain"; \
	else \
		cd "$(SIGNING_DIR)" && \
		openssl pkcs12 -export -out ident.p12 -inkey key.pem -in cert.pem \
			-passout pass:cmdtab \
			-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null && \
		security import ident.p12 -k "$(KEYCHAIN)" -P cmdtab -T /usr/bin/codesign -A; \
	fi

sign-status:
	@codesign -dvvv $(HOME)/Applications/$(APP) 2>&1 | grep -E "Identifier|Authority|Signature" || true

reset-permissions:
	tccutil reset Accessibility com.faucher.cmdtab || true

clean:
	swift package clean
	rm -rf $(APP)
