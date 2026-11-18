#!/usr/bin/env python3
"""Static validator for a Theos-built iOS 6 (armv7, rootful) jailbreak .deb.

Python standard library only: no dpkg-deb, no otool, no ldid, no network.

Two payload layouts are accepted. Which one is required is decided by the
control ``Package`` field, never by what the payload happens to contain:

  tweak-only layout (``Package: org.usageguard.probe``, also the strict default
  for any unknown package id)
    * exactly two regular files under
      ``Library/MobileSubstrate/DynamicLibraries/``: ``<name>.dylib`` and
      ``<name>.plist`` with matching ``<name>``; nothing else

  tweak + preference bundle + app layout (``Package: org.usageguard.timer``)
    * exactly the seven files in ``MAIN_PAYLOAD_FILES``:
          Applications/UsageGuard.app/UsageGuard
          Applications/UsageGuard.app/Info.plist
          Library/MobileSubstrate/DynamicLibraries/UsageGuard.dylib
          Library/MobileSubstrate/DynamicLibraries/UsageGuard.plist
          Library/PreferenceBundles/UsageGuardPrefs.bundle/UsageGuardPrefs
          Library/PreferenceBundles/UsageGuardPrefs.bundle/Info.plist
          Library/PreferenceLoader/Preferences/UsageGuard.plist
    * ``Depends`` also lists ``preferenceloader`` and ``uikittools`` (the
      maintainer script needs ``uicache``)
    * ``control.tar`` carries ``postinst``, executable, refreshing the icon cache

What it enforces, on a single .deb:

  container
    * valid ar(5) archive whose first member is ``debian-binary`` (version 2.0)
    * exactly one ``control.tar.*`` and one ``data.tar.*`` member

  control
    * ``Architecture: iphoneos-arm``
    * ``Package`` and ``Version`` present and non-empty
    * ``Depends`` lists ``mobilesubstrate`` (optionally with a version clause)
    * ``Depends`` lists ``preferenceloader`` and ``uikittools`` (tweak +
      preference bundle + app layout only; the probe's two-file layout depends
      on ``mobilesubstrate`` alone)
    * ``postinst`` present, with all of the 0755 permission bits set
      (``mode & 0755 == 0755``; 0750 or 0700 fails) and referencing ``uicache``
      (tweak + preference bundle + app layout only)

  payload layout
    * every path is relative, normalised, free of ``..``, ``/home/``, ``/dev/``,
      drive letters and backslashes
    * only the directories leading to the expected files are present, and only
      regular files are accepted (no symlinks, no DEBIAN leftovers)
    * the file set is exactly the one required by the layout above; a missing
      or extra file fails the check with the diff in the detail column

  filter plist
    * parses as a property list (XML or binary)
    * ``Filter`` -> ``Bundles`` contains ``com.apple.springboard``

  Mach-O (the .dylib)
    * thin little-endian 32-bit Mach-O, filetype MH_DYLIB
    * cputype == 12 (CPU_TYPE_ARM), cpusubtype == 9 (CPU_SUBTYPE_ARM_V7)
    * LC_VERSION_MIN_IPHONEOS present with min OS 6.0.0
    * LC_CODE_SIGNATURE present (ldid -S happened)
    * LC_ID_DYLIB install name is /Library/MobileSubstrate/DynamicLibraries/<name>.dylib

  Mach-O (the preference bundle binary, tweak + preference bundle layout only)
    * thin little-endian 32-bit Mach-O, filetype MH_BUNDLE (8) only: the
      instance sets ``_DYNAMIC_LIBRARY = NO`` and links with ``-bundle``, so
      MH_DYLIB, MH_EXECUTE and every other filetype are rejected
    * no LC_ID_DYLIB (a ``-bundle`` link installs no dylib identity, so a
      dylib-shaped bundle executable is rejected)
    * cputype == 12 (CPU_TYPE_ARM), cpusubtype == 9 (CPU_SUBTYPE_ARM_V7)
    * LC_VERSION_MIN_IPHONEOS present with min OS 6.0.0
    * LC_CODE_SIGNATURE present

  Mach-O (the configuration app binary, tweak + preference bundle + app layout)
    * thin little-endian 32-bit Mach-O, filetype MH_EXECUTE (2) only: a tweak
      dylib or a bundle in ``/Applications/UsageGuard.app`` would never launch
    * cputype == 12 (CPU_TYPE_ARM), cpusubtype == 9 (CPU_SUBTYPE_ARM_V7)
    * LC_VERSION_MIN_IPHONEOS present with min OS 6.0.0
    * LC_CODE_SIGNATURE present

  app Info.plist (tweak + preference bundle + app layout only)
    * parses as a property list
    * ``CFBundleIdentifier`` == ``org.usageguard.timer.app``
    * ``CFBundleExecutable`` == ``UsageGuard``
    * ``CFBundleShortVersionString`` equals the control ``Version``

  PreferenceLoader entry (tweak + preference bundle + app layout only)
    * parses as a property list
    * top-level ``entry`` dict names ``bundle`` == ``UsageGuardPrefs``
    * ``entry.isController`` is boolean true and ``entry.detail`` is a
      non-empty class name, so PreferenceLoader pushes our PSViewController
    * the bundle's ``Info.plist`` sets ``CFBundleExecutable`` ==
      ``UsageGuardPrefs`` and a non-empty ``NSPrincipalClass`` (independent
      keys: they are allowed to differ)
    * ``Library/PreferenceLoader``, ``Library/PreferenceBundles`` and
      ``Applications`` may not appear at all -- not even as empty directories --
      in the probe layout

Exit status is 0 only when every applicable check passes. Failures print the
check name plus the observed value, so a red CI run is diagnosable from the log.

Usage:
    validate_deb.py [--expect-package PKG] [--forbid-package PKG]
                    [--expect-base NAME] DEB [DEB ...]
"""

