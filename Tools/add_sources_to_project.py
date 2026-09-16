#!/usr/bin/env python3
"""Add files that are on disk but missing from the Xcode project.

Xcode owns project.pbxproj now — it holds the development team and signing —
so regenerating it would throw that away. This adds new files in place
instead, touching nothing else:

    python3 Tools/add_sources_to_project.py

Swift files go into the compile phase; anything under NoobCube/Resources goes
into the copy-resources phase, which is how the Baloo 2 font gets into the app
bundle for Info.plist's UIAppFonts to find.

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


def group_named(text, name):
    """The PBXGroup called `name`, at the point its children start."""
    return re.search(
        r'([0-9A-F]{24}) /\* ' + re.escape(name) + r' \*/ = \{\s*isa = PBXGroup;\s*children = \(',
        text)


def file_type_of(name):
    """What Xcode calls this kind of file."""
    return {
        '.ttf': 'file.ttf',
        '.otf': 'file.otf',
        '.json': 'text.json',
        '.png': 'image.png',
    }.get(os.path.splitext(name)[1], 'file')


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
                if name.startswith('.') or name in text:
                    continue
                relative = os.path.relpath(os.path.join(dirpath, name), ROOT)
                if name.endswith('.swift'):
                    added.append((folder, relative, name, 'source'))
                elif folder == 'NoobCube' and f'{os.sep}Resources{os.sep}' in relative:
                    added.append((folder, relative, name, 'resource'))

    if not added:
        print('nothing to add: every file is already in the project')
        return

    # Find the group each file's folder belongs to, falling back to the target's
    # root group, and the sources build phase for its target.
    for folder, relative, name, kind in added:
        file_ref = oid('ref:' + relative)
        build_ref = oid('build:' + relative)
        file_type = 'sourcecode.swift' if kind == 'source' else file_type_of(name)

        # Which group the reference goes in: the one named after the file's
        # own folder, or the target's own group if that folder is new here —
        # in which case the path has to be spelled out from the target folder
        # down, so the project still points at where the file actually is.
        parent = os.path.basename(os.path.dirname(relative))
        group_name = parent if group_named(text, parent) else folder
        path_in_group = name if group_name == parent else os.path.relpath(relative, folder)

        text = text.replace(
            '/* End PBXFileReference section */',
            f'\t\t{file_ref} = {{isa = PBXFileReference; lastKnownFileType = {file_type}; '
            f'path = "{path_in_group}"; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
        text = text.replace(
            '/* End PBXBuildFile section */',
            f'\t\t{build_ref} = {{isa = PBXBuildFile; fileRef = {file_ref}; }};\n'
            '/* End PBXBuildFile section */')

        # Searched again now the replacements above have moved everything.
        group = group_named(text, group_name)
        if group:
            insert = group.end()
            text = text[:insert] + f'\n\t\t\t\t{file_ref},' + text[insert:]

        # And into that target's compile phase, or the resource phase for
        # things that are copied into the bundle rather than compiled.
        if kind == 'source':
            phases = list(re.finditer(
                r'[0-9A-F]{24} /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;(?:.|\n)*?files = \(',
                text))
            index = 0 if folder == 'NoobCube' else min(1, len(phases) - 1)
        else:
            phases = list(re.finditer(
                r'[0-9A-F]{24} /\* Resources \*/ = \{\s*isa = PBXResourcesBuildPhase;(?:.|\n)*?files = \(',
                text))
            index = 0
        if phases:
            insert = phases[index].end()
            text = text[:insert] + f'\n\t\t\t\t{build_ref},' + text[insert:]

        print(f'  added {relative}')

    open(PROJECT, 'w').write(text)
    print(f'{len(added)} file(s) added to NoobCube.xcodeproj')


if __name__ == '__main__':
    main()
