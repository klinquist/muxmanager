#!/usr/bin/env python3
"""Generate the native macOS Xcode project without changing the iOS project."""
from pathlib import Path
import hashlib
import json
import shutil
root = Path(__file__).resolve().parent.parent
o = {}

def add(identifier, isa, **kw):
    k = hashlib.sha256(('mac:' + identifier).encode()).hexdigest()[:24].upper()
    o[k] = dict(isa=isa, **kw)
    return k

def ser(v, n=0):
    if isinstance(v, dict):
        return '{\n' + ''.join(('\t' * (n + 1) + json.dumps(str(k)) + ' = ' + ser(x, n + 1) + ';\n' for k, x in v.items())) + '\t' * n + '}'
    if isinstance(v, list):
        return '(\n' + ''.join(('\t' * (n + 1) + ser(x, n + 1) + ',\n' for x in v)) + '\t' * n + ')'
    return str(v) if isinstance(v, int) else json.dumps(v)
refs = []
build = []
for p in sorted((root / 'MuxManager').rglob('*.swift')):
    path = str(p.relative_to(root))
    if path in ['MuxManager/App/MuxManagerApp.swift', 'MuxManager/Views/WorkspaceView.swift'] or '/Terminal/' in path:
        continue
    r = add(path, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=path, sourceTree='SOURCE_ROOT')
    refs.append(r)
    build.append(add('build:' + path, 'PBXBuildFile', fileRef=r))
