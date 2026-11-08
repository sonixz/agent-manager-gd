#include "vt_terminal.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
	GDREGISTER_CLASS(VtTerminal);
}

static void uninitialize(ModuleInitializationLevel) {}

extern "C" GDExtensionBool GDE_EXPORT vtterm_init(GDExtensionInterfaceGetProcAddress get_proc, GDExtensionClassLibraryPtr lib, GDExtensionInitialization *init) {
	GDExtensionBinding::InitObject obj(get_proc, lib, init);
	obj.register_initializer(initialize);
	obj.register_terminator(uninitialize);
	obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return obj.init();
}
