#!/usr/bin/env python3
"""Inject AntiCensor.dylib into a decrypted Spotify IPA (arm64) for on-device signing.

Needed for SideStore / AltStore / ESign: unlike Sideloadly they do not inject
dylibs themselves, so the tweak must already live inside the app bundle.

Usage:
    python tools/patch_ipa.py "C:\\path\\Spotify-Decrypted.ipa" \
        -o "C:\\path\\Spotify-AntiCensor.ipa" \
        [--dylib build_output/AntiCensor.dylib]

What it does:
    1. reads Payload/Spotify.app/Spotify (Mach-O 64-bit)
    2. adds LC_LOAD_DYLIB @executable_path/Frameworks/AntiCensor.dylib into the
       header padding (no data shifting, no overlap with the first section)
    3. puts the dylib into Payload/Spotify.app/Frameworks/AntiCensor.dylib
    4. rebuilds the IPA preserving POSIX permissions (exec bit matters)

The code signature becomes invalid on purpose: the signer (SideStore / Sideloadly)
re-signs the whole bundle, including the injected dylib.
"""
import argparse
import os
import struct
import sys
import time
import zipfile

LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19
MH_MAGIC_64 = 0xFEEDFACF
EXE_NAME = "Payload/Spotify.app/Spotify"
FRAMEWORKS_DIR = "Payload/Spotify.app/Frameworks/"
DYLIB_NAME = "AntiCensor.dylib"
DYLIB_PATH = FRAMEWORKS_DIR + DYLIB_NAME
LOAD_PATH = "@executable_path/Frameworks/" + DYLIB_NAME


def align8(n):
    return (n + 7) & ~7


def inject_load_command(exe):
    exe = bytearray(exe)
    magic, _cputype, _cpusub, _filetype, ncmds, sizeofcmds, _flags, _res = struct.unpack_from("<IIIIIIII", exe, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"not a Mach-O 64-bit executable: magic={hex(magic)}")

    off = 32
    first_section_off = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", exe, off)
        if cmdsize < 8 or cmdsize % 8 != 0:
            raise SystemExit(f"corrupted load command at 0x{off:x} (cmdsize={cmdsize})")
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", exe, off + 64)[0]
            sect = off + 72
            for _i in range(nsects):
                size = struct.unpack_from("<Q", exe, sect + 40)[0]
                soff = struct.unpack_from("<I", exe, sect + 48)[0]
                if size > 0 and soff > 0 and (first_section_off is None or soff < first_section_off):
                    first_section_off = soff
                sect += 80
        off += cmdsize

    cmd_end = 32 + sizeofcmds
    need = align8(24 + len(LOAD_PATH) + 1)
    first_section_off = first_section_off or 0x4000
    padding = first_section_off - cmd_end
    if padding < need:
        raise SystemExit(f"not enough header padding: {padding} < {need} bytes")

    payload = struct.pack("<IIIIII", LC_LOAD_DYLIB, need, 24, 0, 0, 0x10000)
    payload += LOAD_PATH.encode() + b"\0"
    payload = payload.ljust(need, b"\0")
    exe[cmd_end:cmd_end + need] = payload
    struct.pack_into("<II", exe, 16, ncmds + 1, sizeofcmds + need)
    print(f"  injected LC_LOAD_DYLIB -> {LOAD_PATH} ({need} bytes, pad left {padding - need})")
    return exe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa", help="source decrypted Spotify IPA")
    ap.add_argument("-o", "--out", required=True, help="output IPA")
    ap.add_argument("--dylib", default=os.path.join("build_output", "AntiCensor.dylib"),
                    help="dylib to inject (default: build_output/AntiCensor.dylib)")
    ap.add_argument("--executable", default=EXE_NAME, help="main executable path inside the IPA")
    args = ap.parse_args()

    if not os.path.isfile(args.ipa):
        raise SystemExit(f"IPA not found: {args.ipa}")
    if not os.path.isfile(args.dylib):
        raise SystemExit(f"dylib not found: {args.dylib}")

    t0 = time.time()
    with open(args.dylib, "rb") as f:
        dylib_bytes = f.read()
    if dylib_bytes[:4] not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
        raise SystemExit("dylib is not a little-endian Mach-O binary")
    print(f"dylib: {os.path.basename(args.dylib)} ({len(dylib_bytes)} bytes)")
    print(f"source: {args.ipa}")

    with zipfile.ZipFile(args.ipa) as zin:
        names = set(zin.namelist())
        if args.executable not in names:
            raise SystemExit(f"main executable not found in IPA: {args.executable}")
        if any(n.endswith("/" + DYLIB_NAME) for n in names):
            raise SystemExit("IPA already contains AntiCensor.dylib")
        print("reading executable ...")
        exe = inject_load_command(zin.read(args.executable))

        print("rebuilding IPA ...")
        tmp_out = args.out + ".part"
        with zipfile.ZipFile(tmp_out, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as zout:
            for info in zin.infolist():
                data = bytes(exe) if info.filename == args.executable else zin.read(info.filename)
                zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.create_system = 3
                mode = (info.external_attr >> 16) & 0xFFFF or (0o755 if info.is_dir() else 0o644)
                if info.filename == args.executable:
                    mode = 0o755
                zi.external_attr = (mode << 16) | (0x10 if info.is_dir() else 0)
                zout.writestr(zi, data)

            zi = zipfile.ZipInfo(DYLIB_PATH, date_time=time.localtime()[:6])
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.create_system = 3
            zi.external_attr = 0o755 << 16
            zout.writestr(zi, dylib_bytes)

    os.replace(tmp_out, args.out)
    print(f"done in {time.time() - t0:.1f}s -> {args.out} ({os.path.getsize(args.out) / 1e6:.1f} MB)")
    print("now install it through SideStore (it will sign the bundle on device)")


if __name__ == "__main__":
    sys.exit(main())
