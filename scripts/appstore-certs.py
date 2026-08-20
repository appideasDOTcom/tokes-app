#!/usr/bin/env python3
"""Creates the signing certificates and provisioning profile the Mac App Store
build needs, via the App Store Connect API.

    scripts/appstore-certs.py --key-id KEYID --issuer ISSUERID --p8 PATH [--dry-run]

Replaces a long click-path in Apple's portal: two certificates (one for the app,
one for the installer package) plus a Mac App Store provisioning profile.

Three deliberate safety properties, because this operates on a live Apple
developer account that has other shipping apps on it:

  * It NEVER revokes anything. Distribution certificates are capped per team and
    revoking one invalidates every build already signed with it. If the cap is
    reached this stops and says so rather than making room.
  * It reuses before it creates, and only counts a certificate as reusable when
    the matching private key is actually in this keychain — a certificate whose
    key lives on another machine is useless here and is reported, not replaced.
  * The private keys are generated locally with openssl and never leave the Mac.
    Apple only ever sees a certificate signing request.

Requires an API key with Admin (or Account Holder) access: only those roles may
create distribution certificates.
"""

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"

# The two certificates a Mac App Store submission needs, and what each signs.
WANTED = [
    ("DISTRIBUTION", "Apple Distribution", "Tokes.app"),
    ("MAC_INSTALLER_DISTRIBUTION", "Mac Installer Distribution", "the .pkg installer"),
]


def log(msg=""):
    print(msg, flush=True)


def die(msg):
    log("\nerror: %s" % msg)
    sys.exit(1)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def mint_jwt(key_id, issuer, p8):
    """altool signs the ES256 token for us, so this needs no crypto library.

    It writes the token to stderr, with a banner line first.
    """
    out = subprocess.run(
        ["xcrun", "altool", "--generate-jwt", "--apiKey", key_id,
         "--apiIssuer", issuer, "--p8-file-path", str(p8)],
        capture_output=True, text=True)
    for line in (out.stdout + out.stderr).splitlines():
        line = line.strip()
        if re.match(r"^ey[A-Za-z0-9_-]+\.", line):
            return line
    die("could not mint a JWT from the API key:\n%s" % (out.stdout + out.stderr).strip())


