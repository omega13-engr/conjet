#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: build-native-core-assets.sh OUTPUT_DIRECTORY" >&2
  exit 2
fi

root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
output="$1"
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "native Core assets output already exists: $output" >&2
  exit 1
fi

stage="$(mktemp -d "$(dirname -- "$output")/.conjet-native-core.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT

compiler=("${CONJET_NATIVE_CC:-musl-gcc}")
if [ -n "${CONJET_NATIVE_UAPI_DIR:-}" ]; then
  compiler+=(-idirafter "$CONJET_NATIVE_UAPI_DIR")
fi
for helper in conjet-memd conjet-reclaimd; do
  "${compiler[@]}" -static -O2 -Wall -Wextra -pthread \
    "$root/guest/image/conjet-core/src/$helper.c" -o "$stage/$helper"
  case "$(file -b "$stage/$helper")" in
    "ELF 64-bit LSB "*"ARM aarch64"*"statically linked"*) ;;
    *) echo "expected a static AArch64 Linux executable: $helper" >&2; exit 1 ;;
  esac
done

curl --disable --fail --silent --show-error --location --max-redirs 4 \
  --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 90 --retry 2 \
  --output "$stage/Image" \
  'https://github.com/omega13-engr/conjet/releases/download/conjet-core-v1.3.1/conjet-linux-6.12.86-aarch64-Image'
(cd "$stage" && shasum -a 512 -c "$root/build-support/native-core-kernel.sha512")

mkdir -m 0755 "$output"
install -m 0644 "$stage/Image" "$stage/conjet-memd" "$stage/conjet-reclaimd" "$output/"
install -m 0644 "$root/build-support/native-core-kernel.sha512" "$output/kernel.sha512"
