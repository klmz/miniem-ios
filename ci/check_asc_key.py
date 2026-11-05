"""Checks the App Store Connect API key CI was given, without printing any of it.

Usage: check_asc_key.py <path to .p8>, with ASC_KEY_ID and ASC_ISSUER_ID in the environment.
Exits non-zero, with the reason, when Apple would refuse the key.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import jwt

path = sys.argv[1]
key_id = os.environ.get("ASC_KEY_ID", "").strip()
issuer = os.environ.get("ASC_ISSUER_ID", "").strip()
problems = []

try:
    pem = open(path, encoding="utf-8").read()
except (OSError, UnicodeDecodeError):
    pem = ""
if "-----BEGIN PRIVATE KEY-----" not in pem:
    problems.append(
        "APP_STORE_CONNECT_KEY_BASE64 does not decode to a .p8 private key. Set it to the output of "
        "`base64 -i AuthKey_XXXX.p8 | tr -d '\\n'`, not the file's text."
    )
if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
    problems.append(f"APP_STORE_CONNECT_KEY_ID is not a 10-character key ID (it has {len(key_id)} characters).")
if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", issuer):
    problems.append(
        "APP_STORE_CONNECT_ISSUER_ID is not a UUID. It is shown above the Team Keys table "
        f"(it has {len(issuer)} characters)."
    )
if problems:
    print("\n".join(f"::error::{p}" for p in problems))
    sys.exit(1)

now = int(time.time())
try:
    token = jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        pem,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )
except Exception as error:  # noqa: BLE001
    print(f"::error::The .p8 could not sign a token: {error}")
    sys.exit(1)

request = urllib.request.Request(
    "https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=nl.klmz.miniem&limit=1",
    headers={"Authorization": f"Bearer {token}"},
)
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        apps = json.load(response).get("data", [])
except urllib.error.HTTPError as error:
    detail = error.read().decode("utf-8", "replace")[:400]
    print(f"::error::Apple refused the key ({error.code}): {detail}")
    if error.code == 401:
        print(
            "::error::A 401 means the key ID, the issuer ID and the .p8 do not belong together, or it is an "
            "Individual key: xcodebuild needs a key from the Team Keys tab."
        )
    sys.exit(1)

print("App Store Connect accepted the key.")
# Signing also needs the provisioning part of the API, which a weaker role does not reach.
request = urllib.request.Request(
    "https://api.appstoreconnect.apple.com/v1/certificates?limit=1",
    headers={"Authorization": f"Bearer {token}"},
)
try:
    with urllib.request.urlopen(request, timeout=20):
        print("The key can manage certificates and profiles.")
except urllib.error.HTTPError as error:
    print(f"::error::The key cannot manage certificates and profiles ({error.code}); it needs the Admin role.")
    sys.exit(1)
if not apps:
    print("::warning::No App Store Connect app has bundle ID nl.klmz.miniem yet; the upload will fail without it.")
else:
    print(f"App record found: {apps[0]['attributes'].get('name')}")
