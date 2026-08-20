#!/usr/bin/env python3
"""Uploads the App Store screenshots to App Store Connect.

    scripts/appstore-screenshots.py [--dry-run] [--dir PATH] [--replace]

The frames are authored by the design practice and live in their repo, not
ours — `packaging/appstore/screenshots-source.txt` records the path. We pull
and upload; we never write into their handoff directory, which their build
regenerates.

Uploading is NOT submitting. Screenshots attach to the version record and sit
there until a human presses Submit for Review.

Three things that are easy to get wrong here:

  * **macOS screenshots may not carry an alpha channel.** App Store Connect
    rejects them, and the failure surfaces as an opaque asset error rather than
    "your PNG has alpha". Every file is checked before a single byte is sent.
  * **Order is the order they are created in**, not filename order as Apple
    reads it — so the files are sorted and uploaded sequentially, and the set's
    relationship is then PATCHed explicitly to pin it.
  * **The upload is a three-step dance**: reserve (POST, which returns
    `uploadOperations`), execute each operation against a signed URL, then
    commit with `uploaded: true` and the file's MD5 as `sourceFileChecksum`.
    Skip the commit and the asset silently stays in a half-created state that
    looks uploaded in the API but never appears in the web UI.
"""

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.appideas.tokes"
LOCALE = "en-US"
# macOS uses a single display type. iOS has one per device family.
DISPLAY_TYPE = "APP_DESKTOP"
# The only sizes App Store Connect accepts for a Mac app.
VALID_SIZES = {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)}
SOURCE_POINTER = pathlib.Path("packaging/appstore/screenshots-source.txt")


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
    # altool writes the token to stderr after a banner line; 2>/dev/null yields
    # an empty string and a confusing 401.
    out = subprocess.run(
        ["xcrun", "altool", "--generate-jwt", "--apiKey", env["ASC_KEY_ID"],
         "--apiIssuer", env["ASC_ISSUER_ID"], "--p8-file-path", env["ASC_P8"]],
        capture_output=True, text=True)
    for line in (out.stdout + out.stderr).splitlines():
        line = line.strip()
        if line.count(".") == 2 and len(line) > 100:
            return line
    die("could not obtain a JWT from altool:\n%s" % (out.stdout + out.stderr))


def api(token, path, method="GET", body=None):
    url = path if path.startswith("http") else "%s/%s" % (API, path.lstrip("/"))
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": "Bearer " + token,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        die("%s %s -> HTTP %d\n%s" % (method, url, e.code, e.read().decode()[:900]))


