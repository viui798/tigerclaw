#pragma once
// Portable replacement for std::atomic<std::shared_ptr<T>>.
// Apple libc++ (Xcode 16) does not provide the C++20 shared_ptr atomic
// specialization, while the MSVC standard library used by the Windows build
// does. Mutex-protected shared_ptr load/store gives identical publication
// semantics for the few snapshot hand-off sites in this code base.
#include <atomic>
#include <memory>
#include <mutex>
#include <utility>

namespace tiger::core
{
    template <class T>
    class AtomicSharedPtr
    {
        mutable std::mutex _mutex;
        std::shared_ptr<T> _value;
    public:
        AtomicSharedPtr() = default;
        explicit AtomicSharedPtr(std::shared_ptr<T> value) : _value(std::move(value)) {}
        std::shared_ptr<T> load(std::memory_order = std::memory_order_seq_cst) const
        {
            std::lock_guard<std::mutex> guard(_mutex);
            return _value;
        }
        void store(std::shared_ptr<T> value, std::memory_order = std::memory_order_seq_cst)
        {
            std::lock_guard<std::mutex> guard(_mutex);
            _value = std::move(value);
        }
        std::shared_ptr<T> exchange(std::shared_ptr<T> value, std::memory_order = std::memory_order_seq_cst)
        {
            std::lock_guard<std::mutex> guard(_mutex);
            _value.swap(value);
            return value;
        }
        AtomicSharedPtr& operator=(std::shared_ptr<T> value)
        {
            store(std::move(value));
            return *this;
        }
    };
}
