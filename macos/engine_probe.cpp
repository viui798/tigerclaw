// Headless acceptance probe for the macOS host wrapper.
// It exercises the same RuntimeInput path as the InputMethodKit controller
// without a GUI, so dictionary staging, schema switching and sentence decode
// can be verified in CI or from a terminal.
#include "TigerClawEngine.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <thread>

using tigerclaw::macos::Engine;
using tigerclaw::macos::KeyInput;
using tigerclaw::macos::Snapshot;

static std::string Utf8(std::u16string_view value)
{
    std::string result;
    for (char16_t unit : value)
    {
        std::uint32_t code = unit;
        if (code < 0x80) result.push_back(static_cast<char>(code));
        else if (code < 0x800)
        {
            result.push_back(static_cast<char>(0xc0 | (code >> 6)));
            result.push_back(static_cast<char>(0x80 | (code & 63)));
        }
        else
        {
            result.push_back(static_cast<char>(0xe0 | (code >> 12)));
            result.push_back(static_cast<char>(0x80 | ((code >> 6) & 63)));
            result.push_back(static_cast<char>(0x80 | (code & 63)));
        }
    }
    return result;
}

static void Print(const char* label, const Snapshot& snapshot)
{
    std::printf("%s schema=%s handled=%d composing=%d marked=%s commit=%s candidates=%zu",
        label, Utf8(snapshot.schema).c_str(), snapshot.handled, snapshot.composing,
        Utf8(snapshot.markedText).c_str(), Utf8(snapshot.commit).c_str(), snapshot.candidates.size());
    for (std::size_t i = 0; i < snapshot.candidates.size(); ++i)
        std::printf(" [%zu:%s]", i + 1, Utf8(snapshot.candidates[i].display).c_str());
    if (!snapshot.error.empty()) std::printf(" error=%s", snapshot.error.c_str());
    std::printf("\n");
}

static Snapshot Key(Engine& engine, int vk, bool shift = false)
{
    KeyInput input;
    input.virtualKey = vk;
    input.shift = shift;
    return engine.Process(input);
}

static int Fail(const char* message)
{
    std::fprintf(stderr, "FAIL: %s\n", message);
    return 1;
}

int main(int argc, char** argv)
{
    std::filesystem::path root = argc > 1 ? argv[1] : "/tmp/tigerclaw-macos-probe";
    std::filesystem::path resources = argc > 2 ? argv[2] :
        std::filesystem::path(__FILE__).parent_path() / "resources";
    std::filesystem::path model = argc > 3 ? argv[3] :
        "/Users/viui/Desktop/Tigirl macOS/build-macos/TigirlInputMethod.app/Contents/Resources/Models/sentence-fivegram-mobile.bin";

    if (std::getenv("TIGERCLAW_PROBE_RESET"))
    {
        std::error_code ignored;
        std::filesystem::remove_all(root, ignored);
    }

    tigerclaw::macos::Paths paths;
    paths.dataDirectory = root;
    paths.resourceDirectory = resources;
    paths.configFile = root / "config.txt";
    paths.lexiconRoot = root / "码表";
    paths.modelFile = model;

    Engine& engine = Engine::Shared();
    std::string error;
    auto started = std::chrono::steady_clock::now();
    if (!engine.Initialize(paths, error)) return Fail(error.c_str());
    auto loadMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    std::printf("initialized in %lldms schema=%s\n", static_cast<long long>(loadMs),
        Utf8(engine.CurrentSchema()).c_str());
    for (const auto& name : engine.SchemaNames()) std::printf("schema: %s\n", Utf8(name).c_str());

    auto result = Key(engine, 'U');
    Print("U", result);
    if (!result.handled || result.candidates.empty()) return Fail("ordinary candidate missing");
    if (result.candidates[0].commit != u"的") return Fail("first candidate for u is not 的");
    result = Key(engine, 32);
    Print("space", result);
    if (result.commit != u"的") return Fail("space did not commit 的");

    result = Key(engine, 'F');
    Print("F", result);
    result = Key(engine, 32);
    Print("space", result);
    if (result.commit != u"一") return Fail("space did not commit 一");

    if (!std::filesystem::exists(model))
    {
        std::printf("SKIP sentence checks: model not found at %s\n", model.c_str());
        std::printf("PASS\n");
        return 0;
    }
    if (!engine.SwitchSchema(u"虎整句", error)) return Fail(error.c_str());
    std::printf("switched schema=%s\n", Utf8(engine.CurrentSchema()).c_str());
    result = Key(engine, 'T');
    Print("T", result);
    bool found = false;
    for (int i = 0; i < 40; ++i)
    {
        result = engine.Capture();
        if (!result.candidates.empty()) { found = true; break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    Print("sentence", result);
    if (!found) return Fail("sentence candidates did not arrive");
    if (result.candidates[0].commit != u"我") return Fail("sentence first candidate for t is not 我");

    result = engine.SelectCandidate(0);
    Print("sentence select", result);
    if (result.commit != u"我") return Fail("sentence selection did not commit 我");

    std::printf("PASS\n");
    return 0;
}
