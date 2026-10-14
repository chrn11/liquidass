# 同进程局部按钮材质 view（隔离候选）

## 边界 / 输入

这是一套显式 per-view API，不是全 `UIButton` hook：宿主自己挑一个 44×44pt return control、保留其 `UIControl` tracking/actions/hitTest/尺寸原样，并把 `LGLocalButtonMaterialView` 作为非交互 sibling 放在原前景下面。view 不带 target/action，不改宿主层级以外的控件语义。初始化/提交默认不能激活：`LG_LOCAL_BUTTON_RENDERER_COMPILED` 在头文件默认 `0`；调用方还必须显式传 `explicitOptIn:YES` 并在每次提交传 `enabled:YES`。

调用方必须提供 `LGLocalButtonSourceProvider`。它只可返回它自己进程拥有、可读、实际尺寸匹配的 Metal texture 和按值的 `LGLocalButtonSourceContract`；本 renderer 不截图、不遍历/绘制 window、不调用 `renderInContext`、不读屏幕或其它 App。合同要求：同一个 owner-space 44×44pt source/target crop、实际 W/H/pointScale/pixelFormat/alpha/mask、非零进程内 nonsecret owner instance token、owner/frame/target-geometry generations、单调时间戳、背景-only 且明确排除目标前景。provider 必须实现 `isOwnerInstanceAlive:generation:`；owner 释放、代际变化、帧回退/过期（>100ms）、坐标/格式/掩码/透明语义不匹配时本 view 隐藏自身并返回失败，宿主原 CA/current/native 继续可见。不得用 token 表示跨进程身份。

`liveAppOwnedTexture` 只表示宿主 App 自己及时提供的局部纹理，不表示系统实时背景。`staticAsset`、`declaredSyntheticColorSource` 只有 `allowApproximateSource:YES` 才能显式用作近似；`isApproximateSource` 会报告，`isSystemLiveBackdrop` 永远为 `NO`。色彩图/静态图不能伪装成 CA/系统采样。当前没有随代码提供的系统源 provider，因此不改变产品默认 return button。

## 调用与回退

```objc
LGLocalButtonMaterialView *local = [[LGLocalButtonMaterialView alloc]
    initWithFrame:returnButton.frame
    targetView:returnButton
    sourceProvider:appOwnedProvider
    allowApproximateSource:NO
    explicitOptIn:(LG_LOCAL_BUTTON_RENDERER_COMPILED && userOptIn)];
if (!local) {
    // 保留现存 CA/current/native path；不降级造色图。
    return;
}
[container insertSubview:local belowSubview:returnButton]; // 前景原样保留

// 每次宿主已有的状态/布局/源更新时，在主线程复制同一个 state；不另造状态机。
LGLocalButtonRendererResult r = [local submitOpticalState:buttonOpticalState
                                                  enabled:featureEnabled];
if (r != LGLocalButtonRendererReadyForNextDraw) {
    [local invalidateLocalSource];
    // 不隐藏、不移除现存 CA/current/native 路径；继续让它处理。
}
```

`ReadyForNextDraw` 只表示本次 source 与 pipeline 通过检查，不表示 drawable 已呈现或视觉达标；本实现从不隐藏/替换旧 renderer。`lastCommandBufferSucceeded` / `lastCompletedSubmissionSerial`只记录最新提交的真实command buffer完成，不是屏幕present证明。source provider 返回 `nil` 时是 `SourceUnavailable`，local view 自身透明/隐藏，宿主直接继续原路径。调用方要在目标 detached/disabled/不活跃/取消时提交当前 state 或 `invalidateLocalSource`；draw 再次检查 freshness/owner。没有常驻display link或轮询：每次合法提交仅有一个一次性源过期timer，100ms到期即隐藏/释放旧帧，不等下一次绘制才发现过期；最多3条同实例command buffer in-flight，完成回调后释放该帧引用。

源必须设置`immutableUntilFrameReleased`，不得在帧和在途GPU持有期间改写同一个纹理；可用frame initializer的`leaseEnded:`回调（线程安全、不能捕获frame本身）归还provider缓冲槽。相同frame generation不得重新打时间戳或换纹理；owner generation不能倒退。只接收与build14/15相同BGRA8Unorm_sRGB域（81），还要显式声明Metal采样结果linear + premultiplied，格式相同并不证明该语义。Opaque源易于满足；未证实的straight-alpha/HDR/P3语义不自动放行。draw混合使用One/OneMinusSourceAlpha，避免重复乘alpha；实际view使用22pt圆形layer裁剪，不能画出方形源片。

材质库来自冻结 LiquidAss `LiquidAssBackboardd/Tweak.mm::kShaderSrc` 将现有 `LGButtonOpticsFormula.inc` 实际注入后的完整 MSL。生成器重建后 SHA256 必须为 `f21b394471fd9d3983502441852e3be0664eec7614a7bcd7652939077c06a72b`；208-byte Uniforms 字段/偏移有 static assert。按同进程 `LGButtonOpticalState` 快照直接取共享9档压力，`LGLocalButtonBuildUniforms`直接取本体`PrefsButtonCandidate`的108厚度/2折射/1.6折射率/16pt边宽，再调用`LGButtonPressureMaterial`写本次uniform；不另造局部preview数值。共享光学函数实际收到厚度/折射变化，不是 view scale/alpha 动画。shader 没有触点 XY uniform，故 touchXY 消费为 `NOT_IMPLEMENTED`，不伪造触点高光。当前 CA atom consumer/runtime 仍 NOT_RUN，与该本地 API 无关。

## 复核

`clang -std=c11 -Wall -Wextra scripts/test_local_button_source_contract.c -lm`：纯C契约/生命周期/几何/alpha/format/mask/近似来源/默认gate/208-byte ABI/压力隔离测试。`python3 scripts/generate_local_button_shader.py` 从冻结 kShaderSrc 与 `.inc` 生成同源只读header（patch 不重复携带此生成产物）；应用 patch 后先运行它，再编译 `.mm`。`python3 scripts/test_local_button_renderer.py`：核对114冻结源hash、实际注入后的 shader SHA 及调用链。新 `.mm` 需由整合者在 iOS16.5 SDK 下显式加入编译、`Metal`/`MetalKit` framework，并在测试编译命令加 `-DLG_LOCAL_BUTTON_RENDERER_COMPILED=1`；原 Makefile 未改。这里不做 package/CI/签名/安装/设备运行。
