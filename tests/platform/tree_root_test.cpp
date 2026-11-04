// tests/platform/tree_root_test.cpp - basalt::platform::tree_root: the tree of serve/ and data/ an installed engine
// carries beside its binaries, found by walking up from the binary, and the tree built in when it carries none.
// CPU only: it writes a scratch tree under the temp folder and reads it back.
#include "basalt/platform/file.hpp"
#include "basalt/platform/system.hpp"

#include <filesystem>
#include <fstream>
#include <string>

namespace {
int failures = 0;
void check(bool ok, const std::string& what) {
    std::printf("tree_root %-58s -> %s\n", what.c_str(), ok ? "ok" : "FAILED   <-- WRONG");
    failures |= !ok;
}

namespace fs = std::filesystem;

/// The marker every installed tree carries. Returns false when the scratch tree cannot be written.
bool make_tree(const fs::path& root) {
    std::error_code ec;
    fs::create_directories(root / "serve", ec);
    if (ec) return false;
    std::ofstream out(root / "serve" / "server.py");
    out << "# the server module\n";
    return (bool) out;
}

fs::path scratch(const char* name) {
    const fs::path root = fs::temp_directory_path() / ("basalt_tree_root_" + std::string(name));
    std::error_code ec;
    fs::remove_all(root, ec);
    return root;
}

std::string native(const fs::path& p) { return p.string(); }
}  // namespace

int main() {
    using basalt::platform::tree_root;
    const std::string built = "the-tree-it-was-built-in";

    // an installed tree: the binary sits in <root>/bin, the tree is <root>
    const fs::path installed = scratch("bin");
    if (!make_tree(installed)) {
        std::printf("tree_root %-58s -> skipped: cannot write the scratch tree\n", "the installed tree beside a bin folder");
        return 0;
    }
    const fs::path exe = installed / "bin" / "basalt-engine";
    std::error_code ec;
    fs::create_directories(exe.parent_path(), ec);
    check(tree_root(native(exe), built) == native(installed), "the installed tree beside a bin folder");

    // the same binary one level lower reaches the same tree, so a dist/bin layout works too
    const fs::path deep = installed / "dist" / "bin" / "basalt-engine";
    fs::create_directories(deep.parent_path(), ec);
    check(tree_root(native(deep), built) == native(installed), "the installed tree two folders below bin");

    // an engine that carries serve/ beside itself, with no bin folder in between
    const fs::path flat = scratch("flat");
    if (make_tree(flat)) {
        check(tree_root(native(flat / "basalt-engine"), built) == native(flat), "the tree beside a loose binary");
    }

    // no tree beside the binary: the answer is the tree it was built in, which is where a build in a source tree
    // finds its serve/ and data/
    const fs::path lone = scratch("lone");
    fs::create_directories(lone / "bin", ec);
    check(tree_root(native(lone / "bin" / "basalt-engine"), built) == built, "no tree beside the binary is the built tree");

    // walking up stops after three folders, so a tree four levels above is not picked up by accident
    const fs::path far = scratch("far");
    if (make_tree(far)) {
        const fs::path exe4 = far / "g" / "h" / "i" / "basalt-engine";
        fs::create_directories(exe4.parent_path(), ec);
        check(tree_root(native(exe4), built) == built, "a tree more than three folders above is not the tree");
    }

    // an empty serve/server.py is not a tree: the marker has to be the real module
    const fs::path empty = scratch("empty");
    fs::create_directories(empty / "serve", ec);
    fs::path marker = empty / "serve" / "server.py";
    fs::create_directories(empty / "bin", ec);
    { std::ofstream(marker).flush(); }
    check(tree_root(native(empty / "bin" / "basalt-engine"), built) == built, "an empty marker file does not make a tree");

    for (const fs::path& p : {installed, flat, lone, far, empty}) fs::remove_all(p, ec);
    return failures;
}
