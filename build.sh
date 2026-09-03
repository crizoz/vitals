#!/bin/bash
# Compila Vitals.app sin Xcode: basta con las Command Line Tools.
#   ./build.sh             compila en build/
#   ./build.sh --install   además la instala en /Applications y la abre
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Vitals.app"
MACOS="$APP/Contents/MacOS"
IDENTITY="Vitals Self Signed"

# Una identidad propia y estable en vez de firma ad-hoc. La firma ad-hoc cambia
# en cada compilación, y el permiso del llavero queda atado a la firma: con
# ad-hoc macOS vuelve a pedir autorización cada vez. Con esto, se autoriza una
# sola vez y queda.
ensure_identity() {
    if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
        return
    fi
    echo "› Creando la identidad de firma (una sola vez)…"
    local tmp
    tmp="$(mktemp -d)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
        -subj "/CN=$IDENTITY" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    # Algoritmos antiguos a propósito: los que sí acepta el llavero de macOS.
    openssl pkcs12 -export -out "$tmp/identity.p12" \
        -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$IDENTITY" -passout pass:vitals \
        -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null
    security import "$tmp/identity.p12" \
        -k "$HOME/Library/Keychains/login.keychain-db" \
        -P vitals -T /usr/bin/codesign
    rm -rf "$tmp"   # la clave privada queda solo en el llavero
}

# El .icns se regenera solo si el generador es más nuevo.
if [[ ! -f "$ROOT/Resources/Vitals.icns" || "$ROOT/Tools/MakeIcon.swift" -nt "$ROOT/Resources/Vitals.icns" ]]; then
    echo "› Generando el ícono…"
    mkdir -p "$ROOT/build"
    swiftc -O "$ROOT/Tools/MakeIcon.swift" -o "$ROOT/build/makeicon"
    "$ROOT/build/makeicon" "$ROOT"
    iconutil -c icns "$ROOT/build/Vitals.iconset" -o "$ROOT/Resources/Vitals.icns"
fi

ensure_identity

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"

echo "› Compilando…"
swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -framework AppKit -framework SwiftUI -framework IOKit \
    -framework Security -framework ServiceManagement \
    -o "$MACOS/Vitals" \
    "$ROOT"/Sources/*.swift

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Vitals.icns" "$APP/Contents/Resources/Vitals.icns"

echo "› Firmando…"
codesign --force --sign "$IDENTITY" --identifier cl.makana.vitals "$APP"

echo "✓ $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "› Instalando en /Applications…"
    pkill -f "/Applications/Vitals.app/Contents/MacOS/Vitals" 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Vitals.app
    cp -R "$APP" /Applications/
    open /Applications/Vitals.app
    echo "✓ /Applications/Vitals.app"
fi
