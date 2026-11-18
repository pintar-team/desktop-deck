#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export SDKROOT="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
MODE="${1:-release}"
JPEG_PREFIX="${JPEG_PREFIX:-/opt/homebrew/opt/jpeg-turbo}"
test -f "$JPEG_PREFIX/lib/libjpeg.a" || { echo 'Set JPEG_PREFIX to a libjpeg-turbo installation' >&2; exit 1; }
echo '[1/5] Preparing pinned OpenSSL with built-in providers'
OPENSSL_PREFIX="$(bash scripts/build-openssl.sh)"
export OPENSSL_PREFIX JPEG_PREFIX
echo '[2/5] Configuring pinned LibVNCClient'
cmake -S Vendor/LibVNCServer -B .build/native -G Ninja \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_OSX_SYSROOT="$SDKROOT" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_C_FLAGS="-ffile-prefix-map=\"$HOME\"=/build -ffile-prefix-map=\"$ROOT\"=/source" \
  -DCMAKE_INSTALL_PREFIX="$ROOT/.native" -DBUILD_SHARED_LIBS=OFF \
  -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF -DWITH_OPENSSL=ON -DWITH_GNUTLS=OFF \
  -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOPENSSL_INCLUDE_DIR="$OPENSSL_PREFIX/include" \
  -DOPENSSL_SSL_LIBRARY="$OPENSSL_PREFIX/lib/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_PREFIX/lib/libcrypto.a" \
  -DWITH_GCRYPT=OFF -DWITH_SASL=OFF -DWITH_PNG=OFF -DWITH_LZO=OFF \
  -DWITH_XCB=OFF -DWITH_FFMPEG=OFF -DWITH_SDL=OFF -DWITH_GTK=OFF \
  -DWITH_QT=OFF -DWITH_LIBSSHTUNNEL=OFF -DWITH_WEBSOCKETS=OFF \
  -DJPEG_INCLUDE_DIR="$JPEG_PREFIX/include" -DJPEG_LIBRARY="$JPEG_PREFIX/lib/libjpeg.a"
echo '[3/5] Building client library and checking VNC authentication'
cmake --build .build/native --target vncclient --parallel 4
mkdir -p .native/include/rfb .native/lib
cp Vendor/LibVNCServer/include/rfb/*.h .native/include/rfb/
cp .build/native/include/rfb/rfbconfig.h .native/include/rfb/
cp .build/native/libvncclient.a .native/lib/
cp -f "$JPEG_PREFIX/lib/libjpeg.a" .native/lib/
cp -f "$OPENSSL_PREFIX/lib/libssl.a" "$OPENSSL_PREFIX/lib/libcrypto.a" .native/lib/
xcrun clang -mmacosx-version-min=26.0 -I Vendor/LibVNCServer/src/common -I .native/include \
  scripts/check-vnc-crypto.c .native/lib/libvncclient.a .native/lib/libcrypto.a \
  -o .build/native/check-vnc-crypto
OPENSSL_CONF=/dev/null OPENSSL_MODULES=/dev/null .build/native/check-vnc-crypto
echo '[4/5] Building Swift application and MCP'
swift build -c "$MODE" --jobs 4 \
  -Xswiftc -file-prefix-map -Xswiftc "$HOME=/build" \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/source" \
  -Xcc "-ffile-prefix-map=$HOME=/build" -Xcc "-ffile-prefix-map=$ROOT=/source"
BIN="$(swift build -c "$MODE" --show-bin-path)"
APP="$ROOT/dist/Desktop Deck.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DesktopDeck" "$APP/Contents/MacOS/"
cp "$BIN/desktop-deck-mcp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f .build/AppIcon.icns ] || [ scripts/make-icon.swift -nt .build/AppIcon.icns ] || [ Resources/AppIcon-source.png -nt .build/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources/AppIcon-source.png .build/AppIcon.iconset
  iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.iconset/icon_256x256@2x.png plugins/desktop-deck/assets/icon.png
cp .build/AppIcon.icns "$APP/Contents/Resources/"
NOTICES="$APP/Contents/Resources/Licenses"
mkdir -p "$NOTICES"
cp LICENSE "$NOTICES/DesktopDeck-GPL-3.0.txt"
for dependency in Vendor/LibVNCServer Vendor/TurboVNC .build/checkouts/*; do
  name="$(basename "$dependency")"
  for notice in "$dependency"/LICENSE* "$dependency"/COPYING*; do
    if [ -f "$notice" ]; then cp -f "$notice" "$NOTICES/$name-$(basename "$notice")"; fi
  done
done
cp -f "$JPEG_PREFIX/share/doc/libjpeg-turbo/LICENSE.md" "$NOTICES/libjpeg-turbo-LICENSE.md"
cp -f "$JPEG_PREFIX/share/doc/libjpeg-turbo/README.ijg" "$NOTICES/libjpeg-turbo-README.ijg"
cp -f "$OPENSSL_PREFIX/LICENSE.txt" "$NOTICES/OpenSSL-LICENSE.txt"
python3 scripts/dependency-receipt.py > "$APP/Contents/Resources/dependencies.json"
for bundle in "$BIN"/*.bundle; do
  if [ -d "$bundle" ]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done
if [ "$MODE" = release ]; then
  strip -S -x "$APP/Contents/MacOS/DesktopDeck" "$APP/Contents/MacOS/desktop-deck-mcp"
fi
codesign --force --deep --sign - "$APP"
echo "[5/5] Built $APP"
