"""Read-only checks for the 0.1.5 payload, candidate index, and installed receipt."""
import argparse
from collections import Counter
import hashlib
from pathlib import Path
import re
import sqlite3
import subprocess
import xml.etree.ElementTree as ET

import yaml

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path("C:/code/auphonic-mt")
SOURCE_COMMIT = "04fbd164ae06796bef170a7f9c3c6d8624cdbe74"
PREVIOUS = "d34a5ad87d408cbdd46a08c0d722744d351ffad9"
DISPOSABLE = Path("C:/extra_Reapers/Reaper_Empty_01")
CHANGED = {
    "scr/elevenlabs_manager_tool.lua",
    "scr/modules-neurocast/elevenlabs_manager_user_view.lua",
    "scr/modules-neurocast/reaper_manager_elevenlabs_api.lua",
}
PAIR = {
    "7z.exe": (577536, "6ee3c0ed0b27663c1b948ae85a7c0bb073aed1498983182f3f0df1f6a8c30b2f"),
    "7z.dll": (1906688, "65e4c1f855f9ef6e8f0f5df8e3f27d9eb5f07311408639da0a1ca0b8f4871b0d"),
}


def check(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


def git_blob(repo, revision, path):
    return subprocess.check_output(["git", "-C", str(repo), "show", f"{revision}:{path}"])


def validate_payload():
    manifest = yaml.safe_load((ROOT / "release-manifest.yml").read_text())
    lock = yaml.safe_load((ROOT / "release-source-lock.yml").read_text())
    check(manifest["source"]["commit"] == lock["tracked_lua"]["commit"] == SOURCE_COMMIT, "source pin")
    check(manifest["package"]["version"] == lock["package"]["version"] == "0.1.5", "package version")
    inputs = [p for p in manifest["payload"] if p["source"].startswith("auphonic-mt:scr/")]
    check(len(inputs) == lock["tracked_lua"]["count"] == manifest["source"]["tracked_lua_count"] == 60, "60 Lua inputs")
    check(set(lock["tracked_lua"]["byte_exact_changed_files"]) == CHANGED, "three changed inputs")
    contents, crlf = {}, set()
    for item in inputs:
        name = item["source"].split(":", 1)[1]
        actual = (ROOT / item["destination"]).read_bytes()
        expected = git_blob(SOURCE, SOURCE_COMMIT, name)
        check(actual.replace(b"\r\n", b"\n") == expected, "source content: " + name)
        if name in CHANGED:
            check(actual == expected, "exact changed bytes: " + name)
        else:
            check(actual == git_blob(ROOT, PREVIOUS, item["destination"]), "unchanged bytes: " + name)
        if b"\r\n" in actual:
            crlf.add(item["destination"])
        contents[name] = actual.decode("utf-8")
        subprocess.run(["luac", "-p", str(ROOT / item["destination"])], check=True, capture_output=True)
    check(len(crlf) == 8 and crlf == set(lock["tracked_lua"]["historical_crlf_preserved_distribution_files"]), "eight historical CRLF files")

    pattern = re.compile(r'\b(?:require|require_module|require_project_module)\s*(?:\(\s*|,\s*)?["\']([^"\']+)["\']')
    pending, seen = list(manifest["entrypoints"]), set()
    check(len(pending) == len(set(pending)) == 14, "14 distinct Main roots")
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        check(name in contents, "missing dependency: " + name)
        seen.add(name)
        for module in pattern.findall(contents[name]):
            if module.startswith("modules-neurocast."):
                pending.append("scr/" + module.replace(".", "/") + ".lua")
            else:
                check(module == "imgui", "unexpected or legacy import: " + name + " -> " + module)
    check(seen == set(contents), "exact dependency closure")
    files = {p.relative_to(ROOT).as_posix() for p in (ROOT / "Neurocast_Tools").rglob("*") if p.is_file()}
    expected_files = {p.get("package_source", p["destination"]) for p in manifest["payload"]}
    check(files == expected_files | {"Neurocast_Tools/index.lua"}, "exact payload; no tests, identities, caches or other extras")
    for group in ("local_windows_inputs", "component_notices", "native_inputs"):
        for item in lock[group]["files"]:
            path = item.get("package_source", item.get("destination"))
            body = (ROOT / path).read_bytes()
            check(len(body) == item["size_bytes"] and hashlib.sha256(body).hexdigest() == item["sha256"], "hash/size pin: " + path)
            if group == "local_windows_inputs" and Path(path).name in PAIR:
                check((len(body), hashlib.sha256(body).hexdigest()) == PAIR[Path(path).name], "official matching 7-Zip pair")
                check(body == (SOURCE / item["source_path"]).read_bytes(), "runtime/distribution binary equality")
            else:
                check(body == git_blob(ROOT, PREVIOUS, path), "unchanged binary/notice: " + path)
    for item in manifest["payload"]:
        if "sha256" in item:
            body = (ROOT / item.get("package_source", item["destination"])).read_bytes()
            check(len(body) == item["size_bytes"] and hashlib.sha256(body).hexdigest() == item["sha256"], "manifest binary pin")
    info = subprocess.check_output([str(ROOT / "Neurocast_Tools/bin/win/7z.exe"), "i"], text=True)
    check("7-Zip 26.03 (x64)" in info, "7-Zip version/architecture")
    check(str(ROOT / "Neurocast_Tools/bin/win/7z.dll").lower() in info.lower(), "package-local 7z.dll loading")

    metadata = (ROOT / "Neurocast_Tools/index.lua").read_text()
    check("-- @version 0.1.5\n" in metadata, "metadata version")
    rows = re.findall(r'^--   \[([^\]]+)\] (.+)$', metadata, re.M)
    expected_rows = set()
    for item in manifest["payload"]:
        role = item["role"]
        path = item.get("package_source", item["destination"]).removeprefix("Neurocast_Tools/")
        if role == "extension":
            path += " > " + Path(item["destination"]).name
        for platform in item["platforms"]:
            expected_rows.add((platform + {"main_action": " main", "extension": " extension"}.get(role, ""), path))
    check(len(rows) == 192 and set(rows) == expected_rows, "192 exact metadata rows")
    check(Counter(f.split()[0] for f, _ in rows) == {"win64": 68, "darwin64": 62, "darwin-arm64": 62}, "platform counts")
    check(Counter(f.split()[0] for f, _ in rows if f.endswith(" main")) == {"win64": 14, "darwin64": 14, "darwin-arm64": 14}, "14 actions per platform")
    print("PASS payload: 60 Lua syntax/content/closure; 3 exact changed and 57 unchanged Lua; official 7-Zip 26.03 pair; other binaries/notices unchanged; 192 rows; 68 Windows files/14 actions")
    return manifest


def validate_index(path, candidate, manifest):
    current = ET.parse(path).getroot()
    old = ET.fromstring(git_blob(ROOT, PREVIOUS, "index.xml"))
    check(current.get("name") == "Neurocast Tools", "repository name")
    check(len(current.findall("./category/reapack")) == 1, "one package")
    elements = current.findall(".//version")
    versions = {v.attrib["name"]: v for v in elements}
    check(len(elements) == len(versions) == 6, "six distinct versions")
    for version in old.findall(".//version"):
        preserved = versions.get(version.attrib["name"])
        check(preserved is not None, "historical version missing")
        version.tail = preserved.tail = None
        check(ET.tostring(version) == ET.tostring(preserved), "immutable historical version: " + version.attrib["name"])
    sources = versions["0.1.5"].findall("source")
    check(len(sources) == 192, "192 indexed sources")
    prefix = f"https://github.com/Logutin/reaper-reapack-neurocast-tools/raw/{candidate}/"
    expected = set()
    for item in manifest["payload"]:
        source = item.get("package_source", item["destination"])
        installed = Path(item["destination"]).name if item["role"] == "extension" else source.removeprefix("Neurocast_Tools/")
        for platform in item["platforms"]:
            expected.add((platform, installed, "main" if item["role"] == "main_action" else "", "extension" if item["role"] == "extension" else "", prefix + source))
    actual = {(s.get("platform"), s.get("file"), s.get("main", ""), s.get("type", ""), s.text.strip()) for s in sources}
    check(actual == expected, "exact index platforms/paths/actions/types/immutable URLs")
    print("PASS index: 192 pinned 0.1.5 sources; all five historical versions unchanged")


def validate_installed(manifest):
    registry = DISPOSABLE / "ReaPack/registry.db"
    with sqlite3.connect(registry.as_uri() + "?mode=ro", uri=True) as db:
        entries = db.execute("SELECT id, version FROM entries WHERE remote='Neurocast Tools' AND category='Neurocast_Tools' AND package='index.lua'").fetchall()
        check(len(entries) == 1 and entries[0][1] == "0.1.5", "installed receipt version")
        files = db.execute("SELECT path, main FROM files WHERE entry=?", (entries[0][0],)).fetchall()
    expected = {}
    actions = []
    for item in manifest["payload"]:
        if "win64" not in item["platforms"]:
            continue
        path = item["destination"] if item["role"] == "extension" else "Scripts/Neurocast Tools/" + item["destination"]
        expected[path] = (item.get("package_source", item["destination"]), item["role"] == "main_action")
        if item["role"] == "main_action":
            actions.append(path)
    check(len(files) == 68 and {path for path, _ in files} == set(expected), "68 exact owned paths")
    kb = (DISPOSABLE / "reaper-kb.ini").read_text(encoding="utf-8")
    for path, main in files:
        source, action = expected[path]
        check(bool(main) == action, "registered role: " + path)
        check((DISPOSABLE / path).read_bytes() == (ROOT / source).read_bytes(), "installed bytes: " + path)
    for path in actions:
        relative = path.removeprefix("Scripts/")
        matches = [line for line in kb.splitlines() if line.startswith("SCR ") and relative in line.replace("\\", "/")]
        check(len(matches) == 1 and matches[0].split()[2] == "0", "exactly-once Main action: " + path)
    print("PASS disposable receipt: 0.1.5; 68 byte-exact owned files; 14 exactly-once Main actions. Owner GUI acceptance remains separate.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path)
    parser.add_argument("--candidate")
    parser.add_argument("--installed", action="store_true")
    args = parser.parse_args()
    manifest = validate_payload()
    if args.index:
        check(args.candidate and re.fullmatch(r"[0-9a-f]{40}", args.candidate), "full --candidate SHA required")
        validate_index(args.index, args.candidate, manifest)
    if args.installed:
        validate_installed(manifest)
