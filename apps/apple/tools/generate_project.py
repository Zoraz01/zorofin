#!/usr/bin/env python3
"""Generate a deterministic, dependency-free Xcode project and shared schemes."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
# Both platform targets belong to one App Store Connect record.
APP_BUNDLE_ID = "org.zorofin.app"
# Platform releases can advance independently within the shared store record.
# Advance the relevant build number for every upload; Top Shelf follows tvOS.
RELEASE_VERSIONS = {"iOS": ("1.5", "64"), "tvOS": ("1.5", "65")}
# App Store validation permits a single suffix component for embedded extensions.
TOP_SHELF_BUNDLE_ID = APP_BUNDLE_ID + ".topshelf"
objects = {}


def write_plist(path, value):
    # Preserve equivalent release metadata byte-for-byte, including its ordering.
    if path.exists() and plistlib.loads(path.read_bytes()) == value:
        return
    with path.open("wb") as stream:
        plistlib.dump(value, stream, sort_keys=True)


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def obj(key_name, isa, **fields):
    key = identifier(key_name)
    objects[key] = dict(isa=isa, **fields)
    return key


def encode(value, depth=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (depth + 1) + json.dumps(str(k)) + " = " + encode(v, depth + 1) + ";\n" for k, v in value.items()) + "\t" * depth + "}"
    if isinstance(value, list):
        return "(" + ", ".join(encode(v, depth) for v in value) + ")"
    return json.dumps(str(value))


sources = sorted((ROOT / "App").glob("*.swift"))
# Asset catalogs are bundles, not collections of individual resource files.
resource_root = ROOT / "Resources"
catalogs = sorted(resource_root.rglob("*.xcassets"))
resources = sorted([p for p in resource_root.rglob("*") if p.is_file()
                    and not any(catalog in p.parents for catalog in catalogs)] + catalogs)
refs = {}
for path in sources + resources:
    relative = path.relative_to(ROOT).as_posix()
    kind = {".swift": "sourcecode.swift", ".png": "image.png", ".xcassets": "folder.assetcatalog"}.get(path.suffix, "file")
    refs[relative] = obj(relative, "PBXFileReference", lastKnownFileType=kind, path=relative, sourceTree="<group>")

package = obj("CorePackage", "XCLocalSwiftPackageReference", relativePath="Core")
# On-device playback for files AVPlayer can't open (App/OnDevicePlayer.swift).
# LGPL-3.0 with an App Store exception; see THIRD_PARTY_NOTICES.md.
aether_package = obj("AetherEnginePackage", "XCRemoteSwiftPackageReference",
                     repositoryURL="https://github.com/superuser404notfound/AetherEngine",
                     requirement={"kind": "upToNextMinorVersion", "minimumVersion": "7.73.0"})
products = obj("Products", "PBXGroup", children=[], name="Products", sourceTree="<group>")
main = obj("Main", "PBXGroup", children=list(refs.values()) + [products], sourceTree="<group>")
targets = []
project_configs = []
for config in ["Debug", "Release"]:
    settings = {"SWIFT_VERSION": "6.0", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
                "SWIFT_STRICT_CONCURRENCY": "complete", "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym"}
    if config == "Debug":
        settings.update(SWIFT_OPTIMIZATION_LEVEL="-Onone", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG", ENABLE_TESTABILITY="YES")
    project_configs.append(obj("Project" + config, "XCBuildConfiguration", name=config, buildSettings=settings))
project_config_list = obj("ProjectConfigs", "XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

for platform in ["iOS", "tvOS"]:
    marketing_version, build_number = RELEASE_VERSIONS[platform]
    name = "Zorofin-" + platform
    product = obj(name + "Product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0", path=name + ".app", sourceTree="BUILT_PRODUCTS_DIR")
    objects[products]["children"].append(product)
    source_builds = [obj(name + path.relative_to(ROOT).as_posix(), "PBXBuildFile", fileRef=refs[path.relative_to(ROOT).as_posix()]) for path in sources]
    platform_resources = [path for path in resources
                          if path.relative_to(resource_root).parts[0] not in {"iOS", "tvOS"}
                          or path.relative_to(resource_root).parts[0] == platform]
    resource_builds = [obj(name + path.relative_to(ROOT).as_posix(), "PBXBuildFile", fileRef=refs[path.relative_to(ROOT).as_posix()]) for path in platform_resources]
    core_product = obj(name + "CoreProduct", "XCSwiftPackageProductDependency", package=package, productName="ZorofinCore")
    core_build = obj(name + "CoreBuild", "PBXBuildFile", productRef=core_product)
    aether_product = obj(name + "AetherProduct", "XCSwiftPackageProductDependency", package=aether_package, productName="AetherEngine")
    aether_build = obj(name + "AetherBuild", "PBXBuildFile", productRef=aether_product)
    phases = [obj(name + "Sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=source_builds, runOnlyForDeploymentPostprocessing="0"),
              obj(name + "Frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[core_build, aether_build], runOnlyForDeploymentPostprocessing="0"),
              obj(name + "Resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=resource_builds, runOnlyForDeploymentPostprocessing="0")]
    configs = []
    for config in ["Debug", "Release"]:
        settings = {"PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": APP_BUNDLE_ID,
                    "INFOPLIST_FILE": f"Config/{platform}-Info.plist", "CODE_SIGN_STYLE": "Automatic",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "App Icon & Top Shelf Image" if platform == "tvOS" else "AppIcon",
                    "SDKROOT": "appletvos" if platform == "tvOS" else "iphoneos",
                    "SUPPORTED_PLATFORMS": "appletvos appletvsimulator" if platform == "tvOS" else "iphoneos iphonesimulator",
                    "TARGETED_DEVICE_FAMILY": "3" if platform == "tvOS" else "1,2",
                    "TVOS_DEPLOYMENT_TARGET" if platform == "tvOS" else "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
                    "SWIFT_EMIT_LOC_STRINGS": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
                    "MARKETING_VERSION": marketing_version, "CURRENT_PROJECT_VERSION": build_number}
        if platform == "tvOS":
            settings["CODE_SIGN_ENTITLEMENTS"] = "Config/tvOS.entitlements"
            # AetherEngine's libdovi ships an arm64-only tvOS simulator slice.
            settings["EXCLUDED_ARCHS[sdk=appletvsimulator*]"] = "x86_64"
        configs.append(obj(name + config, "XCBuildConfiguration", name=config, buildSettings=settings))
    config_list = obj(name + "Configs", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")
    target = obj(name, "PBXNativeTarget", buildConfigurationList=config_list, buildPhases=phases, buildRules=[], dependencies=[],
                 name=name, productName=name, productReference=product, productType="com.apple.product-type.application", packageProductDependencies=[core_product, aether_product])
    targets.append(target)
    scheme_dir = ROOT / "Zorofin.xcodeproj/xcshareddata/xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:Zorofin.xcodeproj"/>'
    (scheme_dir / (name + ".xcscheme")).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"/>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

# A separate, credential-free extension supplies Apple TV Home Screen previews.
name = "Zorofin-TopShelf"
marketing_version, build_number = RELEASE_VERSIONS["tvOS"]
ext_source = obj("TopShelf/ContentProvider.swift", "PBXFileReference", lastKnownFileType="sourcecode.swift", path="TopShelf/ContentProvider.swift", sourceTree="<group>")
objects[main]["children"].append(ext_source)
ext_privacy = obj("TopShelf/PrivacyInfo.xcprivacy", "PBXFileReference", lastKnownFileType="file", path="TopShelf/PrivacyInfo.xcprivacy", sourceTree="<group>")
objects[main]["children"].append(ext_privacy)
product = obj(name + "Product", "PBXFileReference", explicitFileType="wrapper.app-extension", includeInIndex="0", path=name + ".appex", sourceTree="BUILT_PRODUCTS_DIR")
objects[products]["children"].append(product)
core_product = obj(name + "CoreProduct", "XCSwiftPackageProductDependency", package=package, productName="ZorofinCore")
phases = [obj(name + "Sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=[obj(name + "Source", "PBXBuildFile", fileRef=ext_source)], runOnlyForDeploymentPostprocessing="0"),
          obj(name + "Frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[obj(name + "CoreBuild", "PBXBuildFile", productRef=core_product)], runOnlyForDeploymentPostprocessing="0"),
          obj(name + "Resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[obj(name + "Privacy", "PBXBuildFile", fileRef=ext_privacy)], runOnlyForDeploymentPostprocessing="0")]
configs = []
for config in ["Debug", "Release"]:
    settings = {"PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": TOP_SHELF_BUNDLE_ID,
                "INFOPLIST_FILE": "Config/TopShelf-Info.plist", "CODE_SIGN_ENTITLEMENTS": "Config/tvOS.entitlements",
                "CODE_SIGN_STYLE": "Automatic", "SDKROOT": "appletvos", "SUPPORTED_PLATFORMS": "appletvos appletvsimulator",
                "TARGETED_DEVICE_FAMILY": "3", "TVOS_DEPLOYMENT_TARGET": "18.0", "APPLICATION_EXTENSION_API_ONLY": "YES",
                "SKIP_INSTALL": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "SWIFT_EMIT_LOC_STRINGS": "YES",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
                "MARKETING_VERSION": marketing_version, "CURRENT_PROJECT_VERSION": build_number}
    configs.append(obj(name + config, "XCBuildConfiguration", name=config, buildSettings=settings))
config_list = obj(name + "Configs", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")
ext_target = obj(name, "PBXNativeTarget", buildConfigurationList=config_list, buildPhases=phases, buildRules=[], dependencies=[],
                 name=name, productName=name, productReference=product, productType="com.apple.product-type.app-extension", packageProductDependencies=[core_product])
targets.append(ext_target)
proxy = obj(name + "Proxy", "PBXContainerItemProxy", containerPortal=identifier("Project"), proxyType="1", remoteGlobalIDString=ext_target, remoteInfo=name)
dependency = obj(name + "Dependency", "PBXTargetDependency", target=ext_target, targetProxy=proxy)
embed = obj(name + "Embed", "PBXBuildFile", fileRef=product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
embed_phase = obj(name + "EmbedPhase", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="", dstSubfolderSpec="13", files=[embed], name="Embed App Extensions", runOnlyForDeploymentPostprocessing="0")
objects[identifier("Zorofin-tvOS")]["dependencies"].append(dependency)
objects[identifier("Zorofin-tvOS")]["buildPhases"].append(embed_phase)

# An explicit iPad-only UI-test scheme can drive older physical iPads even when
# Device Hub cannot screen-share with their OS. It is never part of app archives.
ui_name = "Zorofin-iPadUITests"
ui_path = "UITests/IPadAcceptanceTests.swift"
ui_ref = obj(ui_path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=ui_path, sourceTree="<group>")
objects[main]["children"].append(ui_ref)
ui_product = obj(ui_name + "Product", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0", path=ui_name + ".xctest", sourceTree="BUILT_PRODUCTS_DIR")
objects[products]["children"].append(ui_product)
ui_phases = [obj(ui_name + "Sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=[obj(ui_name + "Source", "PBXBuildFile", fileRef=ui_ref)], runOnlyForDeploymentPostprocessing="0"),
             obj(ui_name + "Frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"),
             obj(ui_name + "Resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")]
ui_configs = []
for config in ["Debug", "Release"]:
    settings = {"PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "org.zorofin.app.uitests",
                "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGN_STYLE": "Automatic", "SDKROOT": "iphoneos",
                "SUPPORTED_PLATFORMS": "iphoneos", "TARGETED_DEVICE_FAMILY": "2", "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
                "TEST_TARGET_NAME": "Zorofin-iOS", "ENABLE_TESTING_SEARCH_PATHS": "YES", "SKIP_INSTALL": "YES",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]}
    ui_configs.append(obj(ui_name + config, "XCBuildConfiguration", name=config, buildSettings=settings))
ui_config_list = obj(ui_name + "Configs", "XCConfigurationList", buildConfigurations=ui_configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")
ui_proxy = obj(ui_name + "Proxy", "PBXContainerItemProxy", containerPortal=identifier("Project"), proxyType="1", remoteGlobalIDString=identifier("Zorofin-iOS"), remoteInfo="Zorofin-iOS")
ui_dependency = obj(ui_name + "Dependency", "PBXTargetDependency", target=identifier("Zorofin-iOS"), targetProxy=ui_proxy)
ui_target = obj(ui_name, "PBXNativeTarget", buildConfigurationList=ui_config_list, buildPhases=ui_phases, buildRules=[], dependencies=[ui_dependency], name=ui_name, productName=ui_name, productReference=ui_product, productType="com.apple.product-type.bundle.ui-testing")
targets.append(ui_target)
ui_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="{ui_name}.xctest" BlueprintName="{ui_name}" ReferencedContainer="container:Zorofin.xcodeproj"/>'
app_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier("Zorofin-iOS")}" BuildableName="Zorofin-iOS.app" BlueprintName="Zorofin-iOS" ReferencedContainer="container:Zorofin.xcodeproj"/>'
(scheme_dir / "Zorofin-iPad-UI.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{app_reference}</BuildActionEntry>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ui_reference}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Release" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO" parallelizable="NO">{ui_reference}</TestableReference></Testables></TestAction>
</Scheme>
''')

# Separate phone runner for the existing-account Release journey. Keep the
# iPad-only target above unchanged; neither runner belongs to shipping archives.
phone_ui_name = "Zorofin-iPhoneUITests"
phone_ui_path = "UITests/IPhoneAcceptanceTests.swift"
phone_ui_ref = obj(phone_ui_path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=phone_ui_path, sourceTree="<group>")
objects[main]["children"].append(phone_ui_ref)
phone_ui_product = obj(phone_ui_name + "Product", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0", path=phone_ui_name + ".xctest", sourceTree="BUILT_PRODUCTS_DIR")
objects[products]["children"].append(phone_ui_product)
phone_ui_phases = [obj(phone_ui_name + "Sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=[obj(phone_ui_name + "Source", "PBXBuildFile", fileRef=phone_ui_ref)], runOnlyForDeploymentPostprocessing="0"),
             obj(phone_ui_name + "Frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"),
             obj(phone_ui_name + "Resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")]
phone_ui_configs = []
for config in ["Debug", "Release"]:
    settings = {"PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "org.zorofin.app.iphoneuitests",
                "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGN_STYLE": "Automatic", "SDKROOT": "iphoneos",
                "SUPPORTED_PLATFORMS": "iphoneos", "TARGETED_DEVICE_FAMILY": "1", "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
                "TEST_TARGET_NAME": "Zorofin-iOS", "ENABLE_TESTING_SEARCH_PATHS": "YES", "SKIP_INSTALL": "YES",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]}
    phone_ui_configs.append(obj(phone_ui_name + config, "XCBuildConfiguration", name=config, buildSettings=settings))
phone_ui_config_list = obj(phone_ui_name + "Configs", "XCConfigurationList", buildConfigurations=phone_ui_configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")
phone_ui_proxy = obj(phone_ui_name + "Proxy", "PBXContainerItemProxy", containerPortal=identifier("Project"), proxyType="1", remoteGlobalIDString=identifier("Zorofin-iOS"), remoteInfo="Zorofin-iOS")
phone_ui_dependency = obj(phone_ui_name + "Dependency", "PBXTargetDependency", target=identifier("Zorofin-iOS"), targetProxy=phone_ui_proxy)
phone_ui_target = obj(phone_ui_name, "PBXNativeTarget", buildConfigurationList=phone_ui_config_list, buildPhases=phone_ui_phases, buildRules=[], dependencies=[phone_ui_dependency], name=phone_ui_name, productName=phone_ui_name, productReference=phone_ui_product, productType="com.apple.product-type.bundle.ui-testing")
targets.append(phone_ui_target)
phone_ui_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{phone_ui_target}" BuildableName="{phone_ui_name}.xctest" BlueprintName="{phone_ui_name}" ReferencedContainer="container:Zorofin.xcodeproj"/>'
app_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier("Zorofin-iOS")}" BuildableName="Zorofin-iOS.app" BlueprintName="Zorofin-iOS" ReferencedContainer="container:Zorofin.xcodeproj"/>'
(scheme_dir / "Zorofin-iPhone-UI.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{app_reference}</BuildActionEntry>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{phone_ui_reference}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Release" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO" parallelizable="NO">{phone_ui_reference}</TestableReference></Testables></TestAction>
</Scheme>
''')

# Hosted UIKit/SwiftUI player checks use a generated test pattern only. The
# target, fixture and test scheme are excluded from both shipping archives.
player_test_name = "Zorofin-PlayerTests"
player_test_path = "Tests/PlayerLayoutTests.swift"
player_fixture_path = "Core/Tests/ZorofinCoreTests/Fixtures/player-preparation.mp4"
player_test_ref = obj(player_test_path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=player_test_path, sourceTree="<group>")
player_fixture_ref = obj(player_fixture_path, "PBXFileReference", lastKnownFileType="file", path=player_fixture_path, sourceTree="<group>")
objects[main]["children"].extend([player_test_ref, player_fixture_ref])
player_startup_path = "Tests/PlayerStartupFixture.swift"
player_startup_ref = obj(player_startup_path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=player_startup_path, sourceTree="<group>")
player_trace_path = "Tests/PlayerRotationTrace.swift"
player_trace_ref = obj(player_trace_path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=player_trace_path, sourceTree="<group>")
player_hls_path = "Tests/Fixtures/rotation-hls"
player_hls_ref = obj(player_hls_path, "PBXFileReference", lastKnownFileType="folder", path=player_hls_path, sourceTree="<group>")
objects[main]["children"].extend([player_startup_ref, player_hls_ref])
objects[main]["children"].append(player_trace_ref)
player_test_product = obj(player_test_name + "Product", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0", path=player_test_name + ".xctest", sourceTree="BUILT_PRODUCTS_DIR")
objects[products]["children"].append(player_test_product)
player_test_core = obj(player_test_name + "CoreProduct", "XCSwiftPackageProductDependency", package=package, productName="ZorofinCore")
player_test_phases = [
    obj(player_test_name + "Sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=[obj(player_test_name + "Source", "PBXBuildFile", fileRef=player_test_ref), obj(player_test_name + "StartupSource", "PBXBuildFile", fileRef=player_startup_ref), obj(player_test_name + "TraceSource", "PBXBuildFile", fileRef=player_trace_ref)], runOnlyForDeploymentPostprocessing="0"),
    obj(player_test_name + "Frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[obj(player_test_name + "CoreBuild", "PBXBuildFile", productRef=player_test_core)], runOnlyForDeploymentPostprocessing="0"),
    obj(player_test_name + "Resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[obj(player_test_name + "Fixture", "PBXBuildFile", fileRef=player_fixture_ref), obj(player_test_name + "HLSFixture", "PBXBuildFile", fileRef=player_hls_ref)], runOnlyForDeploymentPostprocessing="0")]
player_test_configs = []
for config in ["Debug", "Release"]:
    player_test_configs.append(obj(player_test_name + config, "XCBuildConfiguration", name=config, buildSettings={
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "org.zorofin.app.playertests",
        "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGN_STYLE": "Automatic", "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "TARGETED_DEVICE_FAMILY": "1,2", "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
        "BUNDLE_LOADER": "$(TEST_HOST)", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Zorofin-iOS.app/Zorofin-iOS",
        "ENABLE_TESTING_SEARCH_PATHS": "YES", "SKIP_INSTALL": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]}))
player_test_config_list = obj(player_test_name + "Configs", "XCConfigurationList", buildConfigurations=player_test_configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Debug")
player_test_dependency = obj(player_test_name + "Dependency", "PBXTargetDependency", target=identifier("Zorofin-iOS"), targetProxy=ui_proxy)
player_test_target = obj(player_test_name, "PBXNativeTarget", buildConfigurationList=player_test_config_list, buildPhases=player_test_phases, buildRules=[], dependencies=[player_test_dependency], name=player_test_name, productName=player_test_name, productReference=player_test_product, productType="com.apple.product-type.bundle.unit-test", packageProductDependencies=[player_test_core])
targets.append(player_test_target)
player_test_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{player_test_target}" BuildableName="{player_test_name}.xctest" BlueprintName="{player_test_name}" ReferencedContainer="container:Zorofin.xcodeproj"/>'
(scheme_dir / "Zorofin-Player-Tests.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{app_reference}</BuildActionEntry>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{player_test_reference}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO" parallelizable="NO">{player_test_reference}</TestableReference></Testables><CommandLineArguments><CommandLineArgument argument="--custom-player" isEnabled="YES"/></CommandLineArguments></TestAction>
</Scheme>
''')

project = obj("Project", "PBXProject", attributes={"LastUpgradeCheck": "2700", "BuildIndependentTargetsInParallel": "YES", "TargetAttributes": {ui_target: {"TestTargetID": identifier("Zorofin-iOS")}, phone_ui_target: {"TestTargetID": identifier("Zorofin-iOS")}}},
              buildConfigurationList=project_config_list, compatibilityVersion="Xcode 15.0", developmentRegion="en", hasScannedForEncodings="0",
              knownRegions=["en", "Base"], mainGroup=main, productRefGroup=products, projectDirPath="", projectRoot="", targets=targets, packageReferences=[package, aether_package])
output = {"archiveVersion": "1", "classes": {}, "objectVersion": "60", "objects": objects, "rootObject": project}
(ROOT / "Zorofin.xcodeproj/project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(output) + "\n")

(ROOT / "Config").mkdir(exist_ok=True)
for platform in ["iOS", "tvOS"]:
    info = {"CFBundleDevelopmentRegion": "en", "CFBundleDisplayName": "Zorofin", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
            "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "$(PRODUCT_NAME)",
            "ITSAppUsesNonExemptEncryption": False, "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            "UIAppFonts": ["InterVariable.ttf"], "NSLocalNetworkUsageDescription": "Connect to the Jellyfin server you choose on your local network.",
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}, "UILaunchScreen": {}}
    if platform == "tvOS":
        info["CFBundleURLTypes"] = [{"CFBundleURLName": "org.zorofin.topshelf", "CFBundleURLSchemes": ["zorofin"]}]
    if platform == "iOS":
        info.update(LSRequiresIPhoneOS=True, UIBackgroundModes=["audio"],
                    UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
                    **{"UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]})
    write_plist(ROOT / f"Config/{platform}-Info.plist", info)
print("Generated Zorofin.xcodeproj with iOS and tvOS schemes")

write_plist(ROOT / "Config/tvOS.entitlements", {"com.apple.security.application-groups": ["group.org.zorofin.app.tv.shared"]})
write_plist(ROOT / "Config/TopShelf-Info.plist", {"CFBundleDevelopmentRegion": "en", "CFBundleDisplayName": "Zorofin",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "$(PRODUCT_NAME)", "CFBundlePackageType": "XPC!", "ITSAppUsesNonExemptEncryption": False,
        "UIRequiredDeviceCapabilities": ["arm64"],
        "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.tv-top-shelf",
                        "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ContentProvider"}})
