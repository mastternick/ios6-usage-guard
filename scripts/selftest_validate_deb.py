#!/usr/bin/env python3
"""Self-test for scripts/validate_deb.py (stdlib only, no dpkg-deb needed).

Builds synthetic .deb files in a temporary directory - one structurally valid
package plus one package per rule that the validator is supposed to reject -
then asserts the validator's exit status and the reason it reported.

Run from the repository root:

    python3 scripts/selftest_validate_deb.py

Exit status 0 means the validator accepts a correct armv7 iOS 6 package and
rejects every malformed variant with the expected diagnostic.
"""

import gzip
import io
import lzma
import os
import struct
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
VALIDATOR = os.path.join(HERE, "validate_deb.py")

DYLIB_DIR = "Library/MobileSubstrate/DynamicLibraries"

# Mirrors validate_deb.py's MAIN_PAYLOAD_FILES; the self-test imports nothing.
MAIN_DYLIB = "UsageGuard"
PREFERENCE_BUNDLE = "UsageGuardPrefs"
BUNDLE_DIR = "Library/PreferenceBundles/%s.bundle" % PREFERENCE_BUNDLE
PREFERENCES_DIR = "Library/PreferenceLoader/Preferences"

CONTROL_TEMPLATE = """Package: {package}
Name: Synthetic
Version: 0.0.1
Architecture: {architecture}
Description: synthetic package for validator self-test
Maintainer: Self Test
Author: Self Test
Section: Tweaks
Depends: {depends}
"""

FILTER_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Filter</key>
<dict>
\t\t<key>Bundles</key>
\t\t<array>
\t\t\t<string>com.apple.springboard</string>
\t\t</array>
\t</dict>
</dict>
</plist>
"""

INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>English</string>
\t<key>CFBundleExecutable</key>
\t<string>UsageGuardPrefs</string>
\t<key>CFBundleIdentifier</key>
\t<string>org.usageguard.timer.prefs</string>
\t<key>CFBundlePackageType</key>
\t<string>BNDL</string>
\t<key>CFBundleShortVersionString</key>
\t<string>1.0.2</string>
\t<key>MinimumOSVersion</key>
\t<string>6.0</string>
\t<key>NSPrincipalClass</key>
\t<string>UGPreferencesController</string>
</dict>
</plist>
"""

