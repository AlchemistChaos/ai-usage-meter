#!/bin/bash
# Configures the five GitHub secrets needed to publish signed, notarized
# releases. Run once:  ./scripts/setup-signing.sh
#
# Nothing is written to disk that outlives the script, and no secret is echoed.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
echo "Configuring signing secrets for $REPO"
echo

command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run: gh auth login"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- certificate
echo "1/3  Developer ID certificate"
IDENTITIES=$(security find-identity -v -p codesigning | grep "Developer ID Application" || true)
if [[ -z "$IDENTITIES" ]]; then
  echo "     No Developer ID Application certificate found in your keychain."
  echo "     Create one at https://developer.apple.com/account/resources/certificates"
  exit 1
fi
echo "$IDENTITIES" | sed 's/^/     /'

TEAM_ID=$(echo "$IDENTITIES" | head -1 | sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/')
CERT_NAME=$(echo "$IDENTITIES" | head -1 | sed -E 's/.*"(.*)"/\1/')
echo "     Using: $CERT_NAME"
echo

# The .p12 needs an export password; it becomes the CSC_KEY_PASSWORD secret.
echo -n "     Choose a password to protect the exported certificate: "
read -rs P12_PASS; echo
[[ -n "$P12_PASS" ]] || { echo "     Password cannot be empty."; exit 1; }

echo "     Exporting… (macOS will ask permission to read the private key)"
security export -t identities -f pkcs12 -P "$P12_PASS" -o "$TMP/cert.p12" \
  2>/dev/null || {
    echo "     Export failed. Grant access when macOS prompts, then retry."
    exit 1
  }

base64 -i "$TMP/cert.p12" | gh secret set CSC_LINK --repo "$REPO"
printf '%s' "$P12_PASS" | gh secret set CSC_KEY_PASSWORD --repo "$REPO"
printf '%s' "$TEAM_ID"  | gh secret set APPLE_TEAM_ID   --repo "$REPO"
unset P12_PASS
echo "     ✓ CSC_LINK, CSC_KEY_PASSWORD, APPLE_TEAM_ID  (team $TEAM_ID)"
echo

# ------------------------------------------------------------------ apple id
echo "2/3  Apple ID"
echo -n "     Apple Developer account email: "
read -r APPLE_ID
[[ -n "$APPLE_ID" ]] || { echo "     Required."; exit 1; }
printf '%s' "$APPLE_ID" | gh secret set APPLE_ID --repo "$REPO"
echo "     ✓ APPLE_ID"
echo

# ------------------------------------------------------- app-specific password
echo "3/3  App-specific password (for notarization)"
echo "     Generate one at https://appleid.apple.com → Sign-In and Security"
echo "     → App-Specific Passwords. Format: abcd-efgh-ijkl-mnop"
echo -n "     Paste it: "
read -rs ASP; echo
[[ -n "$ASP" ]] || { echo "     Required."; exit 1; }
printf '%s' "$ASP" | gh secret set APPLE_APP_SPECIFIC_PASSWORD --repo "$REPO"
unset ASP
echo "     ✓ APPLE_APP_SPECIFIC_PASSWORD"
echo

echo "Done. Configured secrets:"
gh secret list --repo "$REPO" | sed 's/^/  /'
echo
echo "Cut a signed, notarized release with:"
echo "  git tag v0.1.0 && git push --tags"
