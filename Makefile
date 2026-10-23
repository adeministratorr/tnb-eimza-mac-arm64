SHELL := /bin/bash
ROOT := $(shell pwd)
CACHE := $(ROOT)/.jre-cache
BUILD := $(ROOT)/build
APPNAME := TNBTeknolojiImza
DISPLAYNAME := TNB Teknoloji İmza

# Rosetta (x86_64) kabuğunda derlenirse arm64 runtime/paket üretilemez; kur.sh
# bunu kendisi düzeltir, doğrudan `make` çağıranları burada uyarıyoruz.
ARCH := $(shell uname -m)
GOALS := $(if $(MAKECMDGOALS),$(MAKECMDGOALS),app)
ifneq ($(ARCH),arm64)
ifneq ($(filter jre prep app dmg run install,$(GOALS)),)
ifeq ($(shell sysctl -n hw.optional.arm64 2>/dev/null),1)
$(error Terminal Rosetta (x86_64) modunda. Şunu kullanın:  arch -arm64 make $(MAKECMDGOALS))
else
$(error Bu port yalnızca Apple Silicon içindir (mevcut mimari: $(ARCH)))
endif
endif
endif

ZULU11_URL := https://cdn.azul.com/zulu/bin/zulu11.88.17-ca-jdk11.0.31-macosx_aarch64.tar.gz
ZULU21_URL := https://cdn.azul.com/zulu/bin/zulu21.50.19-ca-jdk21.0.11-macosx_aarch64.tar.gz

RUNTIME := $(CACHE)/zulu11-runtime
# Sistem jpackage (Java 17+) varsa onu kullan, yoksa indirilmiş Zulu 21'i
JPACKAGE := $(shell jpackage --version >/dev/null 2>&1 && command -v jpackage || echo $(CACHE)/zulu21/bin/jpackage)

.PHONY: jre
jre: $(RUNTIME)/bin/java $(JPACKAGE)

$(RUNTIME)/bin/java:
	@mkdir -p $(CACHE)
	@echo ">> Zulu 11 arm64 runtime indiriliyor..."
	@curl -fsSL "$(ZULU11_URL)" -o $(CACHE)/zulu11.tar.gz
	@rm -rf $(CACHE)/zulu11-runtime $(CACHE)/_z11 && mkdir -p $(CACHE)/_z11
	@tar -xzf $(CACHE)/zulu11.tar.gz -C $(CACHE)/_z11 --strip-components=1
	@# .app içindeki Contents/Home gerçek JDK kökü
	@if [ -d "$(CACHE)/_z11/zulu-11.jdk/Contents/Home" ]; then \
	   mv "$(CACHE)/_z11/zulu-11.jdk/Contents/Home" $(RUNTIME); \
	 elif [ -d "$(CACHE)/_z11/Contents/Home" ]; then \
	   mv "$(CACHE)/_z11/Contents/Home" $(RUNTIME); \
	 else mv $(CACHE)/_z11 $(RUNTIME); fi
	@rm -rf $(CACHE)/_z11 $(CACHE)/zulu11.tar.gz
	@echo ">> runtime: $(RUNTIME)"

$(CACHE)/zulu21/bin/jpackage:
	@if jpackage --version >/dev/null 2>&1; then \
	   echo ">> sistem jpackage kullanılacak: $$(command -v jpackage)"; \
	 else \
	   echo ">> Zulu 21 (jpackage) indiriliyor..."; \
	   mkdir -p $(CACHE); \
	   curl -fsSL "$(ZULU21_URL)" -o $(CACHE)/zulu21.tar.gz; \
	   rm -rf $(CACHE)/zulu21 $(CACHE)/_z21 && mkdir -p $(CACHE)/_z21; \
	   tar -xzf $(CACHE)/zulu21.tar.gz -C $(CACHE)/_z21 --strip-components=1; \
	   if [ -d "$(CACHE)/_z21/zulu-21.jdk/Contents/Home" ]; then \
	     mv "$(CACHE)/_z21/zulu-21.jdk/Contents/Home" $(CACHE)/zulu21; \
	   elif [ -d "$(CACHE)/_z21/Contents/Home" ]; then \
	     mv "$(CACHE)/_z21/Contents/Home" $(CACHE)/zulu21; \
	   else mv $(CACHE)/_z21 $(CACHE)/zulu21; fi; \
	   rm -rf $(CACHE)/_z21 $(CACHE)/zulu21.tar.gz; \
	 fi

