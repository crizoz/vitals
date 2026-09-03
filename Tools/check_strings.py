"""Revisa que las tablas de traducción calcen con las claves del código."""
import json
import pathlib
import re
import subprocess
import sys

BASE = "en"
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[@dfs]")


def table(path):
    raw = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)],
                         check=True, capture_output=True).stdout
    return json.loads(raw)


def placeholders(text):
    return sorted(re.sub(r"\d+\$", "", m) for m in PLACEHOLDER.findall(text))


def main(root):
    root = pathlib.Path(root)
    source = (root / "Sources/Localization.swift").read_text()
    keys = set(re.findall(r'(?<![A-Za-z0-9_])t\("([^"]+)"', source))
    base = table(root / f"Resources/{BASE}.lproj/Localizable.strings")
    ok = True

    for path in sorted(root.glob("Resources/*.lproj/Localizable.strings")):
        lang = path.parent.name.removesuffix(".lproj")
        strings = table(path)
        problems = []

        for key in sorted(keys - set(strings)):
            problems.append(f"falta «{key}»")
        for key in sorted(set(strings) - keys):
            problems.append(f"sobra «{key}», ya no se usa")
        for key in sorted(keys & set(strings) & set(base)):
            if placeholders(strings[key]) != placeholders(base[key]):
                problems.append(f"«{key}» usa {placeholders(strings[key])} "
                                f"y {BASE} usa {placeholders(base[key])}")
        # Un %n$ mal numerado revienta en tiempo de ejecución, no de compilación.
        for key in sorted(keys & set(strings)):
            found = PLACEHOLDER.findall(strings[key])
            positional = [m for m in found if "$" in m]
            if positional and len(positional) != len(found):
                problems.append(f"«{key}» mezcla marcadores posicionales y sueltos")

        if problems:
            ok = False
            print(f"✗ {lang}:", file=sys.stderr)
            for problem in problems:
                print(f"    {problem}", file=sys.stderr)
        else:
            print(f"✓ {lang}: {len(keys)} cadenas")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