import argparse
import fnmatch
import io
import os
import plistlib
import struct
import sys
import tarfile

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

MH_MAGIC = 0xFEEDFACE          # thin 32-bit, little endian
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_BE = 0xFEEDFACE       # same value read big endian means byte-swapped

CPU_TYPE_ARM = 12
CPU_SUBTYPE_ARM_V7 = 9
MH_OBJECT = 1
MH_EXECUTE = 2
MH_DYLIB = 6
MH_BUNDLE = 8

FILETYPE_NAMES = {MH_OBJECT: "MH_OBJECT", MH_EXECUTE: "MH_EXECUTE",
                  MH_DYLIB: "MH_DYLIB", MH_BUNDLE: "MH_BUNDLE"}

# prefs/Makefile sets `UsageGuardPrefs_DYNAMIC_LIBRARY = NO` and links with
# `-Wl,-bundle`, so the preference bundle executable is a real MH_BUNDLE
# (filetype 8) and carries no LC_ID_DYLIB. A dylib-shaped bundle -- Theos'
# bundle.mk default -- is rejected.
BUNDLE_FILETYPES = (MH_BUNDLE,)

LC_CODE_SIGNATURE = 0x1D
LC_VERSION_MIN_IPHONEOS = 0x25
LC_ID_DYLIB = 0x0D

DYLIB_DIR = "Library/MobileSubstrate/DynamicLibraries"
EXPECTED_BUNDLE = "com.apple.springboard"
MIN_OS_REQUIRED = (6, 0, 0)

# Package ids decide which payload layout is required (see the module docstring).
MAIN_PACKAGE = "org.usageguard.timer"

# The tweak + preference bundle + app layout. The self-test mirrors these paths.
MAIN_DYLIB = "UsageGuard"
PREFERENCE_BUNDLE = "UsageGuardPrefs"
PREFERENCE_LOADER_DIR = "Library/PreferenceLoader"
PREFERENCES_DIR = PREFERENCE_LOADER_DIR + "/Preferences"
BUNDLE_PARENT_DIR = "Library/PreferenceBundles"
BUNDLE_DIR = "%s/%s.bundle" % (BUNDLE_PARENT_DIR, PREFERENCE_BUNDLE)
# The configuration app. It is a rootful /Applications bundle, so it is not
# sandboxed like an App Store IPA and can read the tweak's preferences file.
APP_DIR = "Applications"
APP_BUNDLE = "UsageGuard.app"
APP_BUNDLE_DIR = "%s/%s" % (APP_DIR, APP_BUNDLE)
APP_EXECUTABLE = "UsageGuard"
APP_BINARY = "%s/%s" % (APP_BUNDLE_DIR, APP_EXECUTABLE)
APP_INFO_PLIST = "%s/Info.plist" % APP_BUNDLE_DIR
APP_BUNDLE_ID = "org.usageguard.timer.app"
MAIN_POSTINST = "postinst"
MAIN_POSTINST_MODE = 0o755
ICON_CACHE_TOOL = "uicache"

# PreferenceLoader/PreferenceBundles/Applications packaging belongs to the main
# package only; the probe must not ship (or even create) these directories.
MAIN_ONLY_PREFIXES = (
    (PREFERENCE_LOADER_DIR, "PreferenceLoader"),
    (BUNDLE_PARENT_DIR, "PreferenceBundles"),
    (APP_DIR, "/Applications app"),
)

MAIN_PAYLOAD_FILES = (
    APP_BINARY,
    APP_INFO_PLIST,
    "%s/%s.dylib" % (DYLIB_DIR, MAIN_DYLIB),
    "%s/%s.plist" % (DYLIB_DIR, MAIN_DYLIB),
    "%s/%s" % (BUNDLE_DIR, PREFERENCE_BUNDLE),
    "%s/Info.plist" % BUNDLE_DIR,
    "%s/%s.plist" % (PREFERENCES_DIR, MAIN_DYLIB),
)

FORBIDDEN_PREFIXES = ("home/", "dev/", "tmp/", "private/", "var/jb/")

# Mach-O errors that describe the architecture/container rather than a command.
ARCHITECTURE_ERROR_MARKERS = ("cputype", "cpusubtype", "filetype", "universal",
                              "64-bit", "magic", "too small", "fat slice",
                              "extends beyond")


# --------------------------------------------------------------------------- #
# Result collection
# --------------------------------------------------------------------------- #

