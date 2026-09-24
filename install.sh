#!/bin/sh
set -eu

repo="${NULYA_INSTALL_REPO:-Teamon9161/nulya}"
version="${NULYA_VERSION:-latest}"
install_dir="${NULYA_INSTALL_DIR:-$HOME/.local/bin}"

case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) echo "unsupported OS" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "unsupported architecture" >&2; exit 1 ;;
esac

asset="nulya-$arch-$os"
tui_asset="nulya-tui-$arch-$os"
if [ "$version" = latest ]; then
    base="https://github.com/$repo/releases/latest/download"
else
    case "$version" in v*) tag="$version" ;; *) tag="v$version" ;; esac
    base="https://github.com/$repo/releases/download/$tag"
fi

download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$2" "$1"
    else
        echo "curl or wget is required" >&2
        exit 1
    fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
download "$base/$asset" "$tmp/$asset"
download "$base/$tui_asset" "$tmp/$tui_asset"
download "$base/checksums.txt" "$tmp/checksums.txt"
for file in "$asset" "$tui_asset"; do
    expected="$(awk -v name="$file" '$2 == name { print $1; exit }' "$tmp/checksums.txt")"
    [ -n "$expected" ] || { echo "checksum missing for $file" >&2; exit 1; }
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$tmp/$file" | awk '{ print $1 }')"
    else
        actual="$(shasum -a 256 "$tmp/$file" | awk '{ print $1 }')"
    fi
    [ "$expected" = "$actual" ] || { echo "checksum mismatch for $file" >&2; exit 1; }
done
mkdir -p "$install_dir"
install -m 755 "$tmp/$tui_asset" "$install_dir/nulya-tui"
install -m 755 "$tmp/$asset" "$install_dir/nulya"
echo "Installed nulya and its TUI to $install_dir"
case ":$PATH:" in
    *":$install_dir:"*) ;;
    *)
        if [ "$install_dir" = "$HOME/.local/bin" ]; then
            case "${SHELL##*/}" in
                zsh) profile="${ZDOTDIR:-$HOME}/.zshrc" ;;
                bash) profile="$HOME/.bashrc" ;;
                *) profile="$HOME/.profile" ;;
            esac
            line='export PATH="$HOME/.local/bin:$PATH"'
            if ! grep -Fqx "$line" "$profile" 2>/dev/null; then
                printf '\n%s\n' "$line" >> "$profile"
            fi
            echo "Added ~/.local/bin to PATH in $profile; open a new terminal."
        else
            echo "Add $install_dir to PATH before running nulya."
        fi
        ;;
esac
echo "Run: nulya"
