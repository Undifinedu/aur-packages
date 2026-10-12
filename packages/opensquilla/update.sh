#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKGBUILD_PATH="${SCRIPT_DIR}/PKGBUILD"
SRCINFO_PATH="${SCRIPT_DIR}/.SRCINFO"
RELEASES_URL="${RELEASES_URL:-https://api.github.com/repos/TokenRhythm/opensquilla/releases/latest}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing dependency: %s\n' "$1" >&2
    exit 1
  fi
}

require_command curl
require_command jq
require_command awk
require_command makepkg

is_sha256() { # 判断参数是否为 64 位十六进制的 sha256 校验值
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

curl_retry() {
  curl \
    --fail \
    --location \
    --show-error \
    --silent \
    --retry 6 \
    --retry-delay 5 \
    --retry-max-time 180 \
    --retry-connrefused \
    --retry-all-errors \
    --connect-timeout 20 \
    "$@"
}

release_json="$(curl_retry "${RELEASES_URL}")"
pkgver="$(printf '%s\n' "${release_json}" | jq -r '.tag_name | ltrimstr("v")')"
dmg_sha256="$(printf '%s\n' "${release_json}" | jq -r --arg pkgver "${pkgver}" '.assets[] | select(.name == ("OpenSquilla-" + $pkgver + "-mac-arm64.dmg")) | .digest | sub("^sha256:"; "")')"
whl_sha256="$(printf '%s\n' "${release_json}" | jq -r --arg pkgver "${pkgver}" '.assets[] | select(.name == ("opensquilla-" + $pkgver + "-py3-none-any.whl")) | .digest | sub("^sha256:"; "")')"

if [[ -z "${pkgver}" ]] ||
     ! is_sha256 "${dmg_sha256}" ||
     ! is_sha256 "${whl_sha256}"; then
  printf 'failed to resolve latest OpenSquilla macOS release metadata\n' >&2
  exit 1
fi

current_pkgver="$(awk -F= '/^pkgver=/ {print $2; exit}' "${PKGBUILD_PATH}")"
current_pkgrel="$(awk -F= '/^pkgrel=/ {print $2; exit}' "${PKGBUILD_PATH}")"
current_dmg_sha256="$(awk -F"'" '$2 ~ /^[0-9a-f]{64}$/ { count++; if (count == 1) { print $2; exit } }' "${PKGBUILD_PATH}")"
current_whl_sha256="$(awk -F"'" '$2 ~ /^[0-9a-f]{64}$/ { count++; if (count == 2) { print $2; exit } }' "${PKGBUILD_PATH}")"

# 两个旧校验值同时是 sed 的替换锚点：提取失败、格式异常、两值相同（锚点退化）都直接报错退出
if ! is_sha256 "${current_dmg_sha256}" ||
     ! is_sha256 "${current_whl_sha256}" ||
     [[ "${current_dmg_sha256}" == "${current_whl_sha256}" ]]; then
  printf 'failed to locate distinct sha256 values in %s\n' "${PKGBUILD_PATH}" >&2
  exit 1
fi

if [[ "${current_pkgver}" == "${pkgver}" &&
      "${current_pkgrel}" =~ ^[0-9]+$ &&
      "${current_dmg_sha256}" == "${dmg_sha256}" &&
      "${current_whl_sha256}" == "${whl_sha256}" ]]; then
  pkgrel="${current_pkgrel}"
elif [[ "${current_pkgver}" == "${pkgver}" && "${current_pkgrel}" =~ ^[0-9]+$ ]]; then
  pkgrel="$((current_pkgrel + 1))"
else
  pkgrel=1
fi

sed -i \
  -e "s/^pkgver=.*/pkgver=${pkgver}/" \
  -e "s/^pkgrel=.*/pkgrel=${pkgrel}/" \
  -e "s/${current_dmg_sha256}/${dmg_sha256}/" \
  -e "s/${current_whl_sha256}/${whl_sha256}/" \
  "${PKGBUILD_PATH}"

(
  cd "${SCRIPT_DIR}"
  makepkg --printsrcinfo > "${SRCINFO_PATH}"
)

printf '%s-%s\n' "${pkgver}" "${pkgrel}"
