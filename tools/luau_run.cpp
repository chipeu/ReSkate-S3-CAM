// A small Luau runner for the plugin's offline tests, built from ReSkate 2.1.2's own Luau source (External/luau), so the
// tests run the same compiler and VM the game does. It compiles text like the game (optimisation level 1), opens the
// standard libraries, and gives `require(name)` that loads <dir>/<name>.luau or .lua from the folders passed with -I.
// Usage: luau_run [-I dir]... script.lua [args...]   (args are in the global table `arg`, 1-based)
#include "lua.h"
#include "lualib.h"
#include "luacode.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static std::vector<std::string> search;

static bool read_file(const std::string& path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

static int load_chunk(lua_State* L, const std::string& source, const std::string& chunk) {
    lua_CompileOptions options{};
    options.optimizationLevel = 1;
    options.debugLevel = 1;
    size_t size = 0;
    char* bytecode = luau_compile(source.data(), source.size(), &options, &size);
    const int status = luau_load(L, chunk.c_str(), bytecode, size, 0);
    std::free(bytecode);
    return status;
}

static int require_module(lua_State* L) {
    const std::string name = luaL_checkstring(L, 1);
    lua_getfield(L, LUA_REGISTRYINDEX, "_MODULES");
    lua_getfield(L, -1, name.c_str());
    if (!lua_isnil(L, -1)) return 1;
    lua_pop(L, 1);
    std::string source, found;
    for (const auto& dir : search) {
        for (const char* ext : {".luau", ".lua"}) {
            const std::string path = dir + "/" + name + ext;
            if (read_file(path, source)) { found = path; break; }
        }
        if (!found.empty()) break;
    }
    if (found.empty()) luaL_error(L, "module '%s' not found", name.c_str());
    if (load_chunk(L, source, "@" + found) != 0) lua_error(L);
    lua_call(L, 0, 1);
    if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_pushboolean(L, 1); }
    lua_pushvalue(L, -1);
    lua_setfield(L, -3, name.c_str());
    return 1;
}

int main(int argc, char** argv) {
    int i = 1;
    for (; i + 1 < argc && std::string(argv[i]) == "-I"; i += 2) search.push_back(argv[i + 1]);
    if (i >= argc) {
        std::fprintf(stderr, "usage: luau_run [-I dir]... script.lua [args...]\n");
        return 2;
    }
    const std::string script = argv[i];
    const auto slash = script.find_last_of("/\\");
    search.insert(search.begin(), slash == std::string::npos ? std::string(".") : script.substr(0, slash));

    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    lua_newtable(L);
    lua_setfield(L, LUA_REGISTRYINDEX, "_MODULES");
    lua_pushcfunction(L, require_module, "require");
    lua_setglobal(L, "require");
    lua_newtable(L);
    for (int a = i + 1, n = 1; a < argc; ++a, ++n) {
        lua_pushstring(L, argv[a]);
        lua_rawseti(L, -2, n);
    }
    lua_setglobal(L, "arg");

    std::string source;
    if (!read_file(script, source)) {
        std::fprintf(stderr, "cannot read %s\n", script.c_str());
        return 2;
    }
    if (load_chunk(L, source, "@" + script) != 0) {
        std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 1;
    }
    if (lua_pcall(L, 0, 0, 0) != 0) {
        std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 1;
    }
    lua_close(L);
    return 0;
}
