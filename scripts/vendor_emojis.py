#!/usr/bin/env python3
"""Reproduce the offline emoji catalog from pinned, hash-checked upstream data.

Only official upstream HTTPS sources are used. No code from the downloaded
archives is executed. Asset files are copied byte-for-byte from Twemoji.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import tarfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile


REPO = Path(__file__).resolve().parents[1]
SOURCES = {
    "twemoji.tar.gz": (
        "https://codeload.github.com/jdecked/twemoji/tar.gz/refs/tags/v17.0.3",
        "a0855654b633045ae2337537e77f1bb4361162f7fcd910e613eaab1d6d9c5fca",
    ),
    "emoji-test.txt": (
        "https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt",
        "1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda",
    ),
    "zh.xml": (
        "https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/annotations/zh.xml",
        "92389f71659998736530c72d4dcc86e453fe0be170cde5c5ad27094cab2a2de8",
    ),
    "zh-derived.xml": (
        "https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/annotationsDerived/zh.xml",
        "777acebb7c4ed103c34f5605881a2537656e0a17d9d1127518da7cd54f612bcc",
    ),
    "en.xml": (
        "https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/annotations/en.xml",
        "8511aadd046fdba2f0ffe590266ced8bbf48175ad139b2675d85d7141057b235",
    ),
    "unicode-license.txt": (
        "https://www.unicode.org/license.txt",
        "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96",
    ),
    "cldr-license.txt": (
        "https://raw.githubusercontent.com/unicode-org/cldr/release-48/LICENSE",
        "b4c0ae8ef04f7059f96ce5bbe0467f9fe6f6d81bbe13517701dfeb961fb4d0b6",
    ),
}
CATEGORIES = {
    "Smileys & Emotion": "表情与情感",
    "People & Body": "人物与手势",
    "Animals & Nature": "动物与自然",
    "Food & Drink": "食物与饮品",
    "Travel & Places": "旅行与地点",
    "Activities": "活动与运动",
    "Objects": "物品",
    "Symbols": "符号",
    "Flags": "旗帜",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fetch(name, cache, offline):
    url, expected = SOURCES[name]
    target = cache / name
    if target.exists():
        data = target.read_bytes()
    elif offline:
        raise ValueError(f"Missing offline source: {name}")
    else:
        request = urllib.request.Request(url, headers={"User-Agent": "HelloMentor-emoji-vendor"})
        with urllib.request.urlopen(request, timeout=90) as response:
            if response.url.split(":", 1)[0] != "https":
                raise ValueError("Source redirected away from HTTPS")
            data = response.read(20 * 1024 * 1024 + 1)
        if len(data) > 20 * 1024 * 1024:
            raise ValueError(f"Unexpected source size: {name}")
    if sha(data) != expected:
        raise ValueError(f"Upstream hash mismatch: {name}; review a version update explicitly")
    target.write_bytes(data)
    return data


def annotation_key(emoji):
    # CLDR omits presentation selectors in its index. Only use this for label
    # lookup; protocol values remain the exact fully-qualified Unicode string.
    return emoji.replace("\ufe0f", "")


def labels_and_keywords(sources):
    names, terms = {}, {}
    for source in sources:
        for node in ET.fromstring(source).findall(".//annotation"):
            key = annotation_key(node.attrib["cp"])
            if node.text and node.text != "↑↑↑":
                if node.get("type") == "tts":
                    names[key] = node.text
                else:
                    terms[key] = node.text
    return names, terms


def literal(value):
    return json.dumps(value, ensure_ascii=False).replace("$", "\\$")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=REPO / ".tooling/emoji-vendor")
    parser.add_argument("--offline", action="store_true", help="Require every pinned source in the cache")
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    sources = {name: fetch(name, args.cache, args.offline) for name in SOURCES}
    tar = tarfile.open(fileobj=io.BytesIO(sources["twemoji.tar.gz"]), mode="r:gz")
    members = {m.name: m for m in tar.getmembers() if m.isfile()}
    root = "twemoji-17.0.3/"
    pngs = {
        Path(name).stem: tar.extractfile(member).read()
        for name, member in members.items()
        if name.startswith(root + "assets/72x72/") and name.endswith(".png")
    }
    zh_names, zh_terms = labels_and_keywords([sources["zh-derived.xml"], sources["zh.xml"]])
    _, en_terms = labels_and_keywords([sources["en.xml"]])
    records = []
    group = None
    pattern = re.compile(r"^([0-9A-F ]+)\s*; fully-qualified\s*# (\S+) E[0-9.]+ (.+)$")
    for line in sources["emoji-test.txt"].decode().splitlines():
        if line.startswith("# group: "):
            group = line.removeprefix("# group: ")
        match = pattern.match(line)
        if not match:
            continue
        cps = [int(cp, 16) for cp in match[1].split()]
        emoji, english = match[2], match[3]
        if emoji != "".join(chr(cp) for cp in cps):
            raise ValueError("Unicode text and code point columns disagree")
        full = "-".join(f"{cp:x}" for cp in cps)
        no_selector = "-".join(f"{cp:x}" for cp in cps if cp != 0xfe0f)
        asset = full if full in pngs else no_selector
        if asset not in pngs or group not in CATEGORIES:
            raise ValueError(f"Missing supported upstream graphic/category: {full}")
        key = annotation_key(emoji)
        name = zh_names.get(key)
        if not name:
            raise ValueError(f"Missing Chinese name: {full}")
        keywords = " | ".join(dict.fromkeys([
            name, english, zh_terms.get(key, ""), en_terms.get(key, ""),
        ]))
        records.append({
            "emoji": emoji, "name": name, "englishName": english,
            "category": CATEGORIES[group], "keywords": keywords,
            "assetPath": f"assets/emojis/72x72/{asset}.png",
        })
    if len(records) != 3944 or len({row["emoji"] for row in records}) != len(records):
        raise ValueError("Unexpected Unicode 17 inventory")
    legacy = {"👍", "❤️", "😂", "😮", "😢", "🙏"}
    if not legacy <= {row["emoji"] for row in records}:
        raise ValueError("Legacy reactions must remain byte-for-byte identical")

    output = REPO / "apps/mobile/assets/emojis"
    images = output / "72x72"
    licenses = output / "licenses"
    images.mkdir(parents=True, exist_ok=True)
    licenses.mkdir(parents=True, exist_ok=True)
    chosen = {Path(row["assetPath"]).stem for row in records}
    # Never recursively delete the destination. Remove only obsolete generated
    # PNGs from this dedicated vendor directory after validating all sources.
    for previous in images.glob("*.png"):
        if previous.stem not in chosen:
            previous.unlink()
    files = {}
    for name in sorted(chosen):
        data = pngs[name]
        if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (72, 72):
            raise ValueError(f"Unexpected image format: {name}")
        (images / f"{name}.png").write_bytes(data)
        files[f"72x72/{name}.png"] = {"bytes": len(data), "sha256": sha(data)}

    for filename, upstream in [
        ("LICENSE-TWEMOJI-GRAPHICS.txt", "LICENSE-GRAPHICS"),
        ("LICENSE-TWEMOJI-CODE.txt", "LICENSE"),
    ]:
        (licenses / filename).write_bytes(tar.extractfile(members[root + upstream]).read())
    (licenses / "LICENSE-UNICODE.txt").write_bytes(sources["unicode-license.txt"])
    (licenses / "LICENSE-CLDR.txt").write_bytes(sources["cldr-license.txt"])
    notice = """Offline emoji artwork and catalog

