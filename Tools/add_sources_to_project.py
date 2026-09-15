#!/usr/bin/env python3
"""Add Swift files that are on disk but missing from the Xcode project.

Xcode owns project.pbxproj now — it holds the development team and signing —
so regenerating it would throw that away. This adds new source files in place
instead, touching nothing else:

    python3 Tools/add_sources_to_project.py

It is safe to run repeatedly; files already in the project are left alone.
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, 'NoobCube.xcodeproj', 'project.pbxproj')
TARGETS = {'NoobCube': 'app', 'NoobCubeTests': 'tests'}


def oid(role):
    return hashlib.sha1(('add:' + role).encode()).hexdigest()[:24].upper()


def main():
    if not os.path.exists(PROJECT):
        sys.exit('no project.pbxproj — run Tools/generate_xcodeproj.py first')
    text = open(PROJECT).read()

    added = []
    for folder in TARGETS:
        base = os.path.join(ROOT, folder)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            for name in sorted(filenames):
                if not name.endswith('.swift') or name in text:
                    continue
                relative = os.path.relpath(os.path.join(dirpath, name), ROOT)
                added.append((folder, relative, name))

    if not added:
        print('nothing to add: every Swift file is already in the project')
        return

    # Find the group each file's folder belongs to, falling back to the target's
    # root group, and the sources build phase for its target.
    for folder, relative, name in added:
        file_ref = oid('ref:' + relative)
        build_ref = oid('build:' + relative)

        text = text.replace(
            '/* End PBXFileReference section */',
            f'\t\t{file_ref} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
            f'path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
        text = text.replace(
            '/* End PBXBuildFile section */',
            f'\t\t{build_ref} = {{isa = PBXBuildFile; fileRef = {file_ref}; }};\n'
            '/* End PBXBuildFile section */')

        # Put the reference in the group whose path matches the file's folder.
        parent = os.path.basename(os.path.dirname(relative))
        group = re.search(
            r'([0-9A-F]{24}) /\* ' + re.escape(parent) + r' \*/ = \{\s*isa = PBXGroup;\s*children = \(',
            text)
        if not group:
            group = re.search(
                r'([0-9A-F]{24}) /\* ' + re.escape(folder) + r' \*/ = \{\s*isa = PBXGroup;\s*children = \(',
                text)
        if group:
            insert = group.end()
            text = text[:insert] + f'\n\t\t\t\t{file_ref},' + text[insert:]

        # And into that target's compile phase.
        phase = re.search(
            r'([0-9A-F]{24}) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;.*?files = \(',
            text, re.S if folder == 'NoobCube' else re.S)
        phases = list(re.finditer(
            r'[0-9A-F]{24} /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;(?:.|\n)*?files = \(',
            text))
        index = 0 if folder == 'NoobCube' else min(1, len(phases) - 1)
        if phases:
            insert = phases[index].end()
            text = text[:insert] + f'\n\t\t\t\t{build_ref},' + text[insert:]

        print(f'  added {relative}')

    open(PROJECT, 'w').write(text)
    print(f'{len(added)} file(s) added to NoobCube.xcodeproj')


if __name__ == '__main__':
    main()