assets = add('assets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog', path='MuxManager/Assets.xcassets', sourceTree='SOURCE_ROOT')
notices = add('notices', 'PBXFileReference', lastKnownFileType='text', path='MuxManager/Resources/ThirdPartyNotices.txt', sourceTree='SOURCE_ROOT')
config = add('config', 'PBXFileReference', lastKnownFileType='text.xcconfig', path='Config/Mac.xcconfig', sourceTree='SOURCE_ROOT')
product = add('product', 'PBXFileReference', explicitFileType='wrapper.application', includeInIndex=0, path='Mux Manager.app', sourceTree='BUILT_PRODUCTS_DIR')
products = add('products', 'PBXGroup', children=[product], name='Products', sourceTree='<group>')
group = add('main', 'PBXGroup', children=refs + [assets, notices, config, products], sourceTree='<group>')
source = add('sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=build, runOnlyForDeploymentPostprocessing=0)
resource = add('resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[add('assets-build', 'PBXBuildFile', fileRef=assets), add('notices-build', 'PBXBuildFile', fileRef=notices)], runOnlyForDeploymentPostprocessing=0)
packages = [add('core', 'XCLocalSwiftPackageReference', relativePath='.')]
deps = [add('core-dep', 'XCSwiftPackageProductDependency', productName='MuxCore')]
for name, url, version in [('Citadel', 'https://github.com/orlandos-nl/Citadel.git', '0.12.1'), ('SwiftTerm', 'https://github.com/migueldeicaza/SwiftTerm.git', '1.19.0')]:
    p = add(name, 'XCRemoteSwiftPackageReference', repositoryURL=url, requirement={'kind': 'exactVersion', 'version': version})
    packages.append(p)
    deps.append(add('dep:' + name, 'XCSwiftPackageProductDependency', package=p, productName=name))
frameworks = add('frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[add('framework:' + d, 'PBXBuildFile', productRef=d) for d in deps], runOnlyForDeploymentPostprocessing=0)

def configs(prefix, target):
    ids = []
    for name in ['Debug', 'Release']:
        settings = {'SDKROOT': 'macosx', 'SUPPORTED_PLATFORMS': 'macosx', 'MACOSX_DEPLOYMENT_TARGET': '15.0', 'CLANG_ENABLE_MODULES': 'YES', 'SWIFT_VERSION': '5.0', 'SWIFT_STRICT_CONCURRENCY': 'targeted', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if name == 'Debug' else '-O'}
        if name == 'Debug':
            settings.update(SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG $(inherited)', ENABLE_TESTABILITY='YES', ONLY_ACTIVE_ARCH='YES', DEBUG_INFORMATION_FORMAT='dwarf')
        else:
            settings.update(SWIFT_COMPILATION_MODE='wholemodule', DEBUG_INFORMATION_FORMAT='dwarf-with-dsym')
        if target:
            settings.update(PRODUCT_NAME='Mux Manager', GENERATE_INFOPLIST_FILE='NO', SWIFT_EMIT_LOC_STRINGS='YES')
        ids.append(add(prefix + name, 'XCBuildConfiguration', name=name, buildSettings=settings, **{'baseConfigurationReference': config} if target else {}))
    return add(prefix + 'configs', 'XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
target = add('target', 'PBXNativeTarget', buildConfigurationList=configs('target', True), buildPhases=[source, frameworks, resource], buildRules=[], dependencies=[], name='MuxManagerMac', packageProductDependencies=deps, productName='Mux Manager', productReference=product, productType='com.apple.product-type.application')
test_file = add('mac-tests-file', 'PBXFileReference', lastKnownFileType='sourcecode.swift', path='Tests/MuxManagerMacTests/MacAppTests.swift', sourceTree='SOURCE_ROOT')
o[group]['children'].insert(0, test_file)
test_sources = add('mac-tests-source', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=[add('mac-tests-build', 'PBXBuildFile', fileRef=test_file)], runOnlyForDeploymentPostprocessing=0)
test_product = add('mac-tests-product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', includeInIndex=0, path='MuxManagerMacTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
o[products]['children'].append(test_product)
test_config_ids = []
for name in ['Debug', 'Release']:
    settings = {'PRODUCT_NAME': 'MuxManagerMacTests', 'PRODUCT_BUNDLE_IDENTIFIER': '$(MUX_TEST_BUNDLE_PREFIX).macos-tests', 'MUX_TEST_BUNDLE_PREFIX': 'com.linquist.muxmanager', 'GENERATE_INFOPLIST_FILE': 'YES', 'INFOPLIST_FILE': '', 'CODE_SIGN_ENTITLEMENTS': '', 'BUNDLE_LOADER': '$(TEST_HOST)', 'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/Mux Manager.app/Contents/MacOS/Mux Manager', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @loader_path/../Frameworks @executable_path/../Frameworks'}
    test_config_ids.append(add('mac-tests-config-' + name, 'XCBuildConfiguration', name=name, baseConfigurationReference=config, buildSettings=settings))
test_config = add('mac-tests-configs', 'XCConfigurationList', buildConfigurations=test_config_ids, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
test_dependency = add('mac-tests-dependency', 'PBXTargetDependency', target=target)
test_target = add('mac-tests-target', 'PBXNativeTarget', buildConfigurationList=test_config, buildPhases=[test_sources], buildRules=[], dependencies=[test_dependency], name='MuxManagerMacTests', productName='MuxManagerMacTests', productReference=test_product, productType='com.apple.product-type.bundle.unit-test')
project = add('project', 'PBXProject', attributes={'BuildIndependentTargetsInParallel': 'YES', 'LastUpgradeCheck': '2710', 'TargetAttributes': {target: {'CreatedOnToolsVersion': '27.1', 'SystemCapabilities': {'com.apple.iCloud': {'enabled': 1}, 'com.apple.Sandbox': {'enabled': 1}}}}}, buildConfigurationList=configs('project', False), compatibilityVersion='Xcode 15.0', developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en', 'Base'], mainGroup=group, packageReferences=packages, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target, test_target])
dir = root / 'MuxManagerMac.xcodeproj'
dir.mkdir(exist_ok=True)
(dir / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + ser({'archiveVersion': 1, 'classes': {}, 'objectVersion': 60, 'objects': o, 'rootObject': project}) + '\n')
schemes = dir / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Mux Manager.app" BlueprintName="MuxManagerMac" ReferencedContainer="container:MuxManagerMac.xcodeproj"/>'
(schemes / 'MuxManagerMac.xcscheme').write_text(f'<?xml version="1.0" encoding="UTF-8"?>\n<Scheme LastUpgradeVersion="2710" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="NO"><EnvironmentVariables><EnvironmentVariable key="MUX_SCREENSHOT_SCENE" value="mac-tests" isEnabled="YES"/></EnvironmentVariables><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="MuxManagerMacTests.xctest" BlueprintName="MuxManagerMacTests" ReferencedContainer="container:MuxManagerMac.xcodeproj"/></TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>')
lock = dir / 'project.xcworkspace/xcshareddata/swiftpm'
lock.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'MuxManager.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', lock / 'Package.resolved')
print('Generated native Mac project using shared backend and pinned dependencies.')
