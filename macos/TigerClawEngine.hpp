#pragma once
// macOS host wrapper around TigerClaw's portable input runtime.
//
// The Windows TSF layer (BimeTSF2) and the named-pipe Core are not used here.
// RuntimeLexicons owns the immutable lexicons/config snapshot and RuntimeInput
// owns the serialized composition, sentence decoder and learning receipts.
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace tiger::core
{
    class RuntimeLexicons;
    class RuntimeInput;
    struct PostProcessResult;
}

namespace tigerclaw::macos
{
    struct Paths
    {
        std::filesystem::path dataDirectory;    // writable: config, 码表, journals
        std::filesystem::path resourceDirectory; // app bundle Resources
        std::filesystem::path configFile;
        std::filesystem::path lexiconRoot;
        std::filesystem::path modelFile;
    };

    struct KeyInput
    {
        int virtualKey = 0;
        bool down = true;
        bool shift = false;
        bool ctrl = false;
        bool alt = false;
        bool command = false;
        bool capsLock = false;
        int repeat = 1;
    };

    struct Candidate
    {
        std::u16string display;
        std::u16string commit;
        bool selected = false;
    };

    struct Snapshot
    {
        bool ready = false;
        bool composing = false;
        bool handled = false;
        bool decodePending = false;
        bool isChinese = true;
        std::u16string schema;
        std::u16string markedText;
        std::u16string raw;
        std::u16string commit;
        std::u16string inputBuffer;
        int action = 0;                 // OutputAction: 0 text, 1 add word, 2 toggle candidates
        bool cancelBeforePass = false;
        std::vector<Candidate> candidates;
        std::size_t selected = 0;
        std::uint32_t pageIndex = 0;
        std::uint32_t pageCount = 1;
        std::uint32_t total = 0;
        int pageSize = 5;
        int fontSize = 24;
        bool showIndex = true;
        bool candidateLayoutVertical = true;
        std::string error;
    };

    class Engine
    {
    public:
        static Engine& Shared();

        bool Initialize(const Paths& paths, std::string& error);
        bool Ready() const { return _ready; }
        const std::string& LastError() const { return _error; }

        // Process returns the UI projection after the key. A host must call
        // Capture() on a short timer while composing so asynchronous sentence
        // decodes and neural reranking reach the candidate panel.
        Snapshot Process(const KeyInput& key);
        Snapshot Capture();
        Snapshot SelectCandidate(std::size_t index);
        Snapshot Cancel();
        Snapshot FocusChanged();

        bool SwitchSchema(std::u16string_view name, std::string& error);
        bool AddWord(std::u16string_view code, std::u16string_view text, std::string& error);
        bool Reload(std::string& error);
        std::vector<std::u16string> SchemaNames() const;
        std::u16string CurrentSchema() const;

        // Learning receipts: issue only for the exact result returned by the
        // last Process/SelectCandidate, acknowledge after the client edit.
        std::string IssueLearningReceipt(std::u16string client);
        void AcknowledgeLearningReceipt(std::u16string_view client, const std::string& token, bool success);
        void CancelLearningReceipt();

        const Paths& PathsForTesting() const { return _paths; }

    private:
        Engine() = default;
        Snapshot ApplyResult(const tiger::core::PostProcessResult& result);
        void RememberResult(const tiger::core::PostProcessResult& result);
        void LoadUiSettings();

        bool _ready = false;
        std::string _error;
        Paths _paths;
        std::unique_ptr<tiger::core::RuntimeLexicons> _runtime;
        std::unique_ptr<tiger::core::RuntimeInput> _input;
        std::shared_ptr<tiger::core::PostProcessResult> _lastResult;
        int _fontSize = 24;
        bool _showIndex = true;
        bool _layoutVertical = true;
    };
}
