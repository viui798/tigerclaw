#include "TigerClawEngine.hpp"

#include "RuntimeInput.h"
#include "RuntimeLexicons.h"
#include "RuntimePaths.h"
#include "UpperCaseComposition.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <exception>
#include <cstdio>
#include <stdexcept>
#include <system_error>

namespace tigerclaw::macos
{
    namespace
    {
        constexpr auto ConfigFileKey = u"当前码表";

        std::string Utf8(std::u16string_view value)
        {
            std::string result;
            result.reserve(value.size());
            for (char16_t unit : value)
            {
                std::uint32_t code = unit;
                if (code >= 0xd800 && code <= 0xdbff)
                {
                    // The callers only need keys/names; combine surrogate pairs.
                    // (This engine receives UTF-16 from IMK; malformed tails are
                    // replaced rather than throwing.)
                    code = 0xfffd;
                }
                if (code < 0x80) result.push_back(static_cast<char>(code));
                else if (code < 0x800)
                {
                    result.push_back(static_cast<char>(0xc0 | (code >> 6)));
                    result.push_back(static_cast<char>(0x80 | (code & 63)));
                }
                else if (code < 0x10000)
                {
                    result.push_back(static_cast<char>(0xe0 | (code >> 12)));
                    result.push_back(static_cast<char>(0x80 | ((code >> 6) & 63)));
                    result.push_back(static_cast<char>(0x80 | (code & 63)));
                }
                else
                {
                    result.push_back(static_cast<char>(0xf0 | (code >> 18)));
                    result.push_back(static_cast<char>(0x80 | ((code >> 12) & 63)));
                    result.push_back(static_cast<char>(0x80 | ((code >> 6) & 63)));
                    result.push_back(static_cast<char>(0x80 | (code & 63)));
                }
            }
            return result;
        }

        bool ParseBool(std::u16string_view value, bool fallback)
        {
            if (value == u"是" || value == u"true" || value == u"1") return true;
            if (value == u"否" || value == u"false" || value == u"0") return false;
            return fallback;
        }

        int ParseInt(std::u16string_view value, int fallback)
        {
            try { return std::stoi(Utf8(value)); }
            catch (...) { return fallback; }
        }

        void CopyTree(const std::filesystem::path& source, const std::filesystem::path& target, std::string& error)
        {
            std::error_code code;
            if (!std::filesystem::exists(source, code))
            {
                error = "Missing bundled resource: " + source.string();
                return;
            }
            std::filesystem::create_directories(target.parent_path(), code);
            std::filesystem::copy(source, target,
                std::filesystem::copy_options::recursive | std::filesystem::copy_options::overwrite_existing, code);
            if (code) error = "Cannot copy " + source.string() + ": " + code.message();
        }

        std::u16string ConfigValue(const tiger::core::ConfigValues& config, std::u16string_view key,
            std::u16string fallback = {})
        {
            for (const auto& [name, value] : config)
                if (name == key) return value;
            return fallback;
        }
    }

    Engine& Engine::Shared()
    {
        static Engine engine;
        return engine;
    }

    bool Engine::Initialize(const Paths& paths, std::string& error)
    {
        if (_ready) return true;
        _paths = paths;
        _error.clear();
        try
        {
            std::error_code code;
            std::filesystem::create_directories(_paths.dataDirectory, code);
            if (code) throw std::runtime_error("Cannot create data directory: " + code.message());

            // First run: stage the bundled Tiger-code dictionaries into the
            // writable data directory so user adjustments and learning journals
            // can be written beside them.
            auto bundledLexicons = _paths.resourceDirectory / u"码表";
            if (!std::filesystem::is_directory(_paths.lexiconRoot, code))
            {
                CopyTree(bundledLexicons, _paths.lexiconRoot, error);
                if (!error.empty()) throw std::runtime_error(error);
            }
            // Pinyin reverse lookup is optional on this port. An empty table is
            // a valid runtime state; copy it when a deployment provides one.
            auto bundledPinyin = _paths.resourceDirectory / u"拼音反查码表";
            if (std::filesystem::is_directory(bundledPinyin, code) &&
                !std::filesystem::is_directory(_paths.dataDirectory / u"拼音反查码表", code))
                CopyTree(bundledPinyin, _paths.dataDirectory / u"拼音反查码表", error);

            bool firstRun = !std::filesystem::exists(_paths.configFile);
            _runtime = std::make_unique<tiger::core::RuntimeLexicons>(_paths.dataDirectory);
            _runtime->Initialize(_paths.configFile);

            auto current = _runtime->Read();
            bool save = false;
            bool changed = false;
            std::u16string configError;
            if (ConfigValue(current->config, u"码表存储位置").empty())
            {
                _runtime->SetConfig(u"码表存储位置", u"码表", changed, configError);
                save = true;
            }
            if (firstRun || ConfigValue(current->config, u"当前码表").empty())
            {
                if (!_runtime->SetConfig(u"当前码表", u"虎码字词", changed, configError))
                    throw std::runtime_error("Cannot select the default schema: " + Utf8(configError));
                save = true;
            }
            if (save) _runtime->SaveConfig(_paths.configFile);

            auto upper = tiger::core::MakeUpperCaseServices([](std::u16string_view) {
                // The manual timer command is not implemented in this host. The
                // engine still honours currency conversion in UpperCaseNumeric.
            });
            _input = std::make_unique<tiger::core::RuntimeInput>(*_runtime, std::move(upper),
                _paths.modelFile,
                static_cast<tiger::core::SentenceServiceLifecycle*>(nullptr), true);
            LoadUiSettings();
            _ready = true;
            return true;
        }
        catch (const std::exception& failure)
        {
            _error = failure.what();
            _input.reset();
            _runtime.reset();
        }
        catch (...)
        {
            _error = "Unknown engine initialization failure";
            _input.reset();
            _runtime.reset();
        }
        error = _error;
        return false;
    }