class Report:
    def __init__(self, label):
        self.label = label
        self.rows = []

    def check(self, name, ok, detail=""):
        self.rows.append((name, bool(ok), detail))
        return bool(ok)

    def fail(self, name, detail):
        return self.check(name, False, detail)

    @property
    def failures(self):
        return [row for row in self.rows if not row[1]]

    def print_table(self):
        width = max([len(row[0]) for row in self.rows] + [5])
        print("")
        print(f"== {self.label} ==")
        print(f"{'CHECK'.ljust(width)}  RESULT  DETAIL")
        print(f"{'-' * width}  ------  ------")
        for name, ok, detail in self.rows:
            print(f"{name.ljust(width)}  {'PASS' if ok else 'FAIL':<6}  {detail}")
        print("")


# --------------------------------------------------------------------------- #
# ar(5)
# --------------------------------------------------------------------------- #

def read_ar(blob):
    """Return [(name, data)] for a System V / BSD ar archive."""
    if not blob.startswith(b"!<arch>\n"):
        raise ValueError("not an ar archive (missing '!<arch>' magic)")

    members = []
    offset = 8
    gnu_longnames = b""
    while offset < len(blob):
        header = blob[offset:offset + 60]
        if len(header) < 60:
            raise ValueError("truncated ar member header at offset %d" % offset)
        raw_name = header[0:16].decode("ascii", "replace").rstrip()
        size_field = header[48:58].decode("ascii", "replace").strip()
        if not size_field.isdigit():
            raise ValueError("bad ar size field %r at offset %d" % (size_field, offset))
        size = int(size_field)
        data = blob[offset + 60:offset + 60 + size]
        if len(data) != size:
            raise ValueError("truncated ar member %r (want %d bytes)" % (raw_name, size))
        offset += 60 + size + (size % 2)

        if raw_name == "//":
            gnu_longnames = data
            continue
        if raw_name in ("/", "/SYM64/"):
            continue

        if raw_name.startswith("#1/"):  # BSD extended name
            name_len = int(raw_name[3:])
            name = data[:name_len].decode("ascii", "replace").rstrip("\x00")
            data = data[name_len:]
        elif raw_name.startswith("/") and raw_name[1:].isdigit():
            start = int(raw_name[1:])
            end = gnu_longnames.find(b"/\n", start)
            if end < 0:
                end = len(gnu_longnames)
            name = gnu_longnames[start:end].decode("ascii", "replace")
        else:
            name = raw_name.rstrip("/")

        members.append((name, data))

    return members


# --------------------------------------------------------------------------- #
# tar / compression
# --------------------------------------------------------------------------- #

def decompress_member(name, data):
    lower = name.lower()
    if lower.endswith(".tar") or lower.endswith(".tar."):
        return data
    if lower.endswith(".gz"):
        import gzip
        return gzip.decompress(data)
    if lower.endswith(".xz"):
        import lzma
        return lzma.decompress(data)
    if lower.endswith(".lzma"):
        import lzma
        return lzma.decompress(data, format=lzma.FORMAT_ALONE)
    if lower.endswith(".bz2"):
        import bz2
        return bz2.decompress(data)
    if lower.endswith(".zst"):
        raise ValueError("zstd-compressed member %r is unsupported (stdlib has no zstd decoder); "
                         "build with gzip/xz/lzma" % name)
    raise ValueError("unrecognised tar member compression: %r" % name)


def read_tar(name, data):
    """Return [(path, member, payload_bytes_or_None)] from a tar member."""
    raw = decompress_member(name, data)
    entries = []
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        for member in archive.getmembers():
            payload = None
            if member.isfile():
                handle = archive.extractfile(member)
                payload = handle.read() if handle is not None else b""
            entries.append((member.name, member, payload))
    return entries


def normalise_path(path):
    """Normalise a tar path; return (normalised, error_or_None)."""
    if "\\" in path:
        return path, "backslash in path"
    if path.startswith("/"):
        return path, "absolute path"
    if len(path) > 1 and path[1] == ":":
        return path, "windows drive path"
    cleaned = path
    while cleaned.startswith("./"):
        cleaned = cleaned[2:]
    cleaned = cleaned.lstrip("/")
    parts = [part for part in cleaned.split("/") if part not in ("", ".")]
    if any(part == ".." for part in parts):
        return cleaned, "path traversal ('..')"
    joined = "/".join(parts)
    for prefix in FORBIDDEN_PREFIXES:
        if joined == prefix.rstrip("/") or joined.startswith(prefix):
            return joined, "path under forbidden prefix %r" % prefix
    if joined == "":
        return joined, "empty path"
    return joined, None


# --------------------------------------------------------------------------- #
# Mach-O
# --------------------------------------------------------------------------- #

def decode_version(value):
    return (value >> 16, (value >> 8) & 0xFF, value & 0xFF)


def architecture_errors(errors):
    """The subset of Mach-O errors that describe the architecture, not commands."""
    return [e for e in errors if any(marker in e for marker in ARCHITECTURE_ERROR_MARKERS)]


def filetype_label(filetype):
    return FILETYPE_NAMES.get(filetype, "unknown filetype")


