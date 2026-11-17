#!/usr/bin/env python3
"""Static validator for a Theos-built iOS 6 (armv7, rootful) jailbreak .deb.

Python standard library only: no dpkg-deb, no otool, no ldid, no network.

What it enforces, on a single .deb:

  container
    * valid ar(5) archive whose first member is ``debian-binary`` (version 2.0)
    * exactly one ``control.tar.*`` and one ``data.tar.*`` member

  control
    * ``Architecture: iphoneos-arm``
    * ``Package`` and ``Version`` present and non-empty
    * ``Depends`` lists ``mobilesubstrate`` (optionally with a version clause)

  payload layout
    * every path is relative, normalised, free of ``..``, ``/home/``, ``/dev/``,
      drive letters and backslashes
    * the payload is exactly two regular files:
          Library/MobileSubstrate/DynamicLibraries/<name>.dylib
          Library/MobileSubstrate/DynamicLibraries/<name>.plist
      with matching <name>; nothing else (no symlinks, no DEBIAN leftovers)

  filter plist
    * parses as a property list (XML or binary)
    * ``Filter`` -> ``Bundles`` contains ``com.apple.springboard``

  Mach-O (the .dylib)
    * thin little-endian 32-bit Mach-O, filetype MH_DYLIB
    * cputype == 12 (CPU_TYPE_ARM), cpusubtype == 9 (CPU_SUBTYPE_ARM_V7)
    * LC_VERSION_MIN_IPHONEOS present with min OS 6.0.0
    * LC_CODE_SIGNATURE present (ldid -S happened)
    * LC_ID_DYLIB install name is /Library/MobileSubstrate/DynamicLibraries/<name>.dylib

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
MH_DYLIB = 6

LC_CODE_SIGNATURE = 0x1D
LC_VERSION_MIN_IPHONEOS = 0x25
LC_ID_DYLIB = 0x0D

DYLIB_DIR = "Library/MobileSubstrate/DynamicLibraries"
EXPECTED_BUNDLE = "com.apple.springboard"
MIN_OS_REQUIRED = (6, 0, 0)

FORBIDDEN_PREFIXES = ("home/", "dev/", "tmp/", "private/", "var/jb/")


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


def parse_macho(payload):
    """Return (info_dict, [error strings]) for a Mach-O payload."""
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
        inner_info, inner_errors = parse_macho(payload[arch_offset:arch_offset + arch_size])
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
    if filetype != MH_DYLIB:
        errors.append("filetype is %d, expected %d (MH_DYLIB)" % (filetype, MH_DYLIB))

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


def depends_contains_mobilesubstrate(value):
    for clause in value.split(","):
        first = clause.split("|")[0].strip()
        name = first.split("(")[0].strip()
        if name.lower() == "mobilesubstrate":
            return True
    return False


# --------------------------------------------------------------------------- #
# Per-deb validation
# --------------------------------------------------------------------------- #

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
    for path, member, payload in control_entries:
        normalised, error = normalise_path(path)
        if error is None and normalised == "control" and member.isfile():
            control_blob = payload
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

    for path, member, payload in data_entries:
        if member.isdir():
            # dpkg/tar emit an archive-root entry ("./"); only the directories
            # leading to the MobileSubstrate payload are acceptable.
            if path.rstrip("/") in (".", ""):
                continue
            normalised, error = normalise_path(path)
            if error is not None:
                problems.append("%s: %s" % (path, error))
            elif normalised not in allowed_dirs:
                problems.append("%s: unexpected directory in payload" % normalised)
            continue
        normalised, error = normalise_path(path)
        if error is not None:
            problems.append("%s: %s" % (path, error))
            continue
        if not member.isfile():
            problems.append("%s: not a regular file (symlink/hardlink/device rejected)" % normalised)
            continue
        if normalised.startswith("DEBIAN/"):
            problems.append("%s: DEBIAN/ must live in control.tar, not data.tar" % normalised)
            continue
        payload_files[normalised] = payload

    report.check("payload paths normalised", not problems, "; ".join(problems[:6]) or "ok")

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
                 not [e for e in macho_errors if "cputype" in e or "cpusubtype" in e
                      or "filetype" in e or "universal" in e or "64-bit" in e
                      or "magic" in e or "too small" in e or "fat slice" in e
                      or "extends beyond" in e],
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
