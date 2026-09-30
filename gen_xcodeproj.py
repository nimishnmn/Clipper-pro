#!/usr/bin/env python3
"""
gen_xcodeproj.py — Generates a complete ClipperPro.xcodeproj for Xcode 15+.

Usage:
    python3 gen_xcodeproj.py

This script creates ClipperPro.xcodeproj/project.pbxproj from the source files
in the ClipperPro/ directory. Run it from the repo root (alongside the ClipperPro/ folder).
"""

import os
import uuid
import json
from typing import Optional, List, Dict
from pathlib import Path


# ─── Configuration ────────────────────────────────────────────────────────────

PROJECT_NAME     = "ClipperPro"
BUNDLE_ID        = "com.clipper.pro"
SWIFT_VERSION    = "5.0"
DEPLOYMENT_TARGET= "14.0"
PRODUCT_NAME     = "ClipperPro"

SCRIPT_DIR = Path(__file__).parent.resolve()
SOURCE_ROOT = SCRIPT_DIR / "ClipperPro"
XCODEPROJ_DIR = SCRIPT_DIR / f"{PROJECT_NAME}.xcodeproj"

# ─── PBX ID helpers ──────────────────────────────────────────────────────────

def new_id() -> str:
    """Generate a 24-hex-char Xcode PBX object ID."""
    return uuid.uuid4().hex[:24].upper()

# ─── Collect source files ─────────────────────────────────────────────────────

def collect_files(root: Path) -> List[Path]:
    """Walk the source root and collect all relevant files."""
    extensions = {".swift", ".metal", ".plist", ".entitlements", ".xcassets", ".json"}
    files = []
    for p in sorted(root.rglob("*")):
        if p.is_file():
            if p.suffix in extensions or p.name == "Contents.json":
                files.append(p)
        elif p.is_dir() and p.suffix == ".xcassets":
            files.append(p)  # xcassets added as a group
    # Deduplicate
    seen = set()
    result = []
    for f in files:
        if f not in seen:
            seen.add(f)
            result.append(f)
    return result

# ─── Build PBX sections ───────────────────────────────────────────────────────

