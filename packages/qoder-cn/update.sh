#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKGBUILD_PATH="${SCRIPT_DIR}/PKGBUILD"
SRCINFO_PATH="${SCRIPT_DIR}/.SRCINFO"
RELEASES_URL="${RELEASES_URL:-https://qoder-app.oss-cn-beijing.aliyuncs.com/qoder-app/releases}"
DEB_NAME="Qoder-CN-linux-amd64.deb"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing dependency: %s\n' "$1" >&2
    exit 1
  fi
}

require_command curl
require_command bsdtar
require_command awk
require_command makepkg
require_command sha256sum

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

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# The "latest" URL hides its version number, so read the deb control block
# through a small range request instead of downloading the full archive.
# bsdtar reports the data member as truncated afterwards; the control member
# itself is complete and that is all we need.
curl_retry --range 0-262143 --output "${tmpdir}/head.deb" \
  "${RELEASES_URL}/latest/${DEB_NAME}" >/dev/null
bsdtar -xOf "${tmpdir}/head.deb" control.tar.xz \
  > "${tmpdir}/control.tar.xz" 2>/dev/null || true
pkgver="$(bsdtar -xOf "${tmpdir}/control.tar.xz" ./control 2>/dev/null \
  | awk -F': ' '/^Version:/ {print $2; exit}')"
# drop the deb epoch prefix (e.g. 1:0.4.4) and map dashes to dots for pkgver
pkgver="${pkgver#*:}"
pkgver="${pkgver//-/.}"

if [[ -z "${pkgver}" ]]; then
  printf 'failed to resolve latest Qoder CN deb version\n' >&2
  exit 1
fi

pinned_pkgver="$(awk -F= '/^pkgver=/ {print $2; exit}' "${PKGBUILD_PATH}")"

# Same upstream version: skip the 200+ MB download unless upstream rebuilt
# the artifact, which is detected by comparing the pinned and latest ETags.
if [[ "${pinned_pkgver}" == "${pkgver}" ]]; then
  etag_of() {
    curl_retry --head "$1" \
      | awk 'tolower($1)=="etag:" {gsub(/"/, "", $2); print $2; exit}'
  }
  pinned_etag="$(etag_of "${RELEASES_URL}/${pkgver}/${DEB_NAME}")"
  latest_etag="$(etag_of "${RELEASES_URL}/latest/${DEB_NAME}")"
  if [[ -n "${pinned_etag}" && "${pinned_etag}" == "${latest_etag}" ]]; then
    pinned_pkgrel="$(awk -F= '/^pkgrel=/ {print $2; exit}' "${PKGBUILD_PATH}")"
    printf '%s-%s\n' "${pkgver}" "${pinned_pkgrel}"
    exit 0
  fi
fi

curl_retry --output "${tmpdir}/${DEB_NAME}" \
  "${RELEASES_URL}/${pkgver}/${DEB_NAME}" >/dev/null
source_sha256="$(sha256sum "${tmpdir}/${DEB_NAME}" | awk '{print $1}')"

current_pkgver="$(awk -F= '/^pkgver=/ {print $2; exit}' "${PKGBUILD_PATH}")"
current_pkgrel="$(awk -F= '/^pkgrel=/ {print $2; exit}' "${PKGBUILD_PATH}")"
current_sha256="$(awk -F"'" '$2 ~ /^[0-9a-f]{64}$/ { print $2; exit }' "${PKGBUILD_PATH}")"

if [[ "${current_pkgver}" == "${pkgver}" &&
      "${current_pkgrel}" =~ ^[0-9]+$ &&
      "${current_sha256}" == "${source_sha256}" ]]; then
  pkgrel="${current_pkgrel}"
elif [[ "${current_pkgver}" == "${pkgver}" &&
        "${current_pkgrel}" =~ ^[0-9]+$ &&
        "${current_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
  pkgrel="$((current_pkgrel + 1))"
else
  pkgrel=1
fi

sed -i \
  -e "s/^pkgver=.*/pkgver=${pkgver}/" \
  -e "s/^pkgrel=.*/pkgrel=${pkgrel}/" \
  -e "0,/^[[:space:]]*'[0-9a-f]\\{64\\}'/{s/^[[:space:]]*'[0-9a-f]\\{64\\}'/  '${source_sha256}'/}" \
  "${PKGBUILD_PATH}"

(
  cd "${SCRIPT_DIR}"
  makepkg --printsrcinfo > "${SRCINFO_PATH}"
)

printf '%s-%s\n' "${pkgver}" "${pkgrel}"
