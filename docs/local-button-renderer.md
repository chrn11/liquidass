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

本候选在原来208-byte Uniforms 前缀后，追加16-byte的 contact ABI：`buttonContactCenter` offset 208、压力216、local-source gate220，总224 bytes；CPU/Metal各字段和实际 offset/size均有断言。除本地view的显式opt-in、有效状态接入，其余这些字段默认全零；Backboard原208-byte Uniforms/宏和legacy shader分支未改。共享 `LGButtonOpticsFormula.inc` 新增 `LGButtonOpticsEvaluateWithContact`，旧 `LGButtonOpticsEvaluate` 仍是exact no-contact wrapper；触点在44pt source point域使用7pt有限支撑凹陷、1.5pt smooth edge fade、随pressure线性变化的高度及解析梯度，并把法线送回已有Snell/源平面UV/色光流程；不覆色、不加贴片、不变IOR/source crop/mask/base场。contact输入均限幅/finite，sourceUV/环境UV沿用半texel及原位移cap。新生成MSL hash为 `b2cf63d726009e0dd51a4db2337b57d8a24ea27fa16dbe039629cdea158ff7e7`；旧208-byte shader fixture hash `f21b394471fd9d3983502441852e3be0664eec7614a7bcd7652939077c06a72b`被macOS Metal对照测试实际编译。idle/旧pressure-only synthetic/no valid point/default-off不发触点；press/drag有效point来自同一state，release/cancel保留last point直至压力归零，禁用/失效/generation reset即时清零。此改动只让现有同进程 `submitOpticalState` → `buildUniforms` → fragment路径可消费真实state；未接UI source provider的系统返回按钮仍not ready，未宣称Backboard/CA触点或系统背景接入。

## 可复现验证

`python3 scripts/test_button_contact_source.py`会重建生成header与raw MSL，验证raw shader内formula marker、函数定义在真实contact call之前、调用参数/ABI/hash一致；`scripts/test_button_contact_optics.c`覆盖44pt circle/capsule、0.5/1/1.5/2/3/4 source scales、不同侧与拖移、释放/cancel/disabled、idle synthetic、outside identity、finite、UV半texel/cap、height/normal有限差分、一/多实例隔离及0厚度/IOR1/scale0/zero-contact exact legacy。`scripts/test_button_contact_metal.mm`用确实的Metal fragment pipeline/render target GPU readback对照旧208-byte shader与224-byte no-contact结果逐byte相等、zero-pressure identity和左右/移动接触像素差；不是CPU绘图。`bash scripts/test_button_contact_macos.sh`仅允许Darwin，运行Python结构测试、C数值与历史合同测试、Apple Metal编译/运行及iOS SDK语法门；GitHub Actions新增macOS `contact-tests` job并作为package build前置。当前在iSH只跑过Python源码/生成器/静态marker测试；C、clang、Metal SDK/GPU、iOS SDK及真实UIKit/provider/runtime均`NOT_RUN`，由parent后续GitHub macOS CI及原获准App验证。