def parse_macho(payload, expected_filetype=MH_DYLIB):
    """Return (info_dict, [error strings]) for a Mach-O payload.

    ``expected_filetype`` is one filetype or a sequence of acceptable ones.
    """
    errors = []
    info = {}

    if len(payload) < 28:
        return info, ["file too small to be a Mach-O (%d bytes)" % len(payload)]

    magic_le = struct.unpack_from("<I", payload, 0)[0]
    magic_be = struct.unpack_from(">I", payload, 0)[0]

    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        # cctools lipo keeps a fat container even for a single -arch, so accept
        # a container only when it holds exactly one armv7 slice. Our own output
        # must never carry an armv7s or arm64 slice.
        slice_count = struct.unpack_from(">I", payload, 4)[0]
        if slice_count != 1:
            return info, ["universal (fat) Mach-O with %d slices; exactly one armv7 slice is required"
                          % slice_count]
        arch_cputype, arch_cpusubtype, arch_offset, arch_size = struct.unpack_from(">IIII", payload, 8)
        arch_subtype = arch_cpusubtype & 0x00FFFFFF
        if arch_cputype != CPU_TYPE_ARM or arch_subtype != CPU_SUBTYPE_ARM_V7:
            return info, ["fat slice is cputype=%d subtype=%d, expected armv7 (12/9)"
                          % (arch_cputype, arch_subtype)]
        if arch_offset + arch_size > len(payload):
            return info, ["fat slice extends beyond end of file"]
        inner_info, inner_errors = parse_macho(payload[arch_offset:arch_offset + arch_size],
                                              expected_filetype)
        inner_info["fat"] = True
        return inner_info, inner_errors
    if magic_le in (FAT_MAGIC, FAT_MAGIC_64):
        return info, ["big-endian universal (fat) Mach-O; a single thin armv7 slice is required"]
    if magic_le == MH_MAGIC_64:
        return info, ["64-bit Mach-O (MH_MAGIC_64); armv7 requires 32-bit"]
    if magic_le != MH_MAGIC:
        return info, ["not a thin 32-bit little-endian Mach-O (magic 0x%08X)" % magic_le]

    cputype, cpusubtype, filetype, ncmds, sizeofcmds, _flags = struct.unpack_from("<IIIIII", payload, 4)
    info.update(cputype=cputype, cpusubtype=cpusubtype, filetype=filetype, ncmds=ncmds)

    # Only the low 24 bits carry the actual subtype; the high byte holds capability flags.
    subtype = cpusubtype & 0x00FFFFFF
    if cputype != CPU_TYPE_ARM:
        errors.append("cputype is %d, expected %d (CPU_TYPE_ARM)" % (cputype, CPU_TYPE_ARM))
    if subtype != CPU_SUBTYPE_ARM_V7:
        errors.append("cpusubtype is %d, expected %d (CPU_SUBTYPE_ARM_V7)" % (subtype, CPU_SUBTYPE_ARM_V7))
    accepted = (expected_filetype
                if isinstance(expected_filetype, (list, tuple, set, frozenset))
                else (expected_filetype,))
    if filetype not in accepted:
        errors.append("filetype is %d (%s), expected %s"
                      % (filetype, filetype_label(filetype),
                         " or ".join("%d (%s)" % (want, filetype_label(want))
                                     for want in accepted)))

    offset = 28
    end = 28 + sizeofcmds
    if end > len(payload):
        return info, errors + ["load commands claim %d bytes but file has %d" % (sizeofcmds, len(payload) - 28)]

    version_min = None
    has_code_signature = False
    install_name = None
    index = 0
    while index < ncmds:
        if offset + 8 > end:
            errors.append("truncated load command %d at offset %d" % (index, offset))
            break
        cmd, cmdsize = struct.unpack_from("<II", payload, offset)
        if cmdsize < 8 or cmdsize % 4 != 0:
            errors.append("load command %d has invalid size %d" % (index, cmdsize))
            break
        if offset + cmdsize > end:
            errors.append("load command %d overruns sizeofcmds" % index)
            break

        if cmd == LC_VERSION_MIN_IPHONEOS:
            version_min = struct.unpack_from("<I", payload, offset + 8)[0]
        elif cmd == LC_CODE_SIGNATURE:
            has_code_signature = True
        elif cmd == LC_ID_DYLIB:
            str_offset = struct.unpack_from("<I", payload, offset + 8)[0]
            start = offset + str_offset
            stop = payload.find(b"\x00", start, offset + cmdsize)
            if stop < 0:
                stop = offset + cmdsize
            install_name = payload[start:stop].decode("utf-8", "replace")

        offset += cmdsize
        index += 1

    if version_min is None:
        errors.append("LC_VERSION_MIN_IPHONEOS missing (linker did not record an iOS deployment target)")
    else:
        decoded = decode_version(version_min)
        info["min_os"] = decoded
        if decoded != MIN_OS_REQUIRED:
            errors.append("LC_VERSION_MIN_IPHONEOS is %d.%d.%d, expected %d.%d.%d"
                          % (decoded + MIN_OS_REQUIRED))
    if not has_code_signature:
        errors.append("LC_CODE_SIGNATURE missing (binary was not signed with ldid -S)")
    info["install_name"] = install_name

    return info, errors


# --------------------------------------------------------------------------- #
# control
# --------------------------------------------------------------------------- #

def parse_control(text):
    fields = {}
    key = None
    for line in text.splitlines():
        if not line.strip():
            key = None
            continue
        if line[0] in " \t" and key is not None:
            fields[key] += " " + line.strip()
            continue
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        key = name.strip().lower()
        fields[key] = value.strip()
    return fields


