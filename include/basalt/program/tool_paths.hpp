#pragma once

#include <string>

namespace basalt::program {

// The engine binary a run of this tool starts when the command line names none: the basalt installed beside this
// program (the release folder and the source tree's bin both put them together), else the path the build baked in.
std::string default_engine_bin(const std::string& built);

// The fixture folder a run of this tool reads when the command line names none: the data/bench of the tree this
// program is installed in (a release folder, or the checkout it was built from), else the path the build baked in,
// else the working directory's data/bench.
std::string default_fixtures_dir(const std::string& built);

}  // namespace basalt::program
