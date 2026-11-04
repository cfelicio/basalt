// Where basalt-bench and basalt-probe find the engine and the fixtures when the command line names none. A release
// build bakes the build machine's paths in, and a user unpacks the release somewhere else: the installed tree beside
// this program answers first, the baked paths serve a build running where it was built.
#include "basalt/program/tool_paths.hpp"

#include <filesystem>
#include <system_error>

#include "basalt/platform/file.hpp"
#include "basalt/platform/system.hpp"

namespace basalt::program {

namespace fs = std::filesystem;

std::string default_engine_bin(const std::string& built) {
    const std::string exe = basalt::platform::module_path();
    if (!exe.empty()) {
        const fs::path dir = fs::path(exe).parent_path();
        for (const char* name : {"basalt", "basalt.exe"}) {
            std::error_code ec;
            if (fs::exists(dir / name, ec)) return (dir / name).string();
        }
    }
    return built;
}

std::string default_fixtures_dir(const std::string& built) {
    const std::string exe = basalt::platform::module_path();
    if (!exe.empty()) {
        const std::string tree = basalt::platform::tree_root(exe, "");
        if (!tree.empty()) {
            const fs::path bench = fs::path(tree) / "data" / "bench";
            std::error_code ec;
            if (fs::exists(bench / "conv.ids", ec)) return bench.string();
        }
    }
    std::error_code ec;
    if (!built.empty() && fs::exists(fs::path(built) / "conv.ids", ec)) return built;
    if (fs::exists(fs::path("data") / "bench" / "conv.ids", ec)) return "data/bench";
    return built;   // nothing found: the error names the path the build was configured with
}

}  // namespace basalt::program