def check_image(path):
    """Geometry and alpha, before anything is sent. sips is the same tool the
    designer's own checker uses, so a disagreement means a different file."""
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight",
                          "-g", "hasAlpha", str(path)],
                         capture_output=True, text=True).stdout
    got = {}
    for line in out.splitlines():
        parts = line.strip().split(":")
        if len(parts) == 2:
            got[parts[0].strip()] = parts[1].strip()
    w, h = int(got.get("pixelWidth", 0)), int(got.get("pixelHeight", 0))
    if (w, h) not in VALID_SIZES:
        die("%s is %dx%d — not an accepted macOS screenshot size" % (path.name, w, h))
    if got.get("hasAlpha") != "no":
        die("%s carries an alpha channel — App Store Connect rejects it" % path.name)
    return w, h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", help="directory of frames (default: the recorded source)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--replace", action="store_true",
                    help="delete any existing screenshot set first")
    args = ap.parse_args()

    src = pathlib.Path(args.dir) if args.dir else None
    if src is None:
        if not SOURCE_POINTER.exists():
            die("no --dir given and %s does not exist" % SOURCE_POINTER)
        src = pathlib.Path(SOURCE_POINTER.read_text().strip().splitlines()[0])
    if not src.is_dir():
        die("not a directory: %s" % src)

    files = sorted(src.glob("*.png"))
    if not files:
        die("no PNGs in %s" % src)
    if len(files) > 10:
        die("%d files — App Store Connect accepts at most 10 per localization"
            % len(files))

    print("Source: %s\n" % src)
    for f in files:
        w, h = check_image(f)
        print("  %-24s %dx%-5d %6d B  md5 %s"
              % (f.name, w, h, f.stat().st_size,
                 hashlib.md5(f.read_bytes()).hexdigest()[:12]))
    print("\n%d file(s) pass geometry and alpha checks." % len(files))

    token = jwt(creds())
    apps = api(token, "apps?filter[bundleId]=%s" % BUNDLE_ID)["data"]
    if not apps:
        die("no App Store Connect record for %s" % BUNDLE_ID)
    version = api(token, "apps/%s/appStoreVersions?limit=1" % apps[0]["id"])["data"][0]
    print("\nVersion %s (%s)" % (version["attributes"]["versionString"],
                                 version["attributes"]["appStoreState"]))

    locs = api(token, "appStoreVersions/%s/appStoreVersionLocalizations"
               % version["id"])["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
    if loc is None:
        die("no %s localization on this version" % LOCALE)

    sets = api(token, "appStoreVersionLocalizations/%s/appScreenshotSets"
               % loc["id"])["data"]
    existing = next((s for s in sets
                     if s["attributes"]["screenshotDisplayType"] == DISPLAY_TYPE), None)
    if existing:
        shots = api(token, "appScreenshotSets/%s/appScreenshots" % existing["id"])["data"]
        print("Existing %s set: %d screenshot(s)" % (DISPLAY_TYPE, len(shots)))
        if not args.replace:
            die("a screenshot set already exists — pass --replace to delete and re-upload")

    if args.dry_run:
        print("\nDry run — would upload %d screenshot(s) to %s / %s, in this order:"
              % (len(files), LOCALE, DISPLAY_TYPE))
        for i, f in enumerate(files, 1):
            print("  %d. %s" % (i, f.name))
        print("\nUploading is not submitting; nothing would be sent for review.")
        return

    if existing and args.replace:
        api(token, "appScreenshotSets/%s" % existing["id"], method="DELETE")
        print("Deleted existing set.")
        existing = None

    if existing is None:
        created = api(token, "appScreenshotSets", method="POST", body={
            "data": {"type": "appScreenshotSets",
                     "attributes": {"screenshotDisplayType": DISPLAY_TYPE},
                     "relationships": {"appStoreVersionLocalization": {
                         "data": {"type": "appStoreVersionLocalizations",
                                  "id": loc["id"]}}}}})
        set_id = created["data"]["id"]
        print("Created %s set %s" % (DISPLAY_TYPE, set_id))
    else:
        set_id = existing["id"]

    uploaded_ids = []
    for f in files:
        blob = f.read_bytes()
        reserved = api(token, "appScreenshots", method="POST", body={
            "data": {"type": "appScreenshots",
                     "attributes": {"fileSize": len(blob), "fileName": f.name},
                     "relationships": {"appScreenshotSet": {
                         "data": {"type": "appScreenshotSets", "id": set_id}}}}})
        shot_id = reserved["data"]["id"]
        ops = reserved["data"]["attributes"]["uploadOperations"]

        for op in ops:
            chunk = blob[op["offset"]:op["offset"] + op["length"]]
            req = urllib.request.Request(op["url"], data=chunk,
                                         method=op["method"].upper())
            for header in op.get("requestHeaders", []):
                req.add_header(header["name"], header["value"])
            try:
                urllib.request.urlopen(req).read()
            except urllib.error.HTTPError as e:
                die("upload chunk for %s failed: HTTP %d\n%s"
                    % (f.name, e.code, e.read().decode()[:400]))

        # Commit. Without this the asset stays half-created: present in the API,
        # absent from the web UI, and it never attaches to the version.
        api(token, "appScreenshots/%s" % shot_id, method="PATCH", body={
            "data": {"type": "appScreenshots", "id": shot_id,
                     "attributes": {"uploaded": True,
                                    "sourceFileChecksum":
                                        hashlib.md5(blob).hexdigest()}}})
        uploaded_ids.append(shot_id)
        print("  uploaded %-24s %s" % (f.name, shot_id))

    # Pin display order explicitly rather than relying on creation order.
    api(token, "appScreenshotSets/%s/relationships/appScreenshots" % set_id,
        method="PATCH",
        body={"data": [{"type": "appScreenshots", "id": i} for i in uploaded_ids]})
    print("\nPinned display order (%d)." % len(uploaded_ids))
    print("Uploaded %d screenshot(s). Nothing has been submitted for review."
          % len(uploaded_ids))


if __name__ == "__main__":
    main()
