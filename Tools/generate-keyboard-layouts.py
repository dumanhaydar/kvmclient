#!/usr/bin/env python3
"""Builds KVMUI/Resources/KeyboardLayouts.json from xkeyboard-config (the PC keyboard layouts used
by Linux/X11, permissively licensed) so the app can type text on a remote PC in its own layout.

For every character it records the physical key (USB HID usage) and the modifiers needed: Shift,
AltGr, or a dead key followed by the base key (e.g. ^ then e for ê).

Usage:
    git clone --depth 1 https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config.git
    git clone --depth 1 https://gitlab.freedesktop.org/xorg/proto/xorgproto.git
    python3 Tools/generate-keyboard-layouts.py xkeyboard-config xorgproto > KVMUI/Resources/KeyboardLayouts.json
"""

import json
import re
import sys
import unicodedata
from pathlib import Path

# App layout code → (xkb file, section or None for the file's default, display name).
# Codes match what JetKVM-family devices store, so the device's own setting is picked up.
LAYOUTS = {
    "en-US": ("us", None, "English (US)"),
    "en-GB": ("gb", None, "English (UK)"),
    "fr-FR": ("fr", None, "Français"),
    "fr-BE": ("be", None, "Belge"),
    "fr-CH": ("ch", "fr", "Français (Suisse)"),
    "de-DE": ("de", None, "Deutsch"),
    "de-CH": ("ch", None, "Schweizerdeutsch"),
    "es-ES": ("es", None, "Español"),
    "it-IT": ("it", None, "Italiano"),
    "pt-PT": ("pt", None, "Português"),
    "da-DK": ("dk", None, "Dansk"),
    "nb-NO": ("no", None, "Norsk bokmål"),
    "sv-SE": ("se", None, "Svenska"),
    "fi-FI": ("fi", None, "Suomi"),
    "cs-CZ": ("cz", None, "Čeština"),
    "hu-HU": ("hu", None, "Magyar"),
    "pl-PL": ("pl", None, "Polski"),
    "sl-SI": ("si", None, "Slovenščina"),
    "ru-RU": ("ru", None, "Русский"),
    "ja-JP": ("jp", None, "日本語"),
}
ALIASES = {"nl-BE": "fr-BE"}  # same Belgian AZERTY

# XKB key names → USB HID usages (positional).
KEYCODES = {
    "TLDE": 0x35, "LSGT": 0x64, "BKSL": 0x31, "SPCE": 0x2C, "AB11": 0x87, "AE13": 0x89,
    **{f"AE{i:02d}": u for i, u in enumerate([0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2D, 0x2E], 1)},
    **{f"AD{i:02d}": u for i, u in enumerate([0x14, 0x1A, 0x08, 0x15, 0x17, 0x1C, 0x18, 0x0C, 0x12, 0x13, 0x2F, 0x30], 1)},
    **{f"AC{i:02d}": u for i, u in enumerate([0x04, 0x16, 0x07, 0x09, 0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0x33, 0x34], 1)},
    **{f"AB{i:02d}": u for i, u in enumerate([0x1D, 0x1B, 0x06, 0x19, 0x05, 0x11, 0x10, 0x36, 0x37, 0x38], 1)},
}

LETTER_KEYS = {f"AD{i:02d}" for i in range(1, 11)} | {f"AC{i:02d}" for i in range(1, 10)} | {f"AB{i:02d}" for i in range(1, 8)}

# Dead keysyms → (combining mark used to compose, the spacing character typed alone).
DEAD_KEYS = {
    "dead_grave": ("̀", "`"), "dead_acute": ("́", "´"), "dead_circumflex": ("̂", "^"),
    "dead_tilde": ("̃", "~"), "dead_macron": ("̄", "¯"), "dead_breve": ("̆", "˘"),
    "dead_abovedot": ("̇", "˙"), "dead_diaeresis": ("̈", "¨"), "dead_abovering": ("̊", "˚"),
    "dead_doubleacute": ("̋", "˝"), "dead_caron": ("̌", "ˇ"), "dead_cedilla": ("̧", "¸"),
    "dead_ogonek": ("̨", "˛"),
}


def load_keysyms(proto: Path) -> dict:
    """keysymdef.h: `#define XK_eacute 0x00e9  /* U+00E9 LATIN SMALL LETTER E WITH ACUTE */`."""
    table = {}
    pattern = re.compile(r"^#define XK_(\w+)\s+0x[0-9a-fA-F]+\s*/\*[ (]*U\+([0-9A-Fa-f]{4,6})")
    for line in (proto / "include/X11/keysymdef.h").read_text().splitlines():
        match = pattern.match(line)
        if match:
            table.setdefault(match.group(1), chr(int(match.group(2), 16)))
    return table


def keysym_char(name: str, keysyms: dict):
    if name in DEAD_KEYS:
        return ("dead", name)
    if re.fullmatch(r"U[0-9A-Fa-f]{4,6}", name):
        return ("char", chr(int(name[1:], 16)))
    if len(name) == 1:
        return ("char", name)
    if name in keysyms:
        return ("char", keysyms[name])
    return None


