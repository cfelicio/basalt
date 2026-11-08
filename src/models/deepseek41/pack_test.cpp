// src/models/deepseek41/pack_test.cpp - open_pack's reading of the experts.layout, without a model or a GPU:
// an all-i-quant pack parses to the fields of its lines, and a pack whose experts are a format this build
// does not carry is refused by name (a UD pack's layer 0 keeps its down experts as Q2_K, id 10; loading it
// used to divide by a staged stride of zero at serve time instead).
#include "models/deepseek41/pack.hpp"

#include "basalt/core/model_format.hpp"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace basalt::models::deepseek41 {
namespace {

namespace fs = std::filesystem;
using core::kHeaderBytes, core::kModelMagic, core::kModelVersion, core::kSectionAlign;

int g_fail = 0;
void check(bool ok, const std::string& what) {
    std::printf("  %-84s %s\n", what.c_str(), ok ? "ok" : "FAIL");
    if (!ok) ++g_fail;
}

struct TempDir {
    fs::path path;
    TempDir() {
        path = fs::temp_directory_path() /
               ("basalt-pack-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
        fs::create_directories(path);
    }
    ~TempDir() {
        std::error_code ignored;
        fs::remove_all(path, ignored);
    }
};

struct Sec {
    std::string name;
    std::string data;
};

/// Writes a model file with the given sections, each at a multiple of kSectionAlign (as tests/core does).
std::string write_model(const fs::path& path, const std::vector<Sec>& secs) {
    std::vector<char> file((size_t) kHeaderBytes, 0);
    core::FileHeader h{};
    std::memcpy(h.magic, kModelMagic, 8);
    h.version = kModelVersion;
    h.n_sections = (uint32_t) secs.size();
    for (size_t i = 0; i < secs.size(); ++i) {
        const uint64_t off = (file.size() + kSectionAlign - 1) / kSectionAlign * kSectionAlign;
        file.resize((size_t) off, 0);
        file.insert(file.end(), secs[i].data.begin(), secs[i].data.end());
        core::SectionEntry e{};
        std::memcpy(e.name, secs[i].name.data(), secs[i].name.size());
        e.offset = off;
        e.bytes = secs[i].data.size();
        std::memcpy(file.data() + sizeof h + i * sizeof e, &e, sizeof e);
    }
    h.file_bytes = file.size();
    std::memcpy(file.data(), &h, sizeof h);
    std::ofstream(path, std::ios::binary).write(file.data(), (std::streamsize) file.size());
    return path.string();
}

const char* kMeta =
    R"({"arch":"deepseek41","geometry":{"block_count":2,"embedding_length":512,"expert_count":8,)"
    R"("expert_used_count":2,"expert_feed_forward_length":1024},"tensors":{}})";

std::string layout(const std::string& line1) {
    return "# experts v5: layer gu_type d_type offset blob_bytes (n_expert 8, total 0)\n"
           "0 19 19 0 4096\n" +
           line1 + "\n";
}

bool open(const fs::path& dir, const std::string& line1, Pack& p, std::string& err) {
    const std::string file = write_model(dir / "m.basalt", {{"meta", kMeta}, {"experts.layout", layout(line1)}});
    return open_pack(file, p, err);
}

}  // namespace

int run_all() {
    TempDir d;
    std::string err;

    // 1. an all-i-quant pack: the lines parse to the fields, the geometry reads
    {
        Pack p;
        const bool ok = open(d.path, "1 16 22 32768 8192", p, err);
        check(ok, "a pack of carried formats opens" + (ok ? "" : ": " + err));
        check(p.geo.n_expert == 8 && p.geo.n_used == 2, "the geometry read");
        check(p.experts.size() == 2 && p.experts[1].gu_type == 16 && p.experts[1].d_type == 22 &&
                  p.experts[1].offset == 32768 && p.experts[1].blob_bytes == 8192,
              "the layout lines read to their fields");
    }

    // 2. a format the build does not carry is refused, by layer and by id (Q2_K is 10, ggml names it not here)
    {
        Pack p;
        const bool ok = open(d.path, "1 19 10 32768 4096", p, err);
        check(!ok && err.find("layer 1") != std::string::npos && err.find("id 10") != std::string::npos,
              "a down expert of type 10 is refused naming layer 1 and id 10: " + err);
    }
    {
        Pack p;
        const bool ok = open(d.path, "1 39 19 32768 4096", p, err);
        check(!ok && err.find("layer 1") != std::string::npos && err.find("id 39") != std::string::npos,
              "a gate/up of type 39 is refused naming id 39: " + err);
    }
    {
        Pack p;
        const bool ok = open(d.path, "1 19 99 32768 4096", p, err);
        check(!ok && err.find("id 99") != std::string::npos, "an id past the count is refused too: " + err);
    }

    // 3. a hole below the enum's first id: no traits either
    {
        Pack p;
        const bool ok = open(d.path, "1 19 4 32768 4096", p, err);
        check(!ok && err.find("id 4") != std::string::npos, "id 4 (no traits here) refused naming its id: " + err);
    }

    std::printf("%s\n", g_fail == 0 ? "pack_test: ok" : "pack_test: FAILED");
    return g_fail;
}

}  // namespace basalt::models::deepseek41

int main() { return basalt::models::deepseek41::run_all() == 0 ? 0 : 1; }