class PBXProject:
    def __init__(self):
        self.objects: dict[str, dict] = {}
        
        # Top-level IDs
        self.project_id         = new_id()
        self.main_group_id      = new_id()
        self.products_group_id  = new_id()
        self.config_list_id     = new_id()
        self.debug_config_id    = new_id()
        self.release_config_id  = new_id()
        
        # Target IDs
        self.app_target_id      = new_id()
        self.app_config_list_id = new_id()
        self.app_debug_id       = new_id()
        self.app_release_id     = new_id()
        
        # Build phases
        self.sources_phase_id   = new_id()
        self.resources_phase_id = new_id()
        self.frameworks_phase_id= new_id()
        
        # Product reference
        self.app_product_id     = new_id()
        
        # File references and build files
        self.file_refs: dict[Path, str]   = {}  # path -> PBX ID
        self.build_files: dict[Path, str] = {}  # path -> PBX build file ID
        self.groups: dict[Path, str]      = {}  # dir path -> group ID
        
    def add_file_ref(self, path: Path) -> str:
        if path in self.file_refs:
            return self.file_refs[path]
        ref_id = new_id()
        self.file_refs[path] = ref_id
        
        rel_path = path.relative_to(SCRIPT_DIR)
        
        # Determine file type
        ext = path.suffix
        if ext == ".swift":
            last_known = "sourcecode.swift"
        elif ext == ".metal":
            last_known = "sourcecode.metal"
        elif ext == ".plist":
            last_known = "text.plist.xml"
        elif ext == ".entitlements":
            last_known = "text.plist.entitlements"
        elif ext == ".xcassets":
            last_known = "folder.assetcatalog"
        elif ext == ".json":
            last_known = "text.json"
        else:
            last_known = "file"
        
        self.objects[ref_id] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": last_known,
            "name": path.name,
            "path": str(rel_path),
            "sourceTree": "<group>",
        }
        return ref_id
    
    def add_build_file(self, path: Path) -> Optional[str]:
        if path in self.build_files:
            return self.build_files[path]
        ref_id = self.file_refs.get(path)
        if not ref_id:
            return None
        bf_id = new_id()
        self.build_files[path] = bf_id
        self.objects[bf_id] = {
            "isa": "PBXBuildFile",
            "fileRef": ref_id,
        }
        return bf_id
    
    def make_group(self, dir_path: Path, name: Optional[str] = None) -> str:
        if dir_path in self.groups:
            return self.groups[dir_path]
        group_id = new_id()
        self.groups[dir_path] = group_id
        self.objects[group_id] = {
            "isa": "PBXGroup",
            "children": [],
            "name": name or dir_path.name,
            "sourceTree": "<group>",
        }
        return group_id
    
    def build_group_tree(self, files: List[Path]) -> str:
        """Build nested group hierarchy for all source files."""
        # Create groups for all directories
        all_dirs: set[Path] = set()
        for f in files:
            p = f.parent
            while p != SCRIPT_DIR and p != SCRIPT_DIR.parent:
                all_dirs.add(p)
                p = p.parent
        
        # Sort dirs by depth so parents are created first
        sorted_dirs = sorted(all_dirs, key=lambda d: len(d.parts))
        
        for d in sorted_dirs:
            self.make_group(d)
        
        # Add files to their parent groups
        for f in files:
            ref_id = self.add_file_ref(f)
            parent_group_id = self.groups.get(f.parent)
            if parent_group_id and ref_id not in self.objects[parent_group_id]["children"]:
                self.objects[parent_group_id]["children"].append(ref_id)
        
        # Add child groups to parent groups
        for d in sorted_dirs:
            parent = d.parent
            if parent in self.groups:
                child_id = self.groups[d]
                if child_id not in self.objects[self.groups[parent]]["children"]:
                    self.objects[self.groups[parent]]["children"].append(child_id)
        
        # Main group: has the source root as a child
        source_root_group = self.groups.get(SOURCE_ROOT)
        main_group_children = []
        if source_root_group:
            main_group_children.append(source_root_group)
        main_group_children.append(self.products_group_id)
        
        self.objects[self.main_group_id] = {
            "isa": "PBXGroup",
            "children": main_group_children,
            "name": PROJECT_NAME,
            "sourceTree": "<group>",
        }
        
        return self.main_group_id
    
    def generate(self, files: List[Path]) -> str:
        # Build file references and group tree
        self.build_group_tree(files)
        
        # Determine source files (Swift + Metal) and resource files
        swift_files = [f for f in files if f.suffix == ".swift"]
        metal_files = [f for f in files if f.suffix == ".metal"]
        resource_files = [f for f in files if f.suffix in {".xcassets"} or f.name == "Assets.xcassets"]
        
        source_build_files = []
        for f in swift_files + metal_files:
            bf_id = self.add_build_file(f)
            if bf_id:
                source_build_files.append(bf_id)
        
        resource_build_files = []
        xcassets = SOURCE_ROOT / "Resources" / "Assets.xcassets"
        if xcassets in self.file_refs:
            bf_id = self.add_build_file(xcassets)
            if bf_id:
                resource_build_files.append(bf_id)
        
        # Info.plist and entitlements are not build-file entries; they're configured in build settings
        
        # Build phases
        self.objects[self.sources_phase_id] = {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": source_build_files,
            "runOnlyForDeploymentPostprocessing": "0",
        }
        
        self.objects[self.resources_phase_id] = {
            "isa": "PBXResourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": resource_build_files,
            "runOnlyForDeploymentPostprocessing": "0",
        }
        
        self.objects[self.frameworks_phase_id] = {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": "2147483647",
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        }
        
        # Product file reference
        self.objects[self.app_product_id] = {
            "isa": "PBXFileReference",
            "explicitFileType": "wrapper.application",
            "includeInIndex": "0",
            "path": f"{PRODUCT_NAME}.app",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        }
        
        # Products group
        self.objects[self.products_group_id] = {
            "isa": "PBXGroup",
            "children": [self.app_product_id],
            "name": "Products",
            "sourceTree": "<group>",
        }
        
        # ─── Build Configurations ───────────────────────────────────────────
        
        common_settings = {
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CLANG_ANALYZER_NONNULL": "YES",
            "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
            "CLANG_CXX_LANGUAGE_STANDARD": "\"gnu++20\"",
            "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "CLANG_ENABLE_OBJC_WEAK": "YES",
            "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
            "CLANG_WARN_BOOL_CONVERSION": "YES",
            "CLANG_WARN_COMMA": "YES",
            "CLANG_WARN_CONSTANT_CONVERSION": "YES",
            "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
            "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
            "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
            "CLANG_WARN_EMPTY_BODY": "YES",
            "CLANG_WARN_ENUM_CONVERSION": "YES",
            "CLANG_WARN_INFINITE_RECURSION": "YES",
            "CLANG_WARN_INT_CONVERSION": "YES",
            "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
            "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
            "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
            "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
            "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
            "CLANG_WARN_STRICT_PROTOTYPES": "YES",
            "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
            "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
            "CLANG_WARN_UNREACHABLE_CODE": "YES",
            "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
            "COPY_PHASE_STRIP": "NO",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "GCC_C_LANGUAGE_STANDARD": "gnu11",
            "GCC_NO_COMMON_BLOCKS": "YES",
            "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
            "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
            "GCC_WARN_UNDECLARED_SELECTOR": "YES",
            "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
            "GCC_WARN_UNUSED_FUNCTION": "YES",
            "GCC_WARN_UNUSED_VARIABLE": "YES",
            "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "MTL_FAST_MATH": "YES",
            "ONLY_ACTIVE_ARCH": "YES",
            "SDKROOT": "macosx",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        }
        
        debug_settings = dict(common_settings)
        debug_settings["DEBUG_INFORMATION_FORMAT"] = "dwarf"
        debug_settings["ENABLE_TESTABILITY"] = "YES"
        debug_settings["GCC_DYNAMIC_NO_PIC"] = "NO"
        debug_settings["GCC_OPTIMIZATION_LEVEL"] = "0"
        debug_settings["GCC_PREPROCESSOR_DEFINITIONS"] = ["DEBUG=1", "$(inherited)"]
        debug_settings["MTL_ENABLE_DEBUG_INFO"] = "INCLUDE_SOURCE"
        
        release_settings = dict(common_settings)
        release_settings["DEBUG_INFORMATION_FORMAT"] = "\"dwarf-with-dsym\""
        release_settings["ENABLE_NS_ASSERTIONS"] = "NO"
        release_settings["GCC_OPTIMIZATION_LEVEL"] = "s"
        release_settings["MTL_ENABLE_DEBUG_INFO"] = "NO"
        release_settings["MTL_FAST_MATH"] = "YES"
        release_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = ""
        release_settings["SWIFT_OPTIMIZATION_LEVEL"] = "-Owholemodule"
        release_settings["VALIDATE_PRODUCT"] = "YES"
        
        self.objects[self.debug_config_id] = {
            "isa": "XCBuildConfiguration",
            "buildSettings": debug_settings,
            "name": "Debug",
        }
        self.objects[self.release_config_id] = {
            "isa": "XCBuildConfiguration",
            "buildSettings": release_settings,
            "name": "Release",
        }
        self.objects[self.config_list_id] = {
            "isa": "XCConfigurationList",
            "buildConfigurations": [self.debug_config_id, self.release_config_id],
            "defaultConfigurationIsVisible": "0",
            "defaultConfigurationName": "Release",
        }
        
        # Target build settings
        entitlements_path = "ClipperPro/Resources/ClipperPro.entitlements"
        infoplist_path    = "ClipperPro/Resources/Info.plist"
        
        target_debug_settings = {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CODE_SIGN_ENTITLEMENTS": entitlements_path,
            "CODE_SIGN_STYLE": "Automatic",
            "COMBINE_HIDPI_IMAGES": "YES",
            "CURRENT_PROJECT_VERSION": "1",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "ENABLE_PREVIEWS": "YES",
            "INFOPLIST_FILE": infoplist_path,
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
            "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
            "MARKETING_VERSION": "1.0",
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "MTL_FAST_MATH": "YES",
            "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SDKROOT": "macosx",
            "SWIFT_EMIT_LOC_STRINGS": "YES",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "SWIFT_VERSION": SWIFT_VERSION,
        }
        
        target_release_settings = dict(target_debug_settings)
        target_release_settings["MTL_ENABLE_DEBUG_INFO"] = "NO"
        target_release_settings["MTL_FAST_MATH"] = "YES"
        target_release_settings["SWIFT_OPTIMIZATION_LEVEL"] = "-Owholemodule"
        
        self.objects[self.app_debug_id] = {
            "isa": "XCBuildConfiguration",
            "buildSettings": target_debug_settings,
            "name": "Debug",
        }
        self.objects[self.app_release_id] = {
            "isa": "XCBuildConfiguration",
            "buildSettings": target_release_settings,
            "name": "Release",
        }
        self.objects[self.app_config_list_id] = {
            "isa": "XCConfigurationList",
            "buildConfigurations": [self.app_debug_id, self.app_release_id],
            "defaultConfigurationIsVisible": "0",
            "defaultConfigurationName": "Release",
        }
        
        # ─── Target ─────────────────────────────────────────────────────────
        
        self.objects[self.app_target_id] = {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": self.app_config_list_id,
            "buildPhases": [
                self.sources_phase_id,
                self.frameworks_phase_id,
                self.resources_phase_id,
            ],
            "buildRules": [],
            "dependencies": [],
            "name": PROJECT_NAME,
            "productName": PROJECT_NAME,
            "productReference": self.app_product_id,
            "productType": "\"com.apple.product-type.application\"",
        }
        
        # ─── Project ─────────────────────────────────────────────────────────
        
        self.objects[self.project_id] = {
            "isa": "PBXProject",
            "attributes": {
                "BuildIndependentTargetsInParallel": "1",
                "LastSwiftUpdateCheck": "1500",
                "LastUpgradeCheck": "1500",
                "TargetAttributes": {
                    self.app_target_id: {
                        "CreatedOnToolsVersion": "15.0",
                    }
                },
            },
            "buildConfigurationList": self.config_list_id,
            "compatibilityVersion": "\"Xcode 14.0\"",
            "developmentRegion": "en",
            "hasScannedForEncodings": "0",
            "knownRegions": ["en", "Base"],
            "mainGroup": self.main_group_id,
            "productRefGroup": self.products_group_id,
            "projectDirPath": "\"\"",
            "projectRoot": "\"\"",
            "targets": [self.app_target_id],
        }
        
        return self._render()
    
    def _render(self) -> str:
        """Render objects to pbxproj format."""
        lines = [
            "// !$*UTF8*$!",
            "{",
            "\tarchiveVersion = 1;",
            "\tclasses = {",
            "\t};",
            "\tobjectVersion = 56;",
            "\tobjects = {",
            "",
        ]
        
        # Group by isa
        by_isa: dict[str, list[tuple[str, dict]]] = {}
        for obj_id, obj in self.objects.items():
            isa = obj.get("isa", "Unknown")
            by_isa.setdefault(isa, []).append((obj_id, obj))
        
        isa_order = [
            "PBXBuildFile", "PBXFileReference", "PBXFrameworksBuildPhase",
            "PBXGroup", "PBXNativeTarget", "PBXProject",
            "PBXResourcesBuildPhase", "PBXSourcesBuildPhase",
            "XCBuildConfiguration", "XCConfigurationList",
        ]
        
        for isa in isa_order:
            if isa not in by_isa:
                continue
            lines.append(f"\t\t/* Begin {isa} section */")
            for obj_id, obj in sorted(by_isa[isa], key=lambda x: x[0]):
                lines.append(f"\t\t{obj_id} = {{")
                for k, v in obj.items():
                    lines.append(f"\t\t\t{k} = {self._fmt(v)};")
                lines.append("\t\t};")
            lines.append(f"\t\t/* End {isa} section */")
            lines.append("")
        
        lines.extend([
            "\t};",
            f"\trootObject = {self.project_id};",
            "}",
        ])
        
        return "\n".join(lines)
    
    def _fmt(self, v) -> str:
        if isinstance(v, str):
            # Quote if contains spaces or special chars, unless already quoted
            if v.startswith('"') or v in ("YES", "NO", "0", "1", "2147483647"):
                return v
            if " " in v or "/" in v or "." in v or "(" in v or "$" in v:
                return f'"{v}"'
            return v
        elif isinstance(v, list):
            inner = ", ".join(self._fmt(i) for i in v)
            return f"({inner}, )"
        elif isinstance(v, dict):
            inner = " ".join(f"{k} = {self._fmt(val)};" for k, val in v.items())
            return "{" + inner + "}"
        else:
            return str(v)


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    print(f"🔍 Scanning source files in: {SOURCE_ROOT}")
    
    files = collect_files(SOURCE_ROOT)
    # Filter out Contents.json inside xcassets (only include the xcassets dir itself)
    filtered = []
    xcassets_dirs = set()
    for f in files:
        if f.suffix == ".xcassets" and f.is_dir():
            xcassets_dirs.add(f)
            filtered.append(f)
        elif any(f.is_relative_to(d) for d in xcassets_dirs):
            pass  # Skip files inside xcassets
        else:
            filtered.append(f)
    
    print(f"  Found {len(filtered)} files:")
    for f in filtered:
        print(f"    {f.relative_to(SCRIPT_DIR)}")
    
    proj = PBXProject()
    pbxproj_content = proj.generate(filtered)
    
    XCODEPROJ_DIR.mkdir(parents=True, exist_ok=True)
    pbxproj_path = XCODEPROJ_DIR / "project.pbxproj"
    pbxproj_path.write_text(pbxproj_content, encoding="utf-8")
    
    print(f"\n✅ Generated: {pbxproj_path}")
    print(f"\n📂 To open in Xcode:")
    print(f"   open \"{XCODEPROJ_DIR}\"")
    print(f"\n🔧 First time setup in Xcode:")
    print(f"   1. Set Team in Signing & Capabilities")
    print(f"   2. Build (⌘B) to compile Metal shaders")
    print(f"   3. Run (⌘R) to launch the app")


if __name__ == "__main__":
    main()
