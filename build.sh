#!/usr/bin/env bash
#
# Creates a distributible tarball for Notion.
NOTION_VERSION="3.11.1"
NOTION_DMG="Notion-3.11.1-universal.dmg"
BETTER_SQLITE3_VERSION="11.1.2"
ELECTRON_ABI="125"

set -eo pipefail

info() {
  echo -e "\\033[36mINFO\\033[0m:" "$@"
}

error() {
  echo -e "\\033[31mERROR\\033[0m:" "$@"
}

sevenzip="7z"
if command -v 7zz >/dev/null; then # 7zip on macOS
  sevenzip="7zz"
elif command -v 7za >/dev/null; then # p7zip on Ubuntu
  sevenzip="7za"
fi

OS="$(uname -s)"
if [[ "$OS" == "Darwin" ]]; then
  OS="darwin"
elif [[ "$OS" == "Linux" ]]; then
  OS="linux"
else
  error "unsupported OS: $OS"
  exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" == "x86_64" ]]; then
  ARCH="x64"
elif [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
  ARCH="arm64"
else
  error "unsupported architecture: $ARCH"
  exit 1
fi

if ! command -v "$sevenzip" >/dev/null; then
  error "$sevenzip not found (install 7zip package?)"
  exit 1
fi

# Clean dirs
rm -rf tmp deps release 2>/dev/null || true
mkdir deps release tmp 2>/dev/null || true

info "Checking existence of $NOTION_DMG ..."
if [[ ! -e "$NOTION_DMG" ]]; then
  error "$NOTION_DMG not found"
  exit 1
fi

info "Building Electron app ..."
rm -rf tmp/build 2>/dev/null || true
mkdir -p tmp/build 2>/dev/null || true

# This will usually yell about an /Applications symlink, but it's fine. So,
# ignore errors here.
"$sevenzip" x "$NOTION_DMG" -y -otmp/notion >/dev/null || true

chrome_and_electron_string=$(strings tmp/notion/Notion/Notion.app/Contents/Frameworks/Electron\ Framework.framework/Electron\ Framework | grep "Chrome/" | grep -i Electron | grep -v '%s' | sort -u)
info "Reading from $NOTION_DMG... $chrome_and_electron_string"

# Detect the version of Electron, if we haven't had one custom set.
if [[ -z "$ELECTRON_VERSION" ]]; then
  ELECTRON_VERSION=$(strings tmp/notion/Notion/Notion.app/Contents/Frameworks/Electron\ Framework.framework/Electron\ Framework |
    grep "Chrome/" | grep -i Electron | grep -v '%s' | sort -u | cut -f 3 -d '/')
  ELECTRON_VERSION="v$ELECTRON_VERSION"
  info "Detected Electron version: $ELECTRON_VERSION"
fi

info "Ensuring electron $ELECTRON_VERSION ..."
if [[ ! -e "deps/electron-$ELECTRON_VERSION.zip" ]]; then
  wget "https://github.com/electron/electron/releases/download/$ELECTRON_VERSION/electron-$ELECTRON_VERSION-$OS-$ARCH.zip" -O "deps/electron-$ELECTRON_VERSION.zip"
fi

info "Ensuring better-sqlite3 ..."
better_sqlite3_filename="better-sqlite3-v$BETTER_SQLITE3_VERSION-electron-v$ELECTRON_ABI-$OS-$ARCH.tar.gz"
node_binding_target="deps/better_sqlite3.node"
if [[ ! -e "deps/better_sqlite3.node" ]]; then
  if [[ "$OS" == "linux" ]] && [[ "$ARCH" == "arm64" ]]; then
    info "linux/arm64 doesn't have better-sqlite3 prebuilts, building manually ..."
    git clone https://github.com/WiseLibs/better-sqlite3 tmp/better-sqlite3 || true
    pushd tmp/better-sqlite3 >/dev/null
    git checkout "v$BETTER_SQLITE3_VERSION"
    npm install
    npx --no-install prebuild -r electron -t "$ELECTRON_VERSION" --include-regex 'better_sqlite3.node$' --arch arm64
    popd >/dev/null

    cp "tmp/better-sqlite3/build/Release/better_sqlite3.node" "$node_binding_target"
  else
    wget "https://github.com/WiseLibs/better-sqlite3/releases/download/v$BETTER_SQLITE3_VERSION/$better_sqlite3_filename" \
      -O "deps/$better_sqlite3_filename"

    tar -xzf "deps/$better_sqlite3_filename" -C deps
    find deps/ -name "better_sqlite3.node" -exec mv {} deps \;
  fi
fi

"$sevenzip" x "deps/electron-$ELECTRON_VERSION.zip" -y -otmp/build >/dev/null

appExtractPath=""
if [[ "$OS" == "darwin" ]]; then
  appExtractPath="tmp/build/Electron.app/Contents/Resources"
elif [[ "$OS" == "linux" ]]; then
  appExtractPath="tmp/build/resources"
elif [[ "$appExtractPath" == "" ]]; then
  error "unsupported OS: $OS"
  exit 1
fi

# Install the app.asar into the electron package we downloaded
# earlier.
cp -rp tmp/notion/Notion/Notion.app/Contents/Resources/{app.asar.unpacked,app.asar} "$appExtractPath"
cp deps/better_sqlite3.node "$appExtractPath/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
cp notion-rewrapped Notion_app_logo.png tmp/build

# Build the archive
# rm -rf release/*
# "$sevenzip" a "release/notion-$NOTION_VERSION.tar" tmp/build
# "$sevenzip" rn "release/notion-$NOTION_VERSION.tar" tmp/build "notion-$NOTION_VERSION"

# Remove stock app.asar
rm "$appExtractPath/default_app.asar"

mv tmp/build/* release/

set +x

info "Built in 'release/'"
