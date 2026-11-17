extends SceneTree

const TESTS := [
	"res://tests/test_graph_model.gd",
	"res://tests/test_validator.gd",
	"res://tests/test_auto_layout.gd",
	"res://tests/test_json_io.gd",
]

var _checks := 0
var _failures := 0

func _initialize() -> void:
	for path in TESTS:
		var script: GDScript = load(path)
		if script == null or not script.can_instantiate():
			printerr("无法加载测试: ", path)
			_failures += 1
			continue
		print("== ", path)
		var test = script.new()
		test.run(self)
	print("checks=%d failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("ALL TESTS PASSED")
		quit(0)
	else:
		printerr("TESTS FAILED")
		quit(1)

func expect(actual, expected, msg: String) -> void:
	_checks += 1
	if typeof(actual) != typeof(expected) or actual != expected:
		_failures += 1
		printerr("FAIL: %s (expected=%s actual=%s)" % [msg, str(expected), str(actual)])

func expect_true(cond: bool, msg: String) -> void:
	expect(cond, true, msg)

func expect_false(cond: bool, msg: String) -> void:
	expect(cond, false, msg)

func expect_has_issue(issues: Array, code: String, msg: String) -> void:
	var found := false
	for it in issues:
		if it.get("code", "") == code:
			found = true
			break
	expect_true(found, msg)
