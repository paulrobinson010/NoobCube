#!/usr/bin/env python3
"""Write Design/tokens.json into everything that draws NoobCube.

The app, the website and the taster on the bio site should look like one
product. They are written in Swift, CSS, JavaScript and JSON, so the only way
they stay in step is for one file to own the numbers and for the rest to be
generated from it.

    python3 Tools/sync_design.py            # write
    python3 Tools/sync_design.py --check    # fail if anything has drifted

The words are owned the same way, except their home is the Swift that the
child actually hears: the stage names on the website are read straight out of
SolvePlan.swift, so the site cannot claim a step the app does not have.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKENS = ROOT / "Design" / "tokens.json"
PLAN = ROOT / "NoobCube" / "CubeKit" / "Solver" / "SolvePlan.swift"

BEGIN = "BEGIN generated from Design/tokens.json"
END = "END generated"


# ---------------------------------------------------------------- reading in

def load_tokens() -> dict:
    return json.loads(TOKENS.read_text())


def hex_to_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def stages_from_swift() -> list[tuple[str, str]]:
    """The stages the child works through, in order, as (case, short name).

    Read from the Swift rather than repeated here: the app is where the words
    belong, because it is the app that says them out loud.
    """
    source = PLAN.read_text()

    enum = re.search(r"enum Kind[^{]*\{(.*?)\n    \}", source, re.S)
    if not enum:
        raise SystemExit("could not find SolveStage.Kind in SolvePlan.swift")
    order = re.findall(r"case (\w+)", enum.group(1))

    block = re.search(r"var shortName: String \{(.*?)\n    \}", source, re.S)
    if not block:
        raise SystemExit("could not find shortName in SolvePlan.swift")
    names = dict(re.findall(r'case \.(\w+):\s*return "([^"]*)"', block.group(1)))

    missing = [case for case in order if case not in names]
    if missing:
        raise SystemExit(f"no short name for {', '.join(missing)}")

    # 'hold' is how you pick the cube up, not a step you tick off.
    return [(case, names[case]) for case in order if case != "hold"]


# ---------------------------------------------------------------- writing out

def replace_block(path: Path, body: str, comment: str) -> str:
    """Swap the generated region of a file for `body`."""
    text = path.read_text()
    if comment == "html":
        start, finish = f"<!-- {BEGIN} -->", f"<!-- {END} -->"
    elif comment == "slash":
        start, finish = f"/* {BEGIN} */", f"/* {END} */"
    else:
        start, finish = f"// {BEGIN}", f"// {END}"

    if start not in text or finish not in text:
        raise SystemExit(f"{path.relative_to(ROOT.parent)} has no generated region")

    head, rest = text.split(start, 1)
    _, tail = rest.split(finish, 1)
    return f"{head}{start}\n{body.rstrip()}\n{' ' * indent_of(head)}{finish}{tail}"


def indent_of(head: str) -> int:
    """How far the marker line was indented, so the closer lines up with it."""
    last = head.rsplit("\n", 1)[-1]
    return len(last) - len(last.lstrip())


def css_block(t: dict) -> str:
    lines = ["  /* the cube's own stickers, straight off the icon */"]
    for name, value in t["sticker"].items():
        key = "chalk" if name == "white" else name
        lines.append(f"  --{key}: {value};")
    lines.append("")
    lines.append("  /* the glow either side of the cube in the icon */")
    for name, value in t["brand"].items():
        lines.append(f"  --{name}: {value};")
    lines.append("")
    lines.append("  /* the page itself, starting from the icon's edge colour */")
    for name, value in t["surface"].items():
        key = {"background": "bg", "text": "text"}.get(name, name)
        lines.append(f"  --{key}: {value};")
    lines.append("")
    r, g, b = hex_to_rgb(t["surface"]["band"])
    lines.append("  /* the band, thinned so the cubes keep drifting behind it */")
    lines.append(f"  --band-veil: rgba({r}, {g}, {b}, 0.9);")
    lines.append("")
    lines.append("  /* what each colour is for, so the app and the site agree */")
    lines.append(f"  --action: {role_colour(t, 'action')};")
    lines.append(f"  --action-shadow: {shade(role_colour(t, 'action'), t['shape']['shadowDepth'])};")
    lines.append(f"  --attention: {role_colour(t, 'attention')};")
    lines.append(f"  --done: {role_colour(t, 'done')};")
    lines.append("")
    shape = t["shape"]
    lines.append(f"  --radius: {shape['cornerRadius']}px;")
    lines.append(f"  --drop: {shape['buttonDrop']}px;")
    lines.append(f"  --sticker-radius: {round(shape['stickerRadius'] * 100)}%;")
    return "\n".join(lines)


def role_colour(t: dict, role: str) -> str:
    """The colour a job is done in, whichever family it came from."""
    name = t["role"][role]
    for family in ("sticker", "brand"):
        if name in t[family]:
            return t[family][name]
    raise SystemExit(f"no colour called {name}")


def cubes_js_block(t: dict) -> str:
    order = ["white", "yellow", "red", "orange", "green", "blue"]
    lines = ["  const COLOUR = ["]
    for name in order:
        r, g, b = hex_to_rgb(t["sticker"][name])
        lines.append(f"    [{r}, {g}, {b}],".ljust(24) + f"// {name}")
    lines.append("  ];")
    r, g, b = hex_to_rgb(t["surface"]["plastic"])
    lines.append(f"  const PLASTIC = [{r}, {g}, {b}];   // the black body the stickers sit on")
    lines.append(f"  const STICKER = {t['shape']['stickerFraction']};   // how much of a face the sticker covers")
    cube = t["cube"]
    lines.append(f"  const POSE = {{ pitch: {cube['pitch']}, yaw: {cube['yaw']} }};")
    return "\n".join(lines)


def cubebox_js_block(t: dict) -> str:
    """The taster on the bio site: the same cube, in CSS instead of canvas."""
    s = t["sticker"]
    cube = t["cube"]
    degrees = lambda radians: round(math.degrees(radians))
    return "\n".join([
        ("  const COLOUR = {{ U: \"{white}\", D: \"{yellow}\", F: \"{green}\","
         " B: \"{blue}\", R: \"{red}\", L: \"{orange}\" }};").format(**s),
        f"  const STICKER = {t['shape']['stickerFraction']};   "
        "// how much of a face the sticker covers",
        f"  const STICKER_RADIUS = \"{round(t['shape']['stickerRadius'] * 100)}%\";",
        f"  const POSE = {{ x: {degrees(cube['pitch'])}, y: {degrees(cube['yaw'])} }};   "
        "// how it sits before you touch it",
    ])


def swift_colour_block(t: dict) -> str:
    lines = ["        switch self {"]
    for name in ["white", "yellow", "green", "blue", "red", "orange"]:
        r, g, b = hex_to_rgb(t["sticker"][name])
        triple = ", ".join(f"{v / 255:.3f}" for v in (r, g, b))
        lines.append(f"        case .{name}:".ljust(23) + f"return ({triple})")
    lines.append("        }")
    return "\n".join(lines)


def swift_theme_block(t: dict) -> str:
    def colour(value: str) -> str:
        r, g, b = hex_to_rgb(value)
        return f"Color(red: {r / 255:.3f}, green: {g / 255:.3f}, blue: {b / 255:.3f})"

    shape = t["shape"]
    cube = t["cube"]
    lines = [
        "    /// The button you press to get on with it.",
        f"    static let action = {colour(role_colour(t, 'action'))}",
        "",
        "    /// Where you are now: the step you are on, the move to make next.",
        f"    static let attention = {colour(role_colour(t, 'attention'))}",
        "    /// The same colour turned down, for things that glow rather than shine.",
        f"    static let attentionGlow = {colour(shade(role_colour(t, 'attention'), 0.35))}",
        "",
        "    /// Finished, ticked off, done.",
        f"    static let done = {colour(role_colour(t, 'done'))}",
        "",
        f"    static let card = {colour(t['surface']['card'])}",
        f"    static let muted = {colour(t['surface']['muted'])}",
        f"    static let ink = {colour(t['surface']['ink'])}",
        "",
        "    /// The black a cube is made of, under the stickers.",
        f"    static let plastic = {colour(t['surface']['plastic'])}",
        "",
        f"    static let cornerRadius: CGFloat = {shape['cornerRadius']}",
        f"    static let buttonDrop: CGFloat = {shape['buttonDrop']}",
        "    /// How much light comes out of a button's colour for its shadow.",
        f"    static let shadowDepth: CGFloat = {shape['shadowDepth']}",
        f"    static let stickerFraction: CGFloat = {shape['stickerFraction']}",
        f"    static let stickerRadius: CGFloat = {shape['stickerRadius']}",
        "    /// Comfortably bigger than the 44pt minimum: small fingers, moving target.",
        f"    static let minimumTapTarget: CGFloat = {shape['tapTarget']}",
        "",
        "    /// How a cube sits when nothing is happening: the same three-quarter",
        "    /// view the website draws, so it is recognisably the same object.",
        f"    static let cubePitch: Float = {cube['pitch']}",
        f"    static let cubeYaw: Float = {cube['yaw']}",
    ]
    return "\n".join(lines)


def shade(value: str, factor: float) -> str:
    r, g, b = hex_to_rgb(value)
    return "#%02x%02x%02x" % (int(r * factor), int(g * factor), int(b * factor))


def colorset(value: str) -> str:
    r, g, b = hex_to_rgb(value)
    return json.dumps({
        "colors": [{
            "color": {
                "color-space": "srgb",
                "components": {
                    "alpha": "1.000",
                    "red": f"{r / 255:.3f}",
                    "green": f"{g / 255:.3f}",
                    "blue": f"{b / 255:.3f}",
                },
            },
            "idiom": "universal",
        }],
        "info": {"author": "Tools/sync_design.py", "version": 1},
    }, indent=2) + "\n"


def stage_tints(t: dict, count: int) -> list[str]:
    """One colour name per step, padded if the solve ever grows a step."""
    tints = list(t["stageTint"]["colours"])
    while len(tints) < count:
        tints.append("cyan")
    return tints[:count]


def stage_chips(t: dict, stages: list[tuple[str, str]]) -> str:
    tints = stage_tints(t, len(stages))
    lines = []
    for index, (_, name) in enumerate(stages):
        css = "chalk" if tints[index] == "white" else tints[index]
        lines.append(f'        <span><b style="background: var(--{css})">{index + 1}</b>'
                     f'{name}</span>')
    return "\n".join(lines)


def stage_tint_swift(t: dict, stages: list[tuple[str, str]]) -> str:
    """The same eight colours again, for the app."""
    tints = stage_tints(t, len(stages))
    width = max(len(case) for case, _ in stages) + 2
    lines = ["        switch self {", "        case .hold: return Theme.attention"]
    for (case, _), tint in zip(stages, tints):
        if tint in t["sticker"]:
            value = f"CubeColour.{tint}.swiftUIColor"
        else:
            value = f"Theme.{tint}"
        lines.append(f"        case .{case}:".ljust(width + 14) + f"return {value}")
    lines.append("        }")
    return "\n".join(lines)


# ---------------------------------------------------------------------- main

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="report what has drifted instead of writing")
    parser.add_argument("--bio", type=Path, default=Path("/home/user/aboutme"),
                        help="the bio site, if it is checked out next door")
    args = parser.parse_args()

    t = load_tokens()
    stages = stages_from_swift()

    planned: list[tuple[Path, str]] = [
        (ROOT / "docs/assets/site.css", replace_block(ROOT / "docs/assets/site.css", css_block(t), "slash")),
        (ROOT / "docs/assets/cubes.js", replace_block(ROOT / "docs/assets/cubes.js", cubes_js_block(t), "slash")),
        (ROOT / "docs/index.html", replace_block(ROOT / "docs/index.html", stage_chips(t, stages), "html")),
        (ROOT / "NoobCube/UI/StageTint.swift", replace_block(ROOT / "NoobCube/UI/StageTint.swift", stage_tint_swift(t, stages), "swift")),
        (ROOT / "NoobCube/UI/Theme.swift", replace_block(ROOT / "NoobCube/UI/Theme.swift", swift_theme_block(t), "swift")),
        (ROOT / "NoobCube/CubeKit/CubeColour.swift", replace_block(ROOT / "NoobCube/CubeKit/CubeColour.swift", swift_colour_block(t), "swift")),
        (ROOT / "NoobCube/Assets.xcassets/LaunchBackground.colorset/Contents.json", colorset(t["surface"]["background"])),
        (ROOT / "NoobCube/Assets.xcassets/AccentColor.colorset/Contents.json", colorset(t["brand"][t["role"]["attention"]])),
    ]

    cubebox = args.bio / "assets" / "cubebox.js"
    if cubebox.exists():
        planned.append((cubebox, replace_block(cubebox, cubebox_js_block(t), "slash")))

    drifted = [path for path, content in planned if path.read_text() != content]

    if args.check:
        for path in drifted:
            print(f"out of step: {path}")
        if drifted:
            print(f"\n{len(drifted)} file(s) have drifted — run Tools/sync_design.py")
        else:
            print(f"all {len(planned)} files match Design/tokens.json")
        return 1 if drifted else 0

    for path, content in planned:
        path.write_text(content)
    print(f"wrote {len(planned)} files, {len(drifted)} of which had drifted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
