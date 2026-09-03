"""Read-only, release-specific source/payload/index checks; never shipped."""
import argparse
from collections import Counter
import hashlib
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

import yaml

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path("C:/code/auphonic-mt")
SOURCE_COMMIT = "7c7def2d31526fa6cd0f9fd387c246ed44a34e21"
PREVIOUS = "0ffd532021348a987683050ad660252350f3ef2f"
CHANGED = {
    "scr/elevenlabs_tool.lua",
    "scr/elevenlabs_manager_tool.lua",
    "scr/modules-neurocast/elevenlabs_api_via_neurocast.lua",
    "scr/modules-neurocast/elevenlabs_manager_user_view.lua",
}


def git_blob(repo, revision, path):
    return subprocess.check_output(["git", "-C", str(repo), "show", f"{revision}:{path}"])


def check(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


def validate_payload():
    manifest = yaml.safe_load((ROOT / "release-manifest.yml").read_text())
    lock = yaml.safe_load((ROOT / "release-source-lock.yml").read_text())
    check(manifest["source"]["commit"] == lock["tracked_lua"]["commit"] == SOURCE_COMMIT,
          "source commit")
    check(manifest["package"]["version"] == lock["package"]["version"] == "0.1.3", "version")
    inputs = [p for p in manifest["payload"] if p["source"].startswith("auphonic-mt:scr/")
              and p["source"].endswith(".lua")]
    check(len(inputs) == lock["tracked_lua"]["count"] == manifest["source"]["tracked_lua_count"] == 54,
          "54 Lua inputs")
    check(set(lock["tracked_lua"]["byte_exact_changed_files"]) == CHANGED, "four changed inputs")
    crlf = set()
    contents = {}
    for item in inputs:
        source_path = item["source"].split(":", 1)[1]
        destination = item["destination"]
        actual = (ROOT / destination).read_bytes()
        expected = git_blob(SOURCE, SOURCE_COMMIT, source_path)
        check(actual.replace(b"\r\n", b"\n") == expected, f"source content: {source_path}")
        if source_path in CHANGED:
            check(actual == expected, f"changed bytes: {source_path}")
        else:
            check(actual == git_blob(ROOT, PREVIOUS, destination), f"unchanged bytes: {destination}")
        if b"\r\n" in actual:
            crlf.add(destination)
        contents[source_path] = actual.decode("utf-8")
        subprocess.run(["luac", "-p", str(ROOT / destination)], check=True, capture_output=True)
    check(crlf == set(lock["tracked_lua"]["historical_crlf_preserved_distribution_files"]), "CRLF list")
    check(len(crlf) == 10, "ten unchanged historical CRLF files")

    # Literal dependencies from the actual 13 roots, including pcall(require, name).
    seen = set()
    pending = list(manifest["entrypoints"])
    pattern = re.compile(r'\b(?:require|require_module|require_project_module)\s*(?:\(\s*|,\s*)?["\']([^"\']+)["\']')
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        check(name in contents, f"missing dependency: {name}")
        seen.add(name)
        for module in pattern.findall(contents[name]):
            check(not module.startswith("modules."), f"legacy import in {name}")
            if module.startswith("modules-neurocast."):
                pending.append("scr/" + module.replace(".", "/") + ".lua")
            else:
                check(module == "imgui", f"unexpected external import {module} in {name}")
    check(seen == set(contents), "dependency closure mismatch: " + str(sorted(set(contents) - seen)))

    expected_files = {item.get("package_source", item["destination"]) for item in manifest["payload"]}
    actual_files = {p.relative_to(ROOT).as_posix() for p in (ROOT / "Neurocast_Tools").rglob("*") if p.is_file()}
    check(actual_files == expected_files | {"Neurocast_Tools/index.lua"}, "exact payload tree; no extra files")
    for group in ("local_windows_inputs", "component_notices", "native_inputs"):
        for item in lock[group]["files"]:
            path = item.get("package_source", item.get("destination"))
            body = (ROOT / path).read_bytes()
            check(len(body) == item["size_bytes"] and hashlib.sha256(body).hexdigest() == item["sha256"],
                  f"pinned size/hash: {path}")
            check(body == git_blob(ROOT, PREVIOUS, path), f"unchanged binary/notice: {path}")
    metadata = (ROOT / "Neurocast_Tools/index.lua").read_text()
    rows = re.findall(r'^--   \[([^\]]+)\] (.+)$', metadata, re.M)
    expected_rows = set()
    for item in manifest["payload"]:
        role = item["role"]
        path = item.get("package_source", item["destination"]).removeprefix("Neurocast_Tools/")
        if role == "extension":
            path += " > " + Path(item["destination"]).name
        for platform in item["platforms"]:
            flags = platform + ({"main_action": " main", "extension": " extension"}.get(role, ""))
            expected_rows.add((flags, path))
    check(len(rows) == 174 and set(rows) == expected_rows, "174 exact platform metadata rows")
    check(Counter(flags.split()[0] for flags, _ in rows) == {"win64": 62, "darwin64": 56, "darwin-arm64": 56},
          "platform counts")
    check(Counter(flags.split()[0] for flags, _ in rows if flags.endswith(" main")) ==
          {"win64": 13, "darwin64": 13, "darwin-arm64": 13}, "13 Main actions per platform")
    print("PASS payload: 54 Lua syntax/content/closure; four exact changed blobs; 50 unchanged Lua; pinned binaries/notices; 174 rows; exclusions")
    return manifest


def validate_index(path, candidate, manifest, candidate_only):
    current = ET.parse(path).getroot()
    old = ET.fromstring(git_blob(ROOT, PREVIOUS, "index.xml"))
    check(len(current.findall("./category/reapack")) == 1, "one indexed package")
    versions = {v.attrib["name"]: v for v in current.findall(".//version")}
    check(len(versions) == (1 if candidate_only else 4), "version count")
    if not candidate_only:
        for version in old.findall(".//version"):
            check(ET.tostring(version) == ET.tostring(versions[version.attrib["name"]]),
                  "immutable historical version " + version.attrib["name"])
    sources = versions["0.1.3"].findall("source")
    check(len(sources) == 174, "174 indexed sources")
    prefix = f"https://raw.githubusercontent.com/Logutin/reaper-reapack-neurocast-tools/{candidate}/"
    expected = set()
    for item in manifest["payload"]:
        source = item.get("package_source", item["destination"])
        installed = Path(item["destination"]).name if item["role"] == "extension" else source.removeprefix("Neurocast_Tools/")
        for platform in item["platforms"]:
            expected.add((platform, installed, "main" if item["role"] == "main_action" else "",
                          "extension" if item["role"] == "extension" else "", prefix + source))
    actual = {(s.get("platform"), s.get("file"), s.get("main", ""), s.get("type", ""), s.text.strip()) for s in sources}
    check(actual == expected, "exact indexed paths/platforms/actions/types and immutable source URLs")
    print("PASS index: exact 0.1.3 sources" + ("; historical versions unchanged" if not candidate_only else " (local candidate only)"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path)
    parser.add_argument("--candidate")
    parser.add_argument("--candidate-only", action="store_true")
    args = parser.parse_args()
    manifest = validate_payload()
    if args.index:
        check(args.candidate is not None, "--candidate required with --index")
        validate_index(args.index, args.candidate, manifest, args.candidate_only)