def depends_contains(value, wanted):
    for clause in value.split(","):
        first = clause.split("|")[0].strip()
        name = first.split("(")[0].strip()
        if name.lower() == wanted:
            return True
    return False


def depends_contains_mobilesubstrate(value):
    return depends_contains(value, "mobilesubstrate")


def wants_preference_layout(fields):
    """Return True when this package must carry the preference bundle payload.

    The package id decides, so a package cannot opt into the weaker two-file
    layout by shipping a two-file payload. The probe keeps the two-file
    layout, and so does any unknown package id, which is why the probe (run with
    ``--expect-package org.usageguard.probe``) is never asked for
    ``preferenceloader`` or ``uikittools``.
    """
    return fields.get("package", "") == MAIN_PACKAGE


def main_only_label(normalised):
    """Return the packaging label when this path belongs to the main package only."""
    for prefix, label in MAIN_ONLY_PREFIXES:
        if normalised == prefix or normalised.startswith(prefix + "/"):
            return label
    return None


# --------------------------------------------------------------------------- #
# Per-deb validation
# --------------------------------------------------------------------------- #

def validate_preference_bundle(report, payload_files):
    """Check the preference bundle binary and its PreferenceLoader entry plist."""
    bundle_key = "%s/%s" % (BUNDLE_DIR, PREFERENCE_BUNDLE)
    bundle_payload = payload_files.get(bundle_key)
    if bundle_payload is None:
        for name in ("bundle binary is armv7 MH_BUNDLE",
                     "bundle LC_VERSION_MIN_IPHONEOS 6.0.0",
                     "bundle LC_CODE_SIGNATURE present",
                     "bundle has no LC_ID_DYLIB"):
            report.fail(name, "%s is missing from the payload" % bundle_key)
    else:
        info, errors = parse_macho(bundle_payload, expected_filetype=BUNDLE_FILETYPES)
        unsigned = [e for e in errors if "LC_CODE_SIGNATURE" in e]
        report.check("bundle binary is armv7 MH_BUNDLE",
                     not architecture_errors(errors),
                     "filetype=%s (%s), cputype=%s subtype=%s%s"
                     % (info.get("filetype", "?"),
                        filetype_label(info.get("filetype", -1)),
                        info.get("cputype", "?"), info.get("cpusubtype", "?"),
                        ", single-slice fat" if info.get("fat") else ""))
        report.check("bundle LC_VERSION_MIN_IPHONEOS 6.0.0",
                     "min_os" in info and info["min_os"] == MIN_OS_REQUIRED,
                     "%d.%d.%d" % info["min_os"] if "min_os" in info else "missing")
        report.check("bundle LC_CODE_SIGNATURE present", not unsigned,
                     "unsigned" if unsigned else "signed")
        # A -bundle link has no dylib identity to install, and Preferences.app
        # only dlopen()s this binary; an LC_ID_DYLIB means it was linked
        # -dynamiclib, i.e. it is still a dylib wearing a .bundle name.
        install_name = info.get("install_name")
        report.check("bundle has no LC_ID_DYLIB", install_name is None,
                     "no LC_ID_DYLIB" if install_name is None
                     else "carries LC_ID_DYLIB install name %r (dylib-shaped bundle)" % install_name)
        report.check("bundle Mach-O load commands clean", not errors,
                     "ok" if not errors else "; ".join(errors))

    # PreferenceLoader only loads the entry's bundle as a controller when
    # entry.isController is true, and then pushes entry.detail as a
    # PSViewController; a plain link cell or a missing detail class means the
    # Settings row either does nothing or crashes on the push.
    prefs_key = "%s/%s.plist" % (PREFERENCES_DIR, MAIN_DYLIB)
    problems = []
    detail = None
    prefs_payload = payload_files.get(prefs_key)
    if prefs_payload is None:
        problems.append("%s is missing from the payload" % prefs_key)
    else:
        try:
            parsed = plistlib.loads(prefs_payload)
        except Exception as error:  # plistlib raises several unrelated types
            problems.append("not a valid property list: %s" % error)
        else:
            entry = parsed.get("entry") if isinstance(parsed, dict) else None
            if not isinstance(entry, dict):
                problems.append("top-level 'entry' dict missing")
            else:
                bundle = entry.get("bundle")
                if bundle != PREFERENCE_BUNDLE:
                    problems.append("entry.bundle is %r, expected %r" % (bundle, PREFERENCE_BUNDLE))
                is_controller = entry.get("isController")
                if is_controller is not True:
                    problems.append("entry.isController is %r, expected boolean true"
                                    % (is_controller,))
                detail = entry.get("detail")
                if not isinstance(detail, str) or not detail.strip():
                    problems.append("entry.detail is %r, expected a controller class name"
                                    % (detail,))
    report.check("PreferenceLoader entry is a controller", not problems,
                 "; ".join(problems) or "%s, detail %s" % (PREFERENCE_BUNDLE, detail))

    # NSPrincipalClass is the class PreferenceLoader instantiates out of the
    # bundle; CFBundleExecutable names the binary that must carry it. They are
    # independent keys, so a mismatch between them is not required.
    info_key = "%s/Info.plist" % BUNDLE_DIR
    info_problems = []
    info_detail = ""
    info_payload = payload_files.get(info_key)
    if info_payload is None:
        info_problems.append("%s is missing from the payload" % info_key)
    else:
        try:
            parsed = plistlib.loads(info_payload)
        except Exception as error:  # plistlib raises several unrelated types
            info_problems.append("not a valid property list: %s" % error)
        else:
            if not isinstance(parsed, dict):
                info_problems.append("top-level dict missing")
                parsed = {}
            executable = parsed.get("CFBundleExecutable")
            principal = parsed.get("NSPrincipalClass")
            if executable != PREFERENCE_BUNDLE:
                info_problems.append("CFBundleExecutable is %r, expected %r"
                                     % (executable, PREFERENCE_BUNDLE))
            if not isinstance(principal, str) or not principal.strip():
                info_problems.append("NSPrincipalClass is %r, expected a class name" % (principal,))
            else:
                info_detail = "%s, principal %s" % (executable, principal)
    report.check("bundle Info.plist declares CFBundleExecutable and NSPrincipalClass",
                 not info_problems, "; ".join(info_problems) or info_detail)


