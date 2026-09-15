#!/usr/bin/env python3
"""Generate NoobCube.xcodeproj from whatever is on disk.

Hand-editing a pbxproj is a good way to produce a project Xcode will not open,
so it is generated instead. Re-run this after adding or removing source files:

    python3 Tools/generate_xcodeproj.py

Object identifiers are derived from a hash of each object's role, so re-running
produces the same file and the diff stays readable.
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = 'NoobCube'
TESTS = 'NoobCubeTests'
BUNDLE_ID = 'com.noobcube.app'
DEPLOYMENT_TARGET = '17.0'
SWIFT_VERSION = '5.0'

# Camera and Bluetooth usage strings live in NoobCube/Info.plist.


def oid(role):
    """A stable 24 character hex identifier for an object."""
    return hashlib.sha1(role.encode()).hexdigest()[:24].upper()


# ---------------------------------------------------------------- plist output

BARE = re.compile(r'^[A-Za-z0-9_./]+$')


def fmt(value, indent=1):
    pad = '\t' * indent
    closing = '\t' * (indent - 1)
    if isinstance(value, dict):
        if not value:
            return '{\n' + closing + '}'
        lines = ['{']
        for key in sorted(value):
            lines.append(f'{pad}{quote(key)} = {fmt(value[key], indent + 1)};')
        lines.append(closing + '}')
        return '\n'.join(lines)
    if isinstance(value, list):
        if not value:
            return '(\n' + closing + ')'
        lines = ['(']
        for item in value:
            lines.append(f'{pad}{fmt(item, indent + 1)},')
        lines.append(closing + ')')
        return '\n'.join(lines)
    return quote(str(value))


def quote(text):
    if text and BARE.match(text):
        return text
    escaped = text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
    return f'"{escaped}"'


# ---------------------------------------------------------------- file walking

def swift_files(folder):
    """Every .swift file under `folder`, relative to it, in a stable order."""
    found = []
    base = os.path.join(ROOT, folder)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith('.swift'):
                rel = os.path.relpath(os.path.join(dirpath, name), base)
                found.append(rel)
    return found


class Builder:
    def __init__(self):
        self.objects = {}

    def add(self, key, body):
        identifier = oid(key)
        self.objects[identifier] = body
        return identifier

    def group_tree(self, top_folder, relative_paths, extra_children=None):
        """Build PBXGroups mirroring the folder layout, return the root group id."""
        tree = {}
        for rel in relative_paths:
            parts = rel.split(os.sep)
            node = tree
            for part in parts[:-1]:
                node = node.setdefault(part, {})
            node.setdefault('__files__', []).append(parts[-1])

        def build(node, path_prefix, name, is_root):
            children = []
            for filename in sorted(node.get('__files__', [])):
                rel = os.path.join(path_prefix, filename) if path_prefix else filename
                children.append(self.add(f'fileref:{top_folder}/{rel}', {
                    'isa': 'PBXFileReference',
                    'lastKnownFileType': 'sourcecode.swift',
                    'path': filename,
                    'sourceTree': '<group>',
                }))
            for sub in sorted(k for k in node if k != '__files__'):
                sub_prefix = os.path.join(path_prefix, sub) if path_prefix else sub
                children.append(build(node[sub], sub_prefix, sub, False))
            if is_root and extra_children:
                children.extend(extra_children)
            return self.add(f'group:{top_folder}/{path_prefix}', {
                'isa': 'PBXGroup',
                'children': children,
                'path': name,
                'sourceTree': '<group>',
            })

        return build(tree, '', top_folder, True)


def build_project():
    b = Builder()

    app_sources = swift_files(APP)
    test_sources = swift_files(TESTS)
    if not app_sources:
        sys.exit(f'no Swift files found under {APP}/')

    # Asset catalog and Info.plist live inside the app folder. The plist is
    # referenced through INFOPLIST_FILE, not a build phase, so it is listed
    # here only so it shows up in the navigator.
    assets_ref = b.add('fileref:assets', {
        'isa': 'PBXFileReference',
        'lastKnownFileType': 'folder.assetcatalog',
        'path': 'Assets.xcassets',
        'sourceTree': '<group>',
    })
    plist_ref = b.add('fileref:infoplist', {
        'isa': 'PBXFileReference',
        'lastKnownFileType': 'text.plist.xml',
        'path': 'Info.plist',
        'sourceTree': '<group>',
    })

    app_group = b.group_tree(APP, app_sources, extra_children=[assets_ref, plist_ref])
    test_group = b.group_tree(TESTS, test_sources)

    app_product = b.add('product:app', {
        'isa': 'PBXFileReference',
        'explicitFileType': 'wrapper.application',
        'includeInIndex': 0,
        'path': f'{APP}.app',
        'sourceTree': 'BUILT_PRODUCTS_DIR',
    })
    test_product = b.add('product:tests', {
        'isa': 'PBXFileReference',
        'explicitFileType': 'wrapper.cfbundle',
        'includeInIndex': 0,
        'path': f'{TESTS}.xctest',
        'sourceTree': 'BUILT_PRODUCTS_DIR',
    })
    products_group = b.add('group:Products', {
        'isa': 'PBXGroup',
        'children': [app_product, test_product],
        'name': 'Products',
        'sourceTree': '<group>',
    })
    main_group = b.add('group:main', {
        'isa': 'PBXGroup',
        'children': [app_group, test_group, products_group],
        'sourceTree': '<group>',
    })

    def build_files(folder, sources, tag):
        ids = []
        for rel in sources:
            ids.append(b.add(f'buildfile:{tag}:{rel}', {
                'isa': 'PBXBuildFile',
                'fileRef': oid(f'fileref:{folder}/{rel}'),
            }))
        return ids

    app_build_files = build_files(APP, app_sources, 'app')
    test_build_files = build_files(TESTS, test_sources, 'tests')
    assets_build_file = b.add('buildfile:assets', {
        'isa': 'PBXBuildFile',
        'fileRef': assets_ref,
    })

    app_sources_phase = b.add('phase:app:sources', {
        'isa': 'PBXSourcesBuildPhase',
        'buildActionMask': 2147483647,
        'files': app_build_files,
        'runOnlyForDeploymentPostprocessing': 0,
    })
    app_resources_phase = b.add('phase:app:resources', {
        'isa': 'PBXResourcesBuildPhase',
        'buildActionMask': 2147483647,
        'files': [assets_build_file],
        'runOnlyForDeploymentPostprocessing': 0,
    })
    app_frameworks_phase = b.add('phase:app:frameworks', {
        'isa': 'PBXFrameworksBuildPhase',
        'buildActionMask': 2147483647,
        'files': [],
        'runOnlyForDeploymentPostprocessing': 0,
    })
    test_sources_phase = b.add('phase:tests:sources', {
        'isa': 'PBXSourcesBuildPhase',
        'buildActionMask': 2147483647,
        'files': test_build_files,
        'runOnlyForDeploymentPostprocessing': 0,
    })
    test_frameworks_phase = b.add('phase:tests:frameworks', {
        'isa': 'PBXFrameworksBuildPhase',
        'buildActionMask': 2147483647,
        'files': [],
        'runOnlyForDeploymentPostprocessing': 0,
    })

    shared = {
        'ALWAYS_SEARCH_USER_PATHS': 'NO',
        'CLANG_ENABLE_MODULES': 'YES',
        'CLANG_ENABLE_OBJC_ARC': 'YES',
        'COPY_PHASE_STRIP': 'NO',
        'ENABLE_STRICT_OBJC_MSGSEND': 'YES',
        'ENABLE_USER_SCRIPT_SANDBOXING': 'YES',
        'GCC_NO_COMMON_BLOCKS': 'YES',
        'IPHONEOS_DEPLOYMENT_TARGET': DEPLOYMENT_TARGET,
        'SDKROOT': 'iphoneos',
        'SWIFT_VERSION': SWIFT_VERSION,
        'TARGETED_DEVICE_FAMILY': '1,2',
    }
    debug = dict(shared, **{
        'DEBUG_INFORMATION_FORMAT': 'dwarf',
        'ENABLE_TESTABILITY': 'YES',
        'GCC_OPTIMIZATION_LEVEL': '0',
        'GCC_PREPROCESSOR_DEFINITIONS': ['DEBUG=1', '$(inherited)'],
        'MTL_ENABLE_DEBUG_INFO': 'INCLUDE_SOURCE',
        'ONLY_ACTIVE_ARCH': 'YES',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG $(inherited)',
        'SWIFT_OPTIMIZATION_LEVEL': '-Onone',
    })
    release = dict(shared, **{
        'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym',
        'ENABLE_NS_ASSERTIONS': 'NO',
        'MTL_ENABLE_DEBUG_INFO': 'NO',
        'SWIFT_COMPILATION_MODE': 'wholemodule',
        'VALIDATE_PRODUCT': 'YES',
    })

    app_settings = {
        'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
        'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME': 'AccentColor',
        'CODE_SIGN_STYLE': 'Automatic',
        'CURRENT_PROJECT_VERSION': '1',
        'ENABLE_PREVIEWS': 'YES',
        # A real Info.plist rather than a generated one: the launch screen is a
        # UILaunchScreen dictionary, which INFOPLIST_KEY_ settings cannot express.
        'GENERATE_INFOPLIST_FILE': 'NO',
        'INFOPLIST_FILE': f'{APP}/Info.plist',
        'MARKETING_VERSION': '1.0',
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID,
        'PRODUCT_NAME': '$(TARGET_NAME)',
        'SWIFT_EMIT_LOC_STRINGS': 'YES',
    }
    test_settings = {
        'BUNDLE_LOADER': '$(TEST_HOST)',
        'CODE_SIGN_STYLE': 'Automatic',
        'CURRENT_PROJECT_VERSION': '1',
        'GENERATE_INFOPLIST_FILE': 'YES',
        'MARKETING_VERSION': '1.0',
        'PRODUCT_BUNDLE_IDENTIFIER': f'{BUNDLE_ID}.tests',
        'PRODUCT_NAME': '$(TARGET_NAME)',
        'SWIFT_EMIT_LOC_STRINGS': 'NO',
        'TEST_HOST': f'$(BUILT_PRODUCTS_DIR)/{APP}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{APP}',
    }

    def config_list(tag, debug_settings, release_settings):
        d = b.add(f'config:{tag}:debug', {
            'isa': 'XCBuildConfiguration',
            'buildSettings': debug_settings,
            'name': 'Debug',
        })
        r = b.add(f'config:{tag}:release', {
            'isa': 'XCBuildConfiguration',
            'buildSettings': release_settings,
            'name': 'Release',
        })
        return b.add(f'configlist:{tag}', {
            'isa': 'XCConfigurationList',
            'buildConfigurations': [d, r],
            'defaultConfigurationIsVisible': 0,
            'defaultConfigurationName': 'Release',
        })

    project_configs = config_list('project', debug, release)
    app_configs = config_list('app', dict(app_settings), dict(app_settings))
    test_configs = config_list('tests', dict(test_settings), dict(test_settings))

    app_target = oid('target:app')
    proxy = b.add('proxy:app', {
        'isa': 'PBXContainerItemProxy',
        'containerPortal': oid('project'),
        'proxyType': 1,
        'remoteGlobalIDString': app_target,
        'remoteInfo': APP,
    })
    dependency = b.add('dependency:tests', {
        'isa': 'PBXTargetDependency',
        'target': app_target,
        'targetProxy': proxy,
    })

    b.add('target:app', {
        'isa': 'PBXNativeTarget',
        'buildConfigurationList': app_configs,
        'buildPhases': [app_sources_phase, app_frameworks_phase, app_resources_phase],
        'buildRules': [],
        'dependencies': [],
        'name': APP,
        'productName': APP,
        'productReference': app_product,
        'productType': 'com.apple.product-type.application',
    })
    test_target = b.add('target:tests', {
        'isa': 'PBXNativeTarget',
        'buildConfigurationList': test_configs,
        'buildPhases': [test_sources_phase, test_frameworks_phase],
        'buildRules': [],
        'dependencies': [dependency],
        'name': TESTS,
        'productName': TESTS,
        'productReference': test_product,
        'productType': 'com.apple.product-type.bundle.unit-test',
    })

    b.add('project', {
        'isa': 'PBXProject',
        'attributes': {
            'BuildIndependentTargetsInParallel': 1,
            'LastSwiftUpdateCheck': 1600,
            'LastUpgradeCheck': 1600,
            'TargetAttributes': {
                app_target: {'CreatedOnToolsVersion': '16.0'},
                test_target: {'CreatedOnToolsVersion': '16.0', 'TestTargetID': app_target},
            },
        },
        'buildConfigurationList': project_configs,
        'compatibilityVersion': 'Xcode 14.0',
        'developmentRegion': 'en',
        'hasScannedForEncodings': 0,
        'knownRegions': ['en', 'Base'],
        'mainGroup': main_group,
        'productRefGroup': products_group,
        'projectDirPath': '',
        'projectRoot': '',
        'targets': [app_target, test_target],
    })

    return {
        'archiveVersion': 1,
        'classes': {},
        'objectVersion': 56,
        'objects': b.objects,
        'rootObject': oid('project'),
    }


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "{app}.app"
               BlueprintName = "{app}"
               ReferencedContainer = "container:{app}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "{tests}.xctest"
               BlueprintName = "{tests}"
               ReferencedContainer = "container:{app}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{app}.app"
            BlueprintName = "{app}"
            ReferencedContainer = "container:{app}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{app}.app"
            BlueprintName = "{app}"
            ReferencedContainer = "container:{app}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""


def write_scheme(out_dir):
    folder = os.path.join(out_dir, 'xcshareddata', 'xcschemes')
    os.makedirs(folder, exist_ok=True)
    body = SCHEME.format(app=APP, tests=TESTS,
                         app_target=oid('target:app'),
                         test_target=oid('target:tests'))
    with open(os.path.join(folder, f'{APP}.xcscheme'), 'w') as handle:
        handle.write(body)


def main():
    project = build_project()
    out_dir = os.path.join(ROOT, f'{APP}.xcodeproj')
    os.makedirs(out_dir, exist_ok=True)
    body = '// !$*UTF8*$!\n' + fmt(project) + '\n'
    with open(os.path.join(out_dir, 'project.pbxproj'), 'w') as handle:
        handle.write(body)
    write_scheme(out_dir)
    count = len(project['objects'])
    print(f'wrote {APP}.xcodeproj/project.pbxproj ({count} objects) and a shared scheme')


if __name__ == '__main__':
    main()
