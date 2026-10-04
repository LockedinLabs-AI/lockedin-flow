#!/usr/bin/env bash
# Install/remove only this candidate on an ephemeral GitHub Linux runner.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_OS:-}" != Linux || "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
  echo 'This destructive installation test is restricted to an ephemeral Linux CI runner.' >&2
  exit 1
fi
cd "$(dirname "$0")/.."
shopt -s nullglob
packages=(target/release/bundle/deb/*.deb)
if [[ ${#packages[@]} != 1 ]]; then
  echo 'Expected exactly one DEB package.' >&2
  exit 1
fi
package_name=$(dpkg-deb --field "${packages[0]}" Package)
if [[ ! "$package_name" =~ ^locked-?in-flow(-desktop)?$ ]]; then
  echo 'Refusing to install an unexpected package identity.' >&2
  exit 1
fi
if dpkg-query --show "$package_name" >/dev/null 2>&1; then
  echo 'Refusing to replace a pre-existing system package.' >&2
  exit 1
fi
cleanup() {
  local result=$?
  trap - EXIT
  sudo dpkg --remove "$package_name" || result=1
  exit "$result"
}
trap cleanup EXIT
sudo dpkg --install "${packages[0]}"
mapfile -t files < <(dpkg-query --listfiles "$package_name")
models=()
for file in "${files[@]}"; do
  case "$file" in
    */models/ggml-base.en.bin) models+=("$file") ;;
  esac
done
[[ ${#models[@]} == 1 ]]
model="${models[0]}"
[[ "$(sha256sum -- "$model" | cut -d ' ' -f 1)" == a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002 ]]
resources="${model%/models/ggml-base.en.bin}"
for name in SBOM.cdx.json THIRD-PARTY-NOTICES.txt LICENSE.txt MODEL.json; do
  cmp -- "app/resources/compliance/$name" "$resources/compliance/$name"
done
[[ -x /usr/bin/lockedin-flow-desktop ]]
node --input-type=module <<'NODE'
import { boundedFile, debApplicationDigest, digest, limits } from './scripts/linux-package-evidence.mjs';
const reference = await boundedFile('target/release/lockedin-flow-desktop', limits.file);
const installed = await boundedFile('/usr/bin/lockedin-flow-desktop', limits.file);
if (digest(installed) !== debApplicationDigest(reference)) {
  throw new Error('Installed application integrity check failed.');
}
NODE
# Run the installed executable as the ordinary runner user, with its own X/DBus
# session and no external network interface. Do not request microphone access.
sudo unshare --net -- runuser -u "$(id -un)" -- env \
  GITHUB_ACTIONS=true RUNNER_OS=Linux RUNNER_ENVIRONMENT=github-hosted \
  PATH="$PATH" dbus-run-session -- xvfb-run -a node scripts/test-linux-launch.mjs
sudo dpkg --remove "$package_name"
trap - EXIT
[[ ! -e /usr/bin/lockedin-flow-desktop && ! -e "$model" ]]
git diff --exit-code -- Cargo.lock package-lock.json
echo 'DEB installation, resource integrity, and removal passed.'