Twemoji 17.0.3 graphics by Twitter, Inc. and Twemoji contributors, maintained
by Jason Sofonia and Justine De Caires. Graphics licensed under Creative Commons
Attribution 4.0 International (CC BY 4.0).
https://github.com/jdecked/twemoji/releases/tag/v17.0.3
https://creativecommons.org/licenses/by/4.0/
The selected original 72×72 PNGs are copied without modification. This App does
not contact an emoji CDN and does not bundle Telegram custom emoji or stickers.

Emoji strings, ordering and English names: Unicode Emoji 17.0 emoji-test.txt.
Chinese names and bilingual keywords: Unicode CLDR release 48.
These data are used under Unicode License V3; both upstream notices accompany
the bundle. Generated metadata selects fully-qualified emoji and omits unused
CLDR data. Unicode and the Unicode Logo are registered trademarks of Unicode,
Inc. in the U.S. and other countries.
https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt
https://github.com/unicode-org/cldr/tree/release-48

Reproduce with: python3 scripts/vendor_emojis.py
Source hashes and per-image hashes are recorded in ../manifest.json.
"""
    (licenses / "NOTICE.txt").write_text(notice)

    dart = """// Generated by scripts/vendor_emojis.py. Do not edit the catalog by hand.
// Unicode Emoji 17.0 / CLDR 48 data: Unicode License V3.
// Twemoji 17.0.3 PNG graphics: CC BY 4.0. Notices: assets/emojis/licenses/.
// Keep generated rows stable across Dart formatter releases.
// dart format off

class EmojiEntry {
  const EmojiEntry(this.emoji, this.name, this.englishName, this.category,
      this.keywords, this.assetPath);
  final String emoji, name, englishName, category, keywords, assetPath;
}

abstract final class EmojiCatalog {
  static const twemojiVersion = '17.0.3';
  static const unicodeVersion = '17.0';
  static const cldrVersion = '48';
  static const categories = <String>[
"""
    dart += "".join(f"    {literal(category)},\n" for category in CATEGORIES.values())
    dart += "  ];\n  static const entries = <EmojiEntry>[\n"
    for row in records:
        dart += "    EmojiEntry(" + ", ".join(literal(value) for value in row.values()) + "),\n"
    dart += """  ];
  static final values = List<String>.unmodifiable(entries.map((entry) => entry.emoji));
  static final Map<String, EmojiEntry> _byEmoji = {
    for (final entry in entries) entry.emoji: entry,
  };
  static final Map<String, int> _positions = {
    for (var index = 0; index < entries.length; index++) entries[index].emoji: index,
  };
  static EmojiEntry? find(String emoji) => _byEmoji[emoji];
  static bool contains(String emoji) => _byEmoji.containsKey(emoji);
  static int indexOf(String emoji) => _positions[emoji] ?? -1;
}
"""
    catalog = REPO / "apps/mobile/lib/core/emoji_catalog.dart"
    catalog.write_text(dart)
    packed = io.BytesIO()
    with zipfile.ZipFile(packed, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for filename in sorted(files):
            archive.writestr(filename, (output / filename).read_bytes())
    manifest = {
        "schemaVersion": 1,
        "twemojiVersion": "17.0.3", "unicodeVersion": "17.0", "cldrVersion": "48",
        "emojiCount": len(records), "categoryCount": len(CATEGORIES),
        "assetCount": len(files), "assetBytes": sum(item["bytes"] for item in files.values()),
        "assetZipBytes": len(packed.getvalue()), "generatedDartBytes": len(dart.encode()),
        "runtimeNetworkRequired": False, "artworkModified": False,
        "sources": {name: {"url": url, "sha256": digest, "bytes": len(sources[name])}
                    for name, (url, digest) in SOURCES.items()},
        "files": files,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: manifest[key] for key in [
        "twemojiVersion", "emojiCount", "categoryCount", "assetCount", "assetBytes",
        "assetZipBytes", "generatedDartBytes", "runtimeNetworkRequired",
    ]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