    void Engine::LoadUiSettings()
    {
        if (!_input) return;
        _fontSize = std::clamp(ParseInt(_input->ConfigValue(u"字体大小", u"24"), 24), 10, 64);
        _showIndex = ParseBool(_input->ConfigValue(u"显示候选序号", u"是"), true);
        auto layout = _input->ConfigValue(u"候选布局", u"4");
        _layoutVertical = layout == u"2" || layout == u"4";
    }

    void Engine::RememberResult(const tiger::core::PostProcessResult& result)
    {
        _lastResult = std::make_shared<tiger::core::PostProcessResult>(result);
    }

    Snapshot Engine::ApplyResult(const tiger::core::PostProcessResult& result)
    {
        Snapshot snapshot;
        snapshot.ready = true;
        snapshot.handled = result.handled;
        snapshot.commit = result.text;
        snapshot.inputBuffer = result.inputBuffer;
        snapshot.action = static_cast<int>(result.action);
        snapshot.cancelBeforePass = result.cancelCompositionBeforePass;
        snapshot.fontSize = _fontSize;
        snapshot.showIndex = _showIndex;
        snapshot.candidateLayoutVertical = _layoutVertical;
        try
        {
            auto state = _input->CaptureSnapshot();
            snapshot.composing = state.composing;
            snapshot.decodePending = state.decodePending;
            snapshot.isChinese = state.isChinese;
            snapshot.schema = state.schemaName;
            snapshot.raw = state.raw;
            snapshot.markedText = state.displayCode.empty() ? state.raw : state.displayCode;
            if (!state.composing) snapshot.markedText.clear();
            snapshot.pageIndex = state.page.pageIndex;
            snapshot.pageSize = std::max(1, state.pageSize);
            snapshot.total = state.page.total;
            snapshot.pageCount = (state.page.total + snapshot.pageSize - 1) / snapshot.pageSize;
            if (snapshot.pageCount == 0) snapshot.pageCount = 1;
            auto base = static_cast<std::size_t>(state.page.pageIndex) * static_cast<std::size_t>(snapshot.pageSize);
            snapshot.selected = state.selectedCandidateIndex >= base ? state.selectedCandidateIndex - base : 0;
            snapshot.candidates.reserve(state.page.entries.size());
            for (std::size_t i = 0; i < state.page.entries.size(); ++i)
            {
                Candidate candidate;
                candidate.commit = state.page.entries[i];
                try { candidate.display = _input->CandidateDisplay(candidate.commit); }
                catch (...) { candidate.display = candidate.commit; }
                candidate.selected = base + i == state.selectedCandidateIndex;
                snapshot.candidates.push_back(std::move(candidate));
            }
            if (snapshot.candidates.empty()) snapshot.selected = 0;
        }
        catch (const std::exception& failure)
        {
            snapshot.error = failure.what();
            snapshot.composing = false;
        }
        catch (...)
        {
            snapshot.error = "Unknown UI projection failure";
            snapshot.composing = false;
        }
        return snapshot;
    }

    Snapshot Engine::Process(const KeyInput& key)
    {
        Snapshot snapshot;
        snapshot.ready = _ready;
        snapshot.fontSize = _fontSize;
        snapshot.showIndex = _showIndex;
        snapshot.candidateLayoutVertical = _layoutVertical;
        if (!_ready || !_input)
        {
            snapshot.error = _error.empty() ? "Engine is not ready" : _error;
            return snapshot;
        }
        try
        {
            tiger::core::InputKeyEvent event;
            event.vk = key.virtualKey;
            event.scan = 0;
            event.repeat = std::max(1, key.repeat);
            event.action = key.down ? u"down" : u"up";
            event.shift = key.shift;
            event.ctrl = key.ctrl;
            event.alt = key.alt;
            event.win = key.command;
            event.capsLock = key.capsLock;
            auto result = _input->Process(event, std::chrono::system_clock::now());
            RememberResult(result);
            return ApplyResult(result);
        }
        catch (const std::exception& failure)
        {
            _error = failure.what();
            snapshot.error = _error;
            return snapshot;
        }
        catch (...)
        {
            _error = "Unknown key processing failure";
            snapshot.error = _error;
            return snapshot;
        }
    }

