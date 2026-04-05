#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

class QuantadsNativeProcessor : public RefCounted {
	GDCLASS(QuantadsNativeProcessor, RefCounted);

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("is_high_value_auction", "cpc"), &QuantadsNativeProcessor::is_high_value_auction);
	}

public:
	bool is_high_value_auction(double cpc) const {
		return cpc > 0.15;
	}
};

extern "C" {
GDExtensionBool GDE_EXPORT quantads_library_init(
	GDExtensionInterfaceGetProcAddress get_proc_address,
	GDExtensionClassLibraryPtr library,
	GDExtensionInitialization *initialization
) {
	GDExtensionBinding::InitObject init_obj(get_proc_address, library, initialization);
	init_obj.register_initializer([](ModuleInitializationLevel level) {
		if (level == MODULE_INITIALIZATION_LEVEL_SCENE) {
			ClassDB::register_class<QuantadsNativeProcessor>();
		}
	});
	init_obj.register_terminator([](ModuleInitializationLevel) {});
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
