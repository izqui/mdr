#!/usr/bin/env python3
"""Keep development bundles from shadowing the installed app in LaunchServices."""
import os
import plistlib
import subprocess
import sys
from pathlib import Path

installed = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent.parent
register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for directory in (root / "work", root / "dist"):
    for current, directories, _ in os.walk(directory):
        bundle = Path(current)
        if bundle.suffix != ".app":
            continue
        directories[:] = []
        if bundle.resolve() == installed:
            continue
        try:
            with (bundle / "Contents/Info.plist").open("rb") as stream:
                identifier = plistlib.load(stream).get("CFBundleIdentifier")
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        if identifier == "app.mdr.reader":
            subprocess.run([register, "-u", str(bundle)], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run([register, "-f", str(installed)], check=True)
