#!/usr/bin/env python3
from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_ROOT = ROOT / "App"
SOURCE = APP_ROOT / "Sources" / "TranslateText.swift"
WORKER = APP_ROOT / "Workers" / "translate_text_worker.py"
BUILD_DIR = APP_ROOT / "build"
OUTPUTS = ROOT / "outputs"
APP_BUNDLE = OUTPUTS / "Translate Text.app"
EXECUTABLE_NAME = "Translate Text"
ICON_SOURCE = ROOT / "assets" / "translator.icns"


def main() -> None:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    (BUILD_DIR / "module-cache").mkdir(parents=True, exist_ok=True)
    OUTPUTS.mkdir(parents=True, exist_ok=True)

    binary = BUILD_DIR / EXECUTABLE_NAME
    subprocess.run(
        [
            "swiftc",
            "-O",
            "-module-cache-path",
            str(BUILD_DIR / "module-cache"),
            "-framework",
            "AppKit",
            str(SOURCE),
            "-o",
            str(binary),
        ],
        check=True,
    )

    if APP_BUNDLE.exists():
        shutil.rmtree(APP_BUNDLE)
    macos_dir = APP_BUNDLE / "Contents" / "MacOS"
    resources_dir = APP_BUNDLE / "Contents" / "Resources"
    macos_dir.mkdir(parents=True)
    resources_dir.mkdir(parents=True)

    shutil.copy2(binary, macos_dir / EXECUTABLE_NAME)
    shutil.copy2(WORKER, resources_dir / "translate_text_worker.py")
    if ICON_SOURCE.exists():
        shutil.copy2(ICON_SOURCE, resources_dir / "translator.icns")

    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": EXECUTABLE_NAME,
        "CFBundleIdentifier": "local.shortcut-translate-text",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Translate Text",
        "CFBundleDisplayName": "Translate Text",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "2.0",
        "CFBundleVersion": "2",
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }
    if (resources_dir / "translator.icns").exists():
        info["CFBundleIconFile"] = "translator"

    with (APP_BUNDLE / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle, sort_keys=False)

    os.chmod(macos_dir / EXECUTABLE_NAME, 0o755)


if __name__ == "__main__":
    main()
