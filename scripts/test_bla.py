#!/usr/bin/env python3
"""Run Arkari BLA regressions using only the installed toolchain and stdlib."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time


UPSTREAM = "dd9e72f53ad97e3eb228523ad25295029107bb63"
SEED = "ArkariSmokeSeed0123456789abcdef0"
FEATURES = ("mba", "opaque", "decoy", "meta")
LEGACY_FEATURES = ("indbr", "icall", "indgv", "cse", "fla", "cie", "cfe", "rtti")
TRIPLES = {
    "x64": "x86_64-pc-windows-msvc",
    "x86": "i686-pc-windows-msvc",
    "arm64": "aarch64-pc-windows-msvc",
}
MACHINES = {"x64": 0x8664, "x86": 0x14C, "arm64": 0xAA64}
INPUTS = ("0", "1", "2", "7", "19", "44", "97", "256")
DECOY = re.compile(r'^define\b[^\n]*@"?(__arkari_bla_decoy_[^"(\s]+)', re.M)
MBA = re.compile(r"^\s*%[^\n]*=[^\n]*!arkari\.bla\.mba\s+!", re.M)
OPAQUE = re.compile(r"^\s*br i1\b[^\n]*!arkari\.bla\.opaque\s+!", re.M)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


class COFF:
    def __init__(self, path: Path):
        data = path.read_bytes()
        self.machine, sections = struct.unpack_from("<HH", data)
        symbols_at, symbol_count = struct.unpack_from("<II", data, 8)
        optional_size = struct.unpack_from("<H", data, 16)[0]
        require(self.machine in MACHINES.values(), f"Not a supported COFF object: {path}")
        characteristics = [struct.unpack_from("<I", data, 20 + optional_size + i * 40 + 36)[0]
                           for i in range(sections)]
        strings = symbols_at + symbol_count * 18
        self.decoys = set()
        self.metadata = set()
        self.anchors = set()
        index = 0
        while index < symbol_count:
            offset = symbols_at + index * 18
            first, second = struct.unpack_from("<II", data, offset)
            if first == 0:
                start = strings + second
                name = data[start:data.index(b"\0", start)].decode("ascii", errors="replace")
            else:
                name = data[offset:offset + 8].rstrip(b"\0").decode("ascii", errors="replace")
            section = struct.unpack_from("<h", data, offset + 12)[0]
            if section > 0:
                if "__arkari_bla_decoy_" in name:
                    self.decoys.add(name)
                if "__arkari_bla_meta_" in name:
                    self.metadata.add(name)
                if "__arkari_bla_anchor_" in name:
                    require(not characteristics[section - 1] & 0x1000,
                            "BLA anchor was emitted as discardable COMDAT data")
                    self.anchors.add(name)
            index += 1 + data[offset + 17]


class PE:
    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        require(self.data[:2] == b"MZ", f"Not a PE: {path}")
        self.pe = struct.unpack_from("<I", self.data, 0x3C)[0]
        require(self.data[self.pe:self.pe + 4] == b"PE\0\0", f"Invalid PE header: {path}")
        self.machine, count = struct.unpack_from("<HH", self.data, self.pe + 4)
        optional_size = struct.unpack_from("<H", self.data, self.pe + 20)[0]
        optional = self.pe + 24
        magic = struct.unpack_from("<H", self.data, optional)[0]
        require(magic in (0x10B, 0x20B), f"Invalid optional header: {path}")
        directory = optional + (112 if magic == 0x20B else 96)
        self.directories = [struct.unpack_from("<II", self.data, directory + i * 8) for i in range(16)]
        self.dll_characteristics = struct.unpack_from("<H", self.data, optional + 70)[0]
        self.sections = []
        table = optional + optional_size
        for i in range(count):
            offset = table + i * 40
            name = self.data[offset:offset + 8].rstrip(b"\0").decode("ascii")
            virtual_size, rva, raw_size, raw = struct.unpack_from("<IIII", self.data, offset + 8)
            flags = struct.unpack_from("<I", self.data, offset + 36)[0]
            require(raw + raw_size <= len(self.data), f"Truncated section {name}: {path}")
            self.sections.append({"name": name, "rva": rva, "size": max(virtual_size, raw_size),
                                  "virtual_size": virtual_size, "raw": raw, "raw_size": raw_size, "flags": flags})

    def containing(self, rva: int, size: int = 1) -> dict:
        for section in self.sections:
            if section["rva"] <= rva and rva + max(1, size) <= section["rva"] + section["size"]:
                return section
        raise RuntimeError(f"RVA {rva:#x}+{size:#x} is outside image sections: {self.path}")

    def offset(self, rva: int) -> int:
        section = self.containing(rva)
        relative = rva - section["rva"]
        require(relative < section["raw_size"], f"RVA has no file-backed data: {rva:#x}")
        return section["raw"] + relative

    def exports(self) -> list[str]:
        rva, _ = self.directories[0]
        if not rva:
            return []
        offset = self.offset(rva)
        count = struct.unpack_from("<I", self.data, offset + 24)[0]
        names_rva = struct.unpack_from("<I", self.data, offset + 32)[0]
        names = []
        for i in range(count):
            name_rva = struct.unpack_from("<I", self.data, self.offset(names_rva) + i * 4)[0]
            start = self.offset(name_rva)
            end = self.data.index(b"\0", start)
            names.append(self.data[start:end].decode("ascii"))
        return sorted(names)

    def debug_identity(self, pdb_path: Path, expected_path: str) -> dict:
        rva, size = self.directories[6]
        require(rva != 0 and size % 28 == 0, "Missing or malformed real PE debug directory")
        records = []
        for index in range(size // 28):
            offset = self.offset(rva + index * 28)
            kind, length, address, pointer = struct.unpack_from("<4I", self.data, offset + 12)
            if kind != 2:
                continue
            require(self.offset(address) == pointer and length >= 25, "Real CodeView data has an invalid address")
            record = self.data[pointer:pointer + length]
            require(record[:4] == b"RSDS" and record[-1:] == b"\0", "Real CodeView data was replaced by decoy bytes")
            require(record[24:-1].decode("utf-8") == expected_path, "The real PDB path was changed")
            records.append((record[4:20], struct.unpack_from("<I", record, 20)[0]))
        require(len(records) == 1, "Expected exactly one real CodeView identity")

        # MSF 7 stream 1 is the PDB information stream. Match its actual GUID
        # and age to the PE, rather than accepting any RSDS-looking byte string.
        data = pdb_path.read_bytes()
        require(data[:32] == b"Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0", "Missing real MSF 7 PDB")
        block_size, _, blocks, directory_size, _, block_map = struct.unpack_from("<6I", data, 32)
        require(block_size >= 512 and block_size & (block_size - 1) == 0 and
                blocks * block_size <= len(data), "Invalid PDB block geometry")

        def block(number: int) -> bytes:
            require(number < blocks, "PDB references an invalid block")
            return data[number * block_size:(number + 1) * block_size]

        directory_blocks = (directory_size + block_size - 1) // block_size
        require(directory_blocks * 4 <= block_size, "Test PDB directory exceeds one block map")
        indices = struct.unpack_from("<" + "I" * directory_blocks, block(block_map))
        directory = b"".join(block(index) for index in indices)[:directory_size]
        streams = struct.unpack_from("<I", directory)[0]
        require(streams >= 2 and (streams + 1) * 4 <= len(directory), "PDB is missing its information stream")
        sizes = struct.unpack_from("<" + "I" * streams, directory, 4)
        cursor = 4 + streams * 4
        info = b""
        for index, length in enumerate(sizes):
            count = 0 if length == 0xFFFFFFFF else (length + block_size - 1) // block_size
            indices = struct.unpack_from("<" + "I" * count, directory, cursor)
            cursor += count * 4
            if index == 1:
                info = b"".join(block(number) for number in indices)[:length]
                break
        require(len(info) >= 28, "Truncated PDB information stream")
        identity = (info[12:28], struct.unpack_from("<I", info, 8)[0])
        require(identity == records[0], "PE CodeView identity does not match the real PDB")
        return {"guid_bytes": identity[0].hex(), "age": identity[1], "path": expected_path}

    def manifest(self, expected: int | None, arch: str, *, decoys: int | None = None,
                 metadata: bool | int | None = None) -> bytes | None:
        sections = [s for s in self.sections if s["name"] == ".enclave"]
        if expected is None:
            require(not sections, f"Disabled PE protection emitted .enclave: {self.path}")
            return None
        require(len(sections) == 1, f"Expected one .enclave section: {self.path}")
        section = sections[0]
        require(section["flags"] == 0x40000040, f".enclave is not read-only initialized data: {self.path}")
        require(self.dll_characteristics & 0x140 == 0x140, "PE protection disabled ASLR or NX compatibility")
        data = self.data[section["raw"]:section["raw"] + section["raw_size"]]
        require(data[:8] == b"ARKBLA01", f"Invalid BLA manifest magic: {self.path}")
        version, header, record_size, records, object_size, objects, level, machine = struct.unpack_from("<8I", data, 8)
        require((version, header, record_size, object_size) == (1, 80, 128, 32), "Invalid BLA manifest layout")
        require(level == expected and records == 2 * (expected + 1), "Incorrect BLA PE strength/record count")
        require(machine == MACHINES[arch], f"BLA manifest target mismatch: {machine:#x}")
        record_offset, object_offset = struct.unpack_from("<II", data, 72)
        require(record_offset == 80 and object_offset == 80 + records * 128, "Invalid BLA manifest offsets")
        end = object_offset + objects * 32
        require(end <= section["virtual_size"] and end <= len(data), "Truncated BLA manifest")
        kinds = {1: 0, 2: 0, 3: 0}
        entries = []
        for i in range(objects):
            kind, rva, size = struct.unpack_from("<III", data, object_offset + i * 32)
            require(kind in kinds, f"Unknown BLA object kind {kind}")
            target = self.containing(rva, size)
            require(not (target["flags"] & 0x80000000), "BLA object points to writable storage")
            if kind == 1:
                require(target["flags"] & 0x20000000, "BLA decoy does not point to executable code")
            if kind == 2:
                start = self.offset(rva)
                require(self.data[start:start + 19] == b"ARKARI-BLA-META-v1\0", "BLA metadata index points to the wrong payload")
            kinds[kind] += 1
            entries.append((rva, size))
        for i in range(records):
            offset = record_offset + i * 128
            _, ordinal, index, rva, size, reserved = struct.unpack_from("<6I", data, offset)
            require(ordinal == i and reserved == 0, "Invalid BLA record ordinal/reserved field")
            require(b"\0" in data[offset + 24:offset + 128], "BLA record text is not NUL-terminated")
            if index == 0xFFFFFFFF:
                require(rva == 0 and size == 0 and objects == 0, "Invalid unbound BLA record")
            else:
                require(index < objects and entries[index] == (rva, size), "BLA record points outside object index")
        if decoys is not None:
            require(kinds[1] == decoys, f"Decoy graph did not survive GC/ICF: expected {decoys}, got {kinds[1]}")
        if isinstance(metadata, bool):
            require((kinds[2] > 0) == metadata, "Metadata did not survive GC/ICF")
        elif metadata is not None:
            require(kinds[2] == metadata, f"Metadata ownership was duplicated or lost: expected {metadata}, got {kinds[2]}")
        if objects:
            require(all(self.directories[5]), "Address-bearing BLA anchors lost PE base relocations")
        for candidate in self.sections:
            require((candidate["flags"] & 0xA0000000) != 0xA0000000, "Image contains a writable executable section")
        for index in (0, 1, 3, 5, 6, 9, 10):
            rva, size = self.directories[index]
            if rva and size:
                self.containing(rva, size)
        self.bla_summary = {"level": level, "records": records, "objects": objects,
                            "object_kinds": kinds, "machine": machine, "seed_sha256": data[40:72].hex()}
        return data[:end]


class Suite:
    def __init__(self, args: argparse.Namespace):
        self.install = Path(args.install).resolve()
        self.fixtures = Path(args.fixtures).resolve()
        self.output = Path(args.output).resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.build_type = args.build_type
        self.runtime_flag = "/MTd" if args.build_type == "Debug" else "/MT"
        self.bin = self.install / "bin"
        self.tools = {name: self.bin / (name + ".exe") for name in
                      ("clang", "clang-cl", "lld-link", "llvm-readobj", "llvm-objdump")}
        for tool in self.tools.values():
            require(tool.is_file(), f"Missing installed test tool: {tool}")
        # Windows environment lookup is case-insensitive; a plain dict is not.
        self.env = {key.upper(): value for key, value in os.environ.items()}
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        self.report = {"status": "running", "upstream_commit": UPSTREAM, "build_type": args.build_type,
                       "runtime_architectures": ["x64", "x86"], "structural_architectures": ["arm64"], "checks": []}
        metadata = json.loads((self.install / "build-info.json").read_text(encoding="utf-8-sig"))
        self.report["arkari_commit"] = metadata["arkari_commit"]
        self.report["toolchain_thin_lto"] = metadata["thin_lto"]
        for arch in TRIPLES:
            directory = self.output / arch
            directory.mkdir(exist_ok=True)
            for source in self.fixtures.iterdir():
                if source.is_file():
                    shutil.copyfile(source, directory / source.name)
            # Annotation opt-ins have a separate test; the default-off fixture has none.
            plain = (directory / "bla-structure.c").read_text(encoding="utf-8")
            plain = re.sub(r'__attribute__\(\(annotate\("[^"\n]*"\)\)\)', "", plain)
            (directory / "bla-plain.c").write_text(plain, encoding="utf-8")

    def environment(self, arch: str) -> dict:
        env = self.env.copy()
        if arch == "x86":
            vc = Path(env.get("VCTOOLSINSTALLDIR", ""))
            sdk = Path(env.get("WINDOWSSDKDIR", ""))
            version = env.get("WINDOWSSDKVERSION", "").rstrip("\\/")
            libs = [vc / "lib/x86", sdk / "Lib" / version / "ucrt/x86", sdk / "Lib" / version / "um/x86"]
            require(all(path.is_dir() for path in libs), "VS x86 CRT/SDK libraries are missing")
            env["LIB"] = ";".join(map(str, libs))
        return env

    def command(self, name: str, args: list, arch: str = "x64", *, timeout: int = 300,
                success: bool | None = True) -> subprocess.CompletedProcess:
        directory = self.output / arch
        command = list(map(str, args))
        try:
            result = subprocess.run(command, cwd=directory, env=self.environment(arch), capture_output=True,
                                    text=True, encoding="utf-8", errors="replace", timeout=timeout)
        except subprocess.TimeoutExpired as error:
            def text(value):
                return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""
            log = (subprocess.list2cmdline(command) + f"\n\nTIMEOUT after {timeout}s\nSTDOUT\n" +
                   text(error.stdout) + "\nSTDERR\n" + text(error.stderr))
            (directory / (name + ".log")).write_text(log, encoding="utf-8")
            raise RuntimeError(f"{arch}/{name} timed out after {timeout}s; partial output retained in {name}.log") from error
        log = subprocess.list2cmdline(command) + "\n\nSTDOUT\n" + result.stdout + "\nSTDERR\n" + result.stderr
        (directory / (name + ".log")).write_text(log, encoding="utf-8")
        if success is True:
            require(result.returncode == 0, f"{arch}/{name} failed ({result.returncode}):\n{result.stderr[-5000:]}")
        elif success is False:
            require(result.returncode != 0, f"{arch}/{name} unexpectedly accepted invalid configuration")
        return result

    def check(self, name: str, callback) -> None:
        started = time.monotonic()
        entry = {"name": name, "status": "running"}
        self.report["checks"].append(entry)
        try:
            details = callback()
            entry.update(status="passed", seconds=round(time.monotonic() - started, 2))
            if details is not None:
                entry["details"] = details
            print("PASS " + name, flush=True)
        except Exception as error:
            entry.update(status="failed", seconds=round(time.monotonic() - started, 2), error=str(error))
            print("FAIL " + name + ": " + str(error), file=sys.stderr, flush=True)
        finally:
            self.write_report()

    def write_report(self) -> None:
        self.report["checks_passed"] = sum(c["status"] == "passed" for c in self.report["checks"])
        (self.output / "results.json").write_text(json.dumps(self.report, indent=2) + "\n", encoding="utf-8")

    def config(self, arch: str, name: str, *, level: int = 3, feature: str | None = "all",
               legacy: bool = False, pe: bool = True, seed: str = SEED, overrides: dict | None = None) -> Path:
        data = json.loads((self.fixtures / "full-protection.json").read_text()) if legacy else {}
        data["randomSeed"] = seed
        for item in FEATURES:
            data["bla-" + item] = {"enable": feature in ("all", item), "level": level}
        data["linker"] = {"bla-pe": {"enable": pe, "level": level}}
        if overrides:
            data.update(copy.deepcopy(overrides))
        path = self.output / arch / (name + ".json")
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        return path

    @staticmethod
    def llvm_args(config: Path | None = None, extra: tuple | list = (), *, cl: bool = False) -> list[str]:
        values = (["-arkari-cfg=" + str(config)] if config else []) + list(extra)
        result = []
        for value in values:
            result.extend(["/clang:-mllvm", "/clang:" + value] if cl else ["-mllvm", value])
        return result

    def ir(self, name: str, *, config: Path | None = None, extra: tuple | list = (),
           arch: str = "x64", source: str = "bla-plain.c", optimize: str = "O2",
           success: bool = True) -> str:
        output = self.output / arch / (name + ".ll")
        self.command(name, [self.tools["clang"], "--target=" + TRIPLES[arch], "-" + optimize,
                           "-S", "-emit-llvm", source, "-o", output,
                           *self.llvm_args(config, extra)], arch, success=success)
        return output.read_text(encoding="utf-8") if success else ""

    @staticmethod
    def function(ir: str, name: str) -> str:
        match = re.search(r'^define\b[^\n]*@' + re.escape(name) + r'\([^\n]*\)[^\n]*\{\n(.*?)^}', ir, re.M | re.S)
        require(match is not None, f"Missing IR function {name}")
        return match.group(0)

    @staticmethod
    def absent(ir: str) -> None:
        require("__arkari_bla_" not in ir and "arkari.bla." not in ir and not MBA.search(ir) and not OPAQUE.search(ir),
                "Disabled BLA options changed IR")

    def compile(self, name: str, sources: list[str], arch: str, *, config: Path | None = None,
                link_config: bool = True, extra: tuple | list = (), lto: bool = False,
                shared: bool = False, link: tuple | list = (), guard: bool = False) -> Path:
        output = self.output / arch / (name + (".dll" if shared else ".exe"))
        args = [self.tools["clang-cl"], "--target=" + TRIPLES[arch], "/nologo", "/O2", "/Gy", "/Gw", self.runtime_flag,
                "/EHsc", "/GR", "/std:c++17", "/clang:-fuse-ld=lld", *sources,
                *self.llvm_args(config, extra, cl=True), "/Fe:" + str(output)]
        if shared:
            args.append("/LD")
        if lto:
            args.append("/clang:-flto=thin")
        if guard:
            args.append("/guard:cf")
        args += ["/link", "/OPT:REF", "/OPT:ICF", "/Brepro", "/DYNAMICBASE", "/NXCOMPAT", *link]
        if guard:
            args.append("/guard:cf")
        if config and link_config:
            args.append("/arkari-cfg:" + str(config))
        self.command(name, args, arch)
        return output

    def execute(self, name: str, path: Path, arch: str, inputs: tuple = ()) -> str:
        return self.command(name, [path, *inputs], arch, timeout=30).stdout.strip()

    def structure(self) -> None:
        baseline = self.ir("default-off")
        self.absent(baseline)
        self.absent(self.ir("level-only", extra=tuple("-level-bla-" + f + "=3" for f in FEATURES)))
        disabled = self.config("x64", "disabled", level=3, feature=None, pe=False)
        self.absent(self.ir("json-disabled", config=disabled))
        for feature in FEATURES:
            for level in range(4):
                config = self.config("x64", f"{feature}-{level}", level=level, feature=feature, pe=False)
                ir = self.ir(f"ir-{feature}-{level}", config=config)
                if feature == "mba":
                    require(MBA.search(ir) is not None, "MBA flag did not transform an instruction")
                    require(len(re.findall(r'^\s*%[^\n]*=', ir, re.M)) > len(re.findall(r'^\s*%[^\n]*=', baseline, re.M)),
                            "MBA marked instructions without expanding the arithmetic")
                    for body in re.findall(r'^define\b[^\n]*\{\n.*?^}', ir, re.M | re.S):
                        require(len(MBA.findall(body)) <= (16 << level), "MBA per-function budget exceeded")
                elif feature == "opaque":
                    require(OPAQUE.search(ir) is not None, "Opaque flag did not create a guarded branch")
                    for body in re.findall(r'^define\b[^\n]*\{\n.*?^}', ir, re.M | re.S):
                        require(len(OPAQUE.findall(body)) <= level + 1, "Opaque per-function budget exceeded")
                elif feature == "decoy":
                    require(len(DECOY.findall(ir)) == 8 * (level + 1), "Wrong per-module decoy count")
                else:
                    require(ir.count("ARKARI-BLA-META-v1") == 1, "Metadata flag did not emit one payload")
                    require(ir.count("shadow-control") == (3, 6, 10, 16)[level], "Incorrect metadata chaff strength")
                    require(ir.count("api:") == (3, 6, 10, 16)[level], "Independent IR metadata omitted API-name chaff")
                    for marker in ("canary:shadow-evidence-", "diagnostic:route=deferred; state=attested-", ".?AVShadowPolicy_", "RSDS"):
                        require(ir.count(marker) == 2 * (level + 1), "Incorrect metadata record strength: " + marker)
                if feature != "decoy":
                    require(not DECOY.search(ir), "An independent feature enabled the decoy graph")
                if feature != "meta":
                    require("ARKARI-BLA-META-v1" not in ir, "An independent feature enabled metadata")

    def precedence_and_validation(self) -> None:
        config = self.config("x64", "precedence", feature="mba", pe=False,
                             overrides={"bla-decoy": {"enable": True, "level": 3}})
        self.absent(self.ir("cli-disables-json", config=config,
                            extra=("-irobf-bla-mba=false", "-irobf-bla-decoy=false")))
        ir = self.ir("cli-level-overrides-json", config=config, extra=("-level-bla-decoy=1",))
        require(len(DECOY.findall(ir)) == 16, "CLI level did not override JSON")
        annotations = self.ir("annotation-precedence", config=config, source="bla-structure.c",
                              extra=("-irobf", "-irobf-bla-mba=false", "-irobf-bla-opaque=false", "-irobf-bla-decoy=false"))
        disabled = self.function(annotations, "annotation_disabled")
        enabled = self.function(annotations, "annotation_enabled")
        require(not MBA.search(disabled) and not OPAQUE.search(disabled), "Negative annotation was ignored")
        require(MBA.search(enabled) and OPAQUE.search(enabled), "Positive annotation did not override the CLI")
        for feature in FEATURES:
            for value in ("-1", "4", "not-a-level"):
                self.ir("invalid-" + feature + "-" + value, extra=("-level-bla-" + feature + "=" + value,), success=False)
            for index, value in enumerate((-1, 4, "3", True, None)):
                name = "invalid-json-" + feature + "-" + str(index)
                bad = self.config("x64", name, feature=feature, pe=False,
                                  overrides={"bla-" + feature: {"enable": True, "level": value}})
                self.ir(name, config=bad, success=False)
        invalid_annotation = self.output / "x64/invalid-annotation.c"
        invalid_annotation.write_text((self.fixtures / "bla-structure.c").read_text().replace("^bla-mba=3", "^bla-mba=4"), encoding="utf-8")
        self.ir("invalid-annotation", source=invalid_annotation.name, extra=("-irobf",), success=False)

        # These static functions intentionally have no manual noinline attribute.
        # Preparation must retain annotation boundaries before the O2 inliner.
        self.absent(self.ir("inline-annotation-master-off", source="bla-inline-annotation.c"))
        annotation_only = self.ir("inline-annotation-only", source="bla-inline-annotation.c", extra=("-irobf",))
        caller = self.function(annotation_only, "annotation_caller")
        enabled = self.function(annotation_only, "inline_enabled")
        require(MBA.search(enabled), "Annotation-only function was inlined before MBA protection")
        require(re.search(r'\bcall\b[^\n]*@inline_enabled\(', caller), "Caller lost the protected annotation-only boundary")
        global_options = self.config("x64", "inline-annotation-global", feature="mba", pe=False,
                                     overrides={"bla-opaque": {"enable": True, "level": 3}})
        bounded = self.ir("inline-annotation-global", source="bla-inline-annotation.c", config=global_options)
        caller = self.function(bounded, "annotation_caller")
        enabled = self.function(bounded, "inline_enabled")
        disabled = self.function(bounded, "inline_disabled")
        require(MBA.search(enabled) and not OPAQUE.search(enabled), "Positive annotation priority was lost before inlining")
        require(not MBA.search(disabled) and not OPAQUE.search(disabled), "Negative annotation boundary was lost before inlining")
        require(all(re.search(r'\bcall\b[^\n]*@' + name + r'\(', caller) for name in ("inline_enabled", "inline_disabled")),
                "O2 caller no longer invokes both annotation boundaries")

    def deterministic_and_repeat(self) -> None:
        config = self.config("x64", "deterministic", level=3, pe=True)
        first = self.ir("deterministic-a", config=config)
        second = self.ir("deterministic-b", config=config)
        require(first == second, "Fixed-seed IR generation is not deterministic")
        alternate = self.config("x64", "other-seed", seed="0123456789abcdef0123456789abcdef")
        require(self.ir("deterministic-other-seed", config=alternate) != first, "The seed has no effect")
        repeated = self.ir("repeated-ir", config=config, source="deterministic-a.ll", optimize="O0")
        require(set(DECOY.findall(repeated)) == set(DECOY.findall(first)), "Reprocessing duplicated the decoy graph")
        require(repeated.count("ARKARI-BLA-META-v1") == first.count("ARKARI-BLA-META-v1"), "Reprocessing duplicated metadata")

    def prologue_and_tail(self) -> None:
        config = self.config("x64", "prologue", feature="opaque", pe=False)
        ir = self.ir("prologue", config=config, source="bla-prologue.ll", optimize="O0")
        entry = self.function(ir, "escaped").split("bla.guard", 1)[0]
        require("alloca i32" in entry and "@llvm.localescape" in entry,
                "Opaque protection moved static allocation or EH setup out of the original entry")
        tail = self.function(ir, "tail")
        require(re.search(r'musttail call[^\n]*\n\s*ret i32', tail),
                "Opaque protection separated a musttail call from its return")
        obj = self.output / "x64/prologue.obj"
        self.command("prologue-codegen", [self.tools["clang"], "--target=" + TRIPLES["x64"],
                     "-O0", "-c", "prologue.ll", "-o", obj])
        symbols = self.command("prologue-symbols", [self.tools["llvm-readobj"], "--symbols", obj]).stdout
        require("__chkstk" not in symbols, "Opaque protection introduced an unnecessary dynamic stack probe")

    def legacy_win32_constants(self) -> dict:
        # LLVM 23 no longer implicitly truncates a 64-bit random page-table key
        # to i32. A textual IR round trip silently repairs the bad ConstantInt,
        # so exercise the frontend-to-COFF path without serializing the module.
        for level in range(4):
            name = "legacy-win32-constants-" + str(level)
            options = {feature: {"enable": True, "level": level} for feature in LEGACY_FEATURES}
            config = self.config("x86", name, feature=None, pe=False, overrides=options)
            obj = self.output / "x86" / (name + ".obj")
            self.command(name, [self.tools["clang-cl"], "--target=" + TRIPLES["x86"],
                         "/nologo", "/O2", "/EHsc", "/c", "bla-legacy-win32.cpp", "/Fo:" + str(obj),
                         *self.llvm_args(config, cl=True)], "x86")
            require(COFF(obj).machine == MACHINES["x86"], "Legacy random-key regression did not emit i386 COFF")
        return {"legacy_levels": [0, 1, 2, 3], "direct_source_to_coff": True, "bla_enabled": False}

    def tiny_object(self, name: str, arch: str, config: Path | None, *, optimize: str = "O2",
                    lto: bool | str = False, source: str = "bla-plain.c", debug: bool = False) -> Path:
        output = self.output / arch / (name + ".obj")
        args = [self.tools["clang"], "--target=" + TRIPLES[arch], "-" + optimize, "-ffreestanding",
                "-fno-stack-protector", "-ffunction-sections", "-fdata-sections", "-c", source, "-o", output,
                *self.llvm_args(config)]
        if lto:
            args.append("-flto=" + ("thin" if lto is True else lto))
        if debug:
            args += ["-g", "-gcodeview"]
        self.command(name, args, arch)
        if not lto:
            readobj = self.command(name + "-readobj", [self.tools["llvm-readobj"], "--file-headers", "--sections", "--symbols", "--relocations", output], arch)
            self.command(name + "-disassembly", [self.tools["llvm-objdump"], "-dr", output], arch)
            if config and json.loads(config.read_text())["bla-decoy"]["enable"]:
                info = json.loads(config.read_text())
                coff = COFF(output)
                require(coff.machine == MACHINES[arch], "COFF target machine mismatch")
                require(len(coff.decoys) == 8 * (info["bla-decoy"]["level"] + 1), "COFF decoy graph is incomplete")
                require(len(coff.anchors) == 1 and len(coff.metadata) == 1, "COFF omitted or duplicated the graph/data anchor")
                required = {"x64": ("IMAGE_REL_AMD64_ADDR64", "IMAGE_REL_AMD64_REL32"),
                            "x86": ("IMAGE_REL_I386_DIR32", "IMAGE_REL_I386_REL32"),
                            "arm64": ("IMAGE_REL_ARM64_ADDR64", "IMAGE_REL_ARM64_BRANCH26")}[arch]
                require(all(reloc in readobj.stdout for reloc in required), "Missing real pointer/call COFF relocations")
        return output

    def tiny_link(self, name: str, arch: str, obj: Path | list[Path], *, config: Path | None = None,
                  extra: tuple | list = (), success: bool = True) -> Path:
        output = self.output / arch / (name + ".exe")
        objects = obj if isinstance(obj, list) else [obj]
        args = [self.tools["lld-link"], *objects, "/out:" + str(output), "/entry:entry", "/subsystem:console",
                "/nodefaultlib", "/opt:ref", "/opt:icf", "/brepro", "/dynamicbase", "/nxcompat",
                "/lldmap:" + str(output.with_suffix(".map")), *extra]
        if config:
            args.append("/arkari-cfg:" + str(config))
        self.command(name, args, arch, success=success)
        return output

    def coff_and_pe(self, arch: str) -> dict:
        profiles = []
        baseline = self.tiny_object("plain", arch, None)
        PE(self.tiny_link("plain", arch, baseline)).manifest(None, arch)
        PE(self.tiny_link("pe-level-only", arch, baseline, extra=("/arkari-bla-pe-level:3",))).manifest(None, arch)
        for level in range(4):
            config = self.config(arch, f"pe-{level}", level=level)
            obj = self.tiny_object(f"coff-{level}", arch, config)
            image = self.tiny_link(f"pe-{level}", arch, obj, config=config)
            pe = PE(image)
            require(pe.machine == MACHINES[arch], "PE target machine mismatch")
            first = pe.manifest(level, arch, decoys=8 * (level + 1), metadata=True)
            require(pe.directories[1] == (0, 0), "Inert BLA semantic metadata introduced API imports")
            profiles.append(pe.bla_summary)
            second = PE(self.tiny_link(f"pe-{level}-repeat", arch, obj, config=config)).manifest(level, arch)
            require(first == second, "Fixed-input PE manifest is not deterministic")
        highest = self.config(arch, "pe-highest")
        debug_results = {}
        for name, options in (("plain", None), ("protected", highest)):
            name = "real-pdb-" + name
            obj = self.tiny_object(name, arch, options, debug=True)
            pdb = self.output / arch / (name + ".pdb")
            image = PE(self.tiny_link(name, arch, obj, config=options,
                       extra=("/debug", "/pdb:" + str(pdb), "/pdbaltpath:arkari-real-identity.pdb")))
            image.manifest(3 if options else None, arch)
            debug_results[name] = image.debug_identity(pdb, "arkari-real-identity.pdb")
            self.command(name + "-debug-directory", [self.tools["llvm-readobj"], "--coff-debug-directory", image.path], arch)
        protected_object = self.tiny_object("ir-only", arch, highest)
        ir_only = self.tiny_link("ir-does-not-enable-linker", arch, protected_object)
        PE(ir_only).manifest(None, arch)
        link_map = ir_only.with_suffix(".map").read_text(encoding="utf-8", errors="replace")
        require(len(set(re.findall(r'__arkari_bla_decoy_[A-Za-z0-9_.$]+', link_map))) == 32,
                "IR-only decoys were removed by GC/ICF when PE protection was disabled")
        require("__arkari_bla_anchor_" in link_map and "__arkari_bla_meta_" in link_map,
                "IR-only metadata/anchor was removed by GC")
        PE(self.tiny_link("pe-json-cli-off", arch, protected_object, config=highest,
                          extra=("/arkari-bla-pe:no",))).manifest(None, arch)
        pe_only = PE(self.tiny_link("pe-only", arch, baseline, config=highest))
        pe_only.manifest(3, arch, decoys=0, metadata=False)
        disabled = self.config(arch, "pe-disabled", feature=None, pe=False)
        PE(self.tiny_link("pe-cli-overrides-json", arch, baseline, config=disabled,
                          extra=("/arkari-bla-pe", "/arkari-bla-pe-level:2"))).manifest(2, arch, decoys=0, metadata=False)
        for value in ("-1", "4", "not-a-level"):
            self.tiny_link("invalid-pe-" + value, arch, baseline, extra=("/arkari-bla-pe-level:" + value,), success=False)
        bad = self.config(arch, "invalid-pe-json", feature=None,
                          overrides={"linker": {"bla-pe": {"enable": True, "level": 4}}})
        self.tiny_link("invalid-pe-json", arch, baseline, config=bad, success=False)
        for optimize in ("O0", "O2"):
            obj = self.tiny_object("coff-full-" + optimize, arch, highest, optimize=optimize)
            PE(self.tiny_link("pe-full-" + optimize, arch, obj, config=highest)).manifest(3, arch, decoys=32, metadata=True)
        bitcode = self.tiny_object("thinlto", arch, highest, lto=True)
        PE(self.tiny_link("thinlto", arch, bitcode, config=highest)).manifest(3, arch, decoys=32, metadata=True)
        dual_results = {}
        for mode in ("thin", "full"):
            first = self.tiny_object("dual-a-" + mode, arch, highest, lto=mode, source="bla-dual-a.c")
            second = self.tiny_object("dual-b-" + mode, arch, highest, lto=mode, source="bla-dual-b.c")
            # shared() is deliberately importable and may be copied/inlined into
            # the caller by ThinLTO. Each original TU must still own one graph.
            image = PE(self.tiny_link("dual-" + mode, arch, [first, second], config=highest))
            image.manifest(3, arch, decoys=64, metadata=2)
            dual_results[mode] = image.bla_summary
        return {"profiles": profiles, "ordinary_optimization": ["O0", "O2"],
                "application_thin_lto": True, "dual_translation_unit_lto": dual_results,
                "real_pe_pdb_identity": debug_results}

    def inventory(self, arch: str) -> dict:
        sources = ["protection-main.cpp", "protection-worker.cpp"]
        baseline = self.compile("inventory-baseline", sources, arch)
        expected = [self.execute("inventory-baseline-" + value, baseline, arch, (value,)) for value in INPUTS]
        require(all(line.startswith("Arkari full protection smoke: OK ") for line in expected), "Invalid inventory baseline")
        legacy = self.config(arch, "inventory-legacy", legacy=True, feature=None, pe=False)
        variants = [("legacy", legacy, False, None, False)]
        for level in range(4):
            variants.append(("bla-" + str(level), self.config(arch, "inventory-bla-" + str(level), level=level), False, level, False))
        combined = self.config(arch, "inventory-combined", legacy=True)
        variants += [("legacy-thinlto", legacy, True, None, False),
                     ("bla-thinlto", self.config(arch, "inventory-bla-thinlto"), True, 3, False),
                     ("combined-low", self.config(arch, "inventory-combined-low", legacy=True, level=0), False, 0, False),
                     ("combined", combined, False, 3, False), ("combined-thinlto", combined, True, 3, False),
                     ("bla-cfg", self.config(arch, "inventory-bla-cfg"), False, 3, True)]
        output = {}
        self.report["checks"][-1]["details"] = output
        for name, config, lto, pe_level, guard in variants:
            entry = {"status": "running", "stage": "compile", "application_thin_lto": lto,
                     "control_flow_guard": guard, "program_returncodes": {}}
            output[name] = entry
            try:
                exe = self.compile("inventory-" + name, sources, arch, config=config, lto=lto, guard=guard)
                entry["stage"] = "run"
                actual = []
                for value in INPUTS:
                    entry["program_returncodes"][value] = None
                    result = self.command("inventory-" + name + "-" + value, [exe, value], arch, timeout=30, success=None)
                    entry["program_returncodes"][value] = result.returncode
                    require(result.returncode == 0, f"{arch} inventory {name} input {value} exited with {result.returncode}")
                    actual.append(result.stdout.strip())
                require(actual == expected, f"{arch} inventory {name} differs from the unprotected program")
                entry["stage"] = "verify"
                PE(exe).manifest(pe_level, arch)
                if guard:
                    require(PE(exe).dll_characteristics & 0x4000, "Control Flow Guard was disabled")
                if name in ("legacy", "legacy-thinlto", "combined-low", "combined", "combined-thinlto"):
                    data = exe.read_bytes()
                    require(b"ARKARI_PROTECTED_LITERAL_7D2BC640" not in data and b".?AUSmokeDerived@@" not in data,
                            "Legacy string encryption/RTTI erasure stopped working")
                entry.update(status="passed", stage="complete", inputs=len(actual),
                             output_sha256=hashlib.sha256("\n".join(actual).encode()).hexdigest())
            except Exception as error:
                entry.update(status="failed", error=str(error))
                print(f"FAIL {arch} inventory {name}: {error}", file=sys.stderr, flush=True)
            finally:
                self.write_report()
        failures = [name for name, entry in output.items() if entry["status"] != "passed"]
        require(not failures, f"{arch} inventory failed variants: {', '.join(failures)}")
        return output

    def compatibility(self, arch: str) -> dict:
        inputs = ("0", "19", "256")
        details = {"inputs": list(inputs), "pairs_expected": 5 * len(LEGACY_FEATURES),
                   "old_only": {}, "pairs": {}}
        # Attach this mutable object before compiling. On the first failure the
        # group retains the exact pair, completed return codes and command logs.
        self.report["checks"][-1]["details"] = details
        baseline = self.output / arch / "inventory-baseline.exe"
        require(baseline.is_file(), "Run the inventory controls before the compatibility matrix")
        expected = []
        baseline_codes = {}
        for value in inputs:
            result = self.command("compat-baseline-" + value, [baseline, value], arch, timeout=30)
            expected.append(result.stdout.strip())
            baseline_codes[value] = result.returncode
        original = baseline.read_bytes()
        require(b"ARKARI_PROTECTED_LITERAL_7D2BC640" in original and b".?AUSmokeDerived@@" in original,
                "Inventory baseline lacks the business string/RTTI fixture")
        details["baseline"] = {"program_returncodes": baseline_codes,
                               "output_sha256": hashlib.sha256("\n".join(expected).encode()).hexdigest()}

        def variant(old: str, new: str | None, name: str, bucket: dict) -> None:
            pair = ("old-only:" + old) if new is None else ("bla-" + new + "+" + old)
            entry = {"name": pair, "old_feature": old, "new_feature": new, "status": "running",
                     "stage": "compile", "program_returncodes": {}, "program_log_prefix": name}
            bucket[pair] = entry
            started = time.monotonic()
            self.write_report()
            try:
                config = self.config(arch, name, feature=new if new in FEATURES else None,
                                     pe=new == "pe", level=3,
                                     overrides={old: {"enable": True, "level": 3}})
                options = json.loads(config.read_text())
                active_ir = [feature for feature in FEATURES if options["bla-" + feature]["enable"]]
                active_old = [feature for feature in LEGACY_FEATURES if options.get(feature, {}).get("enable", False)]
                require(active_ir == ([new] if new in FEATURES else []) and active_old == [old],
                        "Compatibility configuration enabled an unrelated IR pass")
                require(options["linker"]["bla-pe"]["enable"] == (new == "pe"),
                        "Compatibility configuration enabled an unrelated PE feature")
                entry.update(ir_features_enabled=active_ir, legacy_features_enabled=active_old,
                             pe_feature_enabled=new == "pe")
                exe = self.compile(name, ["protection-main.cpp", "protection-worker.cpp"], arch, config=config)
                entry["stage"] = "run"
                actual = []
                for value, oracle in zip(inputs, expected):
                    # None denotes a timed-out/killed process if command() raises
                    # before a completed process return code becomes available.
                    entry["program_returncodes"][value] = None
                    self.write_report()
                    result = self.command(name + "-" + value, [exe, value], arch, timeout=30, success=None)
                    entry["program_returncodes"][value] = result.returncode
                    actual.append(result.stdout.strip())
                    entry["output_sha256"] = hashlib.sha256("\n".join(actual).encode()).hexdigest()
                    self.write_report()
                    require(result.returncode == 0,
                            f"input {value} exited with {result.returncode}: {result.stderr[-3000:]}")
                    require(actual[-1] == oracle, f"input {value} output differs from the unprotected program")
                entry["stage"] = "verify"
                image = PE(exe)
                if new == "pe":
                    image.manifest(3, arch, decoys=0, metadata=False)
                    require(image.bla_summary["objects"] == 0, "PE-only pair unexpectedly enabled an IR feature")
                    entry["pe_manifest"] = image.bla_summary
                else:
                    image.manifest(None, arch)
                data = exe.read_bytes()
                if old == "cse":
                    require(b"ARKARI_PROTECTED_LITERAL_7D2BC640" not in data, "Business string encryption did not take effect")
                    entry["business_string_encryption_verified"] = True
                if old == "rtti":
                    require(b".?AUSmokeDerived@@" not in data, "Real business RTTI name was not erased")
                    entry["business_rtti_erasure_verified"] = True
                if new == "meta":
                    for marker in (b"ARKARI-BLA-META-v1\0", b"canary:shadow-evidence-",
                                   b"api:kernel32.dll!CreateFileW", b"diagnostic:route=deferred; state=attested-",
                                   b".?AVShadowPolicy_", b"RSDS"):
                        require(marker in data, "Semantic decoy metadata stopped being plaintext: " + repr(marker))
                    entry["semantic_metadata_plaintext_verified"] = True
                else:
                    require(b"ARKARI-BLA-META-v1\0" not in data, "An independent pair unexpectedly enabled semantic metadata")
                entry.update(status="passed", stage="complete")
                print("PASS " + arch + " compatibility " + pair, flush=True)
            except Exception as error:
                entry.update(status="failed", error=str(error))
                print(f"FAIL {arch} compatibility {pair} during {entry['stage']}: {error}", file=sys.stderr, flush=True)
            finally:
                entry["seconds"] = round(time.monotonic() - started, 2)
                self.write_report()

        # Establish each old pass independently before attributing a failure to a
        # new/old interaction. No other old or new switch is enabled here.
        for old in LEGACY_FEATURES:
            variant(old, None, "compat-old-" + old, details["old_only"])
        for new in (*FEATURES, "pe"):
            for old in LEGACY_FEATURES:
                variant(old, new, "compat-" + new + "-" + old, details["pairs"])
        require(len(details["pairs"]) == details["pairs_expected"], "Compatibility matrix is incomplete")
        failures = [name for bucket in (details["old_only"], details["pairs"]) for name, entry in bucket.items()
                    if entry["status"] != "passed"]
        require(not failures, f"{arch} compatibility failed variants: {', '.join(failures)}")
        return details

    def arithmetic_and_concurrency(self, arch: str) -> dict:
        arithmetic = self.compile("arithmetic-baseline", ["bla-arithmetic.cpp"], arch)
        expected = self.execute("arithmetic-baseline", arithmetic, arch)
        require(expected == "BLA arithmetic: 637fc87f", "The arithmetic oracle changed")
        for level in range(4):
            config = self.config(arch, "arithmetic-" + str(level), level=level, feature="mba", pe=False)
            exe = self.compile("arithmetic-" + str(level), ["bla-arithmetic.cpp"], arch, config=config)
            require(self.execute("arithmetic-" + str(level), exe, arch) == expected, "MBA arithmetic mismatch")
        concurrent = self.compile("concurrent-baseline", ["bla-concurrent.cpp"], arch)
        expected_concurrent = self.execute("concurrent-baseline", concurrent, arch)
        require(expected_concurrent == "BLA concurrent: ec6026a0 7ec8a260 3dc27be0 e1286760", "The concurrent oracle changed")
        for name, legacy in (("bla", False), ("combined", True)):
            config = self.config(arch, "concurrent-" + name, legacy=legacy)
            exe = self.compile("concurrent-" + name, ["bla-concurrent.cpp"], arch, config=config)
            for repeat in range(3):
                require(self.execute("concurrent-" + name + "-" + str(repeat), exe, arch) == expected_concurrent,
                        "Concurrent execution is nondeterministic or differs from baseline")
        return {"boundary_pairs": 49, "pseudorandom_pairs": 4096, "threads": 4, "calls_per_thread": 2000}

    def dll(self, arch: str) -> None:
        baseline = self.compile("dll-baseline", ["bla-dll.cpp"], arch, shared=True)
        baseline_exports = PE(baseline).exports()
        require(len(baseline_exports) == 1, "Invalid DLL baseline exports")
        config = self.config(arch, "dll-combined", legacy=True)
        protected = self.compile("dll-protected", ["bla-dll.cpp"], arch, shared=True, config=config)
        require(PE(protected).exports() == baseline_exports, "BLA changed DLL exports")
        PE(protected).manifest(3, arch)
        results = []
        for name, library in (("baseline", baseline), ("protected", protected)):
            client = self.compile("dll-client-" + name, ["bla-dll-client.cpp"], arch,
                                  link=(str(library.with_suffix(".lib")),))
            results.append(self.execute("dll-client-" + name, client, arch))
        require(results[0] == results[1], "DLL/import-library/runtime compatibility failed")

    def run(self) -> None:
        self.report["compiler_version"] = self.command("compiler-version", [self.tools["clang"], "--version"]).stdout.strip()
        self.report["linker_version"] = self.command("linker-version", [self.tools["lld-link"], "--version"]).stdout.strip()
        self.check("IR default-off, independent flags, levels and budgets", self.structure)
        self.check("IR JSON/CLI/annotation precedence and invalid levels", self.precedence_and_validation)
        self.check("IR fixed seed and repeated processing", self.deterministic_and_repeat)
        self.check("Windows static allocation, localescape and musttail preservation", self.prologue_and_tail)
        self.check("Legacy Win32 random page-table constants, direct source to COFF", self.legacy_win32_constants)
        for arch in TRIPLES:
            self.check(arch + " COFF/PE, linker options, GC/ICF and single/dual-TU LTO", lambda arch=arch: self.coff_and_pe(arch))
        for arch in ("x64", "x86"):
            self.check(arch + " inventory: legacy, BLA 0..3, combined and application ThinLTO", lambda arch=arch: self.inventory(arch))
            self.check(arch + " 5 new protections x 8 legacy passes compatibility", lambda arch=arch: self.compatibility(arch))
            self.check(arch + " arithmetic and concurrent runtime equivalence", lambda arch=arch: self.arithmetic_and_concurrency(arch))
            self.check(arch + " DLL export/import-library/runtime compatibility", lambda arch=arch: self.dll(arch))
        failures = [entry["name"] for entry in self.report["checks"] if entry["status"] != "passed"]
        self.report["failed_groups"] = failures
        require(not failures, "BLA regression groups failed: " + "; ".join(failures))
        self.report["status"] = "passed"
        self.write_report()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", required=True)
    parser.add_argument("--fixtures", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--build-type", choices=("Release", "Debug"), default="Release")
    args = parser.parse_args()
    suite = None
    try:
        require(sys.platform == "win32", "Runtime regressions require the Windows Visual Studio runner")
        suite = Suite(args)
        suite.run()
        print(f"BLA regression suite passed ({suite.report['checks_passed']} groups).", flush=True)
        return 0
    except Exception as error:
        if suite:
            suite.report["status"] = "failed"
            suite.report["error"] = str(error)
            suite.write_report()
        print(str(error), file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
