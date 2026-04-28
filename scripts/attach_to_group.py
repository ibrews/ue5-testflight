#!/usr/bin/env python3
"""Poll ASC until the latest build is VALID, then attach it to the external TestFlight group.

visionOS builds take 30+ minutes to process; iOS typically 5–10 min.
This script polls for up to 60 minutes and exits cleanly either way.

Usage:
    attach_to_group.py [ios|visionos]   (platform filter, default: ios)

Config is read from ue5kit.conf (sourced as shell vars, parsed here as KEY=VALUE).
"""
import urllib.request, urllib.error, json, base64, time, sys, os, re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONF_PATH  = os.path.join(SCRIPT_DIR, "..", "ue5kit.conf")
PLATFORM_FILTER = sys.argv[1].upper() if len(sys.argv) > 1 else "IOS"
# Map CLI arg to ASC API platform value
_PLATFORM_MAP = {"VISIONOS": "VISION_OS", "MACOS": "MAC_OS", "IOS": "IOS"}
ASC_PLATFORM = _PLATFORM_MAP.get(PLATFORM_FILTER, "IOS")
MAX_POLLS = 60   # 60 × 60s = 60 min


def load_conf(path):
    conf = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            v = v.strip().strip('"').strip("'")
            conf[k.strip()] = v
    return conf


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_jwt(key_id, issuer_id, key_path):
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

    now = int(time.time())
    hdr = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    pay = b64url(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 1200,
                              "aud": "appstoreconnect-v1"}).encode())
    msg = (hdr + "." + pay).encode()
    with open(os.path.expanduser(key_path), "rb") as f:
        key = load_pem_private_key(f.read(), None)
    sig = key.sign(msg, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(sig)
    return hdr + "." + pay + "." + b64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


def asc_request(method, path, conf, body=None):
    jwt = make_jwt(conf["ASC_KEY_ID"], conf["ASC_ISSUER_ID"], conf["ASC_KEY_PATH"])
    url = "https://api.appstoreconnect.apple.com" + path
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method,
                                  headers={"Authorization": "Bearer " + jwt,
                                           "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return e.code, {}


def main():
    if not os.path.exists(CONF_PATH):
        print(f"ERROR: ue5kit.conf not found at {CONF_PATH}")
        sys.exit(1)

    conf = load_conf(CONF_PATH)
    app_id       = conf["ASC_APP_ID"]
    ext_group_id = conf["ASC_EXTERNAL_GROUP_ID"]

    print(f"Polling ASC for VALID {ASC_PLATFORM} build (up to {MAX_POLLS} min)...")

    build_id = None
    for attempt in range(MAX_POLLS):
        time.sleep(60)
        try:
            status, data = asc_request("GET",
                f"/v1/builds?filter[app]={app_id}"
                f"&filter[preReleaseVersion.platform]={ASC_PLATFORM}"
                f"&sort=-uploadedDate&limit=1"
                f"&fields[builds]=processingState,version",
                conf)
            builds = data.get("data", []) if status == 200 else []
            if builds:
                b = builds[0]
                state = b["attributes"]["processingState"]
                ver   = b["attributes"]["version"]
                print(f"[{attempt+1}/{MAX_POLLS}] Build {ver}: {state}")
                if state == "VALID":
                    build_id = b["id"]
                    break
                elif state in ("INVALID", "FAILED"):
                    print(f"Build processing failed with state: {state}")
                    sys.exit(1)
            else:
                print(f"[{attempt+1}/{MAX_POLLS}] No builds found yet (HTTP {status})")
        except Exception as e:
            print(f"[{attempt+1}/{MAX_POLLS}] Poll error: {e}")

    if not build_id:
        print(f"No VALID build found within {MAX_POLLS} minutes.")
        print("Re-run this script manually once the build processes: python3 attach_to_group.py")
        sys.exit(0)

    # 1. Attach to external group (required for external visibility, but not sufficient on its own)
    status, _ = asc_request("POST",
        f"/v1/betaGroups/{ext_group_id}/relationships/builds",
        conf,
        {"data": [{"type": "builds", "id": build_id}]})
    if status in (200, 201, 204):
        print(f"Attached build {build_id} to external TestFlight group (HTTP {status})")
    else:
        print(f"Attach failed HTTP {status}. Attach manually in ASC or re-run this script.")

    # 2. Submit for Beta App Review — REQUIRED to actually push the build to external testers.
    #    Without this, externalBuildState stays at READY_FOR_BETA_SUBMISSION and the build
    #    never appears in the external group's build list. Apple typically auto-approves
    #    repeat submissions of the same app within seconds.
    status, body = asc_request("POST",
        "/v1/betaAppReviewSubmissions",
        conf,
        {"data": {"type": "betaAppReviewSubmissions",
                  "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    if status in (200, 201):
        print(f"Submitted build {build_id} for Beta App Review — external testers will be notified once approved")
    else:
        print(f"Beta App Review submit failed HTTP {status}: {str(body)[:200]}")
        print("If this build is already in review, that's fine. Otherwise submit manually in ASC.")

    print("Internal group (hasAccessToAllBuilds=true) distributes automatically.")


if __name__ == "__main__":
    main()