class SymbolsResolver:
    def __init__(self, root: Path):
        self.root = root / "symbols"
        self.cache = {}

    def sections(self, file: str) -> dict:
        if file not in self.cache:
            text = re.sub(r"//.*", "", (self.root / file).read_text())
            sections, first, default = {}, None, None
            for match in re.finditer(r'((?:\w+\s+)*)xkb_symbols\s+"([^"]+)"\s*\{', text):
                depth, i = 1, match.end()
                while depth:
                    depth += {"{": 1, "}": -1}.get(text[i], 0)
                    i += 1
                sections[match.group(2)] = text[match.end():i - 1]
                first = first or match.group(2)
                if "default" in match.group(1).split():
                    default = match.group(2)
            self.cache[file] = (sections, default or first)
        return self.cache[file]

    def resolve(self, file: str, section, state=None):
        """Returns (keys {name: [levels]}, has_level3, name)."""
        state = state or {"keys": {}, "origin": {}, "level3": False, "name": None}
        sections, default = self.sections(file)
        body = sections[section or default]
        for statement in re.finditer(r'include\s+"([^"]+)"|name\[Group1\]\s*=\s*"([^"]*)"|key\s+<(\w+)>\s*\{([^;]*)\}\s*;', body):
            include, name, key, definition = statement.groups()
            if include:
                for part in re.split(r"[+|]", include):
                    target = re.fullmatch(r"([\w\-]+)(?:\(([\w\-]+)\))?(?::\d+)?", part.strip())
                    if not target:
                        continue
                    if target.group(1) == "level3" and target.group(2) in ("ralt_switch", "ralt_switch_multikey", "ralt_alt"):
                        state["level3"] = True
                    if (self.root / target.group(1)).exists() and target.group(1) not in ("level3", "pc", "compose", "keypad"):
                        self.resolve(target.group(1), target.group(2), state)
            elif name is not None:
                state["name"] = state["name"] or name
            elif key:
                levels = re.search(r"\[([^\]]*)\]", definition)
                if not levels:
                    continue
                current = state["keys"].setdefault(key, [None] * 4)
                origin = state["origin"].setdefault(key, [None] * 4)
                for index, symbol in enumerate(s.strip() for s in levels.group(1).split(",")):
                    if index < 4 and symbol and symbol != "NoSymbol":
                        current[index] = symbol
                        origin[index] = file
        return state


def build_layout(resolver, keysyms, file, section):
    state = resolver.resolve(file, section)
    max_level = 4 if state["level3"] else 2
    # Candidate strokes per character, best first: fewer modifiers, no dead keys.
    direct, dead = {}, {}
    for order, (key, levels) in enumerate(state["keys"].items()):
        usage = KEYCODES.get(key)
        if usage is None:
            continue
        for level, symbol in enumerate(levels[:max_level]):
            if not symbol:
                continue
            resolved = keysym_char(symbol, keysyms)
            if not resolved:
                continue
            stroke = {"k": usage}
            if level in (1, 3):
                stroke["s"] = 1
            if level in (2, 3):
                stroke["a"] = 1
            kind, value = resolved
            # XKB sometimes offers a character on two keys where Windows has one. Prefer what the
            # layout itself defines over what it inherits from "latin", then fewer modifiers, then
            # non-letter keys (AltGr on letters is mostly Linux-only extras), then the later key.
            # This reproduces the PC layouts: Belgian { on AltGr+9 and [ on AltGr+^, Spanish @ on
            # AltGr+2 and [ on AltGr+`, Italian [ on AltGr+è and { on Shift+AltGr+è.
            inherited = state["origin"][key][level] != file
            cost = (inherited, level, key in LETTER_KEYS, -order)
            target = dead if kind == "dead" else direct
            if value not in target or cost < target[value][0]:
                target[value] = (cost, stroke)
    direct.setdefault(" ", ((False, 0, False, 0), {"k": 0x2C}))

    chars = {c: s for c, (_, s) in direct.items() if c.isprintable() or c == " "}
    # Accents only reachable as dead keys: dead key then Space.
    for dead_name, (_, stroke) in dead.items():
        spacing = DEAD_KEYS[dead_name][1]
        if spacing not in chars:
            chars[spacing] = {**stroke, "d": 1}
    # Accented letters: dead key, then the base letter.
    for dead_name, (_, accent) in sorted(dead.items(), key=lambda item: item[1][0]):
        mark = DEAD_KEYS[dead_name][0]
        for base, base_stroke in list(chars.items()):
            if len(base) != 1 or not base.isalpha() or "d" in base_stroke or "acc" in base_stroke:
                continue
            composed = unicodedata.normalize("NFC", base + mark)
            if len(composed) == 1 and composed not in chars:
                chars[composed] = {**base_stroke, "acc": {k: v for k, v in accent.items()}}
    chars["\n"] = {"k": 0x28}
    chars["\t"] = {"k": 0x2B}
    return chars


def main():
    xkb, proto = Path(sys.argv[1]), Path(sys.argv[2])
    keysyms = load_keysyms(proto)
    resolver = SymbolsResolver(xkb)
    output = {}
    for code, (file, section, name) in LAYOUTS.items():
        output[code] = {"name": name, "chars": build_layout(resolver, keysyms, file, section)}
    for alias, target in ALIASES.items():
        output[alias] = {**output[target], "alias": target}
    json.dump(output, sys.stdout, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    for code, layout in output.items():
        print(f"{code:6} {len(layout['chars']):4} chars  {layout['name']}", file=sys.stderr)


if __name__ == "__main__":
    main()
