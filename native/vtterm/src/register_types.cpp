#include "vt_terminal.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/classes/font_file.hpp>
#include <godot_cpp/classes/font_variation.hpp>
#include <godot_cpp/classes/system_font.hpp>

using namespace godot;

static void initialize(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
	// clang (the Windows build uses zig) only emits an engine class's binding registration where the class is used in
	// a certain way; register the font classes a theme hands us explicitly, or passing one fails on Windows.
	internal::EngineClassRegistration<FontFile>::callback();
	internal::EngineClassRegistration<SystemFont>::callback();
	internal::EngineClassRegistration<FontVariation>::callback();
	GDREGISTER_CLASS(VtTerminal);
}

static void uninitialize(ModuleInitializationLevel) {}

extern "C" GDExtensionBool GDE_EXPORT vtterm_init(GDExtensionInterfaceGetProcAddress get_proc, GDExtensionClassLibraryPtr lib, GDExtensionInitialization *init) {
	GDExtensionBinding::InitObject obj(get_proc, lib, init);
	obj.register_initializer(initialize);
	obj.register_terminator(uninitialize);
	obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_CORE);  // engine class bindings (FontFile…) from the start
	return obj.init();
}
