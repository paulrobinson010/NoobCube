#!/usr/bin/env python3
"""Find Swift calls whose argument labels are in a different order from the
declaration, which Swift rejects and which is easy to do by accident when a
function grows a new parameter.

    python3 Tools/check_call_order.py

There is no Swift compiler on the machine this project is mostly written on,
so this stands in for the one diagnostic that keeps coming back.

It only reports a call when the labels are out of order for *every* declaration
of that name. The first version of this script threw away any name declared
more than once, to avoid guessing which overload a call meant — and promptly
missed a real error, because `step` is declared twice.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def labels(header):
    """The argument labels in a parameter list or a call, in order.

    Three things have to be stepped over, each of which this got wrong once and
    each of which hid a real error:

      * string literals, because the words the app says out loud are full of
        commas, and a comma inside one split an argument in half;
      * angle brackets, but only where they are generics — counting the `<` in
        `count <= 4` as a bracket swallowed every argument after it;
      * nothing else, since a call is otherwise just commas at the top level.
    """
    parts, depth, angle, buffer = [], 0, 0, ""
    index = 0
    while index < len(header):
        character = header[index]
        previous = header[index - 1] if index else " "

        if character == '"':
            end = index + 1
            while end < len(header) and header[end] != '"':
                end += 2 if header[end] == "\\" else 1
            buffer += header[index:end + 1]
            index = end + 1
            continue

        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        elif character == "<" and previous.isalnum() and header[index + 1:index + 2] != "=":
            angle += 1                     # Set<Face>, not count < 4
        elif character == ">" and angle > 0 and previous != "-":
            angle -= 1

        if character == "," and depth == 0 and angle == 0:
            parts.append(buffer)
            buffer = ""
        else:
            buffer += character
        index += 1
    parts.append(buffer)

    found = []
    for part in parts:
        match = re.match(r"\s*(?:(\w+)\s+)?(\w+)\s*:", part)
        if match:
            found.append(match.group(1) or match.group(2))
    return [name for name in found if name != "_"]


def closing(text, start):
    """The index of the bracket that closes the one just opened."""
    depth, index = 1, start
    while depth and index < len(text):
        character = text[index]
        if character == '"':
            index += 1
            while index < len(text) and text[index] != '"':
                index += 2 if text[index] == "\\" else 1
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
        index += 1
    return index - 1


def main():
    files = sorted(ROOT.glob("NoobCube/**/*.swift")) + sorted(ROOT.glob("NoobCubeTests/**/*.swift"))
    sources = {path: path.read_text() for path in files}

    # Every declaration of every name, because a name can have several.
    declarations = {}
    for source in sources.values():
        for match in re.finditer(r"\bfunc\s+(\w+)\s*\(", source):
            order = labels(source[match.end():closing(source, match.end())])
            declarations.setdefault(match.group(1), []).append(order)

    problems = 0
    for path, source in sources.items():
        for name, orders in declarations.items():
            # A dot in front is the usual case — builder.step(...) — so only a
            # word character rules a match out. Excluding the dot as well meant
            # every method call was skipped, which is every call there is.
            for match in re.finditer(r"(?<!\w)" + re.escape(name) + r"\(", source):
                if re.search(r"\bfunc\s+$", source[:match.start()]):
                    continue
                used = labels(source[match.end():closing(source, match.end())])
                if not used:
                    continue
                # In order for any one of the declarations is good enough.
                if any(sorted([l for l in used if l in order], key=order.index)
                       == [l for l in used if l in order]
                       and all(l in order for l in used)
                       for order in orders):
                    continue
                if not any(all(l in order for l in used) for order in orders):
                    continue          # a call to something else of the same name
                line = source[:match.start()].count("\n") + 1
                wanted = min((o for o in orders if all(l in o for l in used)),
                             key=lambda o: len(o))
                print("%s:%d  %s(%s) should be (%s)"
                      % (path.relative_to(ROOT), line, name, ", ".join(used),
                         ", ".join(sorted(used, key=wanted.index))))
                problems += 1

    print("%d call(s) with their arguments out of order" % problems)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