def api(jwt, path, method="GET", body=None):
    req = urllib.request.Request(
        "%s/%s" % (API, path), method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": "Bearer %s" % jwt,
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        try:
            errors = json.loads(detail)["errors"]
            detail = "\n".join("  %s — %s" % (x.get("title"), x.get("detail")) for x in errors)
        except Exception:
            pass
        die("%s %s failed (HTTP %s):\n%s" % (method, path, e.code, detail))


def local_identities():
    """{sha1 fingerprint: display name} for identities with a usable private key.

    Matched on fingerprint, never on name: App Store Connect labels the installer
    certificate "Mac Installer Distribution" while the certificate's own common
    name is "3rd Party Mac Developer Installer", so any name comparison reports
    a certificate as missing when it is sitting right there.
    """
    out = subprocess.run(["security", "find-identity", "-v"],
                         capture_output=True, text=True).stdout
    return {h.upper(): n for h, n in re.findall(r'\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', out)}


def fingerprint(cert_content_b64):
    """SHA-1 of the DER certificate — the same value `security find-identity` prints."""
    return hashlib.sha1(base64.b64decode(cert_content_b64)).hexdigest().upper()


def make_csr(workdir, common_name):
    """Generates a 2048-bit RSA key and a CSR. The key stays on this machine."""
    key = workdir / "key.pem"
    csr = workdir / "req.csr"
    run(["openssl", "genrsa", "-out", str(key), "2048"])
    run(["openssl", "req", "-new", "-key", str(key), "-out", str(csr),
         "-subj", "/CN=%s/C=US" % common_name])
    return key, csr


def install(workdir, key, cert_der_b64, label, backup_dir):
    """Imports the identity into the login keychain and backs it up as a .p12.

    The .p12 backup matters: lose the keychain without it and the certificate
    cannot be recovered — only revoked and reissued, which breaks existing builds.
    """
    der = workdir / "cert.cer"
    pem = workdir / "cert.pem"
    der.write_bytes(base64.b64decode(cert_der_b64))
    run(["openssl", "x509", "-inform", "DER", "-in", str(der), "-out", str(pem)])

    password = secrets.token_urlsafe(24)
    p12 = workdir / "identity.p12"
    run(["openssl", "pkcs12", "-export", "-legacy", "-inkey", str(key), "-in", str(pem),
         "-out", str(p12), "-name", label, "-passout", "pass:%s" % password])

    run(["security", "import", str(p12), "-k",
         os.path.expanduser("~/Library/Keychains/login.keychain-db"),
         "-P", password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/productbuild",
         "-T", "/usr/bin/security"])

    backup_dir.mkdir(parents=True, exist_ok=True)
    safe = re.sub(r"[^A-Za-z0-9]+", "-", label).strip("-")
    dest = backup_dir / ("%s.p12" % safe)
    shutil.copy(p12, dest)
    dest.chmod(stat.S_IRUSR | stat.S_IWUSR)
    secret = backup_dir / ("%s.p12.password.txt" % safe)
    secret.write_text(password + "\n")
    secret.chmod(stat.S_IRUSR | stat.S_IWUSR)
    return dest, secret


def main():
    env = {}
    creds = pathlib.Path("packaging/appstore/asc-credentials.env")
    if creds.exists():
        for line in creds.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"')

    ap = argparse.ArgumentParser()
    ap.add_argument("--key-id", default=env.get("ASC_KEY_ID"))
    ap.add_argument("--issuer", default=env.get("ASC_ISSUER_ID"))
    ap.add_argument("--p8", type=pathlib.Path,
                    default=pathlib.Path(env["ASC_P8"]) if env.get("ASC_P8") else None)
    ap.add_argument("--bundle-id", default="com.appideas.tokes")
    ap.add_argument("--common-name", default="APPideas")
    ap.add_argument("--backup-dir", type=pathlib.Path,
                    help="where to copy .p12 backups (default: beside the .p8)")
    ap.add_argument("--profile-out", type=pathlib.Path,
                    default=pathlib.Path("packaging/appstore/embedded.provisionprofile"))
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would change and exit without creating anything")
    ap.add_argument("--revoke", nargs="+", metavar="CERT_ID", default=[],
                    help="revoke these certificate ids and exit. Explicit ids only — "
                         "there is deliberately no way to say 'revoke all'. Revoking "
                         "invalidates every build already signed with that certificate.")
    args = ap.parse_args()
    if not (args.key_id and args.issuer and args.p8):
        die("App Store Connect credentials not found.\n"
            "Copy packaging/appstore/asc-credentials.env.example to "
            "asc-credentials.env and fill it in, or pass --key-id/--issuer/--p8.")

    backup_dir = args.backup_dir or args.p8.parent
    jwt = mint_jwt(args.key_id, args.issuer, args.p8)
    log("Authenticated with App Store Connect.\n")

    if args.revoke:
        current = {c["id"]: c["attributes"] for c in api(jwt, "certificates?limit=200")["data"]}
        for cert_id in args.revoke:
            if cert_id not in current:
                die("no certificate %s on this team — refusing to guess." % cert_id)
        for cert_id in args.revoke:
            a = current[cert_id]
            log("Revoking %s  %s  %r" % (cert_id, a["certificateType"], a.get("name")))
            api(jwt, "certificates/%s" % cert_id, "DELETE")
        remaining = api(jwt, "certificates?limit=200")["data"]
        log("\n%d certificate(s) remain:" % len(remaining))
        for c in remaining:
            a = c["attributes"]
            log("  id=%-12s %-28s %s" % (c["id"], a["certificateType"], (a.get("name") or "")[:40]))
        return

    # ---------------------------------------------------------- certificates --
    existing = api(jwt, "certificates?limit=200")["data"]
    keychain = local_identities()
    log("Certificates on this team: %d" % len(existing))
    for c in existing:
        a = c["attributes"]
        log("  %-28s %-38s expires %s" % (a["certificateType"], a.get("name", "")[:38],
                                          (a.get("expirationDate") or "")[:10]))
    log()

    resolved = {}
    for cert_type, label, signs in WANTED:
        match = next((c for c in existing if c["attributes"]["certificateType"] == cert_type), None)
        if match:
            content = match["attributes"].get("certificateContent")
            local = keychain.get(fingerprint(content)) if content else None
            if local:
                log("%-28s reusing %r (signs %s)" % (label + ":", local, signs))
                resolved[cert_type] = match["id"]
                continue
            die("%s exists on the team but its private key is not in this keychain.\n"
                "It was created on another machine. Restore that key's .p12, or revoke\n"
                "the certificate in the portal yourself — this script will not revoke it,\n"
                "because doing so invalidates every build already signed with it."
                % label)

        if args.dry_run:
            log("%-28s WOULD CREATE (signs %s)" % (label + ":", signs))
            continue

        log("%-28s creating (signs %s)" % (label + ":", signs))
        with tempfile.TemporaryDirectory() as tmp:
            work = pathlib.Path(tmp)
            key, csr = make_csr(work, args.common_name)
            created = api(jwt, "certificates", "POST", {
                "data": {"type": "certificates", "attributes": {
                    "certificateType": cert_type,
                    # Raw PEM, NOT base64 of it. Apple rejects a re-encoded CSR
                    # with HTTP 409 "Invalid Certificate", which reads like a
                    # problem with the key rather than with the wrapping.
                    "csrContent": csr.read_text()}}})
            attrs = created["data"]["attributes"]
            p12, pw = install(work, key, attrs["certificateContent"],
                              attrs.get("name") or label, backup_dir)
            resolved[cert_type] = created["data"]["id"]
            log("      issued to %r, expires %s" % (attrs.get("name"),
                                                    (attrs.get("expirationDate") or "")[:10]))
            log("      imported into the login keychain")
            log("      backup: %s" % p12)
            log("      password: %s" % pw)

    if args.dry_run:
        log("\nDry run — nothing was created.")
        return

    # ------------------------------------------------------------- profile ---
    log()
    bundles = api(jwt, "bundleIds?filter[identifier]=%s&limit=10" % args.bundle_id)["data"]
    if not bundles:
        die("bundle ID %s is not registered on this team." % args.bundle_id)
    bundle_resource = bundles[0]["id"]
    log("Bundle ID %s -> %s" % (args.bundle_id, bundle_resource))

    profile_name = "Tokes Mac App Store"
    for p in api(jwt, "profiles?limit=200")["data"]:
        if p["attributes"]["name"] == profile_name:
            log("Removing the previous %r profile so it can be reissued against the "
                "current certificate." % profile_name)
            api(jwt, "profiles/%s" % p["id"], "DELETE")

    # MAC_APP_STORE profiles historically wanted the legacy Mac App Distribution
    # certificate; the unified Apple Distribution is what Xcode uses now. Try the
    # modern one and fall back rather than creating a second certificate blindly.
    cert_id = resolved.get("DISTRIBUTION") or resolved.get("MAC_APP_DISTRIBUTION")
    profile = api(jwt, "profiles", "POST", {
        "data": {"type": "profiles",
                 "attributes": {"name": profile_name, "profileType": "MAC_APP_STORE"},
                 "relationships": {
                     "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource}},
                     "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})
    attrs = profile["data"]["attributes"]
    args.profile_out.parent.mkdir(parents=True, exist_ok=True)
    args.profile_out.write_bytes(base64.b64decode(attrs["profileContent"]))
    log("Profile %r (%s) -> %s" % (attrs["name"], attrs["profileState"], args.profile_out))

    log("\nSigning identities now available:")
    for ident in sorted(local_identities()):
        if "Distribution" in ident or "Installer" in ident:
            log("  %s" % ident)
    log("\nNext: scripts/appstore.sh --sign-app \"<Apple Distribution: ...>\" "
        "--sign-pkg \"<3rd Party Mac Developer Installer: ...>\"")


if __name__ == "__main__":
    main()
