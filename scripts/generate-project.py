#!/usr/bin/env python3
"""Generate a conventional Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parent.parent
objects = {}
existing_settings = {}
existing_project = ROOT / "MuxManager.xcodeproj/project.pbxproj"
if existing_project.exists():
    parsed = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(existing_project)]))
    for obj in parsed["objects"].values():
        if obj.get("isa") == "XCBuildConfiguration" and "PRODUCT_NAME" in obj.get("buildSettings", {}):
            existing_settings[obj["name"]] = {key: value for key, value in obj["buildSettings"].items()
                                               if key in ["PRODUCT_BUNDLE_IDENTIFIER", "DEVELOPMENT_TEAM", "CODE_SIGN_IDENTITY", "PROVISIONING_PROFILE_SPECIFIER", "CLOUD_CONTAINER_IDENTIFIER"]}


def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(identifier, isa, **values):
    key = uid(identifier)
    objects[key] = dict(isa=isa, **values)
    return key


def serialize(value, indent=0):
    if isinstance(value, dict):
        body = "\n".join("\t" * (indent + 1) + json.dumps(str(k)) + " = " + serialize(v, indent + 1) + ";" for k, v in value.items())
        return "{\n" + body + "\n" + "\t" * indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (indent + 1) + serialize(v, indent + 1) + ",\n" for v in value) + "\t" * indent + ")"
    return str(value) if isinstance(value, int) else json.dumps(value)


files = []
sources = []
for path in sorted((ROOT / "MuxManager").rglob("*.swift")):
    relative = str(path.relative_to(ROOT))
    ref = add("file:" + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
    files.append(ref)
    sources.append(add("build:" + relative, "PBXBuildFile", fileRef=ref))

assets = add("assets", "PBXFileReference", lastKnownFileType="folder.assetcatalog", path="MuxManager/Assets.xcassets", sourceTree="SOURCE_ROOT")
assetBuild = add("assets-build", "PBXBuildFile", fileRef=assets)
notices = add("notices", "PBXFileReference", lastKnownFileType="text", path="MuxManager/Resources/ThirdPartyNotices.txt", sourceTree="SOURCE_ROOT")
noticesBuild = add("notices-build", "PBXBuildFile", fileRef=notices)
baseConfig = add("config", "PBXFileReference", lastKnownFileType="text.xcconfig", path="Config/Base.xcconfig", sourceTree="SOURCE_ROOT")
product = add("product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="Mux Manager.app", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", "PBXGroup", children=[product], name="Products", sourceTree="<group>")
main = add("main", "PBXGroup", children=files + [assets, notices, baseConfig, products], sourceTree="<group>")
sourcePhase = add("sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0)
resourcePhase = add("resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[assetBuild, noticesBuild], runOnlyForDeploymentPostprocessing=0)

packages = [add("local-core", "XCLocalSwiftPackageReference", relativePath=".")]
productsList = [add("core-dep", "XCSwiftPackageProductDependency", productName="MuxCore")]
for name, url, version in [
    ("Citadel", "https://github.com/orlandos-nl/Citadel.git", "0.12.1"),
    ("SwiftTerm", "https://github.com/migueldeicaza/SwiftTerm.git", "1.19.0"),
]:
    package = add("package:" + name, "XCRemoteSwiftPackageReference", repositoryURL=url, requirement={"kind": "exactVersion", "version": version})
    packages.append(package)
    productsList.append(add("dependency:" + name, "XCSwiftPackageProductDependency", package=package, productName=name))

frameworkPhase = add("frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                     files=[add("framework:" + p, "PBXBuildFile", productRef=p) for p in productsList], runOnlyForDeploymentPostprocessing=0)

def configurations(prefix, is_target):
    configs = []
    for name in ["Debug", "Release"]:
        settings = {"SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "CLANG_ENABLE_MODULES": "YES"}
        if is_target:
            settings.update({"PRODUCT_NAME": "Mux Manager", "SWIFT_EMIT_LOC_STRINGS": "YES", "GENERATE_INFOPLIST_FILE": "NO", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks"})
            settings.update(existing_settings.get(name, {}))
        if name == "Debug":
            settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone", "DEBUG_INFORMATION_FORMAT": "dwarf", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "ENABLE_TESTABILITY": "YES"})
        else:
            settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-O", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule"})
        args = {"baseConfigurationReference": baseConfig} if is_target else {}
        configs.append(add(prefix + name, "XCBuildConfiguration", name=name, buildSettings=settings, **args))
    return add(prefix + "configs", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

target = add("target", "PBXNativeTarget", buildConfigurationList=configurations("target-", True),
             buildPhases=[sourcePhase, frameworkPhase, resourcePhase], buildRules=[], dependencies=[],
             name="MuxManager", packageProductDependencies=productsList, productName="Mux Manager", productReference=product,
             productType="com.apple.product-type.application")
project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600", "TargetAttributes": {target: {"CreatedOnToolsVersion": "16.0", "SystemCapabilities": {"com.apple.iCloud": {"enabled": 1}}}}},
              buildConfigurationList=configurations("project-", False), compatibilityVersion="Xcode 15.0", developmentRegion="en", hasScannedForEncodings=0,
              knownRegions=["en", "Base"], mainGroup=main, packageReferences=packages, productRefGroup=products, projectDirPath="", projectRoot="", targets=[target])
directory = ROOT / "MuxManager.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize({"archiveVersion": 1, "classes": {}, "objectVersion": 60, "objects": objects, "rootObject": project}) + "\n")
schemes = directory / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "MuxManager.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Mux Manager.app" BlueprintName="MuxManager" ReferencedContainer="container:MuxManager.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Mux Manager.app" BlueprintName="MuxManager" ReferencedContainer="container:MuxManager.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Mux Manager.app" BlueprintName="MuxManager" ReferencedContainer="container:MuxManager.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated MuxManager.xcodeproj")