PREFERENCES_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>entry</key>
\t<dict>
\t\t<key>bundle</key>
\t\t<string>UsageGuardPrefs</string>
\t\t<key>cell</key>
\t\t<string>PSLinkCell</string>
\t\t<key>detail</key>
\t\t<string>UGPreferencesController</string>
\t\t<key>isController</key>
\t\t<true/>
\t\t<key>label</key>
\t\t<string>Usage Guard</string>
\t</dict>
</dict>
</plist>
"""


# --------------------------------------------------------------------------- #
# Synthetic Mach-O
# --------------------------------------------------------------------------- #

def macho(cputype=12, cpusubtype=9, filetype=6, min_os=(6, 0, 0),
          install_base="Synthetic", code_signature=True, fat=False, fat_slices=2,
          id_dylib=True):
    """Build a minimal thin Mach-O dylib (or a fat wrapper when fat=True).

    ``filetype`` is passed through untouched and ``id_dylib`` decides whether an
    LC_ID_DYLIB install name is emitted: the tweak is a MH_DYLIB (6) with one,
    the preference bundle a MH_BUNDLE (8) linked ``-bundle`` without one.
    """
    commands = b""
    ncmds = 0
    if id_dylib:
        install_name = "/%s/%s.dylib" % (DYLIB_DIR, install_base)
        name_bytes = install_name.encode("utf-8") + b"\x00"
        name_bytes += b"\x00" * ((4 - len(name_bytes) % 4) % 4)
        commands += struct.pack("<IIIIII", 0x0D, 24 + len(name_bytes), 24, 0, 0x10000, 0x10000) + name_bytes
        ncmds += 1
    version = (min_os[0] << 16) | (min_os[1] << 8) | min_os[2]
    commands += struct.pack("<IIII", 0x25, 16, version, (6 << 16) | (1 << 8) | 3)
    ncmds += 1
    if code_signature:
        commands += struct.pack("<IIII", 0x1D, 16, 0, 16)
        ncmds += 1

    header = struct.pack("<IIIIIII", 0xFEEDFACE, cputype, cpusubtype, filetype,
                         ncmds, len(commands), 0)
    thin = header + commands + b"\x00" * 32
    if not fat:
        return thin

    slices = [(cputype, cpusubtype, thin)]
    if fat_slices > 1:
        slices.append((cputype, 11, thin))  # armv7s companion slice
    return fat_wrap(slices)


def fat_wrap(slices):
    """Wrap (cputype, cpusubtype, payload) slices in a FAT_MAGIC container."""
    header = struct.pack(">II", 0xCAFEBABE, len(slices))
    offset = 8 + 20 * len(slices)
    archs = b""
    body = b""
    for slice_cputype, slice_subtype, payload in slices:
        archs += struct.pack(">IIIII", slice_cputype, slice_subtype,
                             offset + len(body), len(payload), 12)
        body += payload
    return header + archs + body


# --------------------------------------------------------------------------- #
# Synthetic deb
# --------------------------------------------------------------------------- #

def tar_bytes(entries, with_dirs=False):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        if with_dirs:
            # dpkg/GNU tar emit the archive root plus one entry per parent dir.
            directories = {}
            for name, _ in entries:
                parts = name.split("/")[:-1]
                for depth in range(1, len(parts) + 1):
                    directories["./" + "/".join(parts[:depth])] = True
            for name in ["."] + list(directories):
                info = tarfile.TarInfo(name)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.mtime = 0
                archive.addfile(info)
        for name, payload in entries:
            info = tarfile.TarInfo(name)
            if payload is None:
                # A None payload is an explicit directory entry (e.g. an empty
                # Library/PreferenceLoader tree in the probe package).
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.mtime = 0
                archive.addfile(info)
                continue
            info.size = len(payload)
            info.mode = 0o644
            info.mtime = 0
            archive.addfile(info, io.BytesIO(payload))
    return buffer.getvalue()


def ar_bytes(members):
    out = bytearray(b"!<arch>\n")
    for name, payload in members:
        out += ("%-16s%-12s%-6s%-6s%-8s%-10s`\n" % (name, "0", "0", "0", "100644", len(payload))).encode()
        out += payload
        if len(payload) % 2:
            out += b"\n"
    return bytes(out)


def make_deb_dmpl(path, data_entries, control_text):
    """Mirror Theos/dm.pl default: control.tar.gz + data.tar.lzma."""
    control_tar = gzip.compress(tar_bytes([("./control", control_text.encode())]))
    data_tar = lzma.compress(tar_bytes(data_entries), format=lzma.FORMAT_ALONE)
    blob = ar_bytes([
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", control_tar),
        ("data.tar.lzma", data_tar),
    ])
    with open(path, "wb") as handle:
        handle.write(blob)
    return path


def make_deb(path, data_entries, control_text, compression="gz", with_dirs=False):
    control_tar = tar_bytes([("./control", control_text.encode())])
    data_tar = tar_bytes(data_entries, with_dirs=with_dirs)
    if compression == "gz":
        control_tar, data_tar = gzip.compress(control_tar), gzip.compress(data_tar)
        suffix = ".gz"
    elif compression == "lzma":
        control_tar = lzma.compress(control_tar, format=lzma.FORMAT_ALONE)
        data_tar = lzma.compress(data_tar, format=lzma.FORMAT_ALONE)
        suffix = ".lzma"
    elif compression == "xz":
        control_tar, data_tar = lzma.compress(control_tar), lzma.compress(data_tar)
        suffix = ".xz"
    else:
        raise ValueError(compression)

    blob = ar_bytes([
        ("debian-binary", b"2.0\n"),
        ("control.tar" + suffix, control_tar),
        ("data.tar" + suffix, data_tar),
    ])
    with open(path, "wb") as handle:
        handle.write(blob)
    return path


GOOD_CONTROL = CONTROL_TEMPLATE.format(
    package="org.usageguard.synthetic",
    architecture="iphoneos-arm",
    depends="mobilesubstrate, firmware (>= 6.0)",
)

GOOD_ENTRIES = [
    ("%s/Synthetic.dylib" % DYLIB_DIR, macho()),
    ("%s/Synthetic.plist" % DYLIB_DIR, FILTER_PLIST.encode()),
]

# The probe package: two-file payload (only dependency: mobilesubstrate).
PROBE_CONTROL = CONTROL_TEMPLATE.format(
    package="org.usageguard.probe",
    architecture="iphoneos-arm",
    depends="mobilesubstrate, firmware (>= 6.0)",
)

# The main package: same tweak plus the Settings preference bundle.
MAIN_CONTROL = CONTROL_TEMPLATE.format(
    package="org.usageguard.timer",
    architecture="iphoneos-arm",
    depends="mobilesubstrate, preferenceloader, firmware (>= 6.0)",
)

MAIN_ENTRIES = [
    ("%s/%s.dylib" % (DYLIB_DIR, MAIN_DYLIB), macho(install_base=MAIN_DYLIB)),
    ("%s/%s.plist" % (DYLIB_DIR, MAIN_DYLIB), FILTER_PLIST.encode()),
    ("%s/%s" % (BUNDLE_DIR, PREFERENCE_BUNDLE), macho(filetype=8, id_dylib=False)),
    ("%s/Info.plist" % BUNDLE_DIR, INFO_PLIST.encode()),
    ("%s/%s.plist" % (PREFERENCES_DIR, MAIN_DYLIB), PREFERENCES_PLIST.encode()),
]

BUNDLE_BINARY_KEY = "%s/%s" % (BUNDLE_DIR, PREFERENCE_BUNDLE)
INFO_PLIST_KEY = "%s/Info.plist" % BUNDLE_DIR
PREFS_PLIST_KEY = "%s/%s.plist" % (PREFERENCES_DIR, MAIN_DYLIB)


def with_entry(entries, path, payload):
    """Return entries with the payload of ``path`` replaced."""
    return [(name, payload if name == path else data) for name, data in entries]


# --------------------------------------------------------------------------- #
# Cases
# --------------------------------------------------------------------------- #

def cases(tmpdir):
    """Return [(name, deb_path, expect_exit, expected_substring, extra_argv)]."""
    def deb(name, entries, control=GOOD_CONTROL, compression="gz", with_dirs=False):
        return make_deb(os.path.join(tmpdir, name + ".deb"), entries, control, compression, with_dirs)

    good = deb("good-gzip", GOOD_ENTRIES)
    good_lzma = deb("good-lzma", GOOD_ENTRIES, compression="lzma")
    good_xz = deb("good-xz", GOOD_ENTRIES, compression="xz")
    # dpkg-deb/GNU tar emit explicit directory entries, including "./".
    good_dirs = deb("good-dpkg-dir-entries", GOOD_ENTRIES, with_dirs=True)
    # cctools lipo -create keeps a fat container even for one -arch.
    good_fat1 = deb("good-single-slice-fat", [(GOOD_ENTRIES[0][0], macho(fat=True, fat_slices=1)),
                                              GOOD_ENTRIES[1]])
    good_dmpl = make_deb_dmpl(os.path.join(tmpdir, "good-dmpl-default.deb"), GOOD_ENTRIES, GOOD_CONTROL)

    # Probe layout: identified by package id, two files.
    good_probe = deb("good-probe-layout", GOOD_ENTRIES, control=PROBE_CONTROL)

    # Main layout: the five-file payload including the preference bundle.
    good_main = deb("good-main-layout", MAIN_ENTRIES, control=MAIN_CONTROL, with_dirs=True)
    main_extra_bundle_file = deb("bad-main-extra-bundle-file",
                                 MAIN_ENTRIES + [("%s/Extra.strings" % BUNDLE_DIR, b"/* x */\n")],
                                 control=MAIN_CONTROL)
    main_probe_payload = deb("bad-main-two-file-payload", GOOD_ENTRIES, control=MAIN_CONTROL)
    main_bundle_arm64 = deb("bad-main-bundle-arm64",
                            with_entry(MAIN_ENTRIES, BUNDLE_BINARY_KEY,
                                       macho(cputype=22, cpusubtype=2, filetype=8, id_dylib=False)),
                            control=MAIN_CONTROL)
    main_bundle_unsigned = deb("bad-main-bundle-unsigned",
                               with_entry(MAIN_ENTRIES, BUNDLE_BINARY_KEY,
                                          macho(filetype=8, id_dylib=False, code_signature=False)),
                               control=MAIN_CONTROL)
    # Theos' bundle.mk default: -dynamiclib yields a MH_DYLIB with a stray
    # LC_ID_DYLIB. prefs/Makefile opts out with _DYNAMIC_LIBRARY = NO, so the
    # dylib-shaped executable must be rejected.
    main_bundle_dylib = deb("bad-main-bundle-dylib",
                            with_entry(MAIN_ENTRIES, BUNDLE_BINARY_KEY,
                                       macho(filetype=6, install_base=PREFERENCE_BUNDLE)),
                            control=MAIN_CONTROL)
    # A MH_BUNDLE that still carries an LC_ID_DYLIB was linked -dynamiclib
    # under another name; the install name betrays it.
    main_bundle_id_dylib = deb("bad-main-bundle-id-dylib",
                               with_entry(MAIN_ENTRIES, BUNDLE_BINARY_KEY,
                                          macho(filetype=8, install_base=PREFERENCE_BUNDLE)),
                               control=MAIN_CONTROL)
    main_bundle_exec = deb("bad-main-bundle-exec",
                           with_entry(MAIN_ENTRIES, BUNDLE_BINARY_KEY,
                                      macho(filetype=2, id_dylib=False)),
                           control=MAIN_CONTROL)
    main_bad_prefs_plist = deb("bad-main-prefs-plist",
                               with_entry(MAIN_ENTRIES, PREFS_PLIST_KEY,
                                          PREFERENCES_PLIST.replace(PREFERENCE_BUNDLE, "OtherPrefs").encode()),
                               control=MAIN_CONTROL)
    main_no_iscontroller = deb("bad-main-no-iscontroller",
                               with_entry(MAIN_ENTRIES, PREFS_PLIST_KEY,
                                          PREFERENCES_PLIST.replace(
                                              "\t\t<key>isController</key>\n\t\t<true/>\n", "").encode()),
                               control=MAIN_CONTROL)
    main_no_principal = deb("bad-main-no-principal-class",
                            with_entry(MAIN_ENTRIES, INFO_PLIST_KEY,
                                       INFO_PLIST.replace(
                                           "\t<key>NSPrincipalClass</key>\n"
                                           "\t<string>UGPreferencesController</string>\n", "").encode()),
                            control=MAIN_CONTROL)
    main_bad_executable = deb("bad-main-executable-mismatch",
                              with_entry(MAIN_ENTRIES, INFO_PLIST_KEY,
                                         INFO_PLIST.replace("<string>%s</string>" % PREFERENCE_BUNDLE,
                                                            "<string>UsageGuard</string>", 1).encode()),
                              control=MAIN_CONTROL)
    main_bundle_minos = deb("bad-main-bundle-min-ios",
                            with_entry(MAIN_ENTRIES, BUNDLE_BINARY_KEY,
                                       macho(filetype=8, id_dylib=False, min_os=(7, 0, 0))),
                            control=MAIN_CONTROL)
    main_no_preferenceloader = deb("bad-main-no-preferenceloader", MAIN_ENTRIES,
                                   control=MAIN_CONTROL.replace("preferenceloader, ", ""))
    # PreferenceLoader/PreferenceBundles packaging belongs to org.usageguard.timer;
    # an empty directory tree must not slip into the two-file probe.
    probe_pref_dirs = deb("bad-probe-preference-dirs",
                          GOOD_ENTRIES + [("Library/PreferenceLoader/Preferences/", None)],
                          control=PROBE_CONTROL)

    wrong_arch = deb("bad-arch-arm64", [(GOOD_ENTRIES[0][0], macho(cputype=22, cpusubtype=2)),
                                        GOOD_ENTRIES[1]])
    armv7s = deb("bad-arch-armv7s", [(GOOD_ENTRIES[0][0], macho(cpusubtype=11)), GOOD_ENTRIES[1]])
    fat = deb("bad-arch-fat", [(GOOD_ENTRIES[0][0], macho(fat=True)), GOOD_ENTRIES[1]])
    not_dylib = deb("bad-filetype-exec", [(GOOD_ENTRIES[0][0], macho(filetype=2)), GOOD_ENTRIES[1]])
    no_minos = deb("bad-no-version-min", [(GOOD_ENTRIES[0][0], macho(min_os=(7, 0, 0))), GOOD_ENTRIES[1]])
    unsigned = deb("bad-unsigned", [(GOOD_ENTRIES[0][0], macho(code_signature=False)), GOOD_ENTRIES[1]])
    wrong_name = deb("bad-install-name", [(GOOD_ENTRIES[0][0], macho(install_base="Other")), GOOD_ENTRIES[1]])

    bad_architecture = deb("bad-control-arch", GOOD_ENTRIES,
                           control=GOOD_CONTROL.replace("iphoneos-arm", "i386"))
    no_depends = deb("bad-control-depends", GOOD_ENTRIES,
                     control=GOOD_CONTROL.replace("mobilesubstrate, ", ""))
    no_version = deb("bad-control-version", GOOD_ENTRIES,
                     control=GOOD_CONTROL.replace("Version: 0.0.1\n", ""))

    bad_dir = deb("bad-payload-dir", [("usr/lib/Synthetic.dylib", macho()),
                                       GOOD_ENTRIES[1]])
    extra_file = deb("bad-payload-extra", GOOD_ENTRIES + [("usr/share/note.txt", b"hi\n")])
    home_path = deb("bad-path-home", [("home/mobile/lib.dylib", macho()), GOOD_ENTRIES[1]])
    traversal = deb("bad-path-traversal",
                    [("%s/../../usr/lib/X.dylib" % DYLIB_DIR, macho()), GOOD_ENTRIES[1]])
    bad_filter = deb("bad-filter", [GOOD_ENTRIES[0], (GOOD_ENTRIES[1][0],
                                                      FILTER_PLIST.replace("com.apple.springboard",
                                                                           "com.apple.mobilesafari").encode())])

    garbage = os.path.join(tmpdir, "bad-garbage.deb")
    with open(garbage, "wb") as handle:
        handle.write(b"not a deb at all\n")

    no_debian = os.path.join(tmpdir, "bad-no-debian-binary.deb")
    with open(no_debian, "wb") as handle:
        handle.write(ar_bytes([
            ("control.tar.gz", gzip.compress(tar_bytes([("./control", GOOD_CONTROL.encode())]))),
            ("data.tar.gz", gzip.compress(tar_bytes(GOOD_ENTRIES))),
        ]))

    zstd = os.path.join(tmpdir, "bad-zstd.deb")
    with open(zstd, "wb") as handle:
        handle.write(ar_bytes([
            ("debian-binary", b"2.0\n"),
            ("control.tar.zst", b"\x28\xb5\x2f\xfd" + b"\x00" * 16),
            ("data.tar.zst", b"\x28\xb5\x2f\xfd" + b"\x00" * 16),
        ]))

    return [
        ("valid package (gzip)", good, 0, "PASS", []),
        ("valid package (lzma)", good_lzma, 0, "PASS", []),
        ("valid package (xz)", good_xz, 0, "PASS", []),
        ("valid package (dpkg-style dir entries)", good_dirs, 0, "PASS", []),
        ("valid package (single-slice fat armv7)", good_fat1, 0, "single-slice fat", []),
        ("valid package (dm.pl control.gz + data.lzma)", good_dmpl, 0, "PASS", []),
        ("main layout with the full five-file payload accepted", good_main, 0, "5 files", []),
        ("probe layout accepted for the probe package", good_probe, 0,
         "MobileSubstrate dylib + filter plist", []),
        ("probe layout accepted with --expect-package probe", good_probe, 0,
         "MobileSubstrate dylib + filter plist", ["--expect-package", "org.usageguard.probe"]),
        ("extra file inside the preference bundle rejected", main_extra_bundle_file, 1,
         "unexpected: %s/Extra.strings" % BUNDLE_DIR, []),
        ("main package with a two-file payload rejected", main_probe_payload, 1,
         "unexpected: %s/Synthetic.dylib" % DYLIB_DIR, []),
        ("bundle executable as MH_DYLIB rejected", main_bundle_dylib, 1,
         "filetype is 6 (MH_DYLIB), expected 8 (MH_BUNDLE)", []),
        ("bundle binary carrying LC_ID_DYLIB rejected", main_bundle_id_dylib, 1,
         "bundle has no LC_ID_DYLIB", []),
        ("arm64 bundle binary rejected", main_bundle_arm64, 1,
         "bundle binary is armv7 MH_BUNDLE", []),
        ("MH_EXECUTE bundle binary rejected", main_bundle_exec, 1,
         "filetype is 2 (MH_EXECUTE), expected 8 (MH_BUNDLE)", []),
        ("unsigned bundle binary rejected", main_bundle_unsigned, 1,
         "bundle LC_CODE_SIGNATURE", []),
        ("PreferenceLoader plist naming the wrong bundle rejected", main_bad_prefs_plist, 1,
         "PreferenceLoader entry is a controller", []),
        ("PreferenceLoader entry without isController rejected", main_no_iscontroller, 1,
         "entry.isController is None, expected boolean true", []),
        ("bundle Info.plist without NSPrincipalClass rejected", main_no_principal, 1,
         "NSPrincipalClass is None", []),
        ("bundle CFBundleExecutable mismatch rejected", main_bad_executable, 1,
         "CFBundleExecutable is 'UsageGuard'", []),
        ("bundle deployment target 7.0 rejected", main_bundle_minos, 1,
         "bundle LC_VERSION_MIN_IPHONEOS 6.0.0", []),
        ("probe package with PreferenceLoader directories rejected", probe_pref_dirs, 1,
         "only allowed in package org.usageguard.timer", []),
        ("main package missing preferenceloader rejected", main_no_preferenceloader, 1,
         "control: Depends preferenceloader", []),
        ("arm64 slice rejected", wrong_arch, 1, "CPU_TYPE_ARM", []),
        ("armv7s subtype rejected", armv7s, 1, "CPU_SUBTYPE_ARM_V7", []),
        ("fat binary rejected", fat, 1, "universal (fat) Mach-O", []),
        ("MH_EXECUTE rejected", not_dylib, 1, "MH_DYLIB", []),
        ("deployment target 7.0 rejected", no_minos, 1, "expected 6.0.0", []),
        ("unsigned binary rejected", unsigned, 1, "LC_CODE_SIGNATURE", []),
        ("wrong install name rejected", wrong_name, 1, "LC_ID_DYLIB install name", []),
        ("Architecture i386 rejected", bad_architecture, 1, "Architecture", []),
        ("missing mobilesubstrate rejected", no_depends, 1, "mobilesubstrate", []),
        ("missing Version rejected", no_version, 1, "control: Version", []),
        ("payload outside DynamicLibraries rejected", bad_dir, 1, "MobileSubstrate dylib + filter plist", []),
        ("extra payload file rejected", extra_file, 1, "MobileSubstrate dylib + filter plist", []),
        ("home/ path rejected", home_path, 1, "forbidden prefix", []),
        ("path traversal rejected", traversal, 1, "traversal", []),
        ("filter for wrong bundle rejected", bad_filter, 1, "com.apple.springboard", []),
        ("--expect-package mismatch rejected", good, 1, "Package matches expectation",
         ["--expect-package", "org.usageguard.probe"]),
        ("--forbid-package hit rejected", good, 1, "Package not forbidden",
         ["--forbid-package", "org.usageguard.*"]),
        ("garbage file rejected", garbage, 1, "not an ar archive", []),
        ("missing debian-binary rejected", no_debian, 1, "debian-binary", []),
        ("zstd archive rejected with clear message", zstd, 1, "zstd", []),
    ]


def main():
    if not os.path.isfile(VALIDATOR):
        print("error: validator not found at %s" % VALIDATOR, file=sys.stderr)
        return 2

    failures = 0
    with tempfile.TemporaryDirectory(prefix="validate-deb-selftest-") as tmpdir:
        for name, deb_path, expect_exit, needle, extra in cases(tmpdir):
            proc = subprocess.run([sys.executable, VALIDATOR, deb_path] + extra,
                                  capture_output=True, text=True)
            output = proc.stdout + proc.stderr
            status_ok = proc.returncode == expect_exit
            needle_ok = needle in output
            if status_ok and needle_ok:
                print("PASS  %-45s exit=%d" % (name, proc.returncode))
            else:
                failures += 1
                print("FAIL  %-45s exit=%d (want %d), needle %r %s"
                      % (name, proc.returncode, expect_exit, needle,
                         "found" if needle_ok else "MISSING"))
                if not needle_ok:
                    print("      --- validator output ---")
                    for line in output.splitlines():
                        print("      " + line)

    if failures:
        print("\nSELFTEST FAILED: %d case(s)" % failures, file=sys.stderr)
        return 1

    print("\nSELFTEST PASS: validator accepts valid packages and rejects every malformed variant")
    return 0


if __name__ == "__main__":
    sys.exit(main())
