class_name GlbMeta
## Reads the glTF JSON chunk of a .glb directly. Godot's importer does not
## keep glTF "extras", and those carry what the viewer reports: each
## building's construction year and the scene's RD New origin.

var nodes: Array = []          # glTF node dictionaries, in glTF index order
var origin_rd := Vector3.ZERO  # RD New (x east, y north, z up) at scene (0, 0, 0)
var ok := false


static func read(path: String) -> GlbMeta:
	var meta := GlbMeta.new()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_32() != 0x46546C67:
		return meta
	f.get_32()  # version
	f.get_32()  # total length
	var json_len := f.get_32()
	if f.get_32() != 0x4E4F534A:
		return meta
	var doc = JSON.parse_string(f.get_buffer(json_len).get_string_from_utf8())
	if typeof(doc) != TYPE_DICTIONARY:
		return meta
	meta.nodes = doc.get("nodes", [])
	var scenes: Array = doc.get("scenes", [])
	if not scenes.is_empty():
		var extras: Dictionary = scenes[0].get("extras", {})
		var o: Array = extras.get("origin_rd", [0, 0, 0])
		if o.size() == 3:
			meta.origin_rd = Vector3(float(o[0]), float(o[1]), float(o[2]))
	meta.ok = true
	return meta


func extras(index: int) -> Dictionary:
	if index < 0 or index >= nodes.size():
		return {}
	return nodes[index].get("extras", {})


func name_of(index: int) -> String:
	if index < 0 or index >= nodes.size():
		return ""
	return str(nodes[index].get("name", ""))


## Scene position (glTF Y-up, metres) -> RD New. Matches gltf.py's export:
## glTF +X = east, +Y = up, -Z = north.
func to_rd(p: Vector3) -> Vector3:
	return Vector3(origin_rd.x + p.x, origin_rd.y - p.z, origin_rd.z + p.y)
