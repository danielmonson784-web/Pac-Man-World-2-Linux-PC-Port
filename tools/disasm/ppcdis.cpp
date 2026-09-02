// Standalone Gekko disassembler over a raw GameCube DOL, using Dolphin's
// GekkoDisassembler. Usage: ppcdis <main.dol> <vaddr-hex> <instruction-count>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "Common/GekkoDisassembler.h"

struct Sec { unsigned off, va, size; };

int main(int argc, char** argv)
{
  if (argc < 4) { fprintf(stderr, "usage: %s <dol> <vaddr> <count>\n", argv[0]); return 2; }
  FILE* f = fopen(argv[1], "rb");
  if (!f) { perror("open"); return 1; }
  fseek(f, 0, SEEK_END); long fsz = ftell(f); fseek(f, 0, SEEK_SET);
  std::vector<unsigned char> d(fsz);
  if (fread(d.data(), 1, fsz, f) != (size_t)fsz) { fprintf(stderr,"short read\n"); return 1; }
  fclose(f);

  auto be32 = [&](unsigned o) -> unsigned {
    return (d[o]<<24)|(d[o+1]<<16)|(d[o+2]<<8)|d[o+3];
  };

  std::vector<Sec> secs;
  for (int i = 0; i < 18; i++) {
    unsigned off = be32(0x00 + i*4), va = be32(0x48 + i*4), sz = be32(0x90 + i*4);
    if (off && sz) secs.push_back({off, va, sz});
  }

  unsigned long va = strtoul(argv[2], nullptr, 0);
  long n = strtol(argv[3], nullptr, 0);

  for (long i = 0; i < n; i++, va += 4) {
    const Sec* s = nullptr;
    for (const auto& c : secs) if (va >= c.va && va < c.va + c.size) { s = &c; break; }
    if (!s) { printf("%08lX  <unmapped>\n", va); continue; }
    unsigned op = be32(s->off + (va - s->va));
    std::string t = Common::GekkoDisassembler::Disassemble(op, (unsigned)va);
    printf("%08lX  %08X  %s\n", va, op, t.c_str());
  }
  return 0;
}