def validate_configuration_app(report, payload_files, fields):
    """Check the /Applications app: an armv7 MH_EXECUTE and its Info.plist."""
    binary = payload_files.get(APP_BINARY)
    if binary is None:
        for name in ("app binary is armv7 MH_EXECUTE",
                     "app binary min OS 6.0.0",
                     "app binary signed"):
            report.fail(name, "%s is missing from the payload" % APP_BINARY)
    else:
        # MH_EXECUTE only: a dylib or bundle in /Applications/UsageGuard.app
        # would be installed but never launched by SpringBoard.
        info, errors = parse_macho(binary, expected_filetype=MH_EXECUTE)
        unsigned = [e for e in errors if "LC_CODE_SIGNATURE" in e]
        arch_errors = architecture_errors(errors)
        report.check("app binary is armv7 MH_EXECUTE", not arch_errors,
                     "; ".join(arch_errors) if arch_errors
                     else "filetype=%s (%s), cputype=%s subtype=%s%s"
                     % (info.get("filetype", "?"),
                        filetype_label(info.get("filetype", -1)),
                        info.get("cputype", "?"), info.get("cpusubtype", "?"),
                        ", single-slice fat" if info.get("fat") else ""))
        report.check("app binary min OS 6.0.0",
                     "min_os" in info and info["min_os"] == MIN_OS_REQUIRED,
                     "%d.%d.%d" % info["min_os"] if "min_os" in info else "missing")
        report.check("app binary signed", not unsigned,
                     "unsigned" if unsigned else "signed")

    # The app's identity is what makes it a second host for the same
    # preferences file: the bundle id is stable, the executable names the binary
    # inside the bundle, and the version must track the package version (the app,
    # the pane and the tweak are one release).
    expected_version = fields.get("version", "")
    problems = []
    detail = ""
    payload = payload_files.get(APP_INFO_PLIST)
    if payload is None:
        problems.append("%s is missing from the payload" % APP_INFO_PLIST)
    else:
        try:
            parsed = plistlib.loads(payload)
        except Exception as error:  # plistlib raises several unrelated types
            problems.append("not a valid property list: %s" % error)
        else:
            if not isinstance(parsed, dict):
                problems.append("top-level dict missing")
                parsed = {}
            identifier = parsed.get("CFBundleIdentifier")
            executable = parsed.get("CFBundleExecutable")
            version = parsed.get("CFBundleShortVersionString")
            if identifier != APP_BUNDLE_ID:
                problems.append("CFBundleIdentifier is %r, expected %r"
                                % (identifier, APP_BUNDLE_ID))
            if executable != APP_EXECUTABLE:
                problems.append("CFBundleExecutable is %r, expected %r"
                                % (executable, APP_EXECUTABLE))
            if version != expected_version:
                problems.append("CFBundleShortVersionString is %r, expected %r (control Version)"
                                % (version, expected_version))
            else:
                detail = "%s %s" % (identifier, version)
    report.check("app Info.plist matches control identity and version",
                 not problems, "; ".join(problems) or detail)


def validate_maintainer_scripts(report, member, payload):
    """Check the control.tar postinst: present, executable and runs uicache."""
    if member is None or payload is None:
        for name in ("postinst present", "postinst is executable",
                     "postinst refreshes the icon cache"):
            report.fail(name, "%s is missing from control.tar" % MAIN_POSTINST)
        return

    report.check("postinst present", True, "%s (%d bytes)" % (MAIN_POSTINST, len(payload)))
    mode = member.mode & 0o777
    executable = (mode & MAIN_POSTINST_MODE) == MAIN_POSTINST_MODE
    report.check("postinst is executable", executable,
                 "mode %04o" % mode if executable
                 else "mode %04o, expected at least %04o" % (mode, MAIN_POSTINST_MODE))
    # iOS 6 only registers an /Applications bundle after uicache (or a reboot),
    # so a postinst that never calls it ships an app with no home-screen icon.
    refreshes = ICON_CACHE_TOOL.encode() in payload
    report.check("postinst refreshes the icon cache", refreshes,
                 "%s invoked" % ICON_CACHE_TOOL if refreshes
                 else "%s is not referenced" % ICON_CACHE_TOOL)


