"""Execute the real metadata reader and real Client/ObjC wrapper bodies."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IOSurfaceLayoutContract(unittest.TestCase):
    def test_real_reader_and_entry_point_fallbacks(self):
        source = (ROOT / "libmachook/mac_hooks.m").read_text()
        clients = source[source.index("#define MACWS_CLIENT_PLANE_GETTER"):
                         source.index("#undef MACWS_CLIENT_PLANE_GETTER")]
        objc = source[source.index("#define MACWS_OBJC_PLANE_GETTER"):
                      source.index("#undef MACWS_OBJC_PLANE_GETTER")]
        client_entries = re.findall(r"^MACWS_CLIENT_PLANE_GETTER\((\w+), ([^,]+), ([^)]+)\)", clients, re.M)
        objc_entries = re.findall(r"^MACWS_OBJC_PLANE_GETTER\((\w+), ([^)]+)\)", objc, re.M)
        self.assertEqual(len(client_entries), 15)
        self.assertEqual(len(objc_entries), 7)
        prelude = r'''
typedef int BOOL;
#define NO 0
#define __bridge
typedef void *id;
typedef void *SEL;
typedef size_t NSUInteger;
typedef intptr_t NSInteger;
static int ready = 1, fallbacks = 0;
static void *seen_client;
static size_t seen_plane;
static BOOL macws_iosurface_layout_abi_ready(void) { return ready; }
static void macws_install_iosurface_layout_methods(void) {}
#define DYLD_INTERPOSE(a, b)
static BOOL macws_iosurface_native_plane_value(id surface, size_t plane,
        MacWSNativePlaneField field, uintptr_t *value) {
    if (!ready || !surface) return 0;
    void *client = NULL;
    memcpy(&client, (unsigned char *)surface + 8, sizeof(client));
    return MacWSIOSurfaceReadNativePlane(client, plane, field, value);
}
'''
        for name, result, index in client_entries:
            prelude += f"{result} IOSurfaceClientGet{name}OfPlane(void *client, {index} plane) {{\n"
            prelude += "++fallbacks; seen_client=client; seen_plane=plane;"
            prelude += f"return ({result})(uintptr_t)0x7654; }}\n"
        for name, result in objc_entries:
            prelude += f"static {result} original_{name}(id surface, SEL cmd, NSUInteger plane) {{\n"
            prelude += "(void)cmd; ++fallbacks; seen_client=surface; seen_plane=plane;"
            prelude += f"return ({result})(uintptr_t)0x8765; }}\n"
        public_prefixes = []
        for name, result, index in client_entries:
            pattern = (r"(?:size_t|uint32_t|void \*)\s*macws_IOSurfaceGet" + name +
                       r"OfPlane\(\s*IOSurfaceRef surface,\s*size_t plane\) \{")
            match = re.search(pattern, source)
            self.assertIsNotNone(match, name)
            start = match.start()
            original = re.search(r"\n\s*(?:size_t|uint32_t|void\s*\*)\s*original\s*=",
                                 source[match.end():])
            self.assertIsNotNone(original, name)
            prefix = source[start:match.end() + original.start()]
            public_prefixes.append(prefix + f"\nreturn ({result})(uintptr_t)0x9876;\n}}\n")
        exercise = "init(client); ready=1; fallbacks=0;\n"
        for name, result, index in client_entries:
            exercise += f"assert((uintptr_t)macws_IOSurfaceClientGet{name}OfPlane(client, 1) == read_field(client, 1, MacWSNativePlane{name}));\n"
            exercise += f"assert((uintptr_t)macws_IOSurfaceClientGet{name}OfPlane(client, 2) == 0x7654);\n"
        exercise += "assert(fallbacks==15 && seen_client==client && seen_plane==2);\n"
        exercise += "ready=0; assert(macws_IOSurfaceClientGetWidthOfPlane(client, 0)==0x7654); ready=1;\n"
        exercise += "assert(macws_IOSurfaceClientGetWidthOfPlane(client,(uint32_t)UINT64_C(0x100000000))==19);\n"
        exercise += "assert(macws_IOSurfaceClientGetNumberOfComponentsOfPlane(client,UINT64_C(0x100000000))==0x7654);\n"
        exercise += "assert(seen_plane==UINT64_C(0x100000000));\n"
        exercise += "unsigned char object[16]={0}; void *cp=client; memcpy(object+8,&cp,sizeof(cp));\n"
        for name, result, index in client_entries:
            exercise += f"assert((uintptr_t)macws_IOSurfaceGet{name}OfPlane(object,1)==read_field(client,1,MacWSNativePlane{name}));\n"
            exercise += f"assert((uintptr_t)macws_IOSurfaceGet{name}OfPlane(object,2)==0x9876);\n"
        exercise += "client[0x120]=1;\n"
        exercise += "assert(macws_IOSurfaceGetBytesPerRowOfPlane(object,0)==0);\n"
        exercise += "assert(macws_IOSurfaceGetBaseAddressOfPlane(object,0)==NULL); client[0x120]=3;\n"
        for name, result in objc_entries:
            exercise += f"g_macws_iosurface_plane_{name}=original_{name};\n"
            exercise += f"assert((uintptr_t)macws_iosurface_plane_{name}(object,NULL,1)==read_field(client,1,MacWSNativePlane{name}));\n"
            exercise += f"assert((uintptr_t)macws_iosurface_plane_{name}(object,NULL,UINT64_C(0x100000000))==0x8765);\n"
            exercise += "assert(seen_client==object && seen_plane==UINT64_C(0x100000000));\n"
        exercise += "put(client,0xa0,0); assert(macws_IOSurfaceClientGetWidthOfPlane(client,0)==0x7654);\n"
        exercise += "assert(macws_iosurface_plane_Width(object,NULL,0)==0x8765);\n"
        exercise += "ready=0; assert(macws_iosurface_plane_Width(object,NULL,0)==0x8765);\n"
        fixture = (ROOT / "misc/test_iosurface_layout_abi.c").read_text()
        fixture = fixture.replace("/* PRODUCTION_CLIENT_WRAPPERS */", prelude + clients +
                                  "\ntypedef id IOSurfaceRef;\n" + "".join(public_prefixes))
        fixture = fixture.replace("/* PRODUCTION_OBJC_WRAPPERS */", objc)
        fixture = fixture.replace("/* EXERCISE_PRODUCTION_WRAPPERS */", exercise)
        with tempfile.TemporaryDirectory(prefix="macws-surface-layout-") as tmp:
            binary = str(Path(tmp) / "test")
            subprocess.run([os.environ.get("CC", "cc"), "-x", "c", "-std=c11",
                            "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "include"),
                            "-", "-o", binary], input=fixture, text=True, check=True)
            subprocess.run([binary], check=True, timeout=5)

    @unittest.skipUnless(sys.platform == "darwin", "uses native dispatch_once")
    def test_actual_abi_gate_rejects_each_wrong_instruction(self):
        source = (ROOT / "libmachook/mac_hooks.m").read_text()
        gate = source[source.index("static BOOL macws_iosurface_layout_abi_ready(void) {"):
                      source.index("\nstatic void macws_install_iosurface_layout_methods(void);")]
        anchors = re.findall(r"\{(0x[0-9a-f]+), (0x[0-9a-f]+)\}", gate)
        self.assertEqual(len(anchors), 15)
        fixture = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dispatch/dispatch.h>
typedef int BOOL;
#define NO 0
#define YES 1
static unsigned char image[0x9000];
static int protect=1, uuid=1;
static const unsigned char g_macws_iosurface_protection_uuid[16]={0};
typedef struct { void *dli_fbase; } Dl_info;
static void IOSurfaceGetProtectionOptions(void) {}
static int dladdr(void *pointer, Dl_info *info) {
    (void)pointer; info->dli_fbase=image; return 1;
}
static int macws_macho_uuid_matches(void *base, const unsigned char *expected) {
    (void)expected; return base==image && uuid;
}
static BOOL macws_iosurface_protection_abi_ready(void) { return protect; }
'''
        fixture += gate + "\nint main(int argc,char **argv){int mode=argc>1?atoi(argv[1]):0;\n"
        for offset, instruction in anchors:
            fixture += f"{{ uint32_t word={instruction}; memcpy(image+{offset},&word,4); }}\n"
        fixture += "if(mode==1)protect=0; if(mode==2)uuid=0;\n"
        for index, (offset, _) in enumerate(anchors, 3):
            fixture += f"if(mode=={index})image[{offset}]^=1;\n"
        fixture += "assert(macws_iosurface_layout_abi_ready()==(mode==0)); return 0;}\n"
        with tempfile.TemporaryDirectory(prefix="macws-layout-gate-") as tmp:
            binary = str(Path(tmp) / "test")
            subprocess.run([os.environ.get("CC", "cc"), "-x", "c", "-std=c11",
                            "-fblocks", "-Wall", "-Wextra", "-Werror", "-", "-o", binary],
                           input=fixture, text=True, check=True)
            for mode in range(18):
                subprocess.run([binary, str(mode)], check=True, timeout=5)

    def test_bounded_default_policy_and_no_text_patch(self):
        source = (ROOT / "libmachook/mac_hooks.m").read_text()
        section = source.split("// Native IOSurface Client layout boundary.", 1)[1]
        section = section.split("// IOSurface per-plane-layout compatibility.", 1)[0]
        for check in ("macws_iosurface_protection_abi_ready()", "macws_macho_uuid_matches",
                      "instruction != anchors[i].instruction", "method_getTypeEncoding",
                      "ptrauth_strip", "specs[i].offset", "method_setImplementation"):
            self.assertIn(check, section)
        for forbidden in ("MSHookFunction", "ModifyExecutableRegion", "getenv(",
                          "access(", "mprotect("):
            self.assertNotIn(forbidden, section)


if __name__ == "__main__":
    unittest.main()