    Snapshot Engine::Capture()
    {
        Snapshot snapshot;
        snapshot.ready = _ready;
        snapshot.fontSize = _fontSize;
        snapshot.showIndex = _showIndex;
        snapshot.candidateLayoutVertical = _layoutVertical;
        if (!_ready || !_input)
        {
            snapshot.error = _error.empty() ? "Engine is not ready" : _error;
            return snapshot;
        }
        try
        {
            tiger::core::PostProcessResult empty;
            return ApplyResult(empty);
        }
        catch (const std::exception& failure)
        {
            snapshot.error = failure.what();
            return snapshot;
        }
    }

    Snapshot Engine::SelectCandidate(std::size_t index)
    {
        Snapshot snapshot;
        snapshot.ready = _ready;
        snapshot.fontSize = _fontSize;
        snapshot.showIndex = _showIndex;
        snapshot.candidateLayoutVertical = _layoutVertical;
        if (!_ready || !_input)
        {
            snapshot.error = _error.empty() ? "Engine is not ready" : _error;
            return snapshot;
        }
        try
        {
            if (auto selected = _input->SelectSentenceCandidate(index))
            {
                RememberResult(*selected);
                return ApplyResult(*selected);
            }
            // Ordinary tables select through the configured number keys. Use
            // the same virtual-key path so all output bookkeeping stays in one
            // place; page-relative index 9 addresses the tenth entry as '0'.
            if (index >= 10)
            {
                snapshot.error = "Candidate index is out of range";
                return snapshot;
            }
            KeyInput key;
            key.virtualKey = index == 9 ? 0x30 : static_cast<int>(0x31 + index);
            key.down = true;
            return Process(key);
        }
        catch (const std::exception& failure)
        {
            _error = failure.what();
            snapshot.error = _error;
            return snapshot;
        }
    }

    Snapshot Engine::Cancel()
    {
        if (!_input) return Capture();
        _input->Cancel();
        _lastResult.reset();
        return Capture();
    }

    Snapshot Engine::FocusChanged()
    {
        if (!_input) return Capture();
        _input->FocusChanged();
        return Capture();
    }

    bool Engine::SwitchSchema(std::u16string_view name, std::string& error)
    {
        error.clear();
        if (!_ready || !_input)
        {
            error = "Engine is not ready";
            return false;
        }
        try
        {
            bool changed = false;
            std::u16string configError;
            if (!_input->SetConfig(ConfigFileKey, name, changed, configError))
            {
                error = Utf8(configError);
                return false;
            }
            _runtime->SaveConfig(_paths.configFile);
            _lastResult.reset();
            LoadUiSettings();
            return true;
        }
        catch (const std::exception& failure)
        {
            error = failure.what();
            return false;
        }
    }

    bool Engine::AddWord(std::u16string_view code, std::u16string_view text, std::string& error)
    {
        error.clear();
        if (!_ready || !_input)
        {
            error = "Engine is not ready";
            return false;
        }
        try
        {
            if (!_input->AddWord(code, text))
            {
                error = "The code or word is empty";
                return false;
            }
            _lastResult.reset();
            return true;
        }
        catch (const std::exception& failure)
        {
            error = failure.what();
            return false;
        }
    }

    bool Engine::Reload(std::string& error)
    {
        error.clear();
        if (!_ready || !_input)
        {
            error = "Engine is not ready";
            return false;
        }
        try
        {
            _input->Reload(_paths.configFile);
            _lastResult.reset();
            LoadUiSettings();
            return true;
        }
        catch (const std::exception& failure)
        {
            error = failure.what();
            return false;
        }
    }

    std::vector<std::u16string> Engine::SchemaNames() const
    {
        if (!_runtime) return {};
        auto snapshot = _runtime->Read();
        if (!snapshot) return {};
        return tiger::core::GetSchemaNames(snapshot->root);
    }

    std::u16string Engine::CurrentSchema() const
    {
        if (!_input) return {};
        return _input->SchemaName();
    }

    std::string Engine::IssueLearningReceipt(std::u16string client)
    {
        if (!_input || !_lastResult) return {};
        try { return _input->IssueLearningReceipt(std::move(client), *_lastResult); }
        catch (...) { return {}; }
    }

    void Engine::AcknowledgeLearningReceipt(std::u16string_view client, const std::string& token, bool success)
    {
        if (!_input || token.empty()) return;
        try { _input->AcknowledgeLearningReceipt(client, token, success); }
        catch (...) {}
    }

    void Engine::CancelLearningReceipt()
    {
        if (_input) _input->CancelLearningReceipts();
    }
}