.PHONY: prep app
prep: $(RUNTIME)/bin/java
	@JDK="$(RUNTIME)" ./scripts/prep-payload.sh

app: jre prep
	@RUNTIME="$(RUNTIME)" JPACKAGE="$(JPACKAGE)" ./scripts/build-app.sh

.PHONY: dmg run install host uninstall clean sign-devid notarize-app notarize-dmg notary-setup
# DİKKAT: dmg kasıtlı 'app' bağımlılığı DEĞİL — make app ad-hoc imza atıp
# notarize edilmiş imzayı SİLER. Sıralama: make app && make notarize-app
# && make dmg && make notarize-dmg DMG_FILE=...
dmg:
	@test -d "$(BUILD)/$(APPNAME).app" || { echo ">> .app yok — önce: make app (notarize: make notarize-app)"; exit 1; }
	@rm -f $(BUILD)/$(APPNAME).dmg
	@rm -rf $(BUILD)/dmgroot && mkdir -p $(BUILD)/dmgroot
	@cp -R $(BUILD)/$(APPNAME).app $(BUILD)/dmgroot/
	@ln -s /Applications $(BUILD)/dmgroot/Applications
	@hdiutil create -volname "$(APPNAME)" -srcfolder $(BUILD)/dmgroot \
	   -ov -format UDZO $(BUILD)/$(APPNAME).dmg
	@rm -rf $(BUILD)/dmgroot
	@echo ">> dmg: $(BUILD)/$(APPNAME).dmg"

# Kart okunuyor mu, sürücü yükleniyor mu — tarayıcısız hızlı deneme.
run: app
	@./scripts/smoke-test.sh "$(BUILD)/$(APPNAME).app"

# Not: eski sürüm daha önce "sudo" ile kurulmuşsa root'a aittir ve normal
# kullanıcı silemez; bu durumda yönetici izni isteyip devam ediyoruz.
install: app
	@if [ -e "/Applications/$(APPNAME).app" ] && ! rm -rf "/Applications/$(APPNAME).app" 2>/dev/null; then \
	   echo ">> eski sürüm yönetici izniyle kaldırılıyor (şifre isteyebilir)..."; \
	   sudo rm -rf "/Applications/$(APPNAME).app"; \
	 fi
	@if ! cp -R $(BUILD)/$(APPNAME).app /Applications/ 2>/dev/null; then \
	   echo ">> /Applications'a yönetici izniyle kopyalanıyor (şifre isteyebilir)..."; \
	   sudo cp -R $(BUILD)/$(APPNAME).app /Applications/; \
	   sudo chown -R "$$(id -un)":admin "/Applications/$(APPNAME).app"; \
	 fi
	@xattr -dr com.apple.quarantine "/Applications/$(APPNAME).app" 2>/dev/null || true
	@echo ">> kuruldu: /Applications/$(APPNAME).app"
	@$(MAKE) --no-print-directory host

# Tarayıcı kaydı (native messaging host manifest'leri)
host:
	@./scripts/install-host.sh

uninstall:
	@./scripts/install-host.sh --uninstall
	@if [ -e "/Applications/$(APPNAME).app" ] && ! rm -rf "/Applications/$(APPNAME).app" 2>/dev/null; then \
	   echo ">> yönetici izniyle kaldırılıyor (şifre isteyebilir)..."; \
	   sudo rm -rf "/Applications/$(APPNAME).app"; \
	 fi
	@echo ">> kaldırıldı."

