"""Creates fresh App Store provisioning profiles for the app and its widget, signed with the
team's distribution certificate (the one in the keychain), and installs them.

Usage: make_profiles.py <.p8 path> <certificate serial (hex)> <output plist fragment path>
Each run replaces the previous run's profiles, so they never expire or pile up.
"""
import base64
import os
import plistlib
import sys

from asc import AscError, call, token

BUNDLES = ["nl.klmz.miniem", "nl.klmz.miniem.widget"]
PREFIX = "Miniem CI "
APP_GROUP = "group.nl.klmz.miniem"

pem_path, serial, fragment_path = sys.argv[1], sys.argv[2].upper().lstrip("0"), sys.argv[3]
bearer = token(pem_path)

try:
    certificates = call(bearer, "GET", "/v1/certificates?limit=200")["data"]
except AscError as error:
    print(f"::error::The key cannot read certificates ({error}). It needs the Admin role.")
    sys.exit(1)
certificate = next(
    (c for c in certificates if c["attributes"].get("serialNumber", "").upper().lstrip("0") == serial), None
)
if certificate is None:
    print("::error::The certificate in IOS_CERTIFICATE_P12_BASE64 is not one of this team's certificates "
          "(revoked, or from another team).")
    sys.exit(1)
print(f"Signing with {certificate['attributes'].get('certificateType')} certificate "
      f"'{certificate['attributes'].get('name')}', expires {certificate['attributes'].get('expirationDate')}")

existing = call(bearer, "GET", "/v1/profiles?limit=200")["data"]
mapping = {}
directories = [
    os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
    os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),
]
for directory in directories:
    os.makedirs(directory, exist_ok=True)

for identifier in BUNDLES:
    bundle = call(bearer, "GET", f"/v1/bundleIds?filter[identifier]={identifier}&limit=5")["data"]
    bundle = next((b for b in bundle if b["attributes"]["identifier"] == identifier), None)
    if bundle is None:
        print(f"::error::App ID {identifier} is not registered (Certificates, Identifiers & Profiles).")
        sys.exit(1)
    name = PREFIX + identifier
    for old in existing:
        if old["attributes"]["name"] == name:
            call(bearer, "DELETE", f"/v1/profiles/{old['id']}")
    created = call(bearer, "POST", "/v1/profiles", {
        "data": {
            "type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": certificate["id"]}]},
            },
        }
    })["data"]
    content = base64.b64decode(created["attributes"]["profileContent"])
    uuid = created["attributes"]["uuid"]
    # The profile is a signed plist; its entitlements say what the App ID really allows.
    start, end = content.find(b"<?xml"), content.find(b"</plist>")
    entitlements = plistlib.loads(content[start:end + len(b"</plist>")]).get("Entitlements", {})
    groups = entitlements.get("com.apple.security.application-groups", [])
    if APP_GROUP not in groups:
        print(f"::error::App ID {identifier} has no access to {APP_GROUP}. At developer.apple.com → "
              f"Identifiers → {identifier} → App Groups → Configure, tick {APP_GROUP} and save.")
        sys.exit(1)
    for directory in directories:
        with open(os.path.join(directory, f"{uuid}.mobileprovision"), "wb") as handle:
            handle.write(content)
    mapping[identifier] = name
    print(f"Installed profile '{name}' ({uuid})")

with open(fragment_path, "wb") as handle:
    plistlib.dump(mapping, handle)
