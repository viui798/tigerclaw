#import <Cocoa/Cocoa.h>
#import "TigerClawKeyMap.hpp"

namespace tigerclaw::macos
{
    PhysicalKey KeyFromEvent(void* raw)
    {
        NSEvent* event = (__bridge NSEvent*)raw;
        PhysicalKey result;
        if (!event) return result;

        // US ANSI keyCode table (0..49). Explicit cases below cover the keys
        // whose slots are left empty here (section, return, tab, space).
        static const int letters[] = {
            'A','S','D','F','H','G','Z','X','C','V', 0, 'B','Q','W','E','R','Y','T',
            '1','2','3','4','6','5','=','9','7','-','8','0',']','O','U','[','I','P',
            0, 'L','J','\'','K',';','\\',',','/','N','M','.','`'
        };
        const auto code = static_cast<std::size_t>(event.keyCode);
        result.virtualKey = code < sizeof(letters) / sizeof(*letters) ? letters[code] : 0;
        switch (event.keyCode)
        {
            case 36: case 76: result.virtualKey = 13; break; // return / keypad enter
            case 48: result.virtualKey = 9; break;           // tab
            case 49: result.virtualKey = 32; break;          // space
            case 51: result.virtualKey = 8; break;           // delete
            case 117: result.virtualKey = 46; break;         // forward delete
            case 53: result.virtualKey = 27; break;          // escape
            case 123: result.virtualKey = 37; break;         // left
            case 124: result.virtualKey = 39; break;         // right
            case 125: result.virtualKey = 40; break;         // down
            case 126: result.virtualKey = 38; break;         // up
            case 115: result.virtualKey = 36; break;         // home
            case 119: result.virtualKey = 35; break;         // end
            case 116: result.virtualKey = 33; break;         // page up
            case 121: result.virtualKey = 34; break;         // page down
            // Windows OEM punctuation: the engine compares VK_OEM_1 (186)
            // etc., never the ASCII character code.
            case 41: result.virtualKey = 186; break;         // ; :
            case 39: result.virtualKey = 222; break;         // ' "
            case 43: result.virtualKey = 188; break;         // , <
            case 47: result.virtualKey = 190; break;         // . >
            case 44: result.virtualKey = 191; break;         // / ?
            case 27: result.virtualKey = 189; break;         // - _
            case 24: result.virtualKey = 187; break;         // = +
            case 33: result.virtualKey = 219; break;         // [ {
            case 30: result.virtualKey = 221; break;         // ] }
            case 42: result.virtualKey = 220; break;         // \ |
            case 50: result.virtualKey = 192; break;         // ` ~
            case 55: case 56: case 57: case 58: case 59:
            case 60: case 61: case 62: case 63:
                return result; // modifier keys keep virtualKey 0 / valid false
            default: break;
        }
        auto flags = event.modifierFlags;
        result.down = event.type == NSEventTypeKeyDown;
        result.repeat = event.isARepeat ? 2 : 1;
        result.shift = (flags & NSEventModifierFlagShift) != 0;
        result.ctrl = (flags & NSEventModifierFlagControl) != 0;
        result.alt = (flags & NSEventModifierFlagOption) != 0;
        result.command = (flags & NSEventModifierFlagCommand) != 0;
        result.capsLock = (flags & NSEventModifierFlagCapsLock) != 0;
        result.valid = result.virtualKey != 0;
        return result;
    }
}