clean:
	@rm -rf $(BUILD)
	@echo ">> temizlendi (build/). .jre-cache korunur."

# ---------- Developer ID imzası + Apple notarizasyonu ----------
IDENTITY ?= Developer ID Application: ADEM YUCE (99QB736768)
APP := $(BUILD)/$(APPNAME).app
ENT := scripts/entitlements-jvm.plist
NOTARY_PROFILE ?= eimza-notch
DMG_FILE ?= $(BUILD)/$(APPNAME).dmg

ifeq ($(strip $(APPLE_API_KEY_ID)$(APPLE_API_ISSUER_ID)),)
NOTARY_ARGS := --keychain-profile "$(NOTARY_PROFILE)"
else
NOTARY_ARGS := --key "$(HOME)/private_keys/AuthKey_$(APPLE_API_KEY_ID).p8" --key-id "$(APPLE_API_KEY_ID)" --issuer "$(APPLE_API_ISSUER_ID)"
endif

sign-devid: ## Developer ID + hardened runtime imzala (önce: make app)
	@test -d "$(APP)" || { echo ">> .app yok — önce: make app"; exit 1; }
	@[ "build/.signed" -nt "$(APP)" ] && echo ">> Developer ID zaten imzalı (stamp güncel) — atlandı" && exit 0 || true
	@./scripts/inner-sign.py "$(APP)" "$(IDENTITY)"
	@find "$(APP)/Contents" -type f \( -name '*.dylib' -o -name '*.jnilib' -o -name '*.jspawnhelper' -o -path '*/MacOS/*' -o -path '*/Home/bin/*' \) | grep -v 'Contents/runtime/Contents/MacOS/' > build/.macho-list
	@N2=0; NM=$$(wc -l < build/.macho-list | tr -d ' '); while IFS= read -r f; do file "$$f" | grep -q 'Mach-O' || continue; codesign --force --options runtime --timestamp --sign "$(IDENTITY)" "$$f" || exit 9; N2=$$((N2+1)); done < build/.macho-list; rm -f build/.macho-list; echo ">> iç Mach-O imza: $$N2/$$NM"
	@find "$(APP)" \( -path '*/Home/bin/*' -o -name jspawnhelper \) -type f -print0 | xargs -0 -I{} codesign --force --options runtime --timestamp --entitlements "$(ENT)" --sign "$(IDENTITY)" "{}" || exit 3
	@codesign --force --sign "$(IDENTITY)" --options runtime --timestamp "$(APP)/Contents/runtime" || exit 5
	@codesign --force --sign "$(IDENTITY)" --options runtime --timestamp --entitlements "$(ENT)" "$(APP)" || exit 3
	@codesign --verify --deep --strict "$(APP)" || exit 4 ; echo ">> Developer ID imzası geçerli"
	@touch build/.signed

notarize-app: sign-devid ## notarytool submit + wait + staple (.app)
	@ditto -c -k --keepParent "$(APP)" $(BUILD)/notary-upload.zip
	@xcrun notarytool submit $(BUILD)/notary-upload.zip $(NOTARY_ARGS) --wait; st=$$?; rm -f $(BUILD)/notary-upload.zip; exit $$st
	@xcrun stapler staple "$(APP)"
	@xcrun stapler validate "$(APP)"

notarize-dmg: ## DMG'yi notarize et + staple (DMG_FILE=... set edilmeli)
	@test -n "$(DMG_FILE)" && test -f "$(DMG_FILE)" || { echo ">> DMG yok: DMG_FILE=... verin (önce: make dmg)"; exit 1; }
	@xcrun notarytool submit "$(DMG_FILE)" $(NOTARY_ARGS) --wait
	@xcrun stapler staple "$(DMG_FILE)"
	@xcrun stapler validate "$(DMG_FILE)"

notary-setup: ## yerel keychain notarytool profili (interaktif, bir kez)
	@echo "örnek: xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id <ADRES> --team-id 99QB736768"
	@echo "(şifre: account.apple.com -> Uygulamaya Ozel Sifre)"
