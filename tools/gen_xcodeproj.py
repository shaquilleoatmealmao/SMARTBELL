"""
Regenerates SmartBell.xcodeproj/project.pbxproj from the Swift files in SmartBell/.
Run after adding, removing or moving a .swift file:   python3 tools/gen_xcodeproj.py
(Or just add the file in Xcode; either works.)
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "SmartBell")
BUNDLE_ID = "ca.uwaterloo.ece198.smartbell"


def oid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


files = []
for dirpath, _, names in os.walk(SRC):
    for n in sorted(names):
        if n.endswith(".swift"):
            files.append(os.path.relpath(os.path.join(dirpath, n), SRC))
files.sort()
groups = sorted({os.path.dirname(f) for f in files if os.path.dirname(f)})

P = {k: oid("project", k) for k in ["proj", "main", "src", "products", "app", "target", "sources",
                                     "frameworks", "resources", "pcl", "tcl", "pdbg", "prel", "tdbg", "trel",
                                     "plist"]}

lines = []
w = lines.append
w("// !$*UTF8*$!")
w("{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n")
w("/* Begin PBXBuildFile section */")
for f in files:
    n = os.path.basename(f)
    w(f"\t\t{oid('build', f)} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {oid('ref', f)} /* {n} */; }};")
w("/* End PBXBuildFile section */\n")
w("/* Begin PBXFileReference section */")
for f in files:
    n = os.path.basename(f)
    w(f"\t\t{oid('ref', f)} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {n}; sourceTree = \"<group>\"; }};")
w(f"\t\t{P['plist']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
w(f"\t\t{P['app']} /* SmartBell.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SmartBell.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
w("/* End PBXFileReference section */\n")
w("/* Begin PBXFrameworksBuildPhase section */")
w(f"\t\t{P['frameworks']} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
w("/* End PBXFrameworksBuildPhase section */\n")
w("/* Begin PBXGroup section */")
w(f"\t\t{P['main']} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{P['src']} /* SmartBell */,\n\t\t\t\t{P['products']} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
w(f"\t\t{P['products']} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{P['app']} /* SmartBell.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
children = [f"\t\t\t\t{oid('group', g)} /* {g} */," for g in groups]
children += [f"\t\t\t\t{oid('ref', f)} /* {f} */," for f in files if not os.path.dirname(f)]
children.append(f"\t\t\t\t{P['plist']} /* Info.plist */,")
w(f"\t\t{P['src']} /* SmartBell */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n" + "\n".join(children) +
  "\n\t\t\t);\n\t\t\tpath = SmartBell;\n\t\t\tsourceTree = \"<group>\";\n\t\t};")
for g in groups:
    ch = [f"\t\t\t\t{oid('ref', f)} /* {os.path.basename(f)} */," for f in files if os.path.dirname(f) == g]
    w(f"\t\t{oid('group', g)} /* {g} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n" + "\n".join(ch) +
      f"\n\t\t\t);\n\t\t\tpath = {g};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
w("/* End PBXGroup section */\n")
w("/* Begin PBXNativeTarget section */")
w(f"""\t\t{P['target']} /* SmartBell */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {P['tcl']} /* Build configuration list for PBXNativeTarget "SmartBell" */;
\t\t\tbuildPhases = (
\t\t\t\t{P['sources']} /* Sources */,
\t\t\t\t{P['frameworks']} /* Frameworks */,
\t\t\t\t{P['resources']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = SmartBell;
\t\t\tproductName = SmartBell;
\t\t\tproductReference = {P['app']} /* SmartBell.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};""")
w("/* End PBXNativeTarget section */\n")
w("/* Begin PBXProject section */")
w(f"""\t\t{P['proj']} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t}};
\t\t\tbuildConfigurationList = {P['pcl']} /* Build configuration list for PBXProject "SmartBell" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {P['main']};
\t\t\tproductRefGroup = {P['products']} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{P['target']} /* SmartBell */,
\t\t\t);
\t\t}};""")
w("/* End PBXProject section */\n")
w("/* Begin PBXResourcesBuildPhase section */")
w(f"\t\t{P['resources']} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
w("/* End PBXResourcesBuildPhase section */\n")
w("/* Begin PBXSourcesBuildPhase section */")
src = "\n".join(f"\t\t\t\t{oid('build', f)} /* {os.path.basename(f)} in Sources */," for f in files)
w(f"\t\t{P['sources']} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{src}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
w("/* End PBXSourcesBuildPhase section */\n")


def cfg(key, name, settings):
    body = "\n".join(f"\t\t\t\t{k} = {v};" for k, v in settings)
    return f"\t\t{P[key]} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{body}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};"


common = [("ALWAYS_SEARCH_USER_PATHS", "NO"), ("CLANG_ENABLE_MODULES", "YES"),
          ("IPHONEOS_DEPLOYMENT_TARGET", "17.0"), ("SDKROOT", "iphoneos"), ("SWIFT_VERSION", "5.0"),
          ("ENABLE_USER_SCRIPT_SANDBOXING", "YES")]
target = [("CODE_SIGN_STYLE", "Automatic"), ("CURRENT_PROJECT_VERSION", "1"), ("MARKETING_VERSION", "2.0"),
          ("DEVELOPMENT_TEAM", '""'), ("GENERATE_INFOPLIST_FILE", "NO"), ("INFOPLIST_FILE", "SmartBell/Info.plist"),
          ("IPHONEOS_DEPLOYMENT_TARGET", "17.0"), ("LD_RUNPATH_SEARCH_PATHS", '"$(inherited) @executable_path/Frameworks"'),
          ("PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_ID), ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
          ("SWIFT_VERSION", "5.0"), ("TARGETED_DEVICE_FAMILY", "1")]
w("/* Begin XCBuildConfiguration section */")
w(cfg("pdbg", "Debug", common + [("DEBUG_INFORMATION_FORMAT", "dwarf"), ("ENABLE_TESTABILITY", "YES"),
                                  ("GCC_OPTIMIZATION_LEVEL", "0"), ("ONLY_ACTIVE_ARCH", "YES"),
                                  ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
                                  ("SWIFT_OPTIMIZATION_LEVEL", '"-Onone"')]))
w(cfg("prel", "Release", common + [("DEBUG_INFORMATION_FORMAT", '"dwarf-with-dsym"'),
                                    ("SWIFT_COMPILATION_MODE", "wholemodule"),
                                    ("SWIFT_OPTIMIZATION_LEVEL", '"-O"'), ("VALIDATE_PRODUCT", "YES")]))
w(cfg("tdbg", "Debug", target))
w(cfg("trel", "Release", target))
w("/* End XCBuildConfiguration section */\n")
w("/* Begin XCConfigurationList section */")
w(f"""\t\t{P['pcl']} /* Build configuration list for PBXProject "SmartBell" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{P['pdbg']} /* Debug */,
\t\t\t\t{P['prel']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{P['tcl']} /* Build configuration list for PBXNativeTarget "SmartBell" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{P['tdbg']} /* Debug */,
\t\t\t\t{P['trel']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};""")
w("/* End XCConfigurationList section */")
w(f"\t}};\n\trootObject = {P['proj']} /* Project object */;\n}}")

out = os.path.join(ROOT, "SmartBell.xcodeproj")
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "project.pbxproj"), "w") as fh:
    fh.write("\n".join(lines) + "\n")
ws = os.path.join(out, "project.xcworkspace")
os.makedirs(ws, exist_ok=True)
with open(os.path.join(ws, "contents.xcworkspacedata"), "w") as fh:
    fh.write('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n'
             '   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')
print(f"wrote project with {len(files)} Swift files in {len(groups)} groups")
