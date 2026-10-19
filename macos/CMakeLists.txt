cmake_minimum_required(VERSION 3.25)
project(TigerClawMacOS LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

if(NOT APPLE)
  message(FATAL_ERROR "This target requires macOS and InputMethodKit")
endif()

set(TIGERCLAW_ROOT "${CMAKE_CURRENT_LIST_DIR}")
set(CORE "${TIGERCLAW_ROOT}/../next/TigerClaw.Core.Native")
set(CORE_DATA "${TIGERCLAW_ROOT}/../next/TigerClaw.Core/Data")
set(TIGERCLAW_DICTIONARY_ROOT "${TIGERCLAW_ROOT}/resources/码表" CACHE PATH "Bundled 虎码 dictionaries")
set(TIGERCLAW_SENTENCE_MODEL "$ENV{TIGERCLAW_SENTENCE_MODEL}" CACHE FILEPATH "TCSKNM03 fivegram model")
if(NOT TIGERCLAW_SENTENCE_MODEL)
  set(TIGERCLAW_SENTENCE_MODEL "${TIGERCLAW_ROOT}/../Models/sentence-fivegram-mobile.bin")
endif()

# The portable core is the same source set the Windows native Core builds.
# Windows-only runtime pieces (named pipes, TSF hosting, UI publisher) are not
# part of this target; the InputMethodKit adapter replaces them.
set(TIGERCLAW_CORE_SOURCES
  ${CORE}/CompactLexicon.cpp
  ${CORE}/KeyRequestReplayCache.cpp
  ${CORE}/LexiconText.cpp
  ${CORE}/LexiconFile.cpp
  ${CORE}/CodeCase.cpp
  ${CORE}/LexiconAssembly.cpp
  ${CORE}/LexiconOrder.cpp
  ${CORE}/TextElements.cpp
  ${CORE}/WordConstruction.cpp
  ${CORE}/SchemaLexicon.cpp
  ${CORE}/LexiconMetadata.cpp
  ${CORE}/PinyinLexicon.cpp
  ${CORE}/ConfigParser.cpp
  ${CORE}/RuntimePaths.cpp
  ${CORE}/RuntimeLexicons.cpp
  ${CORE}/RuntimeAdjustments.cpp
  ${CORE}/RecentSchemas.cpp
  ${CORE}/CandidatePage.cpp
  ${CORE}/OutputActions.cpp
  ${CORE}/OutputServices.cpp
  ${CORE}/OutputState.cpp
  ${CORE}/SendHistory.cpp
  ${CORE}/KeyPostProcessor.cpp
  ${CORE}/Punctuation.cpp
  ${CORE}/SelectionKeys.cpp
  ${CORE}/SelectionConfig.cpp
  ${CORE}/OrdinaryComposition.cpp
  ${CORE}/PinyinComposition.cpp
  ${CORE}/CandidateSymbolTransition.cpp
  ${CORE}/ChineseComposition.cpp
  ${CORE}/MixedInputDecoder.cpp
  ${CORE}/ActionShortcuts.cpp
  ${CORE}/ShortcutConfig.cpp
  ${CORE}/InputSettings.cpp
  ${CORE}/ReadOnlyMapping.cpp
  ${CORE}/SentenceFivegramModel.cpp
  ${CORE}/SentenceSupplementFile.cpp
  ${CORE}/UpperCaseComposition.cpp
  ${CORE}/UpperCaseNumeric.cpp
  ${CORE}/UpperCaseCurrency.cpp
)

# Embedded tables generated from the shared Core data, exactly like the
# Windows CMake target. They are compiled into every host, not read at runtime.
file(READ "${CORE_DATA}/sentence_char_ranks.txt" SENTENCE_RANK_HEX HEX)
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," SENTENCE_RANK_BYTES "${SENTENCE_RANK_HEX}")
configure_file("${CORE}/SentenceCharacterRanks.cpp.in"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/SentenceCharacterRanks.cpp" @ONLY)
file(READ "${CORE_DATA}/sentence_lexical.bin" SENTENCE_LEXICAL_HEX HEX)
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," SENTENCE_LEXICAL_BYTES "${SENTENCE_LEXICAL_HEX}")
configure_file("${CORE}/SentenceLexicalPrior.cpp.in"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/SentenceLexicalPrior.cpp" @ONLY)

add_library(tigerclaw_core STATIC ${TIGERCLAW_CORE_SOURCES}
  "${CMAKE_CURRENT_BINARY_DIR}/generated/SentenceCharacterRanks.cpp"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/SentenceLexicalPrior.cpp")
target_include_directories(tigerclaw_core PUBLIC ${CORE} ${CMAKE_CURRENT_BINARY_DIR}/generated)
target_compile_definitions(tigerclaw_core PUBLIC TIGERCLAW_MACOS=1)
target_compile_options(tigerclaw_core PRIVATE -Wall -Wextra -Wpedantic
  "-include" "${TIGERCLAW_ROOT}/compat/stop_token")
target_link_libraries(tigerclaw_core PUBLIC "-framework Foundation")

add_executable(TigerClawInputMethod
  TigerClawInputMethod.mm
  TigerClawInputController.mm
  TigerClawCandidateWindow.mm
  TigerClawKeyMap.mm
  TigerClawEngine.cpp
)
target_include_directories(TigerClawInputMethod PRIVATE ${CORE} ${TIGERCLAW_ROOT})
target_compile_options(TigerClawInputMethod PRIVATE
  "-include" "${TIGERCLAW_ROOT}/compat/stop_token")
target_link_libraries(TigerClawInputMethod PRIVATE tigerclaw_core
  "-framework InputMethodKit"
  "-framework Cocoa"
  "-framework Carbon"
  "-framework ApplicationServices"
)
set_target_properties(TigerClawInputMethod PROPERTIES
  MACOSX_BUNDLE TRUE
  BUNDLE_EXTENSION app
  OUTPUT_NAME TigerClaw
  MACOSX_BUNDLE_INFO_PLIST "${TIGERCLAW_ROOT}/Info.plist"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER com.viui.inputmethod.TigerClaw
  XCODE_ATTRIBUTE_PRODUCT_NAME TigerClaw
)

# Headless acceptance probe: same RuntimeInput path as the IME controller.
add_executable(tigerclaw_engine_probe engine_probe.cpp TigerClawEngine.cpp)
target_include_directories(tigerclaw_engine_probe PRIVATE ${CORE} ${TIGERCLAW_ROOT})
target_compile_options(tigerclaw_engine_probe PRIVATE
  "-include" "${TIGERCLAW_ROOT}/compat/stop_token")
target_link_libraries(tigerclaw_engine_probe PRIVATE tigerclaw_core)

# Bundle payload. Model is 405 MB; copy_if_different keeps rebuilds cheap.
set(BUNDLE_CONTENT "$<TARGET_BUNDLE_CONTENT_DIR:TigerClawInputMethod>")
add_custom_command(TARGET TigerClawInputMethod POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${BUNDLE_CONTENT}/Resources"
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    "${TIGERCLAW_DICTIONARY_ROOT}" "${BUNDLE_CONTENT}/Resources/码表"
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    "${TIGERCLAW_ROOT}/resources/拼音反查码表" "${BUNDLE_CONTENT}/Resources/拼音反查码表"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${TIGERCLAW_ROOT}/TigerClaw.pdf" "${BUNDLE_CONTENT}/Resources/TigerClaw.pdf"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${TIGERCLAW_ROOT}/TigerClaw.icns" "${BUNDLE_CONTENT}/Resources/TigerClaw.icns"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${BUNDLE_CONTENT}/Resources/zh-Hans.lproj"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${TIGERCLAW_ROOT}/zh-Hans.lproj/InfoPlist.strings" "${BUNDLE_CONTENT}/Resources/zh-Hans.lproj/InfoPlist.strings"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${BUNDLE_CONTENT}/Resources/en.lproj"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${TIGERCLAW_ROOT}/en.lproj/InfoPlist.strings" "${BUNDLE_CONTENT}/Resources/en.lproj/InfoPlist.strings"
)
if(EXISTS "${TIGERCLAW_SENTENCE_MODEL}")
  add_custom_command(TARGET TigerClawInputMethod POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${BUNDLE_CONTENT}/Resources/Models"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${TIGERCLAW_SENTENCE_MODEL}" "${BUNDLE_CONTENT}/Resources/Models/sentence-fivegram-mobile.bin")
else()
  message(WARNING "TIGERCLAW_SENTENCE_MODEL not found: ${TIGERCLAW_SENTENCE_MODEL}. "
                  "虎整句 will fall back to the ordinary table.")
endif()

include(CTest)
if(BUILD_TESTING)
  add_test(NAME tigerclaw_engine
    COMMAND tigerclaw_engine_probe
      "${CMAKE_CURRENT_BINARY_DIR}/probe-data"
      "${TIGERCLAW_DICTIONARY_ROOT}/.."
      "${TIGERCLAW_SENTENCE_MODEL}")
  set_tests_properties(tigerclaw_engine PROPERTIES TIMEOUT 120
    ENVIRONMENT "TIGERCLAW_PROBE_RESET=1")
endif()

install(TARGETS TigerClawInputMethod
  BUNDLE DESTINATION "Library/Input Methods"
  LIBRARY DESTINATION "Library/Input Methods")
