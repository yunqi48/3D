class_name DialogueJson
extends RefCounted

## 与 Text/Text.json 现有排版一致的 JSON 读写：
## - 解析保留整数/浮点词法（内置 JSON.parse 会把 1 和 1.0 都变成 float）；
## - Dictionary 永远多行；
## - 数组若不含 Dictionary（如 set/if 的 [[...]]）保持单行；
## - 含 Dictionary 的数组（如 choices、顶层节点数组）多行。
## 这是“原样保存零 diff”和未知字段无损往返的基础。

static func read_file(path: String):
	if not FileAccess.file_exists(path):
		push_error("文件不存在: " + path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("无法打开文件: " + path)
		return null
	var text := f.get_as_text()
	f.close()
	return parse(text)

static func parse(text: String):
	var p := _Parser.new(text)
	var value = p.parse_document()
	if not p.ok:
		push_error("JSON 解析失败: " + p.message)
		return null
	return value

static func stringify_pretty(value) -> String:
	return _encode(value, 0)

static func save(path: String, data) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("无法保存文件: " + path)
		return false
	f.store_string(stringify_pretty(data) + "\n")
	f.close()
	return true

static func _encode(value, depth: int) -> String:
	if value is Dictionary:
		return _encode_dict(value, depth)
	if value is Array:
		return _encode_array(value, depth)
	return _encode_scalar(value)

static func _encode_scalar(value) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			return JSON.stringify(value, "", false, true)
		TYPE_STRING, TYPE_STRING_NAME:
			return JSON.stringify(str(value))
		_:
			return JSON.stringify(value)

static func _encode_dict(d: Dictionary, depth: int) -> String:
	if d.is_empty():
		return "{}"
	var pad := "\t".repeat(depth)
	var inner := "\t".repeat(depth + 1)
	var parts: Array[String] = []
	for k in d.keys():
		parts.append(inner + JSON.stringify(str(k), "", false, true) + ": " + _encode(d[k], depth + 1))
	return "{\n" + ",\n".join(parts) + "\n" + pad + "}"

static func _encode_array(a: Array, depth: int) -> String:
	if a.is_empty():
		return "[]"
	if _is_inline(a):
		var inline_parts: Array[String] = []
		for x in a:
			inline_parts.append(_encode(x, depth))
		return "[" + ", ".join(inline_parts) + "]"
	var pad := "\t".repeat(depth)
	var inner := "\t".repeat(depth + 1)
	var parts: Array[String] = []
	for x in a:
		parts.append(inner + _encode(x, depth + 1))
	return "[\n" + ",\n".join(parts) + "\n" + pad + "]"

static func _is_inline(a: Array) -> bool:
	for x in a:
		if x is Dictionary:
			return false
		if x is Array and not _is_inline(x):
			return false
	return true


## 递归下降 JSON 解析器：只为保留 number 词法（int vs float）。
class _Parser extends RefCounted:
	var s: String
	var i := 0
	var ok := true
	var message := ""

	func _init(text: String) -> void:
		s = text

	func _fail(msg: String) -> void:
		if ok:
			ok = false
			message = msg
		i = s.length()

	func _peek(ch: String) -> bool:
		return i < s.length() and s[i] == ch

	func _ws() -> void:
		while i < s.length():
			var c := s[i]
			if c == " " or c == "\t" or c == "\n" or c == "\r":
				i += 1
			else:
				return

	func parse_document():
		_ws()
		var v = _value()
		_ws()
		if ok and i < s.length():
			_fail("多余字符，位置 %d" % i)
		return v

	func _value():
		_ws()
		if i >= s.length():
			_fail("意外结束")
			return null
		var c := s[i]
		if c == "{":
			return _object()
		if c == "[":
			return _array()
		if c == "\"":
			return _string()
		if c == "t":
			return _literal("true", true)
		if c == "f":
			return _literal("false", false)
		if c == "n":
			return _literal("null", null)
		if c == "-" or (c >= "0" and c <= "9"):
			return _number()
		_fail("非法字符 %s，位置 %d" % [c, i])
		return null

	func _literal(token: String, value):
		if s.substr(i, token.length()) != token:
			_fail("非法字面量，位置 %d" % i)
			return null
		i += token.length()
		return value

	func _number():
		var start := i
		if _peek("-"):
			i += 1
		var int_digits := 0
		while i < s.length() and s[i] >= "0" and s[i] <= "9":
			i += 1
			int_digits += 1
		if int_digits == 0:
			_fail("数字缺少整数部分，位置 %d" % start)
			return null
		var is_float := false
		if _peek("."):
			is_float = true
			i += 1
			var frac_digits := 0
			while i < s.length() and s[i] >= "0" and s[i] <= "9":
				i += 1
				frac_digits += 1
			if frac_digits == 0:
				_fail("数字缺少小数部分，位置 %d" % start)
				return null
		if i < s.length() and (s[i] == "e" or s[i] == "E"):
			is_float = true
			i += 1
			if i < s.length() and (s[i] == "+" or s[i] == "-"):
				i += 1
			var exp_digits := 0
			while i < s.length() and s[i] >= "0" and s[i] <= "9":
				i += 1
				exp_digits += 1
			if exp_digits == 0:
				_fail("指数缺少数字，位置 %d" % start)
				return null
		var token := s.substr(start, i - start)
		return token.to_float() if is_float else token.to_int()

	func _string() -> String:
		i += 1  # 开引号
		var out := ""
		while i < s.length():
			var c := s[i]
			if c == "\"":
				i += 1
				return out
			if c == "\\":
				i += 1
				if i >= s.length():
					break
				var e := s[i]
				i += 1
				match e:
					"\"":
						out += "\""
					"\\":
						out += "\\"
					"/":
						out += "/"
					"b":
						out += String.chr(8)
					"f":
						out += String.chr(12)
					"n":
						out += "\n"
					"r":
						out += "\r"
					"t":
						out += "\t"
					"u":
						var code := _hex4()
						if not ok:
							return ""
						if code >= 0xD800 and code <= 0xDBFF:
							if i + 1 < s.length() and s[i] == "\\" and s[i + 1] == "u":
								i += 2
								var lo := _hex4()
								if not ok:
									return ""
								if lo >= 0xDC00 and lo <= 0xDFFF:
									code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
						out += String.chr(code)
					_:
						_fail("非法转义，位置 %d" % (i - 1))
						return ""
			else:
				out += c
				i += 1
		_fail("字符串未闭合")
		return ""

	func _hex4() -> int:
		if i + 4 > s.length():
			_fail("\\u 转义不完整")
			return 0
		var v := 0
		for _k in range(4):
			var d := "0123456789abcdef".find(s[i].to_lower())
			if d < 0:
				_fail("\\u 转义含非法十六进制字符")
				return 0
			v = v * 16 + d
			i += 1
		return v

	func _array() -> Array:
		i += 1  # [
		var out: Array = []
		_ws()
		if _peek("]"):
			i += 1
			return out
		while ok:
			out.append(_value())
			if not ok:
				return out
			_ws()
			if _peek(","):
				i += 1
				_ws()
				continue
			if _peek("]"):
				i += 1
				return out
			_fail("数组缺少 , 或 ]，位置 %d" % i)
			return out
		return out

	func _object() -> Dictionary:
		i += 1  # {
		var out: Dictionary = {}
		_ws()
		if _peek("}"):
			i += 1
			return out
		while ok:
			_ws()
			if not _peek("\""):
				_fail("对象键必须是字符串，位置 %d" % i)
				return out
			var k := _string()
			if not ok:
				return out
			_ws()
			if not _peek(":"):
				_fail("对象缺少 :，位置 %d" % i)
				return out
			i += 1
			var v = _value()
			if not ok:
				return out
			out[k] = v
			_ws()
			if _peek(","):
				i += 1
				continue
			if _peek("}"):
				i += 1
				return out
			_fail("对象缺少 , 或 }，位置 %d" % i)
			return out
		return out
