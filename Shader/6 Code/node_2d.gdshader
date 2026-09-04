shader_type canvas_item;

uniform float number_x:hint_range(0.0, 1.0);

void vertex() {
	
}

void fragment() {
	float test = ((1.-UV.x) + (1.-UV.y)) / 2.;
	COLOR.a *= step(number_x,test);
}

//void light() {
//	// Called for every pixel for every light affecting the CanvasItem.
//	// Uncomment to replace the default light processing function with this one.
//}
