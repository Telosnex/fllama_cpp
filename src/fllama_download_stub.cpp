// fllama_download_stub.cpp — replaces llama.cpp's remote downloads.
//
// fllama accepts local models and caller-provided media. Keep llama.cpp's
// CLI download code and HTTP library out of the native binary: the server
// context references these functions even though fllama does not use them.

#include "arg.h"
#include "download.h"
#include "cpp-httplib/httplib.h"

#include <stdexcept>
#include <type_traits>

// HTTP status 0: llama.cpp then rejects the URL.
std::pair<long, std::vector<char>>
common_remote_get_content(const std::string &, const common_remote_params &) {
  return {0, {}};
}

// A stub with another signature than download.h's is an overload, and it
// replaces nothing. The overloaded name then cannot be resolved here.
static_assert(std::is_same_v<decltype(&common_remote_get_content),
                             std::pair<long, std::vector<char>> (*)(
                                 const std::string &,
                                 const common_remote_params &)>);

// The server uses this for the name of a model downloaded by its CLI.
std::string common_get_default_local_path(const std::string &) {
  throw std::invalid_argument("fllama requires a local model path");
}

// The upstream resolver rejects a hostname with no addresses. No DNS query
// is needed: common_remote_get_content above rejects all HTTP URLs.
void httplib::hosted_at(const std::string &, std::vector<std::string> &addrs) {
  addrs.clear();
}
