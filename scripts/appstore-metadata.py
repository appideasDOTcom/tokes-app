#!/usr/bin/env python3
"""Pushes the App Store listing text from the repo to App Store Connect.

    scripts/appstore-metadata.py [--dry-run]

packaging/appstore/listing.md is the source of truth; App Store Connect is a
render target. Nothing is authored in the web UI — that way "what is live" is
answerable by reading the repo, a bad change is a revert, and the copy that
ships has been through review like any other change.

Idempotent: it diffs current against desired and PATCHes only what differs, so
running it twice is a no-op and running it after a manual web edit shows exactly
what drifted.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
LISTING = pathlib.Path("packaging/appstore/listing.md")

# Apple's limits. Re-checked here as well as in the listing doc: this is the
# last gate before the text is live, and a silent truncation is worse than a
# refusal.
LIMITS = {"name": 30, "subtitle": 30, "keywords": 100,
          "promotionalText": 170, "description": 4000}


def die(msg):
    print("error: %s" % msg, file=sys.stderr)
    sys.exit(1)


def creds():
    env = {}
    f = pathlib.Path("packaging/appstore/asc-credentials.env")
    if f.exists():
        for line in f.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"')
    for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_P8"):
        if not env.get(k):
            die("%s not set. See packaging/appstore/asc-credentials.env.example" % k)
    return env


def jwt(env):
    out = subprocess.run(
        ["xcrun", "altool", "--generate-jwt", "--apiKey", env["ASC_KEY_ID"],
         "--apiIssuer", env["ASC_ISSUER_ID"], "--p8-file-path", env["ASC_P8"]],
        capture_output=True, text=True)
    for line in (out.stdout + out.stderr).splitlines():
        if re.match(r"^ey[A-Za-z0-9_-]+\.", line.strip()):
            return line.strip()
    die("could not mint a JWT")


def api(token, path, method="GET", body=None):
    req = urllib.request.Request(
        "%s/%s" % (API, path), method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": "Bearer %s" % token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        try:
            detail = "\n".join("  %s — %s" % (x.get("title"), x.get("detail"))
                               for x in json.loads(detail)["errors"])
        except Exception:
            pass
        die("%s %s (HTTP %s):\n%s" % (method, path, e.code, detail))


def parse_listing():
    """Reads the fenced blocks and the URL table out of listing.md.

    Deliberately positional over the fences, matching the document's own order,
    so the doc stays readable prose rather than becoming a config file.
    """
    text = LISTING.read_text()
    blocks = re.findall(r"```\n(.*?)\n```", text, re.S)
    if len(blocks) < 5:
        die("expected 5 copy blocks in %s, found %d" % (LISTING, len(blocks)))
    name, subtitle, keywords, promo, description = [b.strip() for b in blocks[:5]]

    urls = dict(re.findall(r"^\|\s*([^|]+?)\s*\|\s*`([^`]+)`\s*\|", text, re.M))
    def url(label):
        for k, v in urls.items():
            if label.lower() in k.lower():
                return v
        die("no %s URL row found in %s" % (label, LISTING))

    return {
        "name": name, "subtitle": subtitle, "keywords": keywords,
        "promotionalText": promo, "description": description,
        "supportUrl": url("Support"), "marketingUrl": url("Marketing"),
        # Required to submit, and it lives on appInfoLocalizations rather than
        # the version — which is why it was missing for so long: the version
        # localization pushed cleanly and nothing reported the gap.
        "privacyPolicyUrl": url("Privacy"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", default="com.appideas.tokes")
    ap.add_argument("--locale", default="en-US")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    want = parse_listing()
    for field, limit in LIMITS.items():
        n = len(want[field])
        if n > limit:
            die("%s is %d characters, limit %d — fix %s" % (field, n, limit, LISTING))
        print("  %-16s %4d/%-5d ok" % (field, n, limit))
    print()

    token = jwt(creds())
    apps = api(token, "apps?filter[bundleId]=%s" % args.bundle_id)["data"]
    if not apps:
        die("no App Store Connect record for %s" % args.bundle_id)
    app_id = apps[0]["id"]

    # name and subtitle live on appInfoLocalizations; the rest on the version.
    info_id = api(token, "apps/%s/appInfos?limit=1" % app_id)["data"][0]["id"]
    version = api(token, "apps/%s/appStoreVersions?limit=1" % app_id)["data"][0]
    print("Version %s (%s)\n" % (version["attributes"]["versionString"],
                                 version["attributes"]["appStoreState"]))

    targets = [
        ("appInfoLocalizations",
         api(token, "appInfos/%s/appInfoLocalizations" % info_id)["data"],
         ["name", "subtitle", "privacyPolicyUrl"]),
        ("appStoreVersionLocalizations",
         api(token, "appStoreVersions/%s/appStoreVersionLocalizations" % version["id"])["data"],
         ["description", "keywords", "promotionalText", "supportUrl", "marketingUrl"]),
    ]

    changed = 0
    for resource, rows, fields in targets:
        row = next((r for r in rows if r["attributes"].get("locale") == args.locale), None)
        if not row:
            die("no %s localization for %s" % (args.locale, resource))
        delta = {f: want[f] for f in fields if (row["attributes"].get(f) or "") != want[f]}
        for f in fields:
            current = row["attributes"].get(f) or ""
            mark = "->" if f in delta else "= "
            preview = want[f].replace("\n", " ")[:60]
            print("  %s %-16s %s" % (mark, f, preview + ("…" if len(want[f]) > 60 else "")))
            if f in delta and current:
                print("     was: %s%s" % (current.replace("\n", " ")[:60],
                                          "…" if len(current) > 60 else ""))
        if delta and not args.dry_run:
            api(token, "%s/%s" % (resource, row["id"]), "PATCH",
                {"data": {"type": resource, "id": row["id"], "attributes": delta}})
        changed += len(delta)
        print()

    if args.dry_run:
        print("Dry run — %d field(s) would change." % changed)
    elif changed:
        print("Pushed %d field(s)." % changed)
    else:
        print("Already in sync — nothing to push.")


if __name__ == "__main__":
    main()