def validate(deb_path, args):
    report = Report(deb_path)
    try:
        with open(deb_path, "rb") as handle:
            blob = handle.read()
    except OSError as error:
        report.fail("read deb", str(error))
        report.print_table()
        return report

    try:
        members = read_ar(blob)
    except ValueError as error:
        report.fail("ar container", str(error))
        report.print_table()
        return report

    names = [name for name, _ in members]
    report.check("ar members", bool(names), ", ".join(names))

    if names and names[0] == "debian-binary":
        report.check("debian-binary first", True, "debian-binary")
        report.check("debian-binary version", members[0][1].startswith(b"2.0"),
                     members[0][1].strip().decode("ascii", "replace")[:20])
    else:
        report.fail("debian-binary first", "first member is %r" % (names[0] if names else "<none>"))

    control_members = [m for m in members if m[0].startswith("control.tar")]
    data_members = [m for m in members if m[0].startswith("data.tar")]
    if not report.check("control.tar present", len(control_members) == 1,
                        ", ".join(m[0] for m in control_members) or "none"):
        report.print_table()
        return report
    if not report.check("data.tar present", len(data_members) == 1,
                        ", ".join(m[0] for m in data_members) or "none"):
        report.print_table()
        return report

    # ---- control.tar ----------------------------------------------------- #
    try:
        control_entries = read_tar(*control_members[0])
    except (ValueError, OSError, tarfile.TarError) as error:
        report.fail("control.tar readable", str(error))
        report.print_table()
        return report

    control_blob = None
    postinst_member = None
    postinst_blob = None
    for path, member, payload in control_entries:
        normalised, error = normalise_path(path)
        if error is not None:
            continue
        if normalised == "control" and member.isfile():
            control_blob = payload
        elif normalised == MAIN_POSTINST and member.isfile():
            postinst_member, postinst_blob = member, payload
    if control_blob is None:
        report.fail("control file present", "no ./control entry in control.tar")
        report.print_table()
        return report

    fields = parse_control(control_blob.decode("utf-8", "replace"))
    report.check("control: Package", bool(fields.get("package")), fields.get("package", "<missing>"))
    report.check("control: Version", bool(fields.get("version")), fields.get("version", "<missing>"))
    report.check("control: Architecture", fields.get("architecture") == "iphoneos-arm",
                 fields.get("architecture", "<missing>"))

    depends = fields.get("depends", "")
    report.check("control: Depends mobilesubstrate", depends_contains_mobilesubstrate(depends),
                 depends or "<missing>")

    preference_layout = wants_preference_layout(fields)
    if preference_layout:
        report.check("control: Depends preferenceloader", depends_contains(depends, "preferenceloader"),
                     depends or "<missing>")
        # uicache ships in uikittools; the postinst below calls it.
        report.check("control: Depends uikittools", depends_contains(depends, "uikittools"),
                     depends or "<missing>")
        validate_maintainer_scripts(report, postinst_member, postinst_blob)

    if args.expect_package:
        package = fields.get("package", "")
        report.check("control: Package matches expectation",
                     fnmatch.fnmatchcase(package, args.expect_package),
                     "%s vs %r" % (package or "<missing>", args.expect_package))
    if args.forbid_package:
        package = fields.get("package", "")
        report.check("control: Package not forbidden",
                     not fnmatch.fnmatchcase(package, args.forbid_package),
                     "%s vs forbidden %r" % (package or "<missing>", args.forbid_package))

    # ---- data.tar -------------------------------------------------------- #
    try:
        data_entries = read_tar(*data_members[0])
    except (ValueError, OSError, tarfile.TarError) as error:
        report.fail("data.tar readable", str(error))
        report.print_table()
        return report

    payload_files = {}
    problems = []
    allowed_dirs = {"", "Library", "Library/MobileSubstrate", DYLIB_DIR}
    if preference_layout:
        # The app lives in /Applications, which iOS 6 does not sandbox the way
        # an App Store bundle is sandboxed; it is part of this package only.
        allowed_dirs |= {PREFERENCE_LOADER_DIR, PREFERENCES_DIR,
                         BUNDLE_PARENT_DIR, BUNDLE_DIR, APP_DIR, APP_BUNDLE_DIR}

    for path, member, payload in data_entries:
        # dpkg/tar emit an archive-root entry ("./").
        if path.rstrip("/") in (".", ""):
            continue
        normalised, error = normalise_path(path)
        if error is not None:
            problems.append("%s: %s" % (path, error))
            continue
        if not preference_layout:
            label = main_only_label(normalised)
            if label is not None:
                problems.append("%s: %s packaging is only allowed in package %s"
                                % (normalised, label, MAIN_PACKAGE))
                continue
        if member.isdir():
            if normalised not in allowed_dirs:
                problems.append("%s: unexpected directory in payload" % normalised)
            continue
        if not member.isfile():
            problems.append("%s: not a regular file (symlink/hardlink/device rejected)" % normalised)
            continue
        if normalised.startswith("DEBIAN/"):
            problems.append("%s: DEBIAN/ must live in control.tar, not data.tar" % normalised)
            continue
        payload_files[normalised] = payload

    report.check("payload paths normalised", not problems, "; ".join(problems[:6]) or "ok")

    if preference_layout:
        missing = sorted(set(MAIN_PAYLOAD_FILES) - set(payload_files))
        unexpected = sorted(set(payload_files) - set(MAIN_PAYLOAD_FILES))
        if missing or unexpected:
            detail = "missing: %s; unexpected: %s" % (
                ", ".join(missing) or "none", ", ".join(unexpected) or "none")
        else:
            detail = "%d files" % len(MAIN_PAYLOAD_FILES)
        report.check("payload matches expected file set", not missing and not unexpected, detail)
        base_name = MAIN_DYLIB
    else:
        expected_names = set()
        for name in payload_files:
            base = os.path.basename(name)
            if os.path.dirname(name) == DYLIB_DIR:
                expected_names.add(os.path.splitext(base)[0])
        unexpected = sorted(set(payload_files) - {
            "%s/%s.dylib" % (DYLIB_DIR, name) for name in expected_names
        } - {
            "%s/%s.plist" % (DYLIB_DIR, name) for name in expected_names
        })
        report.check("payload is only the MobileSubstrate dylib + filter plist",
                     len(expected_names) == 1 and len(payload_files) == 2 and not unexpected,
                     ", ".join(sorted(payload_files)) or "empty payload")

        if len(expected_names) != 1:
            report.print_table()
            return report

        base_name = expected_names.pop()

    if args.expect_base:
        report.check("payload base name matches expectation",
                     fnmatch.fnmatchcase(base_name, args.expect_base),
                     "%s vs %r" % (base_name, args.expect_base))

    dylib_key = "%s/%s.dylib" % (DYLIB_DIR, base_name)
    plist_key = "%s/%s.plist" % (DYLIB_DIR, base_name)
    if not report.check("dylib present", dylib_key in payload_files, dylib_key):
        report.print_table()
        return report
    if not report.check("filter plist present", plist_key in payload_files, plist_key):
        report.print_table()
        return report

    # ---- filter plist ---------------------------------------------------- #
    plist_problems = []
    try:
        parsed = plistlib.loads(payload_files[plist_key])
        filter_dict = parsed.get("Filter") if isinstance(parsed, dict) else None
        if not isinstance(filter_dict, dict):
            plist_problems.append("top-level 'Filter' dict missing")
        else:
            bundles = filter_dict.get("Bundles")
            if not isinstance(bundles, list) or EXPECTED_BUNDLE not in bundles:
                plist_problems.append("Filter.Bundles does not contain %r (got %r)"
                                      % (EXPECTED_BUNDLE, bundles))
    except Exception as error:  # plistlib raises several unrelated types
        plist_problems.append("not a valid property list: %s" % error)
    report.check("filter targets com.apple.springboard", not plist_problems,
                 "; ".join(plist_problems) or EXPECTED_BUNDLE)

    # ---- Mach-O ---------------------------------------------------------- #
    info, macho_errors = parse_macho(payload_files[dylib_key])
    report.check("Mach-O is armv7 MH_DYLIB",
                 not architecture_errors(macho_errors),
                 "cputype=%s subtype=%s%s" % (info.get("cputype", "?"), info.get("cpusubtype", "?"),
                                              ", single-slice fat" if info.get("fat") else ""))
    report.check("LC_VERSION_MIN_IPHONEOS 6.0.0",
                 "min_os" in info and info["min_os"] == MIN_OS_REQUIRED,
                 "%d.%d.%d" % info["min_os"] if "min_os" in info else "missing")
    report.check("LC_CODE_SIGNATURE present",
                 not [e for e in macho_errors if "LC_CODE_SIGNATURE" in e],
                 "signed" if not [e for e in macho_errors if "LC_CODE_SIGNATURE" in e] else "unsigned")

    expected_install_name = "/%s/%s.dylib" % (DYLIB_DIR, base_name)
    report.check("LC_ID_DYLIB install name", info.get("install_name") == expected_install_name,
                 info.get("install_name") or "<missing>")

    report.check("Mach-O load commands clean", not macho_errors,
                 "ok" if not macho_errors else "; ".join(macho_errors))

    if preference_layout:
        validate_configuration_app(report, payload_files, fields)
        validate_preference_bundle(report, payload_files)

    report.print_table()
    return report


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("debs", nargs="+", help="path to the .deb to validate")
    parser.add_argument("--expect-package", default=None,
                        help="fnmatch pattern the control Package field must match")
    parser.add_argument("--forbid-package", default=None,
                        help="fnmatch pattern the control Package field must not match")
    parser.add_argument("--expect-base", default=None,
                        help="fnmatch pattern the dylib/plist base name must match")
    args = parser.parse_args(argv)

    failed = 0
    for deb in args.debs:
        if not os.path.isfile(deb):
            print("error: no such file: %s" % deb, file=sys.stderr)
            failed += 1
            continue
        try:
            report = validate(deb, args)
        except Exception as error:  # a malformed package must never crash the validator
            print("FAILED: %s: validator error: %s" % (deb, error), file=sys.stderr)
            failed += 1
            continue
        if report.failures:
            failed += 1

    if failed:
        print("FAILED: %d of %d package(s) did not validate" % (failed, len(args.debs)), file=sys.stderr)
        return 1

    print("PASS: %d package(s) validated" % len(args.debs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
