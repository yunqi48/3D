shader_type canvas_item;
render_mode unshaded;

// 注意：本 shader 挂在 CanvasGroup 上。
// CanvasGroup 会把子节点先画进一块后缓冲(backbuffer)，再由自身内置 shader 合成。
// 挂自定义材质会替换内置 shader，此时 TEXTURE 是"空的" → 采样返回白色。
// 因此必须从 SCREEN_TEXTURE / SCREEN_UV 读取组内容（与内置 shader 一致的做法）。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

// ===== 进度控制 =====
// 由脚本/动画驱动的擦除进度：0 = 完全隐藏，1 = 完全显示。
// 初始应为 0，按钮按下后让脚本 tween 到 1。
uniform float progress : hint_range(0.0, 1.0) = 0.0;

// 时长/边缘柔化
uniform float duration : hint_range(0.1, 10.0) = 1.5;
uniform float feather : hint_range(0.0, 0.2) = 0.02;

// 调试预览开关：勾选后在编辑器中忽略 progress，用 TIME 自动播一遍。
// 正常使用保持 false，由脚本驱动 progress。
uniform bool auto_play = false;

void fragment() {
    // 1. 从后缓冲取到子节点画好的内容（后缓冲是预乘 alpha，先还原成直通 alpha）
    vec4 tex_color = texture(screen_texture, SCREEN_UV);
    if (tex_color.a > 0.0001) {
        tex_color.rgb /= tex_color.a;
    }

    // 2. 取进度
    float p = clamp(progress, 0.0, 1.0);
    if (auto_play) {
        p = clamp(TIME / duration, 0.0, 1.0);
    }

    // 3. 遮罩：UV.x 从左到右擦除（若 CanvasGroup 并非内容贴满自身范围，
    //    擦除范围会偏，那就需要改成 SubViewport + TextureRect 结构）
    float mask = 1.0 - smoothstep(p - feather, p + feather, UV.x);

    // 4. 输出：内容乘遮罩（同时乘到 alpha 上实现渐显）
    COLOR *= tex_color;
    COLOR.a *= mask;
}
