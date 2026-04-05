extends RefCounted

var _native_processor: Object = null

func _init():
	if ClassDB.class_exists("QuantadsNativeProcessor"):
		_native_processor = ClassDB.instantiate("QuantadsNativeProcessor")

func is_high_value_auction(cpc: float) -> bool:
	if _native_processor and _native_processor.has_method("is_high_value_auction"):
		return _native_processor.is_high_value_auction(cpc)
	return cpc > 0.15
