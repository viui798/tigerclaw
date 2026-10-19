#pragma once
#include <cstdint>

namespace tigerclaw::macos
{
    struct PhysicalKey
    {
        int virtualKey = 0;     // Windows virtual-key code expected by the engine
        int scanCode = 0;
        bool down = true;
        bool shift = false;
        bool ctrl = false;
        bool alt = false;
        bool command = false;
        bool capsLock = false;
        int repeat = 1;
        bool valid = false;
    };

    // Converts an NSEvent key event to the Windows virtual-key space used by
    // TigerClaw's composition engine. The table is the complete US ANSI map;
    // missing slots would shift every later key.
    PhysicalKey KeyFromEvent(void* event);

    // Same mapping for IMK's inputText:key:modifiers:client: entry point, which
    // supplies a hardware keyCode and NSEventModifierFlags but no NSEvent.
    PhysicalKey KeyFromKeyCode(unsigned short keyCode, unsigned long modifierFlags,
        bool down = true, bool repeat = false);
}
